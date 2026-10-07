#include "javascript.h"
#include <dwarf.h>
#include <gelf.h>
#include <stdlib.h>
#include <string.h>

static int ud(Dwarf_Die *d, unsigned code, uint64_t *out) {
    Dwarf_Attribute a; Dwarf_Word v;
    if (!dwarf_attr(d, code, &a) || dwarf_formudata(&a, &v)) return 0;
    *out = v; return 1;
}
static int type(Dwarf_Die *d, Dwarf_Die *out) {
    Dwarf_Attribute a;
    return dwarf_attr(d, DW_AT_type, &a) && dwarf_formref_die(&a, out);
}
static int v8_namespace(Dwarf_Die *d) {
    Dwarf_Die *scopes = NULL;
    int n = dwarf_getscopes_die(d, &scopes), found = 0;
    if (n > 0 && n <= 32) for (int i = 1; i < n; ++i) {
        if (dwarf_tag(&scopes[i]) != DW_TAG_namespace) continue;
        const char *name = dwarf_diename(&scopes[i]);
        if (name && !strcmp(name, "v8")) found = 1;
        else if (!name || (strcmp(name, "internal") && strcmp(name, "api_internal"))) { found = 0; break; }
    }
    free(scopes); return found;
}
static int word_kind(Dwarf_Die d) {
    uint64_t size, encoding;
    for (unsigned i = 0; i < 16; ++i) {
        int tag = dwarf_tag(&d);
        if (tag == DW_TAG_typedef || tag == DW_TAG_const_type || tag == DW_TAG_volatile_type) {
            Dwarf_Die next; if (!type(&d, &next)) return 0; d = next; continue;
        }
        if (!ud(&d, DW_AT_byte_size, &size)) {
            /* DWARF permits pointer types to inherit their compilation
             * unit's address size. Clang uses this form for V8 handles. */
            Dwarf_Die unit; uint8_t address_size = 0;
            if (tag != DW_TAG_pointer_type || !dwarf_diecu(&d, &unit, &address_size, NULL)) return 0;
            size = address_size;
        }
        if (size != 8) return 0;
        if (tag == DW_TAG_pointer_type) return 2;
        if (tag == DW_TAG_base_type && ud(&d, DW_AT_encoding, &encoding) && encoding == DW_ATE_unsigned) return 1;
        return 0;
    }
    return 0;
}
static int handle_word(Dwarf_Die *d, unsigned depth, unsigned *examined) {
    if (depth == 16) return -1;
    Dwarf_Die child; int result = 0;
    int rc = dwarf_child(d, &child);
    if (rc < 0) return -1;
    if (rc > 0) return dwarf_bytesize(d) == 1 ? 0 : -1;
    do {
        if (++*examined > 128) return -1;
        int tag = dwarf_tag(&child);
        if (tag != DW_TAG_member && tag != DW_TAG_inheritance) continue;
        uint64_t offset; Dwarf_Die t;
        if (!ud(&child, DW_AT_data_member_location, &offset) || offset || !type(&child, &t)) return -1;
        int mode;
        if (tag == DW_TAG_inheritance) mode = handle_word(&t, depth + 1, examined);
        else {
            const char *name = dwarf_diename(&child); int k = word_kind(t);
            mode = name && !strcmp(name, "ptr_") && k == 1 ? 1 : name && !strcmp(name, "location_") && k == 2 ? 2 : -1;
        }
        if (mode < 0 || (mode && result)) return -1;
        if (mode) result = mode;
    } while ((rc = dwarf_siblingof(&child, &child)) == 0);
    if (rc < 0) return -1;
    return result || dwarf_bytesize(d) == 1 ? result : -1;
}
int xjs_dwarf_handle(Dwarf_Die *d) {
    const char *name = dwarf_diename(d); uint64_t size;
    if (!name || (strncmp(name, "Local<", 6) && strncmp(name, "Tagged<", 7))) return 0;
    if (!ud(d, DW_AT_byte_size, &size) || size != 8 || !v8_namespace(d)) return 0;
    unsigned examined = 0;
    int result = handle_word(d, 0, &examined);
    return result > 0 ? result : 0;
}

/* Same-image constants emitted by DWARF take precedence as evidence. Every
 * one found must agree with the exact version table; missing constants stay
 * explicitly table-backed. No namespace-free type-name matching. */
static const struct {
    const char *owner, *name;
    uint64_t value;
    int frame_config;
} checks[] = {
    {"JSArray", "kLengthOffset", 24, 0},
    {"ScopeInfo", "kFlags", 0, 0},
    {"ScopeInfo", "kParameterCount", 1, 0},
    {"ScopeInfo", "kContextLocalCount", 2, 0},
    {"ScopeInfo", "kPositionInfoStart", 3, 0},
    {"ScopeInfo", "kPositionInfoEnd", 4, 0},
    {"ScopeInfo", "kVariablePartIndex", 5, 0},
    {"BytecodeArray", "kSourcePositionTableOffset", 24, 0},
    {"TrustedByteArray", "kLengthOffset", 8, 0},
    {"TrustedByteArray", "kHeaderSize", 16, 0},
    {"Code", "kDeoptimizationDataOrInterpreterDataOffset", 8, 0},
    {"Code", "kPositionTableOffset", 16, 0},
    {"Code", "kBuiltinIdOffset", 90, 1},
    {"ExternalString", "kResourceDataOffset", 24, 0},
    {"Script", "kLineOffsetOffset", 24, 0},
    {"Script", "kColumnOffsetOffset", 32, 0},
    {"SharedFunctionInfo", "kTrustedFunctionDataOffset", 8, 0},
    {"JSFunction", "kDispatchHandleOffset", 24, 1},
    {"Internals", "kIsolateJSDispatchTableOffset", 616, 1},
    {"JSDispatchEntry", "kObjectPointerShift", 16, 1},
    {"Builtin", "kInterpreterEntryTrampoline", 83, 1},
    {"", "kRootRegisterBias", 128, 1},
    {"", "kJSDispatchHandleShift", 8, 1},
    {"", "kJSDispatchTableEntrySize", 16, 1},
};
static int owner_match(const char *actual, const char *want) {
    if (!strcmp(actual, want)) return 1;
    const char prefix[] = "TorqueGenerated";
    if (strncmp(actual, prefix, sizeof prefix - 1)) return 0;
    actual += sizeof prefix - 1;
    size_t n = strlen(want);
    return !strncmp(actual, want, n) && actual[n] == '<';
}
static void scan(Dwarf_Die *parent, unsigned ns, const char *owner, unsigned depth,
                 unsigned *visited, struct xjs_dwarf_profile *out) {
    if (out->error) return;
    if (depth >= 32) { out->error = "JavaScriptDwarfDepthLimit"; return; }
    Dwarf_Die die;
    int rc = dwarf_child(parent, &die);
    if (rc < 0) { out->error = "JavaScriptDwarfMalformed"; return; }
    if (rc > 0) return;
    do {
        if (++*visited > 4000000) { out->error = "JavaScriptDwarfWorkLimit"; return; }
        int tag = dwarf_tag(&die); const char *name = dwarf_diename(&die);
        if (tag == DW_TAG_namespace) {
            if (name && !ns && !strcmp(name, "v8")) scan(&die, 1, "", depth + 1, visited, out);
            else if (name && ns == 1 && !strcmp(name, "internal")) scan(&die, 2, "", depth + 1, visited, out);
        } else if (ns == 2) {
            if (name) for (size_t i = 0; i < sizeof checks / sizeof *checks; ++i) {
                uint64_t value;
                if (strcmp(name, checks[i].name) || !owner_match(owner, checks[i].owner) || !ud(&die, DW_AT_const_value, &value)) continue;
                if (value != checks[i].value) { out->error = "JavaScriptDwarfLayoutMismatch"; return; }
                out->fields |= UINT64_C(1) << i;
            }
            if (tag == DW_TAG_class_type || tag == DW_TAG_structure_type || tag == DW_TAG_enumeration_type) {
                const char *next = tag == DW_TAG_enumeration_type && *owner ? owner : name;
                if (next) {
                    int relevant = 0;
                    for (size_t i = 0; i < sizeof checks / sizeof *checks; ++i)
                        if (owner_match(next, checks[i].owner)) relevant = 1;
                    if (relevant) scan(&die, ns, next, depth + 1, visited, out);
                }
            }
        }
        if (out->error) return;
    } while ((rc = dwarf_siblingof(&die, &die)) == 0);
    if (rc < 0) out->error = "JavaScriptDwarfMalformed";
}
/* dwarf_nextcu can accept a length whose claimed end exceeds the actual
 * section. libdw has already decompressed this Elf's recognized sections;
 * use the resulting data size, including for GNU .zdebug_info. */
static int info_size(Dwarf *dwarf, uint64_t *size) {
    Elf *elf = dwarf_getelf(dwarf); size_t names;
    if (!elf || elf_getshdrstrndx(elf, &names)) return 0;
    Elf_Scn *section = NULL;
    while ((section = elf_nextscn(elf, section))) {
        GElf_Shdr header;
        if (!gelf_getshdr(section, &header)) return 0;
        const char *name = elf_strptr(elf, names, header.sh_name);
        if (!name) return 0;
        if (strcmp(name, ".debug_info") && strcmp(name, ".zdebug_info")) continue;
        Elf_Data *data = elf_getdata(section, NULL);
        if (!data || data->d_off || !data->d_size) return 0;
        *size = data->d_size;
        return 1;
    }
    return 0;
}
void xjs_dwarf_profile(Dwarf *dwarf, struct xjs_dwarf_profile *out) {
    memset(out, 0, sizeof *out);
    if (!dwarf) return;
    uint64_t size;
    if (!info_size(dwarf, &size)) { out->error = "JavaScriptDwarfMalformed"; return; }
    Dwarf_Off offset = 0, next; size_t header; unsigned visited = 0;
    for (unsigned cu = 0; cu < 8192; ++cu) {
        uint8_t address_size;
        int rc = dwarf_nextcu(dwarf, offset, &next, &header, NULL, &address_size, NULL);
        if (rc == 1) {
            if (offset != size) out->error = "JavaScriptDwarfMalformed";
            break;
        }
        if (rc || address_size != 8 || next <= offset || next > size || header >= next - offset) {
            out->error = "JavaScriptDwarfMalformed"; return;
        }
        Dwarf_Die unit;
        if (!dwarf_offdie(dwarf, offset + header, &unit)) { out->error = "JavaScriptDwarfMalformed"; return; }
        scan(&unit, 0, "", 0, &visited, out);
        if (out->error) return;
        offset = next;
        if (cu == 8191) { out->error = "JavaScriptDwarfUnitLimit"; return; }
    }
    uint64_t required = 0;
    for (size_t i = 0; i < sizeof checks / sizeof *checks; ++i)
        if (checks[i].frame_config) required |= UINT64_C(1) << i;
    out->frame_config = (out->fields & required) == required;
}
