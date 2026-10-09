#include "go.h"
#include <dwarf.h>
#include <gelf.h>
#include <string.h>
/* Go runtime layout from the image's own DWARF (cmd/link output). Every
 * offset the reader uses is proved here; nothing is hand-written. */
enum kind { SIGNED, UNSIGNED, POINTER };
static const char *const types[] = {
#define XGO_TYPE(key, name) name,
#include "go_types.inc"
#undef XGO_TYPE
};
static const struct { unsigned owner; const char *path; enum kind kind; unsigned width; } fields[] = {
#define XGO_FIELD(key, owner, path, kind, width) {XGO_T_##owner, path, kind, width},
#include "go_fields.inc"
#undef XGO_FIELD
};
static const struct { const char *name; uint64_t value; } constants[] = {
#define XGO_CONSTANT(key, name, value) {name, value},
#include "go_constants.inc"
#undef XGO_CONSTANT
};
struct scan { unsigned work; const char *error; };
static int tick(struct scan *s) {
    if (s->error) return 0;
    if (++s->work > 8000000) { s->error = "GoDwarfWorkLimit"; return 0; }
    return 1;
}
static int ud(Dwarf_Die *d, unsigned code, uint64_t *v) {
    Dwarf_Attribute a; Dwarf_Word word; Dwarf_Sword sword;
    if (!dwarf_attr(d, code, &a)) return 0;
    if (!dwarf_formudata(&a, &word)) { *v = word; return 1; }
    if (!dwarf_formsdata(&a, &sword) && sword >= 0) { *v = (uint64_t)sword; return 1; }
    return 0;
}
static int type(Dwarf_Die *d, Dwarf_Die *out) {
    Dwarf_Attribute a;
    return dwarf_attr(d, DW_AT_type, &a) && dwarf_formref_die(&a, out);
}
static int resolve(Dwarf_Die *d, struct scan *s) {
    for (unsigned n = 0; n < 16 && tick(s); ++n) {
        if (dwarf_tag(d) != DW_TAG_typedef) return dwarf_tag(d) > 0;
        Dwarf_Die next;
        if (!type(d, &next)) { s->error = "GoDwarfMalformed"; return 0; }
        *d = next;
    }
    if (!s->error) s->error = "GoDwarfTypeDepthLimit";
    return 0;
}
static int size(Dwarf_Die *d, uint64_t *out) {
    Dwarf_Word n;
    if (dwarf_tag(d) == DW_TAG_pointer_type) { *out = 8; return 1; }
    if (dwarf_aggregate_size(d, &n) || !n || n > 1 << 20) return 0;
    *out = n; return 1;
}
static int kind(Dwarf_Die *d, enum kind want) {
    uint64_t encoding;
    if (want == POINTER) return dwarf_tag(d) == DW_TAG_pointer_type;
    if (dwarf_tag(d) != DW_TAG_base_type || !ud(d, DW_AT_encoding, &encoding)) return 0;
    return want == SIGNED ? encoding == DW_ATE_signed : encoding == DW_ATE_unsigned;
}
static int member(Dwarf_Die parent, const char *path, struct xgo_field_info *out, Dwarf_Die *leaf, struct scan *s) {
    uint64_t offset = 0;
    for (unsigned depth = 0; depth < 8 && tick(s); ++depth) {
        uint64_t parent_size;
        if (!resolve(&parent, s) || dwarf_tag(&parent) != DW_TAG_structure_type || !size(&parent, &parent_size)) return 0;
        const char *dot = strchr(path, '.');
        size_t len = dot ? (size_t)(dot - path) : strlen(path);
        Dwarf_Die child, selected; uint64_t at = 0; int found = 0;
        int rc = dwarf_child(&parent, &child);
        if (rc < 0) { s->error = "GoDwarfMalformed"; return 0; }
        if (rc > 0) return 0;
        do {
            if (!tick(s)) return 0;
            if (dwarf_tag(&child) != DW_TAG_member) continue;
            const char *name = dwarf_diename(&child);
            if (!name || strlen(name) != len || memcmp(name, path, len)) continue;
            if (found++) { s->error = "GoDwarfAmbiguous"; return 0; }
            if (!ud(&child, DW_AT_data_member_location, &at) || !type(&child, &selected)) { s->error = "GoDwarfMalformed"; return 0; }
        } while ((rc = dwarf_siblingof(&child, &child)) == 0);
        if (rc < 0) { s->error = "GoDwarfMalformed"; return 0; }
        if (!found || !resolve(&selected, s)) return 0;
        uint64_t bytes;
        if (!size(&selected, &bytes) || at > parent_size || bytes > parent_size - at) return 0;
        offset += at;
        if (!dot) {
            if (offset > UINT32_MAX) return 0;
            out->offset = (uint32_t)offset; out->size = (uint32_t)bytes; *leaf = selected; return 1;
        }
        parent = selected; path = dot + 1;
    }
    if (!s->error) s->error = "GoDwarfTypeDepthLimit";
    return 0;
}
static int candidate(Dwarf_Die die, unsigned t, struct xgo_layout *out, struct scan *s) {
    uint64_t bytes;
    if (!resolve(&die, s) || dwarf_tag(&die) != DW_TAG_structure_type || !size(&die, &bytes)) return 0;
    out->sizes[t] = (uint32_t)bytes;
    for (unsigned f = 0; f < XGO_FIELD_COUNT; ++f) {
        if (fields[f].owner != t) continue;
        struct xgo_field_info got; Dwarf_Die leaf;
        if (!member(die, fields[f].path, &got, &leaf, s) || !kind(&leaf, fields[f].kind) || got.size != fields[f].width) return 0;
        out->fields[f] = got;
    }
    return 1;
}
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
const char *xgo_layout_build(Dwarf *dwarf, const uint8_t *id, size_t n, struct xgo_layout *out) {
    memset(out, 0, sizeof *out);
    if (!id || !n || n > sizeof out->build_id) return "GoBuildIdUnavailable";
    if (!dwarf) return "GoDwarfUnavailable";
    uint64_t length;
    if (!info_size(dwarf, &length)) return "GoDwarfMalformed";
    struct scan s = {0};
    uint8_t have[XGO_TYPE_COUNT] = {0}, known[XGO_CONSTANT_COUNT] = {0};
    Dwarf_Off off = 0, next; size_t header;
    for (unsigned cu = 0; off < length; off = next, ++cu) {
        uint8_t width;
        if (cu >= 16384) return "GoDwarfUnitLimit";
        if (dwarf_nextcu(dwarf, off, &next, &header, NULL, &width, NULL) || width != 8 ||
            next <= off || next > length || header >= next - off) return "GoDwarfMalformed";
        Dwarf_Die unit, d;
        if (!dwarf_offdie(dwarf, off + header, &unit)) return "GoDwarfMalformed";
        int rc = dwarf_child(&unit, &d);
        if (rc < 0) return "GoDwarfMalformed";
        if (rc > 0) continue;
        do {
            if (!tick(&s)) return s.error;
            int tag = dwarf_tag(&d); const char *name = dwarf_diename(&d);
            if (!name) continue;
            if (tag == DW_TAG_constant) {
                for (unsigned i = 0; i < XGO_CONSTANT_COUNT; ++i) {
                    if (strcmp(name, constants[i].name)) continue;
                    uint64_t got;
                    if (!ud(&d, DW_AT_const_value, &got) || got != constants[i].value) return "GoConstantMismatch";
                    out->constants[i] = got; known[i] = 1;
                }
                continue;
            }
            if (tag != DW_TAG_structure_type) continue;
            for (unsigned t = 0; t < XGO_TYPE_COUNT; ++t) {
                if (strcmp(name, types[t])) continue;
                struct xgo_layout got = {0};
                if (!candidate(d, t, &got, &s)) {
                    if (s.error) return s.error;
                    return "GoDwarfTypesUnsupported";
                }
                if (have[t] && (out->sizes[t] != got.sizes[t])) return "GoDwarfAmbiguous";
                out->sizes[t] = got.sizes[t];
                for (unsigned f = 0; f < XGO_FIELD_COUNT; ++f) {
                    if (fields[f].owner != t) continue;
                    if (have[t] && memcmp(&out->fields[f], &got.fields[f], sizeof got.fields[f])) return "GoDwarfAmbiguous";
                    out->fields[f] = got.fields[f];
                }
                have[t] = 1;
            }
        } while ((rc = dwarf_siblingof(&d, &d)) == 0);
        if (rc < 0) return "GoDwarfMalformed";
    }
    for (unsigned t = 0; t < XGO_TYPE_COUNT; ++t) if (!have[t]) return "GoDwarfTypesUnavailable";
    for (unsigned i = 0; i < XGO_CONSTANT_COUNT; ++i) if (!known[i]) return "GoDwarfConstantsUnavailable";
    if (out->sizes[XGO_T_FTAB] != 8) return "GoDwarfTypesUnsupported";
    memcpy(out->build_id, id, n); out->build_id_len = (uint8_t)n;
    return NULL;
}
