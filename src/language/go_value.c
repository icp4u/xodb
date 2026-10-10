#include "go_value_internal.h"
#include <string.h>
/* Go 1.27.1: internal/abi/{type,iface}.go, runtime/{type,chan,runtime2}.go.
 * All field offsets, sizes and interpreted enum values come from DWARF. */
int xgv_read_memory(struct xgo_reader *r, uint64_t at, void *out, size_t n) {
    if (r->error) return 0;
    if (!r->read || !at || n > UINT64_MAX - at) { r->error = "GoValueAddressInvalid"; return 0; }
    if (r->reads >= XGV_READ_LIMIT || r->bytes > XGV_BYTE_LIMIT || n > XGV_BYTE_LIMIT - r->bytes) {
        r->error = "GoValueReadLimit"; return 0;
    }
    ++r->reads; r->bytes += n;
    if (r->read(r->context, at, out, n)) { r->error = "GoValueUnreadable"; return 0; }
    return 1;
}
static uint64_t field(const struct xgv_layout *l, const uint8_t *b, unsigned f) {
    uint64_t n = 0;
    for (unsigned i = 0; i < l->fields[f].size; ++i) n |= (uint64_t)b[l->fields[f].offset + i] << (8 * i);
    return n;
}
static const char *layout(const struct xgv_layout *l) {
    if (!l || !l->build_id_len || l->build_id_len > sizeof l->build_id) return "GoValueLayoutInvalid";
    for (unsigned t = 0; t < XGV_TYPE_COUNT; ++t)
        if (!l->sizes[t] || l->sizes[t] > XGV_RECORD) return "GoValueLayoutInvalid";
#define XGV_FIELD(key, owner, path, kind, width) \
    if (l->fields[XGV_##key].size != width || l->fields[XGV_##key].offset > l->sizes[XGV_T_##owner] || \
        width > l->sizes[XGV_T_##owner] - l->fields[XGV_##key].offset) return "GoValueLayoutInvalid";
#include "go_value_fields.inc"
#undef XGV_FIELD
#define XGV_CONSTANT(key, name, value) if (l->constants[XGV_C_##key] != value) return "GoValueLayoutInvalid";
#include "go_value_constants.inc"
#undef XGV_CONSTANT
    return NULL;
}
static int record(const struct xgv_layout *l, struct xgo_reader *r, uint64_t at, unsigned t, uint8_t *b) {
    return xgv_read_memory(r, at, b, l->sizes[t]);
}
static const char *type_read(const struct xgv_layout *l, struct xgo_reader *r, uint64_t module, uint64_t address, int name_required, struct xgv_type_info *out) {
    uint8_t b[XGV_RECORD]; uint64_t seen[64], lo = 0, hi = 0; unsigned count = 0;
    if (!address) return "GoTypeAddressInvalid";
    while (module) {
        if (count == 64) return "GoTypeModuleLimit";
        for (unsigned i = 0; i < count; ++i) if (seen[i] == module) return "GoTypeModuleCycle";
        seen[count++] = module;
        if (!record(l, r, module, XGV_T_MODULE, b)) return r->error;
        lo = field(l, b, XGV_MD_TYPES); hi = field(l, b, XGV_MD_ETYPES);
        if (!lo || hi <= lo) return "GoTypeModuleInvalid";
        if (address >= lo && address < hi) break;
        module = field(l, b, XGV_MD_NEXT);
    }
    if (!module || l->sizes[XGV_T_TYPE] > hi - address) return "GoRuntimeTypeUnmapped";
    if (!record(l, r, address, XGV_T_TYPE, b)) return r->error;
    out->section_start = lo; out->section_end = hi;
    out->address = address; out->size = field(l, b, XGV_T_SIZE);
    out->pointer_bytes = field(l, b, XGV_T_PTRBYTES); out->hash = (uint32_t)field(l, b, XGV_T_HASH);
    out->kind = (uint8_t)field(l, b, XGV_T_KIND);
    uint64_t flags = field(l, b, XGV_T_FLAGS), align = field(l, b, XGV_T_ALIGN), fa = field(l, b, XGV_T_FIELDALIGN);
    if (!out->kind || out->kind > l->constants[XGV_C_UNSAFE_POINTER] || out->size > INT64_MAX ||
        out->pointer_bytes > out->size || !align || align > 8 || (align & (align - 1)) ||
        !fa || fa > 8 || (fa & (fa - 1)) || out->size % align) return "GoRuntimeTypeInvalid";
    out->direct = (flags & l->constants[XGV_C_DIRECT]) != 0;
    if (out->direct != (out->size == 8 && out->pointer_bytes == 8)) return "GoInterfaceStorageMismatch";
    if (!name_required) return NULL;
    uint64_t name = field(l, b, XGV_T_NAME);
    /* Negative name offsets live in runtime's reflect map, not module.types. */
    if (!name || name > INT32_MAX || name >= hi - lo) return "GoTypeNameUnmapped";
    name += lo;
    /* abi.Name: flags byte followed by an unsigned varint length. */
    uint64_t length = 0; unsigned i;
    for (i = 0; i < 5; ++i) {
        uint8_t byte;
        if (name >= hi - 1 || i >= hi - name - 1) return "GoTypeNameInvalid";
        if (!xgv_read_memory(r, name + 1 + i, &byte, 1)) return r->error;
        length |= (uint64_t)(byte & 127) << (7 * i);
        if (!(byte & 128)) break;
    }
    if (i == 5 || !length || length > hi - name - 2 - i) return "GoTypeNameInvalid";
    if (length >= sizeof out->name) return "GoTypeNameLimit";
    if (!xgv_read_memory(r, name + 2 + i, out->name, (size_t)length)) return r->error;
    if (memchr(out->name, 0, (size_t)length)) return "GoTypeNameInvalid";
    out->name[length] = 0;
    if (flags & l->constants[XGV_C_EXTRA_STAR]) {
        if (length < 2 || out->name[0] != '*') return "GoTypeNameInvalid";
        memmove(out->name, out->name + 1, (size_t)length);
    }
    return NULL;
}
void xgv_type_read(const struct xgv_layout *l, struct xgo_reader *r, uint64_t module, uint64_t at, struct xgv_type_info *out) {
    memset(out, 0, sizeof *out);
    out->reason = layout(l);
    if (!out->reason) out->reason = type_read(l, r, module, at, 1, out);
}
void xgv_type_header_read(const struct xgv_layout *l, struct xgo_reader *r, uint64_t module, uint64_t at, struct xgv_type_info *out) {
    memset(out, 0, sizeof *out);
    out->reason = layout(l);
    if (!out->reason) out->reason = type_read(l, r, module, at, 0, out);
}
static void interface_bytes(const struct xgv_layout *l, struct xgo_reader *r, uint64_t module, const uint8_t *original, int nonempty, struct xgv_interface *out) {
    uint8_t b[XGV_RECORD];
    uint64_t type = field(l, original, nonempty ? XGV_IF_TAB : XGV_EF_TYPE);
    out->data = field(l, original, nonempty ? XGV_IF_DATA : XGV_EF_DATA);
    if (!type) {
        if (out->data) out->reason = "GoInterfaceNilMismatch";
        else out->is_nil = 1;
        return;
    }
    uint64_t hash = 0;
    if (nonempty) {
        if (!record(l, r, type, XGV_T_ITAB, b)) { out->reason = r->error; return; }
        struct xgv_type_info inter = {0};
        const char *why = type_read(l, r, module, field(l, b, XGV_IT_INTER), 1, &inter);
        if (why) { out->reason = why; return; }
        if (inter.kind != l->constants[XGV_C_INTERFACE] || !field(l, b, XGV_IT_FUN)) {
            out->reason = "GoInterfaceItabInvalid"; return;
        }
        hash = field(l, b, XGV_IT_HASH); type = field(l, b, XGV_IT_TYPE);
    }
    out->type.reason = type_read(l, r, module, type, 1, &out->type);
    if (out->type.reason) { out->reason = out->type.reason; return; }
    /* Runtime-created itabs deliberately store zero instead of Type.Hash.
     * This first profile refuses uncorroborated itabs, rather than confusing
     * that sentinel with a copied type hash (runtime/iface.go:getitab). */
    if (nonempty && hash != out->type.hash) {
        out->reason = hash ? "GoInterfaceHashMismatch" : "GoInterfaceHashUnproved"; return;
    }
    if (out->type.kind == l->constants[XGV_C_INTERFACE]) { out->reason = "GoInterfaceDynamicTypeInvalid"; return; }
    if (!out->type.direct && !out->data) { out->reason = "GoInterfaceDataInvalid"; return; }
    out->value_address = out->type.direct ? 0 : out->data;
}
void xgv_interface_from_bytes(const struct xgv_layout *l, struct xgo_reader *r, uint64_t module, const void *bytes, size_t n, int nonempty, struct xgv_interface *out) {
    memset(out, 0, sizeof *out);
    if ((out->reason = layout(l))) return;
    if (!bytes || n != l->sizes[nonempty ? XGV_T_IFACE : XGV_T_EFACE]) { out->reason = "GoInterfaceBytesInvalid"; return; }
    interface_bytes(l,r,module,bytes,nonempty,out);
}
void xgv_interface_read(const struct xgv_layout *l, struct xgo_reader *r, uint64_t module, uint64_t at, int nonempty, struct xgv_interface *out) {
    memset(out, 0, sizeof *out);
    if ((out->reason = layout(l))) return;
    uint8_t original[XGV_RECORD], after[XGV_RECORD];
    unsigned t = nonempty ? XGV_T_IFACE : XGV_T_EFACE;
    if (!record(l,r,at,t,original)) { out->reason=r->error; return; }
    interface_bytes(l,r,module,original,nonempty,out);
    if (out->reason) return;
    if (!out->is_nil && out->type.direct) out->value_address=at+l->fields[nonempty ? XGV_IF_DATA : XGV_EF_DATA].offset;
    if (!record(l,r,at,t,after)) out->reason=r->error;
    else if (memcmp(original,after,l->sizes[t])) out->reason="GoValueChanged";
    if (out->reason) out->value_address=0;
}
static const char *queue(const struct xgv_layout *l, struct xgo_reader *r, uint64_t chan, uint64_t first, uint64_t last,
                         uint64_t *seen, unsigned *seen_count, uint32_t *entries, uint32_t *selects) {
    if (!first != !last) return "GoChannelQueueInvalid";
    uint64_t prev = 0;
    while (first) {
        for (unsigned i = 0; i < *seen_count; ++i) if (seen[i] == first) return "GoChannelQueueCycle";
        if (*entries == XGV_WAITERS) return "GoChannelWaitLimit";
        seen[(*seen_count)++] = first;
        uint8_t b[XGV_RECORD];
        if (!record(l, r, first, XGV_T_SUDOG, b)) return r->error;
        uint64_t next = field(l, b, XGV_SD_NEXT), select = field(l, b, XGV_SD_SELECT);
        if (field(l, b, XGV_SD_PREV) != prev || field(l, b, XGV_SD_CHAN) != chan || !field(l, b, XGV_SD_G) || select > 1 ||
            (!next && first != last) || (next && first == last)) return "GoChannelQueueInvalid";
        ++*entries; *selects += (uint32_t)select;
        prev = first; first = next;
    }
    return NULL;
}
void xgv_channel_read(const struct xgv_layout *l, struct xgo_reader *r, uint64_t module, uint64_t at, struct xgv_channel *out) {
    memset(out, 0, sizeof *out);
    if ((out->reason = layout(l))) return;
    if (!at) { out->is_nil = 1; out->header_valid = 1; out->waits_complete = 1; return; }
    uint8_t b[XGV_RECORD], after[XGV_RECORD];
    if (!record(l, r, at, XGV_T_CHAN, b)) { out->reason = r->error; return; }
    if (field(l, b, XGV_CH_TIMER)) { out->reason = "GoChannelTimerUnproved"; return; }
    if (field(l, b, XGV_CH_LOCK)) { out->reason = "GoChannelBusy"; return; }
    uint64_t length = field(l, b, XGV_CH_LEN), cap = field(l, b, XGV_CH_CAP), size = field(l, b, XGV_CH_ELEMSIZE);
    uint64_t send = field(l, b, XGV_CH_SENDX), recv = field(l, b, XGV_CH_RECVX), closed = field(l, b, XGV_CH_CLOSED);
    uint64_t buffer = field(l, b, XGV_CH_BUF);
    if (length > cap || cap > INT64_MAX || closed > 1 || !buffer ||
        (cap ? (send >= cap || recv >= cap || send != (recv + length) % cap) : (send || recv)) ||
        (size && (cap > (UINT64_MAX - buffer) / size))) { out->reason = "GoChannelHeaderInvalid"; return; }
    out->element.reason = type_read(l, r, module, field(l, b, XGV_CH_ELEMTYPE), 1, &out->element);
    if (out->element.reason) { out->reason = out->element.reason; return; }
    if (out->element.size != size) { out->reason = "GoChannelElementMismatch"; return; }
    uint64_t sf = field(l, b, XGV_CH_SEND_FIRST), sl = field(l, b, XGV_CH_SEND_LAST);
    uint64_t rf = field(l, b, XGV_CH_RECV_FIRST), rl = field(l, b, XGV_CH_RECV_LAST);
    /* Stable buffered channels cannot have receivers while nonempty, or
     * senders while nonfull. Closed channels have no queued entries. */
    if ((closed && (sf || rf)) || (cap && ((length && rf) || (length < cap && sf)))) {
        out->reason = "GoChannelQueueInvalid"; return;
    }
    uint64_t seen[2 * XGV_WAITERS]; unsigned seen_count = 0;
    const char *sw = queue(l, r, at, sf, sl, seen, &seen_count, &out->send_entries, &out->select_entries);
    const char *rw = NULL;
    if (!sw || !strcmp(sw, "GoChannelWaitLimit"))
        rw = queue(l, r, at, rf, rl, seen, &seen_count, &out->receive_entries, &out->select_entries);
    out->reason = rw ? rw : sw;
    if (!record(l, r, at, XGV_T_CHAN, after)) out->reason = r->error;
    else if (memcmp(b, after, l->sizes[XGV_T_CHAN])) out->reason = "GoValueChanged";
    if (out->reason && strcmp(out->reason, "GoChannelWaitLimit")) {
        out->send_entries = out->receive_entries = out->select_entries = 0; return;
    }
    out->header_valid = 1; out->waits_complete = out->reason == NULL;
    out->length = length; out->capacity = cap; out->buffer = buffer;
    out->send_index = send; out->receive_index = recv; out->closed = (int)closed;
}
