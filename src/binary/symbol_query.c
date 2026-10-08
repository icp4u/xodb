#include "symbol_query.h"
#include <elf.h>
#include <stdlib.h>
#include <string.h>

#define PAGE 16384
#define STRING_PAGES 64
struct page { uint64_t offset, age; size_t size, done; int used; unsigned char bytes[PAGE]; };
struct wanted { char name[XBS_NAME_BYTES]; uint64_t hash; struct xbs_symbol result; };
struct xbs_query {
    struct xbo_object *object;
    struct page entries, strings[STRING_PAGES];
    uint64_t age;
    unsigned string_hint;
    struct wanted *wanted;
    size_t count, longest;
    uint32_t section;
    const struct xbo_section *table, *names;
    uint64_t position, symbols;
    unsigned char record[24];
    size_t record_done, name_length;
    char name[XBS_NAME_BYTES];
    uint32_t name_offset;
    int pending, name_done, name_too_long, complete;
    enum xbo_status failure;
    const char *error;
};
static uint64_t hash(const char *s) {
    uint64_t h = UINT64_C(14695981039346656037);
    while (*s) { h ^= (unsigned char)*s++; h *= UINT64_C(1099511628211); }
    return h;
}
static uint64_t number(const struct xbs_query *q, const unsigned char *p, unsigned n) {
    uint64_t v = 0;
    int little = xbo_little_endian(q->object);
    for (unsigned i = 0; i < n; ++i) v = v << 8 | p[little ? n - i - 1 : i];
    return v;
}
static enum xbo_status fail(struct xbs_query *q, enum xbo_status status, const char *why) {
    q->failure = status; q->error = why; return status;
}
static enum xbo_status tick(struct xbo_budget *budget) {
    if (!budget) return XBO_LIMIT;
    if (budget->cancelled && budget->cancelled(budget->context)) return XBO_CANCELLED;
    if (budget->deadline_ns && xbo_now_ns() >= budget->deadline_ns) return XBO_AGAIN;
    return XBO_OK;
}
static enum xbo_status page(struct xbs_query *q, struct page *p, uint64_t offset,
                           struct xbo_budget *budget) {
    const struct xbo_identity *identity = xbo_identity(q->object);
    if (!identity || offset >= identity->size) return XBO_MALFORMED;
    uint64_t base = offset - offset % PAGE;
    if (!p->used || p->offset != base) {
        p->used = 1; p->offset = base; p->done = 0;
        p->size = identity->size - base < PAGE ? (size_t)(identity->size - base) : PAGE;
    }
    if (p->done == p->size) return XBO_OK;
    return xbo_read(q->object, base, p->bytes, p->size, &p->done, budget);
}
static enum xbo_status record(struct xbs_query *q, struct xbo_budget *budget) {
    while (q->record_done < q->table->entry_size) {
        uint64_t offset = q->table->offset + q->position + q->record_done;
        enum xbo_status status = page(q, &q->entries, offset, budget);
        if (status != XBO_OK) return status;
        size_t at = (size_t)(offset - q->entries.offset), n = q->entries.size - at;
        if (n > q->table->entry_size - q->record_done) n = (size_t)q->table->entry_size - q->record_done;
        memcpy(q->record + q->record_done, q->entries.bytes + at, n);
        q->record_done += n;
    }
    if (!q->pending) {
        q->name_offset = (uint32_t)number(q, q->record, 4);
        q->name_length = 0; q->name_done = q->name_too_long = 0; q->pending = 1;
    }
    return XBO_OK;
}
static struct page *string_page(struct xbs_query *q, uint64_t offset) {
    uint64_t base = offset - offset % PAGE;
    unsigned selected = q->string_hint;
    if (!q->strings[selected].used || q->strings[selected].offset != base) {
        unsigned oldest = 0;
        for (unsigned i = 0; i < STRING_PAGES; ++i) {
            if (q->strings[i].used && q->strings[i].offset == base) { selected = i; goto found; }
            if (!q->strings[i].used || q->strings[i].age < q->strings[oldest].age) oldest = i;
        }
        selected = oldest;
    }
found:
    q->string_hint = selected;
    q->strings[selected].age = ++q->age;
    return &q->strings[selected];
}
static enum xbo_status name(struct xbs_query *q, struct xbo_budget *budget) {
    while (!q->name_done) {
        uint64_t at = (uint64_t)q->name_offset + q->name_length;
        if (at >= q->names->size) return fail(q, XBO_MALFORMED, "SymbolNameExtent");
        uint64_t offset = q->names->offset + at;
        struct page *strings = string_page(q, offset);
        enum xbo_status status = page(q, strings, offset, budget);
        if (status != XBO_OK) return status;
        unsigned char byte = strings->bytes[offset - strings->offset];
        if (!byte) { q->name[q->name_length] = 0; q->name_done = 1; }
        else if (q->name_length == q->longest) {
            /* A longer name cannot equal any requested one. Its remaining
             * bytes are not needed to establish that non-match. */
            q->name_too_long = q->name_done = 1;
        } else q->name[q->name_length++] = (char)byte;
    }
    return XBO_OK;
}
static enum xbo_status match(struct xbs_query *q) {
    if (q->name_too_long) return XBO_OK;
    unsigned wide = xbo_address_size(q->object) == 8;
    unsigned info = q->record[wide ? 4 : 12];
    uint32_t section = (uint32_t)number(q, q->record + (wide ? 6 : 14), 2);
    if (section == SHN_UNDEF || section == SHN_ABS || section == SHN_COMMON) return XBO_OK;
    uint64_t h = hash(q->name);
    for (size_t i = 0; i < q->count; ++i) {
        struct wanted *w = &q->wanted[i];
        if (h != w->hash || strcmp(w->name, q->name)) continue;
        if (section == SHN_XINDEX) return fail(q, XBO_LIMIT, "SymbolExtendedIndexUnsupported");
        if (section >= SHN_LORESERVE || section >= xbo_section_count(q->object))
            return fail(q, XBO_MALFORMED, "SymbolSectionExtent");
        struct xbs_symbol symbol = {.address = number(q, q->record + (wide ? 8 : 4), wide ? 8 : 4),
            .size = number(q, q->record + (wide ? 16 : 8), wide ? 8 : 4),
            .section = section, .type = ELF64_ST_TYPE(info), .binding = ELF64_ST_BIND(info), .present = 1};
        const struct xbo_section *defined = xbo_section(q->object, section);
        if (!(defined->flags & SHF_ALLOC)) continue;
        if (symbol.type == STT_TLS || (defined->flags & SHF_TLS))
            return fail(q, XBO_LIMIT, "SymbolTlsUnsupported");
        if (symbol.address < defined->address || symbol.address - defined->address > defined->size ||
            symbol.size > defined->size - (symbol.address - defined->address))
            return fail(q, XBO_MALFORMED, "SymbolAddressExtent");
        if (w->result.present && (w->result.address != symbol.address || w->result.size != symbol.size ||
            w->result.section != symbol.section || w->result.type != symbol.type))
            return fail(q, XBO_MALFORMED, "SymbolDefinitionConflict");
        w->result = symbol;
    }
    return XBO_OK;
}
enum xbo_status xbs_create(struct xbo_object *object, const char *const *names,
                           size_t count, struct xbs_query **out) {
    if (!out) return XBO_MALFORMED;
    *out = NULL;
    if (!object || !xbo_identity(object) || !names || !count) return XBO_MALFORMED;
    if (count > XBS_NAMES) return XBO_LIMIT;
    struct xbs_query *q = calloc(1, sizeof *q);
    if (!q) return XBO_NOMEM;
    q->wanted = calloc(count, sizeof *q->wanted);
    if (!q->wanted) { free(q); return XBO_NOMEM; }
    q->object = object; q->count = count;
    for (size_t i = 0; i < count; ++i) {
        if (!names[i]) { xbs_destroy(q); return XBO_MALFORMED; }
        size_t n = 0;
        while (n < XBS_NAME_BYTES && names[i][n]) ++n;
        if (!n || n == XBS_NAME_BYTES) { xbs_destroy(q); return XBO_LIMIT; }
        if (n > q->longest) q->longest = n;
        memcpy(q->wanted[i].name, names[i], n + 1);
        q->wanted[i].hash = hash(names[i]);
    }
    *out = q; return XBO_OK;
}
void xbs_destroy(struct xbs_query *q) {
    if (q) { free(q->wanted); free(q); }
}
enum xbo_status xbs_step(struct xbs_query *q, struct xbo_budget *budget, uint64_t work) {
    if (!q) return XBO_MALFORMED;
    if (q->failure) return q->failure;
    enum xbo_status status = xbo_validate(q->object, budget);
    if (status != XBO_OK) goto done;
    while (q->section < xbo_section_count(q->object)) {
        status = tick(budget);
        if (status != XBO_OK) goto done;
        if (!work--) return XBO_AGAIN;
        if (!q->table) {
            const struct xbo_section *section = xbo_section(q->object, q->section);
            if (section->type != SHT_SYMTAB && section->type != SHT_DYNSYM) { ++q->section; continue; }
            unsigned size = xbo_address_size(q->object) == 8 ? 24 : 16;
            if (section->flags & SHF_COMPRESSED) return fail(q, XBO_LIMIT, "SymbolCompressionUnsupported");
            if (section->entry_size != size || section->size % size || section->link >= xbo_section_count(q->object))
                return fail(q, XBO_MALFORMED, "SymbolTableExtent");
            q->names = xbo_section(q->object, section->link);
            if (q->names->type != SHT_STRTAB) return fail(q, XBO_MALFORMED, "SymbolStringTableType");
            if (q->names->flags & SHF_COMPRESSED) return fail(q, XBO_LIMIT, "SymbolCompressionUnsupported");
            q->table = section; q->position = 0;
        }
        if (q->position == q->table->size) { q->table = NULL; ++q->section; continue; }
        status = record(q, budget);
        if (status != XBO_OK) goto done;
        status = name(q, budget);
        if (status != XBO_OK) goto done;
        status = match(q);
        if (status != XBO_OK) goto done;
        ++q->symbols; q->position += q->table->entry_size;
        q->record_done = 0; q->pending = 0;
    }
    status = xbo_validate(q->object, budget);
    if (status == XBO_OK) q->complete = 1;
done:
    if (status != XBO_OK && status != XBO_AGAIN && status != XBO_CANCELLED)
        return fail(q, status, q->error ? q->error : status == XBO_CHANGED ? "SymbolFileChanged" : "SymbolQueryUnavailable");
    return status;
}
enum xbo_status xbs_result(const struct xbs_query *q, size_t index, struct xbs_symbol *out) {
    if (!out) return XBO_MALFORMED;
    memset(out, 0, sizeof *out);
    if (!q || index >= q->count) return XBO_MALFORMED;
    if (q->failure) return q->failure;
    if (!q->complete) return XBO_AGAIN;
    *out = q->wanted[index].result;
    return out->present ? XBO_OK : XBO_NOT_FOUND;
}
void xbs_progress(const struct xbs_query *q, struct xbs_progress *out) {
    if (!out) return;
    memset(out, 0, sizeof *out);
    if (!q) return;
    out->symbols = q->symbols; out->sections = q->section;
    out->memory_bytes = sizeof *q + q->count * sizeof *q->wanted;
    out->complete = q->complete && !q->failure;
}
const char *xbs_error(const struct xbs_query *q) { return q ? q->error : "SymbolQueryUnavailable"; }
