#include "python.h"
#include <dwarf.h>
#include <string.h>

const char *const xpy_type_symbols[XPY_TYPE_COUNT] = {
    "_Py_NoneStruct", "_Py_TrueStruct", "_Py_FalseStruct", "PyType_Type",  "_PyNone_Type", "PyBool_Type",
    "PyLong_Type",    "PyFloat_Type",   "PyUnicode_Type",  "PyBytes_Type", "PyTuple_Type", "PyList_Type",
    "PyDict_Type",    "PySet_Type",     "PyFrozenSet_Type", "PyCode_Type",
};
/* Paths inside _Py_DebugOffsets (published) and inside the named native
 * structures (unpublished), in enum xpy_field order. */
const char *const xpy_field_names[XPY_FIELD_COUNT] = {
    "runtime_state.interpreters_head",
    "interpreter_state.id",
    "interpreter_state.next",
    "interpreter_state.threads_head",
    "thread_state.next",
    "thread_state.interp",
    "thread_state.current_frame",
    "thread_state.thread_id",
    "thread_state.native_thread_id",
    "interpreter_frame.previous",
    "interpreter_frame.executable",
    "interpreter_frame.instr_ptr",
    "interpreter_frame.owner",
    "code_object.filename",
    "code_object.name",
    "code_object.qualname",
    "code_object.linetable",
    "code_object.firstlineno",
    "code_object.co_code_adaptive",
    "pyobject.size",
    "pyobject.ob_type",
    "type_object.tp_name",
    "type_object.tp_flags",
    "tuple_object.ob_item",
    "tuple_object.ob_size",
    "list_object.ob_item",
    "list_object.ob_size",
    "set_object.used",
    "dict_object.ma_keys",
    "dict_object.ma_values",
    "float_object.ob_fval",
    "long_object.lv_tag",
    "long_object.ob_digit",
    "bytes_object.ob_size",
    "bytes_object.ob_sval",
    "unicode_object.state",
    "unicode_object.length",
    "unicode_object.asciiobject_size",
    "PyCompactUnicodeObject",
    "PyCodeObject.co_flags",
    "PyDictObject.ma_used",
    "PyDictKeysObject.dk_log2_size",
    "PyDictKeysObject.dk_log2_index_bytes",
    "PyDictKeysObject.dk_kind",
    "PyDictKeysObject.dk_nentries",
    "PyDictKeysObject.dk_indices",
    "PyDictValues.values",
};
/* Generated from each version's pycore_debug_offsets.h with offsetof(). */
static const uint16_t positions_3_14[XPY_PUBLISHED_COUNT] = {
    40,  56,  64,  72,  192, 200, 208, 216, 224, 256, 264, 272, 288, 320, 328, 336, 344, 352, 384,
    400, 408, 424, 440, 456, 464, 480, 488, 504, 536, 544, 560, 576, 584, 600, 608, 624, 632, 640,
};
static const uint16_t positions_3_16[XPY_PUBLISHED_COUNT] = {
    40,  56,  64,  72,  192, 200, 208, 240, 248, 320, 328, 336, 352, 384, 392, 400, 408, 416, 448,
    464, 472, 488, 504, 552, 560, 576, 584, 600, 632, 640, 656, 672, 680, 696, 704, 720, 728, 736,
};
/* sizeof(PyCompactUnicodeObject), co_flags, ma_used, dk_log2_size,
 * dk_log2_index_bytes, dk_kind, dk_nentries, dk_indices, PyDictValues.values.
 * Identical for 3.14 and the verified 3.16 prerelease headers. */
const uint64_t xpy_unpublished_3_14[XPY_FIELD_COUNT - XPY_PUBLISHED_COUNT] = {56, 48, 16, 8, 9, 10, 24, 32, 8};

static int final_release(uint64_t v) {
    return ((v >> 4) & 15) == 15;
}
const uint16_t *xpy_published_positions(uint64_t v) {
    if ((v >> 16) == 0x030e)
        return positions_3_14;
    if ((v >> 16) == 0x0310)
        return positions_3_16;
    return NULL;
}
static uint64_t word(const uint8_t *p) {
    uint64_t v = 0;
    for (unsigned i = 0; i < 8; ++i)
        v |= (uint64_t)p[i] << (8 * i);
    return v;
}

/* --- DWARF verification (same image, same build-id) ------------------- */
static int type_of(Dwarf_Die *die, Dwarf_Die *out) {
    Dwarf_Attribute attr;
    return dwarf_attr_integrate(die, DW_AT_type, &attr) && dwarf_formref_die(&attr, out);
}
static int resolve(Dwarf_Die *die) {
    for (unsigned i = 0; i < 16; ++i) {
        int tag = dwarf_tag(die);
        if (tag != DW_TAG_typedef && tag != DW_TAG_const_type && tag != DW_TAG_volatile_type)
            return (tag == DW_TAG_structure_type || tag == DW_TAG_union_type) && !dwarf_hasattr(die, DW_AT_declaration);
        if (!type_of(die, die))
            return 0;
    }
    return 0;
}
/* Byte offset of a dotted member path; bit offset for a bit-field leaf. */
static int member(Dwarf_Die root, const char *path, uint64_t *offset, int *bit_offset, int *bit_size) {
    *offset = 0;
    *bit_offset = *bit_size = -1;
    for (unsigned depth = 0; depth < 8; ++depth) {
        if (!resolve(&root))
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
        if (!found)
            return 0;
        Dwarf_Attribute attr;
        Dwarf_Word at = 0;
        if (dwarf_attr(&child, DW_AT_data_member_location, &attr) && dwarf_formudata(&attr, &at))
            return 0;
        if (dwarf_hasattr(&child, DW_AT_bit_size)) {
            Dwarf_Word bits = 0, size = 0;
            if (dot || !dwarf_attr(&child, DW_AT_data_bit_offset, &attr) || dwarf_formudata(&attr, &bits) ||
                !dwarf_attr(&child, DW_AT_bit_size, &attr) || dwarf_formudata(&attr, &size))
                return 0;
            *bit_offset = (int)bits;
            *bit_size = (int)size;
            return 1;
        }
        *offset += at;
        if (!dot)
            return 1;
        if (!type_of(&child, &root))
            return 0;
        path = dot + 1;
    }
    return 0;
}
enum { T_OFFSETS, T_COMPACT, T_CODE, T_DICT, T_KEYS, T_VALUES, T_ASCII, T_KEY_ENTRY, T_UNICODE_ENTRY, T_COUNT };
static const char *const type_names[T_COUNT] = {"_Py_DebugOffsets", "PyCompactUnicodeObject", "PyCodeObject",
                                                "PyDictObject",     "PyDictKeysObject",       "PyDictValues",
                                                "PyASCIIObject",    "PyDictKeyEntry",         "PyDictUnicodeEntry"};
static const char *find_types(Dwarf *dwarf, Dwarf_Die *out) {
    unsigned char have[T_COUNT] = {0};
    unsigned found = 0, visited = 0;
    Dwarf_Off offset = 0, next;
    size_t header;
    for (unsigned units = 0; units < 8192 && found < T_COUNT; ++units) {
        uint8_t address_size;
        if (dwarf_nextcu(dwarf, offset, &next, &header, NULL, &address_size, NULL))
            break;
        if (address_size != 8 || next <= offset)
            return "PythonLayoutUnsupported";
        Dwarf_Die unit, die;
        if (!dwarf_offdie(dwarf, offset + header, &unit))
            return "PythonMalformedDwarf";
        offset = next;
        if (dwarf_child(&unit, &die))
            continue;
        do {
            if (++visited > 4000000)
                return "PythonDwarfLimit";
            int tag = dwarf_tag(&die);
            if (tag != DW_TAG_typedef && tag != DW_TAG_structure_type)
                continue;
            const char *name = dwarf_diename(&die);
            if (!name)
                continue;
            for (unsigned i = 0; i < T_COUNT; ++i) {
                if (have[i] || strcmp(name, type_names[i]))
                    continue;
                Dwarf_Die resolved = die;
                if (!resolve(&resolved))
                    continue; /* a declaration; keep looking */
                out[i] = resolved;
                have[i] = 1;
                ++found;
            }
        } while (!dwarf_siblingof(&die, &die));
    }
    return found == T_COUNT ? NULL : "PythonDwarfTypesUnavailable";
}
static int expect(Dwarf_Die die, const char *path, uint64_t want) {
    uint64_t at;
    int bit, bits;
    return member(die, path, &at, &bit, &bits) && bit < 0 && at == want;
}
static int expect_bits(Dwarf_Die die, const char *path, int want_offset, int want_size) {
    uint64_t at;
    int bit, bits;
    return member(die, path, &at, &bit, &bits) && bit == want_offset && bits == want_size;
}
static int size_is(Dwarf_Die die, uint64_t want) {
    Dwarf_Word size;
    return !dwarf_aggregate_size(&die, &size) && size == want;
}
static const char *verify(Dwarf *dwarf, const uint16_t *positions, const uint64_t *unpublished) {
    Dwarf_Die t[T_COUNT];
    const char *why = find_types(dwarf, t);
    if (why)
        return why;
    for (unsigned i = 0; i < XPY_PUBLISHED_COUNT; ++i)
        if (!expect(t[T_OFFSETS], xpy_field_names[i], positions[i]))
            return "PythonDebugOffsetsLayoutMismatch";
    for (unsigned i = XPY_PUBLISHED_COUNT + 1; i < XPY_FIELD_COUNT; ++i) {
        const char *dot = strchr(xpy_field_names[i], '.');
        unsigned type = i == XPY_CO_FLAGS ? T_CODE : i == XPY_DICT_USED ? T_DICT : i == XPY_DV_VALUES ? T_VALUES : T_KEYS;
        if (!dot || !expect(t[type], dot + 1, unpublished[i - XPY_PUBLISHED_COUNT]))
            return "PythonLayoutMismatch";
    }
    /* The reader's macro rules: compact header size, state bit-fields and
     * dictionary entry layouts. */
    if (!size_is(t[T_COMPACT], unpublished[0]) || !size_is(t[T_KEY_ENTRY], 24) || !size_is(t[T_UNICODE_ENTRY], 16) ||
        !expect(t[T_KEY_ENTRY], "me_key", 8) || !expect(t[T_KEY_ENTRY], "me_value", 16) ||
        !expect(t[T_UNICODE_ENTRY], "me_key", 0) || !expect(t[T_UNICODE_ENTRY], "me_value", 8) ||
        !expect_bits(t[T_ASCII], "state.kind", 2, 3) || !expect_bits(t[T_ASCII], "state.compact", 5, 1) ||
        !expect_bits(t[T_ASCII], "state.ascii", 6, 1))
        return "PythonLayoutMismatch";
    return NULL;
}

const char *xpy_layout_build(const uint8_t *p, size_t n, Dwarf *dwarf, const uint8_t *id, size_t id_len,
                             struct xpy_layout *out) {
    memset(out, 0, sizeof *out);
    if (!id || !id_len || id_len > sizeof out->build_id)
        return "PythonBuildIdUnavailable";
    if (!p || n < XPY_DEBUG_OFFSETS_BYTES || memcmp(p, "xdebugpy", 8))
        return "PythonDebugOffsetsUnavailable";
    uint64_t version = word(p + 8);
    const uint16_t *positions = xpy_published_positions(version);
    if (!positions)
        return "PythonVersionUnsupported";
    if (word(p + 16))
        return "PythonFreeThreadedUnsupported";
    /* Only a final release has a frozen table; prereleases need DWARF. */
    if (!final_release(version) && !dwarf)
        return "PythonLayoutUnverified";
    if ((version >> 16) == 0x030e && !final_release(version))
        return "PythonVersionUnsupported";
    for (unsigned i = 0; i < XPY_PUBLISHED_COUNT; ++i) {
        if (positions[i] + 8u > n)
            return "PythonDebugOffsetsUnavailable";
        out->fields[i] = word(p + positions[i]);
        if (out->fields[i] > 1u << 20)
            return "PythonDebugOffsetsInvalid";
    }
    for (unsigned i = XPY_PUBLISHED_COUNT; i < XPY_FIELD_COUNT; ++i)
        out->fields[i] = xpy_unpublished_3_14[i - XPY_PUBLISHED_COUNT];
    /* Published values the unpublished table depends on (PyObject_HEAD and
     * the 16-byte var-object header). */
    if (out->fields[XPY_OB_SIZE_OF] != 16 || out->fields[XPY_OB_TYPE] != 8 || out->fields[XPY_LIST_SIZE] != 16 ||
        out->fields[XPY_TUPLE_SIZE] != 16 || out->fields[XPY_STR_ASCII_SIZE] != 40 ||
        out->fields[XPY_FR_PREVIOUS] + 8 > 4096 || out->fields[XPY_FR_OWNER] > 4096)
        return "PythonLayoutMismatch";
    if (dwarf) {
        const char *why = verify(dwarf, positions, xpy_unpublished_3_14);
        if (why)
            return why;
        out->dwarf_verified = 1;
    }
    out->version = version;
    memcpy(out->build_id, id, id_len);
    out->build_id_len = (uint8_t)id_len;
    return NULL;
}
const char *xpy_layout_check(const struct xpy_layout *l, const uint8_t *p, size_t n, const uint8_t *id, size_t id_len) {
    if (!l || !p || n < 24 || memcmp(p, "xdebugpy", 8) || word(p + 8) != l->version || word(p + 16))
        return "PythonVersionMismatch";
    if (!id || id_len != l->build_id_len || memcmp(id, l->build_id, id_len))
        return "PythonBuildIdMismatch";
    return NULL;
}
