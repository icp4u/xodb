#include "ruby.h"
#include <dwarf.h>
#include <gelf.h>
#include <string.h>
enum kind { INTEGER, SIGNED, UNSIGNED, FLOAT, POINTER, ARRAY, AGGREGATE, BIT4 };
static const char *const types[] = {
#define XRB_TYPE(key, name) name,
#include "ruby_types.inc"
#undef XRB_TYPE
};
static const struct { unsigned owner; const char *path; enum kind kind; unsigned width; } fields[] = {
#define XRB_FIELD(key, owner, path, kind, width) {XRB_T_##owner, path, kind, width},
#include "ruby_fields.inc"
#undef XRB_FIELD
};
static const struct { const char *name; uint64_t value; } constants[] = {
#define XRB_CONSTANT(name, value) {#name, value},
#include "ruby_constants.inc"
#undef XRB_CONSTANT
};
struct scan { unsigned work; const char *error; };
static int tick(struct scan *s) {
    if (s->error) return 0;
    if (++s->work > 4000000) { s->error = "RubyDwarfWorkLimit"; return 0; }
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
        if (!type(d, &next)) { s->error = "RubyDwarfMalformed"; return 0; }
        *d = next;
    }
    if (!s->error) s->error = "RubyDwarfTypeDepthLimit";
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
    if ((want == INTEGER || want == BIT4) && tag == DW_TAG_enumeration_type) return 1;
    if (want == POINTER) return tag == DW_TAG_pointer_type;
    if (want == ARRAY) return tag == DW_TAG_array_type;
    if (want == AGGREGATE) return tag == DW_TAG_structure_type || tag == DW_TAG_union_type;
    if (tag != DW_TAG_base_type || !ud(d, DW_AT_encoding, &encoding)) return 0;
    if (want == FLOAT) return encoding == DW_ATE_float;
    int signed_ = encoding == DW_ATE_signed || encoding == DW_ATE_signed_char;
    int unsigned_ = encoding == DW_ATE_unsigned || encoding == DW_ATE_unsigned_char;
    return want == SIGNED ? signed_ : want == UNSIGNED ? unsigned_ : signed_ || unsigned_;
}
static int member(Dwarf_Die parent, const char *path, struct xrb_field_info *out,
                  Dwarf_Die *leaf, struct scan *s, int bit4) {
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
        if (rc < 0) { s->error = "RubyDwarfMalformed"; return 0; }
        if (rc > 0) return 0;
        do {
            if (!tick(s)) return 0;
            if (dwarf_tag(&child) != DW_TAG_member) continue;
            const char *name = dwarf_diename(&child);
            if (!name || strlen(name) != len || memcmp(name, path, len)) continue;
            if (found++) { s->error = "RubyDwarfAmbiguous"; return 0; }
            Dwarf_Attribute bit;
            if (bit4) {
                uint64_t bits, bit_at;
                /* The supported LP64 little-endian revision stores the method
                 * type in bits 0..3. Prove both offsets rather than guessing a
                 * bitfield ABI from the surrounding byte fields. */
                if (dot || depth || !ud(&child,DW_AT_bit_size,&bits) || bits!=4 ||
                    !ud(&child,DW_AT_data_bit_offset,&bit_at) || bit_at!=0) return 0;
            } else if (dwarf_attr(&child, DW_AT_bit_size, &bit) || dwarf_attr(&child, DW_AT_data_bit_offset, &bit)) return 0;
            if (!ud(&child, DW_AT_data_member_location, &at)) {
                if (parent_tag != DW_TAG_union_type && !bit4) return 0;
                at = 0;
            }
            if (!type(&child, &selected)) { s->error = "RubyDwarfMalformed"; return 0; }
        } while ((rc = dwarf_siblingof(&child, &child)) == 0);
        if (rc < 0) { s->error = "RubyDwarfMalformed"; return 0; }
        if (!found || !resolve(&selected, s)) return 0;
        uint64_t bytes;
        if (!size(&selected, &bytes) || at > parent_size || bytes > parent_size - at || offset > UINT32_MAX - at) return 0;
        offset += at;
        if (!dot) {
            out->offset = (uint32_t)offset; out->size = (uint32_t)bytes; *leaf = selected; return 1;
        }
        parent = selected; path = dot + 1;
    }
    if (!s->error) s->error = "RubyDwarfTypeDepthLimit";
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
static int candidate(Dwarf_Die die, unsigned t, struct xrb_layout *out, struct scan *s) {
    uint64_t bytes;
    if (!resolve(&die, s) || !size(&die, &bytes)) return 0;
    out->sizes[t] = (uint32_t)bytes;
    for (unsigned f = 0; f < XRB_FIELD_COUNT; ++f) {
        if (fields[f].owner != t) continue;
        struct xrb_field_info got; Dwarf_Die leaf;
        if (!member(die, fields[f].path, &got, &leaf, s, fields[f].kind == BIT4) ||
            !kind(&leaf, fields[f].kind) || got.size != fields[f].width) return 0;
        out->fields[f] = got;
    }
    return 1;
}
static int declaration(Dwarf_Die *d) {
    Dwarf_Attribute a; bool value = false;
    return dwarf_attr(d, DW_AT_declaration, &a) && (!dwarf_formflag(&a, &value) ? value : 1);
}
static const char *units(Dwarf *dwarf, uint64_t length, uint8_t owned[8192], struct scan *s) {
    static const char *const names[] = {"ruby_version", "rb_vm_exec", "ruby_global_symbols", "rb_iseq_line_no", "rb_hash_aref", "rb_st_lookup", "rb_hash_start"};
    unsigned counts[sizeof names/sizeof *names] = {0};
    Dwarf_Off off = 0, next; size_t header;
    for (unsigned cu = 0; off < length; off = next, ++cu) {
        uint8_t width;
        if (cu >= 8192) return "RubyDwarfUnitLimit";
        if (dwarf_nextcu(dwarf, off, &next, &header, NULL, &width, NULL) || width != 8 ||
            next <= off || next > length || header >= next-off) return "RubyDwarfMalformed";
        Dwarf_Die unit, d;
        if (!dwarf_offdie(dwarf, off+header, &unit)) return "RubyDwarfMalformed";
        int rc = dwarf_child(&unit, &d);
        if (rc < 0) return "RubyDwarfMalformed";
        if (rc > 0) continue;
        do {
            if (!tick(s)) return s->error;
            int tag = dwarf_tag(&d);
            if (tag != DW_TAG_variable && tag != DW_TAG_subprogram) continue;
            const char *name = dwarf_diename(&d);
            if (!name || declaration(&d)) continue;
            for (unsigned i = 0; i < sizeof names/sizeof *names; ++i) {
                if (strcmp(name, names[i])) continue;
                int defined = (i == 0 || i == 2) ? tag == DW_TAG_variable && dwarf_hasattr(&d, DW_AT_location) :
                    tag == DW_TAG_subprogram && (dwarf_hasattr(&d, DW_AT_low_pc) || dwarf_hasattr(&d, DW_AT_ranges));
                if (!defined) continue;
                if (++counts[i] > 1) return "RubyRuntimeMultiple";
                owned[cu] = 1;
            }
        } while ((rc = dwarf_siblingof(&d, &d)) == 0);
        if (rc < 0) return "RubyDwarfMalformed";
    }
    for (unsigned i = 0; i < sizeof names/sizeof *names; ++i) if (!counts[i]) return "RubyDwarfRuntimeUnavailable";
    return NULL;
}
const char *xrb_layout_build(Dwarf *dwarf, const uint8_t *id, size_t n,
                            const char *version, const char *revision, struct xrb_layout *out) {
    memset(out, 0, sizeof *out);
    if (!version || !revision || strcmp(version, XRB_VERSION) || strcmp(revision, XRB_REVISION)) return "RubyVersionUnsupported";
    if (!id || !n || n > sizeof out->build_id) return "RubyBuildIdUnavailable";
    if (!dwarf) return "RubyDwarfUnavailable";
    uint64_t length;
    if (!info_size(dwarf, &length)) return "RubyDwarfMalformed";
    struct scan s = {0}; uint8_t owned[8192] = {0}, have[XRB_TYPE_COUNT] = {0};
    uint8_t known[sizeof constants / sizeof *constants] = {0};
    const char *error = units(dwarf, length, owned, &s);
    if (error) return error;
    Dwarf_Off off = 0, next; size_t header;
    for (unsigned cu = 0; off < length; off = next, ++cu) {
        if (dwarf_nextcu(dwarf, off, &next, &header, NULL, NULL, NULL) || cu >= 8192) return "RubyDwarfMalformed";
        if (!owned[cu]) continue;
        Dwarf_Die unit, d;
        if (!dwarf_offdie(dwarf, off+header, &unit)) return "RubyDwarfMalformed";
        int rc = dwarf_child(&unit, &d);
        if (rc < 0) return "RubyDwarfMalformed";
        if (rc > 0) continue;
        do {
            if (!tick(&s)) return s.error;
            int tag = dwarf_tag(&d); const char *name = dwarf_diename(&d);
            if (tag == DW_TAG_subprogram && name && !declaration(&d) &&
                !strcmp(name,"get_insn_info_succinct_bitvector") &&
                (dwarf_hasattr(&d,DW_AT_low_pc) || dwarf_hasattr(&d,DW_AT_ranges) || dwarf_hasattr(&d,DW_AT_inline)))
                out->succinct_lines = 1;
            if (tag == DW_TAG_enumeration_type) {
                Dwarf_Die e; int erc = dwarf_child(&d,&e);
                if (erc < 0) return "RubyDwarfMalformed";
                if (!erc) do {
                    if (!tick(&s)) return s.error;
                    const char *ename = dwarf_diename(&e);
                    if (dwarf_tag(&e) != DW_TAG_enumerator || !ename) continue;
                    for (unsigned i = 0; i < sizeof constants/sizeof *constants; ++i) {
                        if (strcmp(ename,constants[i].name)) continue;
                        uint64_t got;
                        if (!ud(&e,DW_AT_const_value,&got) || got != constants[i].value) return "RubyConstantMismatch";
                        known[i] = 1;
                    }
                } while ((erc=dwarf_siblingof(&e,&e))==0);
                if (erc < 0) return "RubyDwarfMalformed";
            }
            if (!name || (tag != DW_TAG_structure_type && tag != DW_TAG_typedef) || declaration(&d)) continue;
            for (unsigned t = 0; t < XRB_TYPE_COUNT; ++t) {
                if (strcmp(name,types[t])) continue;
                struct xrb_layout got = {0};
                if (!candidate(d,t,&got,&s)) {
                    if (s.error) return s.error;
                    continue;
                }
                if (have[t] && out->sizes[t] != got.sizes[t]) return "RubyDwarfAmbiguous";
                out->sizes[t] = got.sizes[t];
                for (unsigned f = 0; f < XRB_FIELD_COUNT; ++f) {
                    if (fields[f].owner != t) continue;
                    if (have[t] && memcmp(&out->fields[f],&got.fields[f],sizeof got.fields[f])) return "RubyDwarfAmbiguous";
                    out->fields[f] = got.fields[f];
                }
                have[t] = 1;
            }
        } while ((rc=dwarf_siblingof(&d,&d))==0);
        if (rc < 0) return "RubyDwarfMalformed";
    }
    for (unsigned t = 0; t < XRB_TYPE_COUNT; ++t) if (!have[t]) return "RubyDwarfTypesUnavailable";
    for (unsigned i = 0; i < sizeof constants/sizeof *constants; ++i) if (!known[i]) return "RubyDwarfConstantsUnavailable";
    memcpy(out->build_id,id,n); out->build_id_len=(uint8_t)n;
    return NULL;
}
/* A generic host typedef named VALUE is insufficient. Require the CRuby public
 * value header's typedef and its 64-bit unsigned representation in DWARF. The
 * adapter additionally requires a verified supported runtime in this process. */
int xrb_dwarf_value(Dwarf_Die *input) {
    Dwarf_Die d=*input;struct scan s={0};
    const char *name=dwarf_diename(&d),*file=dwarf_decl_file(&d);
    const char suffix[]="ruby/internal/value.h";
    if (dwarf_tag(&d)!=DW_TAG_typedef || !name || strcmp(name,"VALUE") || !file) return 0;
    size_t n=strlen(file),m=sizeof suffix-1;
    if (n<m || strcmp(file+n-m,suffix) || (n>m && file[n-m-1]!='/')) return 0;
    uint64_t bytes;
    return resolve(&d,&s) && kind(&d,UNSIGNED) && size(&d,&bytes) && bytes==8;
}
