#include "perl.h"
#include <dwarf.h>
#include <limits.h>
#include <string.h>

struct field_spec {
    const char *type, *path;
    unsigned size;
};
static const struct field_spec specs[XPL_FIELD_COUNT] = {
    {"PerlInterpreter", "Icurcop", 8},
    {"PerlInterpreter", "Icurstackinfo", 8},
    {"PerlInterpreter", "Imain_cv", 8},
    {"PerlInterpreter", "Iop", 8},
    {"PERL_SI", "si_cxstack", 8},
    {"PERL_SI", "si_prev", 8},
    {"PERL_SI", "si_cxix", 4},
    {"PERL_SI", "si_cxmax", 4},
    {"PERL_SI", "si_type", 4},
    {"PERL_CONTEXT", "cx_u.cx_blk.blku_type", 1},
    {"PERL_CONTEXT", "cx_u.cx_blk.blku_oldcop", 8},
    {"PERL_CONTEXT", "cx_u.cx_blk.blk_u.blku_sub.cv", 8},
    {"PERL_CONTEXT", "cx_u.cx_blk.blk_u.blku_eval.cv", 8},
    {"PERL_CONTEXT", "cx_u.cx_blk.blku_u16", 2},
    {"COP", "cop_line", 4},
    {"COP", "cop_file", 8},
    {"SV", "sv_any", 8},
    {"SV", "sv_refcnt", 4},
    {"SV", "sv_flags", 4},
    {"SV", "sv_u", 8},
    {"XPV", "xpv_cur", 8},
    {"XPV", "xpv_len_u.xpvlenu_len", 8},
    {"XPVIV", "xiv_u.xivu_iv", 8},
    {"XPVNV", "xnv_u.xnv_nv", 8},
    {"XPVAV", "xav_fill", 8},
    {"XPVAV", "xav_max", 8},
    {"XPVHV", "xhv_keys", 8},
    {"XPVHV", "xhv_max", 8},
    {"XPVCV", "xcv_stash", 8},
    {"XPVCV", "xcv_gv_u", 8},
    {"XPVCV", "xcv_flags", 4},
    {"XPVCV", "xcv_file", 8},
    {"XPVGV", "xiv_u.xivu_namehek", 8},
    {"XPVGV", "xnv_u.xgv_stash", 8},
    {"xpvhv_with_aux", "xhv_aux", 0},
    {"xpvhv_aux", "xhv_name_u", 8},
    {"xpvhv_aux", "xhv_name_count", 4},
    {"HEK", "hek_len", 4},
    {"HEK", "hek_key", 1},
    {"HE", "hent_next", 8},
    {"HE", "hent_hek", 8},
    {"HE", "he_valu.hent_val", 8},
    {"XPVMG", "xmg_stash", 8},
};
static int type_of(Dwarf_Die *die, Dwarf_Die *out) {
    Dwarf_Attribute attr;
    return dwarf_attr_integrate(die, DW_AT_type, &attr) && dwarf_formref_die(&attr, out);
}
static int resolve(Dwarf_Die *die) {
    for (unsigned i = 0; i < 16; ++i) {
        int tag = dwarf_tag(die);
        if (tag != DW_TAG_typedef && tag != DW_TAG_const_type && tag != DW_TAG_volatile_type &&
            tag != DW_TAG_restrict_type)
            return tag == DW_TAG_structure_type || tag == DW_TAG_union_type;
        if (!type_of(die, die))
            return 0;
    }
    return 0;
}
static int field(Dwarf_Die root, const struct field_spec *spec, struct xpl_field_info *out) {
    const char *path = spec->path;
    uint64_t offset = 0;
    for (unsigned depth = 0; depth < 12; ++depth) {
        if (!resolve(&root))
            return 0;
        int parent_size = dwarf_bytesize(&root), parent_tag = dwarf_tag(&root);
        if (parent_size <= 0 || parent_size > 1024 * 1024)
            return 0;
        const char *dot = strchr(path, '.');
        size_t n = dot ? (size_t)(dot - path) : strlen(path);
        Dwarf_Die child;
        if (dwarf_child(&root, &child))
            return 0;
        int found = 0;
        for (unsigned visited = 0; visited < 1024; ++visited) {
            const char *name = dwarf_diename(&child);
            if (dwarf_tag(&child) == DW_TAG_member && name && strlen(name) == n && !memcmp(name, path, n)) {
                found = 1;
                break;
            }
            if (dwarf_siblingof(&child, &child))
                break;
        }
        if (!found || dwarf_hasattr(&child, DW_AT_bit_size))
            return 0;
        Dwarf_Attribute attr;
        Dwarf_Word at = 0;
        if (dwarf_attr(&child, DW_AT_data_member_location, &attr)) {
            if (dwarf_formudata(&attr, &at))
                return 0;
        } else if (parent_tag != DW_TAG_union_type)
            return 0;
        if (at >= (unsigned)parent_size || offset > UINT32_MAX - at || !type_of(&child, &root))
            return 0;
        offset += at;
        if (!dot) {
            Dwarf_Word size;
            if (dwarf_aggregate_size(&root, &size) || size > (unsigned)parent_size - at || size > UINT32_MAX ||
                (spec->size && size != spec->size))
                return 0;
            out->offset = (uint32_t)offset;
            out->size = (uint32_t)size;
            return 1;
        }
        path = dot + 1;
    }
    return 0;
}
const char *xpl_layout_build(Dwarf *dwarf, const uint8_t *id, size_t id_len, const uint8_t version[3],
                             struct xpl_layout *out) {
    memset(out, 0, sizeof *out);
    if (!dwarf || !id || !id_len || id_len > sizeof out->build_id)
        return "PerlBuildIdUnavailable";
    if (!version || version[0] != 5 || version[1] != 44 || version[2] != 0)
        return "PerlVersionUnsupported";
    /* The decoder supplies byte offsets; a different ABI must have a separate
     * macro profile. In particular the unthreaded COP has a GV, not cop_file. */
    Dwarf_Off offset = 0, next;
    size_t header;
    unsigned visited = 0, found = 0, units = 0;
    unsigned char have[XPL_FIELD_COUNT] = {0};
    for (; units < 64 && found < XPL_FIELD_COUNT; ++units) {
        uint8_t address_size;
        int status = dwarf_nextcu(dwarf, offset, &next, &header, NULL, &address_size, NULL);
        if (status < 0)
            return "PerlMalformedDwarf";
        if (status > 0)
            break;
        if (address_size != 8 || next <= offset)
            return "PerlLayoutUnsupported";
        Dwarf_Die unit, die;
        if (!dwarf_offdie(dwarf, offset + header, &unit))
            return "PerlMalformedDwarf";
        offset = next;
        if (dwarf_child(&unit, &die))
            continue;
        do {
            if (++visited > 200000)
                return "PerlDwarfLimit";
            const char *name = dwarf_diename(&die);
            if (!name)
                continue;
            for (unsigned i = 0; i < XPL_FIELD_COUNT; ++i) {
                if (have[i] || strcmp(name, specs[i].type))
                    continue;
                if (!field(die, &specs[i], &out->fields[i]))
                    return "PerlLayoutUnsupported";
                have[i] = 1;
                ++found;
            }
            if (!strcmp(name, "PERL_CONTEXT")) {
                Dwarf_Die resolved = die;
                if (!resolve(&resolved))
                    return "PerlLayoutUnsupported";
                int size = dwarf_bytesize(&resolved);
                if (size <= 0 || size > 4096)
                    return "PerlLayoutUnsupported";
                out->context_size = (unsigned)size;
            }
        } while (!dwarf_siblingof(&die, &die));
    }
    if (found != XPL_FIELD_COUNT || !out->context_size) {
        /* An exhausted search and a complete search with missing types are
         * different outcomes. Probe only the next header, not another DIE. */
        if (units == 64) {
            int status = dwarf_nextcu(dwarf, offset, &next, &header, NULL, NULL, NULL);
            if (status < 0) return "PerlMalformedDwarf";
            if (status == 0) return "PerlDwarfUnitLimit";
        }
        return "PerlDwarfTypesUnavailable";
    }
    memcpy(out->build_id, id, id_len);
    out->build_id_len = (uint8_t)id_len;
    memcpy(out->version, version, 3);
    return NULL;
}
const char *xpl_layout_check(const struct xpl_layout *layout, const uint8_t *id, size_t n, const uint8_t version[3]) {
    if (!layout || !version || memcmp(layout->version, version, 3))
        return "PerlVersionMismatch";
    if (!id || !n || n != layout->build_id_len || n > sizeof layout->build_id || memcmp(id, layout->build_id, n))
        return "PerlBuildIdMismatch";
    return NULL;
}
