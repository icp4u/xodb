#include "lua.h"
#include <dwarf.h>
#include <gelf.h>
#include <string.h>

enum kind { INTEGER, SIGNED, UNSIGNED, FLOAT, POINTER, ARRAY, AGGREGATE };
static const char *const types[XL_TYPE_COUNT][2] = {
#define XL_TYPE(key, a, b) {a, b},
#include "lua_types.inc"
#undef XL_TYPE
};
static const struct field {
    enum xl_type owner;
    const char *paths[2];
    enum kind kind;
    unsigned widths[2];
} fields[] = {
#define XL_FIELD(key, owner, a, b, kind, wa, wb) {XL_T_##owner, {a, b}, kind, {wa, wb}},
#include "lua_fields.inc"
#undef XL_FIELD
};
struct scan { unsigned work; const char *error; };
static int tick(struct scan *s) {
    if (s->error) return 0;
    if (++s->work > 4000000) { s->error = "LuaDwarfWorkLimit"; return 0; }
    return 1;
}
static int ud(Dwarf_Die *d, unsigned code, uint64_t *v) {
    Dwarf_Attribute a; Dwarf_Word word;
    if (!dwarf_attr(d, code, &a) || dwarf_formudata(&a, &word)) return 0;
    *v = word; return 1;
}
static int type(Dwarf_Die *d, Dwarf_Die *out) {
    Dwarf_Attribute a;
    return dwarf_attr(d, DW_AT_type, &a) && dwarf_formref_die(&a, out);
}
static int resolve(Dwarf_Die *d, struct scan *s) {
    for (unsigned n = 0; n < 16 && tick(s); ++n) {
        int tag = dwarf_tag(d);
        if (tag != DW_TAG_typedef && tag != DW_TAG_const_type && tag != DW_TAG_volatile_type && tag != DW_TAG_restrict_type)
            return tag > 0;
        Dwarf_Die next;
        if (!type(d, &next)) { s->error = "LuaDwarfMalformed"; return 0; }
        *d = next;
    }
    if (!s->error) s->error = "LuaDwarfTypeDepthLimit";
    return 0;
}
static int size(Dwarf_Die *d, uint64_t *out) {
    Dwarf_Word n;
    if (dwarf_aggregate_size(d, &n)) {
        if (dwarf_tag(d) != DW_TAG_pointer_type) return 0;
        Dwarf_Die cu; uint8_t address_size = 0;
        if (!dwarf_diecu(d, &cu, &address_size, NULL)) return 0;
        n = address_size;
    }
    if (!n || n > 65536) return 0;
    *out = n; return 1;
}
static int kind(Dwarf_Die *d, enum kind want) {
    int tag = dwarf_tag(d); uint64_t encoding;
    if (want == POINTER) return tag == DW_TAG_pointer_type;
    if (want == ARRAY) return tag == DW_TAG_array_type;
    if (want == AGGREGATE) return tag == DW_TAG_structure_type || tag == DW_TAG_union_type;
    if (tag != DW_TAG_base_type || !ud(d, DW_AT_encoding, &encoding)) return 0;
    if (want == FLOAT) return encoding == DW_ATE_float;
    int signed_ = encoding == DW_ATE_signed || encoding == DW_ATE_signed_char;
    int unsigned_ = encoding == DW_ATE_unsigned || encoding == DW_ATE_unsigned_char;
    return want == SIGNED ? signed_ : want == UNSIGNED ? unsigned_ : signed_ || unsigned_;
}
static int member(Dwarf_Die parent, const char *path, struct xl_field_info *out,
                  Dwarf_Die *leaf, struct scan *s) {
    uint64_t offset = 0;
    for (unsigned depth = 0; depth < 16 && tick(s); ++depth) {
        if (!resolve(&parent, s)) return 0;
        uint64_t parent_size;
        if (!size(&parent, &parent_size)) return 0;
        int parent_tag = dwarf_tag(&parent);
        if (parent_tag != DW_TAG_structure_type && parent_tag != DW_TAG_union_type) return 0;
        const char *dot = strchr(path, '.'); size_t len = dot ? (size_t)(dot - path) : strlen(path);
        Dwarf_Die child, selected; uint64_t at = 0; int found = 0;
        int rc = dwarf_child(&parent, &child);
        if (rc < 0) { s->error = "LuaDwarfMalformed"; return 0; }
        if (rc > 0) return 0;
        do {
            if (!tick(s)) return 0;
            if (dwarf_tag(&child) != DW_TAG_member) continue;
            const char *name = dwarf_diename(&child);
            if (!name || strlen(name) != len || memcmp(name, path, len)) continue;
            if (found++) { s->error = "LuaDwarfAmbiguous"; return 0; }
            Dwarf_Attribute bit;
            if (dwarf_attr(&child, DW_AT_bit_size, &bit) || dwarf_attr(&child, DW_AT_data_bit_offset, &bit)) return 0;
            if (!ud(&child, DW_AT_data_member_location, &at)) {
                if (parent_tag != DW_TAG_union_type) return 0;
                at = 0;
            }
            if (!type(&child, &selected)) { s->error = "LuaDwarfMalformed"; return 0; }
        } while ((rc = dwarf_siblingof(&child, &child)) == 0);
        if (rc < 0) { s->error = "LuaDwarfMalformed"; return 0; }
        if (!found || !resolve(&selected, s)) return 0;
        uint64_t bytes;
        if (!size(&selected, &bytes) || at > parent_size || bytes > parent_size - at || offset > UINT32_MAX - at) return 0;
        offset += at;
        if (!dot) {
            out->offset = (uint32_t)offset; out->size = (uint32_t)bytes; *leaf = selected; return 1;
        }
        parent = selected; path = dot + 1;
    }
    if (!s->error) s->error = "LuaDwarfTypeDepthLimit";
    return 0;
}
/* libdw may accept a CU length past EOF. Check the actual decompressed
 * section extent before walking; a trailing malformed unit is a refusal. */
static int info_size(Dwarf *dwarf, uint64_t *out) {
    Elf *elf = dwarf_getelf(dwarf); size_t names;
    if (!elf || elf_getshdrstrndx(elf, &names)) return 0;
    Elf_Scn *scn = NULL;
    while ((scn = elf_nextscn(elf, scn))) {
        GElf_Shdr sh;
        if (!gelf_getshdr(scn, &sh)) return 0;
        const char *name = elf_strptr(elf, names, sh.sh_name);
        if (!name) return 0;
        if (strcmp(name, ".debug_info") && strcmp(name, ".zdebug_info")) continue;
        Elf_Data *d = elf_getdata(scn, NULL);
        if (!d || d->d_off || !d->d_size) return 0;
        *out = d->d_size; return 1;
    }
    return 0;
}
static int supported(const uint8_t v[3]) {
    return v && v[0] == 5 && ((v[1] == 2 && v[2] == 4) || (v[1] == 4 && v[2] == 9));
}
const char *xl_layout_check(const struct xl_layout *p, const uint8_t *id, size_t n, const uint8_t v[3]) {
    if (!supported(v) || memcmp(p->version, v, 3)) return "LuaVersionUnsupported";
    if (!id || !n || n > sizeof p->build_id || p->build_id_len != n || memcmp(p->build_id, id, n)) return "LuaBuildIdMismatch";
    return NULL;
}
const char *xl_layout_build(Dwarf *dwarf, const uint8_t *id, size_t n, const uint8_t v[3], struct xl_layout *out) {
    memset(out, 0, sizeof *out);
    if (!supported(v)) return "LuaVersionUnsupported";
    if (!id || !n || n > sizeof out->build_id) return "LuaBuildIdUnavailable";
    if (!dwarf) return "LuaDwarfUnavailable";
    unsigned version = v[1] == 4; struct scan s = {0}; uint8_t have[XL_TYPE_COUNT] = {0};
    uint64_t length;
    if (!info_size(dwarf, &length)) return "LuaDwarfMalformed";
    Dwarf_Off off = 0, next; size_t header;
    for (unsigned cu = 0; off < length; off = next, ++cu) {
        if (cu >= 8192) return "LuaDwarfUnitLimit";
        uint8_t address_size;
        int rc = dwarf_nextcu(dwarf, off, &next, &header, NULL, &address_size, NULL);
        if (rc || address_size != 8 || next <= off || next > length || header >= next - off) return "LuaDwarfMalformed";
        Dwarf_Die unit, d;
        if (!dwarf_offdie(dwarf, off + header, &unit)) return "LuaDwarfMalformed";
        rc = dwarf_child(&unit, &d);
        if (rc < 0) return "LuaDwarfMalformed";
        if (rc > 0) continue;
        do {
            if (!tick(&s)) return s.error;
            int tag = dwarf_tag(&d);
            if (tag != DW_TAG_structure_type && tag != DW_TAG_union_type && tag != DW_TAG_typedef) continue;
            const char *name = dwarf_diename(&d); if (!name) continue;
            for (unsigned t = 0; t < XL_TYPE_COUNT; ++t) {
                if (!types[t][version] || strcmp(name, types[t][version])) continue;
                Dwarf_Die resolved = d;
                if (!resolve(&resolved, &s)) return s.error ? s.error : "LuaDwarfMalformed";
                Dwarf_Attribute attr; bool declared = false;
                if (dwarf_attr(&resolved, DW_AT_declaration, &attr) && !dwarf_formflag(&attr, &declared) && declared) continue;
                uint64_t bytes;
                if (!size(&resolved, &bytes)) return "LuaLayoutUnsupported";
                if (have[t] && out->sizes[t] != bytes) return "LuaDwarfAmbiguous";
                out->sizes[t] = (uint32_t)bytes;
                for (unsigned f = 0; f < XL_FIELD_COUNT; ++f) {
                    const struct field *spec = &fields[f];
                    if (spec->owner != t || !spec->paths[version]) continue;
                    struct xl_field_info got; Dwarf_Die leaf;
                    if (!member(resolved, spec->paths[version], &got, &leaf, &s)) return s.error ? s.error : "LuaLayoutUnsupported";
                    if (!kind(&leaf, spec->kind) || (spec->widths[version] && spec->widths[version] != got.size)) return "LuaLayoutUnsupported";
                    if (f == XL_PROTO_CODE || f == XL_CI_PC) {
                        Dwarf_Die instruction; uint64_t instruction_size;
                        if (!type(&leaf, &instruction) || !resolve(&instruction, &s) ||
                            !size(&instruction, &instruction_size) || instruction_size != 4 ||
                            !kind(&instruction, UNSIGNED)) return s.error ? s.error : "LuaLayoutUnsupported";
                    }
                    if (have[t] && memcmp(&out->fields[f], &got, sizeof got)) return "LuaDwarfAmbiguous";
                    out->fields[f] = got;
                }
                have[t] = 1;
                /* Every collectable representation must share the same
                 * tag byte used by the GC-header check. */
                if (t == XL_T_STRING || t == XL_T_TABLE || t == XL_T_LCLOSURE || t == XL_T_CCLOSURE ||
                    t == XL_T_PROTO || t == XL_T_UPVAL || t == XL_T_UDATA || t == XL_T_STATE) {
                    const char *path = !version && t == XL_T_STRING ? "tsv.tt" : !version && t == XL_T_UDATA ? "uv.tt" : "tt";
                    struct xl_field_info tag_field; Dwarf_Die leaf;
                    if (!member(resolved, path, &tag_field, &leaf, &s) || tag_field.offset != 8 || tag_field.size != 1 ||
                        !kind(&leaf, UNSIGNED)) return s.error ? s.error : "LuaLayoutUnsupported";
                }
            }
        } while ((rc = dwarf_siblingof(&d, &d)) == 0);
        if (rc < 0) return "LuaDwarfMalformed";
    }
    for (unsigned t = 0; t < XL_TYPE_COUNT; ++t)
        if (types[t][version] && !have[t]) return "LuaDwarfTypesUnavailable";
    if (out->sizes[XL_T_VALUE] != 8 || out->sizes[XL_T_TVALUE] > 32 || out->sizes[XL_T_STACK] < out->sizes[XL_T_TVALUE] ||
        out->fields[XL_NODE_VALUE].size != out->sizes[XL_T_TVALUE] || out->fields[XL_STATE_BASE].size != out->sizes[XL_T_CI] ||
        out->fields[XL_CC_UP].size != out->sizes[XL_T_TVALUE] || out->fields[XL_GC_TAG].offset != 8 ||
        out->fields[XL_NUMBER].offset || out->fields[XL_POINTER].offset || out->fields[XL_INTEGER].offset || out->fields[XL_BOOL].offset ||
        (version && (out->fields[XL_STACK_VALUE].offset || out->fields[XL_STACK_VALUE].size != out->sizes[XL_T_TVALUE]))) return "LuaLayoutUnsupported";
    memcpy(out->build_id, id, n); out->build_id_len = (uint8_t)n; memcpy(out->version, v, 3);
    return NULL;
}
