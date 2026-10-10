#include "elisp.h"
#include <dwarf.h>
#include <gelf.h>
#include <elfutils/libdwelf.h>
#include <string.h>
enum kind { INTEGER, SIGNED, UNSIGNED, FLOAT, POINTER, ARRAY, AGGREGATE, BIT8, REDIRECT, FLEX8 };
static const char *const types[] = {
#define XEL_TYPE(key, name) name,
#include "elisp_types.inc"
#undef XEL_TYPE
};
static const struct { unsigned owner; const char *path; enum kind kind; unsigned width; } fields[] = {
#define XEL_FIELD(key, owner, path, kind, width) {XEL_T_##owner, path, kind, width},
#include "elisp_fields.inc"
#undef XEL_FIELD
};
static const struct { const char *name; uint64_t value; } constants[] = {
#define XEL_CONSTANT(name, value) {#name, value},
#include "elisp_constants.inc"
#undef XEL_CONSTANT
};
struct scan { unsigned work; const char *error; };
static int tick(struct scan *s) {
    if (s->error) return 0;
    if (++s->work > 4000000) { s->error = "ElispDwarfWorkLimit"; return 0; }
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
        if (!type(d, &next)) { s->error = "ElispDwarfMalformed"; return 0; }
        *d = next;
    }
    if (!s->error) s->error = "ElispDwarfTypeDepthLimit";
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
    if ((want == INTEGER || want == BIT8 || want == REDIRECT) && tag == DW_TAG_enumeration_type) return 1;
    if (want == POINTER) return tag == DW_TAG_pointer_type;
    if (want == ARRAY || want == FLEX8) return tag == DW_TAG_array_type;
    if (want == AGGREGATE) return tag == DW_TAG_structure_type || tag == DW_TAG_union_type;
    if (tag != DW_TAG_base_type || !ud(d, DW_AT_encoding, &encoding)) return 0;
    if (want == FLOAT) return encoding == DW_ATE_float;
    int signed_ = encoding == DW_ATE_signed || encoding == DW_ATE_signed_char;
    int unsigned_ = encoding == DW_ATE_unsigned || encoding == DW_ATE_unsigned_char;
    return want == SIGNED ? signed_ : want == UNSIGNED ? unsigned_ : signed_ || unsigned_;
}
static int member(Dwarf_Die parent, const char *path, struct xel_field_info *out,
                  Dwarf_Die *leaf, struct scan *s, enum kind want) {
    int bitfield = want == BIT8 || want == REDIRECT;
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
        if (rc < 0) { s->error = "ElispDwarfMalformed"; return 0; }
        if (rc > 0) return 0;
        do {
            if (!tick(s)) return 0;
            if (dwarf_tag(&child) != DW_TAG_member) continue;
            const char *name = dwarf_diename(&child);
            if (!name || strlen(name) != len || memcmp(name, path, len)) continue;
            if (found++) { s->error = "ElispDwarfAmbiguous"; return 0; }
            Dwarf_Attribute bit;
            if (bitfield && !dot) {
                uint64_t bits, bit_at, storage;
                /* This profile proves either a byte tag or the symbol's
                 * two redirect bits immediately after its GC mark bit. */
                uint64_t want_bits = want == BIT8 ? 8 : 2;
                uint64_t want_at = want == BIT8 ? 0 : 1;
                if (!ud(&child,DW_AT_bit_size,&bits) || bits!=want_bits) return 0;
                if (ud(&child,DW_AT_data_bit_offset,&bit_at)) {
                    if (bit_at != want_at) return 0;
                } else {
                    /* DWARF 4 counts from the high end of the storage unit.
                     * ELF admission below has already proved little endian. */
                    if (!ud(&child,DW_AT_byte_size,&storage) || storage != 4 ||
                        !ud(&child,DW_AT_bit_offset,&bit_at) || bit_at != 32-want_at-want_bits) return 0;
                }
            } else if (dwarf_attr(&child, DW_AT_bit_size, &bit) || dwarf_attr(&child, DW_AT_data_bit_offset, &bit)) return 0;
            if (!ud(&child, DW_AT_data_member_location, &at)) {
                if (parent_tag != DW_TAG_union_type && !(bitfield && !dot)) return 0;
                at = 0;
            }
            if (!type(&child, &selected)) { s->error = "ElispDwarfMalformed"; return 0; }
        } while ((rc = dwarf_siblingof(&child, &child)) == 0);
        if (rc < 0) { s->error = "ElispDwarfMalformed"; return 0; }
        if (!found || !resolve(&selected, s)) return 0;
        uint64_t bytes;
        if (!dot && want == FLEX8 && dwarf_tag(&selected) == DW_TAG_array_type) {
            Dwarf_Die element; uint64_t element_size;
            if (!type(&selected, &element) || !resolve(&element, s) || !size(&element, &element_size) ||
                element_size != 8 || dwarf_tag(&element) != DW_TAG_pointer_type) return 0;
            Dwarf_Die bound;
            int rc = dwarf_child(&selected, &bound);
            if (rc != 0 || dwarf_tag(&bound) != DW_TAG_subrange_type || dwarf_hasattr(&bound, DW_AT_upper_bound) ||
                dwarf_hasattr(&bound, DW_AT_count)) return 0;
            if (dwarf_siblingof(&bound, &bound) != 1) return 0;
            bytes = 0;
        } else if (!size(&selected, &bytes)) return 0;
        if (at > parent_size || bytes > parent_size - at || offset > UINT32_MAX - at) return 0;
        offset += at;
        if (!dot) {
            out->offset = (uint32_t)offset; out->size = (uint32_t)(bitfield ? 1 : bytes); *leaf = selected; return 1;
        }
        parent = selected; path = dot + 1;
    }
    if (!s->error) s->error = "ElispDwarfTypeDepthLimit";
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
static int candidate(Dwarf_Die die, unsigned t, struct xel_layout *out, struct scan *s) {
    uint64_t bytes;
    if (!resolve(&die, s) || !size(&die, &bytes)) return 0;
    out->sizes[t] = (uint32_t)bytes;
    for (unsigned f = 0; f < XEL_FIELD_COUNT; ++f) {
        if (fields[f].owner != t) continue;
        struct xel_field_info got; Dwarf_Die leaf;
        if (!member(die, fields[f].path, &got, &leaf, s, fields[f].kind) ||
            !kind(&leaf, fields[f].kind) || (fields[f].width && got.size != fields[f].width)) return 0;
        if (f == XEL_MAIN_STATE && (!dwarf_diename(&leaf) || strcmp(dwarf_diename(&leaf), "thread_state"))) return 0;
        out->fields[f] = got;
    }
    return 1;
}
static int declaration(Dwarf_Die *d) {
    Dwarf_Attribute a; bool value = false;
    return dwarf_attr(d, DW_AT_declaration, &a) && (!dwarf_formflag(&a, &value) ? value : 1);
}
static const char *units(Dwarf *dwarf, uint64_t length, uint8_t owned[8192], struct scan *s) {
    static const char *const names[] = {"current_thread", "main_thread", "lispsym", "emacs_version", "Fdebugger_trap", "exec_byte_code", "USE_LSB_TAG", "GCTYPEBITS", "INTTYPEBITS", "VALMASK", "PSEUDOVECTOR_FLAG", "ARRAY_MARK_FLAG", "Qnil", "Fwindow_buffer"};
    unsigned counts[sizeof names/sizeof *names] = {0};
    Dwarf_Off off = 0, next; size_t header;
    for (unsigned cu = 0; off < length; off = next, ++cu) {
        uint8_t width;
        if (cu >= 8192) return "ElispDwarfUnitLimit";
        if (dwarf_nextcu(dwarf, off, &next, &header, NULL, &width, NULL) || width != 8 ||
            next <= off || next > length || header >= next-off) return "ElispDwarfMalformed";
        Dwarf_Die unit, d;
        if (!dwarf_offdie(dwarf, off+header, &unit)) return "ElispDwarfMalformed";
        int rc = dwarf_child(&unit, &d);
        if (rc < 0) return "ElispDwarfMalformed";
        if (rc > 0) continue;
        do {
            if (!tick(s)) return s->error;
            int tag = dwarf_tag(&d);
            if (tag != DW_TAG_variable && tag != DW_TAG_subprogram) continue;
            const char *name = dwarf_diename(&d);
            if (!name || declaration(&d)) continue;
            for (unsigned i = 0; i < sizeof names/sizeof *names; ++i) {
                if (strcmp(name, names[i])) continue;
                int defined = (strcmp(name, "Fdebugger_trap") && strcmp(name, "exec_byte_code") && strcmp(name, "Fwindow_buffer")) ? tag == DW_TAG_variable && dwarf_hasattr(&d, DW_AT_location) :
                    tag == DW_TAG_subprogram && (dwarf_hasattr(&d, DW_AT_low_pc) || dwarf_hasattr(&d, DW_AT_ranges));
                if (!defined) continue;
                if (++counts[i] > 1) return "ElispRuntimeMultiple";
                owned[cu] = 1;
            }
        } while ((rc = dwarf_siblingof(&d, &d)) == 0);
        if (rc < 0) return "ElispDwarfMalformed";
    }
    for (unsigned i = 0; i < sizeof names/sizeof *names; ++i) if (!counts[i]) return "ElispDwarfRuntimeUnavailable";
    return NULL;
}
const char *xel_layout_build(Dwarf *dwarf, const uint8_t *id, size_t n,
                            const char *version, struct xel_layout *out) {
    memset(out, 0, sizeof *out);
    if (!version || strcmp(version, XEL_VERSION)) return "ElispVersionUnsupported";
    if (!id || !n || n > sizeof out->build_id) return "ElispBuildIdUnavailable";
    if (!dwarf) return "ElispDwarfUnavailable";
    GElf_Ehdr eh;
    if (!gelf_getehdr(dwarf_getelf(dwarf), &eh) || eh.e_ident[EI_CLASS] != ELFCLASS64 ||
        eh.e_ident[EI_DATA] != ELFDATA2LSB || eh.e_machine != EM_X86_64) return "ElispArchitectureUnsupported";
    const void *actual_id = NULL;
    ssize_t actual_size = dwelf_elf_gnu_build_id(dwarf_getelf(dwarf), &actual_id);
    if (actual_size <= 0 || (size_t)actual_size != n || memcmp(id, actual_id, n)) return "ElispBuildIdMismatch";
    uint64_t length;
    if (!info_size(dwarf, &length)) return "ElispDwarfMalformed";
    struct scan s = {0}; uint8_t owned[8192] = {0}, have[XEL_TYPE_COUNT] = {0};
    uint8_t known[sizeof constants / sizeof *constants] = {0};
    const char *error = units(dwarf, length, owned, &s);
    if (error) return error;
    Dwarf_Off off = 0, next; size_t header;
    for (unsigned cu = 0; off < length; off = next, ++cu) {
        if (dwarf_nextcu(dwarf, off, &next, &header, NULL, NULL, NULL) || cu >= 8192) return "ElispDwarfMalformed";
        if (!owned[cu]) continue;
        Dwarf_Die unit, d;
        if (!dwarf_offdie(dwarf, off+header, &unit)) return "ElispDwarfMalformed";
        int rc = dwarf_child(&unit, &d);
        if (rc < 0) return "ElispDwarfMalformed";
        if (rc > 0) continue;
        do {
            if (!tick(&s)) return s.error;
            int tag = dwarf_tag(&d); const char *name = dwarf_diename(&d);
            if (tag == DW_TAG_enumeration_type) {
                Dwarf_Die e; int erc = dwarf_child(&d,&e);
                if (erc < 0) return "ElispDwarfMalformed";
                if (!erc) do {
                    if (!tick(&s)) return s.error;
                    const char *ename = dwarf_diename(&e);
                    if (dwarf_tag(&e) != DW_TAG_enumerator || !ename) continue;
                    for (unsigned i = 0; i < sizeof constants/sizeof *constants; ++i) {
                        if (strcmp(ename,constants[i].name)) continue;
                        uint64_t got;
                        if (!ud(&e,DW_AT_const_value,&got) || got != constants[i].value) return "ElispConstantMismatch";
                        known[i] = 1;
                    }
                } while ((erc=dwarf_siblingof(&e,&e))==0);
                if (erc < 0) return "ElispDwarfMalformed";
            }
            if (!name || (tag != DW_TAG_structure_type && tag != DW_TAG_union_type && tag != DW_TAG_typedef) || declaration(&d)) continue;
            for (unsigned t = 0; t < XEL_TYPE_COUNT; ++t) {
                if (strcmp(name,types[t])) continue;
                struct xel_layout got = {0};
                if (!candidate(d,t,&got,&s)) {
                    if (s.error) return s.error;
                    return "ElispDwarfLayoutUnsupported";
                }
                if (have[t] && out->sizes[t] != got.sizes[t]) return "ElispDwarfAmbiguous";
                out->sizes[t] = got.sizes[t];
                for (unsigned f = 0; f < XEL_FIELD_COUNT; ++f) {
                    if (fields[f].owner != t) continue;
                    if (have[t] && memcmp(&out->fields[f],&got.fields[f],sizeof got.fields[f])) return "ElispDwarfAmbiguous";
                    out->fields[f] = got.fields[f];
                }
                have[t] = 1;
            }
        } while ((rc=dwarf_siblingof(&d,&d))==0);
        if (rc < 0) return "ElispDwarfMalformed";
    }
    for (unsigned t = 0; t < XEL_TYPE_COUNT; ++t) if (!have[t]) return "ElispDwarfTypesUnavailable";
    for (unsigned i = 0; i < sizeof constants/sizeof *constants; ++i) if (!known[i]) return "ElispDwarfConstantsUnavailable";
    memcpy(out->build_id,id,n); out->build_id_len=(uint8_t)n;
    return NULL;
}

int xel_dwarf_object(Dwarf_Die *input) {
    Dwarf_Die d = *input; struct scan s = {0};
    const char *name = dwarf_diename(&d), *file = dwarf_decl_file(&d);
    if (dwarf_tag(&d) != DW_TAG_typedef || !name || strcmp(name,"Lisp_Object") || !file) return 0;
    const char *base = strrchr(file,'/'); base = base ? base+1 : file;
    if (strcmp(base,"lisp.h")) return 0;
    uint64_t bytes; Dwarf_Die child;
    if (!resolve(&d,&s) || !kind(&d,POINTER) || !size(&d,&bytes) || bytes != 8 ||
        !type(&d,&child) || !resolve(&child,&s) || dwarf_tag(&child) != DW_TAG_structure_type) return 0;
    name = dwarf_diename(&child);
    return name && !strcmp(name,"Lisp_X");
}
