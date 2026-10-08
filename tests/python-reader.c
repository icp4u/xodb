#include "../src/language/python.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

/* An owned synthetic address space; invalid addresses never reach a real
 * pointer. Thread/interpreter offsets are synthetic; object offsets follow
 * the 3.14 GIL layout so the macro rules are exercised as in a real build. */
#define BASE 0x100000u
static unsigned char memory[2 * 1024 * 1024];
static size_t attempts, fail_at, next_free = 0x1000;
static int read_fake(void *unused, uint64_t address, void *out, size_t n) {
    (void)unused;
    if (++attempts == fail_at || address < BASE || address - BASE > sizeof memory ||
        n > sizeof memory - (size_t)(address - BASE))
        return -1;
    memcpy(out, memory + (size_t)(address - BASE), n);
    return 0;
}
static void put(uint64_t address, uint64_t value, size_t n) {
    assert(address >= BASE && address + n <= BASE + sizeof memory);
    for (size_t i = 0; i < n; ++i)
        memory[address - BASE + i] = (unsigned char)(value >> (i * 8));
}
static void bytes(uint64_t address, const void *data, size_t n) {
    assert(address >= BASE && address + n <= BASE + sizeof memory);
    memcpy(memory + address - BASE, data, n);
}
static uint64_t alloc(size_t n) {
    uint64_t at = BASE + next_free;
    next_free += (n + 15) & ~(size_t)15;
    assert(next_free < sizeof memory);
    memset(memory + at - BASE, 0, n);
    return at;
}
static struct xpy_reader reader(void) {
    attempts = 0;
    return (struct xpy_reader){.read = read_fake};
}
enum { TP_NAME = 24, TP_FLAGS = 168 };
static struct xpy_layout L;
static uint64_t type_object(const char *name, uint64_t flags) {
    uint64_t t = alloc(256), s = alloc(strlen(name) + 1);
    bytes(s, name, strlen(name) + 1);
    put(t, 0xC0000000u, 8);
    put(t + 8, L.types[XPY_TYPE_TYPE], 8);
    put(t + TP_NAME, s, 8);
    put(t + TP_FLAGS, flags, 8);
    return t;
}
static uint64_t object(uint64_t type, size_t n, uint64_t refcnt) {
    uint64_t o = alloc(n);
    put(o, refcnt, 8);
    put(o + 8, type, 8);
    return o;
}
static void setup(void) {
    memset(&L, 0, sizeof L);
    uint64_t f[XPY_FIELD_COUNT] = {
        [XPY_RT_INTERPRETERS] = 40, [XPY_IS_ID] = 8,           [XPY_IS_NEXT] = 0,        [XPY_IS_THREADS] = 72,
        [XPY_TS_NEXT] = 8,          [XPY_TS_INTERP] = 16,      [XPY_TS_FRAME] = 56,      [XPY_TS_THREAD_ID] = 64,
        [XPY_TS_NATIVE_ID] = 72,    [XPY_FR_PREVIOUS] = 8,     [XPY_FR_EXECUTABLE] = 0,  [XPY_FR_INSTR] = 56,
        [XPY_FR_OWNER] = 74,        [XPY_CO_FILENAME] = 112,   [XPY_CO_NAME] = 120,      [XPY_CO_QUALNAME] = 128,
        [XPY_CO_LINETABLE] = 136,   [XPY_CO_FIRSTLINE] = 68,   [XPY_CO_CODE] = 208,      [XPY_OB_SIZE_OF] = 16,
        [XPY_OB_TYPE] = 8,          [XPY_TP_NAME] = TP_NAME,   [XPY_TP_FLAGS] = TP_FLAGS, [XPY_TUPLE_ITEM] = 24,
        [XPY_TUPLE_SIZE] = 16,      [XPY_LIST_ITEM] = 24,      [XPY_LIST_SIZE] = 16,     [XPY_SET_USED] = 24,
        [XPY_DICT_KEYS] = 32,       [XPY_DICT_VALUES] = 40,    [XPY_FLOAT_VALUE] = 16,   [XPY_LONG_TAG] = 16,
        [XPY_LONG_DIGIT] = 24,      [XPY_BYTES_SIZE] = 16,     [XPY_BYTES_VALUE] = 32,   [XPY_STR_STATE] = 32,
        [XPY_STR_LENGTH] = 16,      [XPY_STR_ASCII_SIZE] = 40,
        [XPY_FR_LOCALSPLUS] = 80, [XPY_FR_STACKPOINTER] = 64, [XPY_CO_ARGCOUNT] = 52,
        [XPY_CO_LOCAL_NAMES] = 96, [XPY_CO_LOCAL_KINDS] = 104,
    };
    memcpy(L.fields, f, sizeof f);
    for (unsigned i = XPY_PUBLISHED_COUNT; i < XPY_FIELD_COUNT; ++i)
        L.fields[i] = xpy_unpublished_3_14[i - XPY_PUBLISHED_COUNT];
    L.types[XPY_TYPE_TYPE] = alloc(256);
    put(L.types[XPY_TYPE_TYPE], 0xC0000000u, 8);
    put(L.types[XPY_TYPE_TYPE] + 8, L.types[XPY_TYPE_TYPE], 8);
    put(L.types[XPY_TYPE_TYPE] + TP_FLAGS, 1u << 31, 8);
    uint64_t tn = alloc(8);
    bytes(tn, "type", 5);
    put(L.types[XPY_TYPE_TYPE] + TP_NAME, tn, 8);
    L.types[XPY_TYPE_NONE] = type_object("NoneType", 0);
    L.types[XPY_TYPE_BOOL] = type_object("bool", 1u << 24);
    L.types[XPY_TYPE_LONG] = type_object("int", 1u << 24);
    L.types[XPY_TYPE_FLOAT] = type_object("float", 0);
    L.types[XPY_TYPE_UNICODE] = type_object("str", 1u << 28);
    L.types[XPY_TYPE_BYTES] = type_object("bytes", 1u << 27);
    L.types[XPY_TYPE_TUPLE] = type_object("tuple", 1u << 26);
    L.types[XPY_TYPE_LIST] = type_object("list", 1u << 25);
    L.types[XPY_TYPE_DICT] = type_object("dict", 1u << 29);
    L.types[XPY_TYPE_SET] = type_object("set", 0);
    L.types[XPY_TYPE_FROZENSET] = type_object("frozenset", 0);
    L.types[XPY_TYPE_CODE] = type_object("code", 0);
    L.types[XPY_TYPE_CELL] = type_object("cell", 0);
    L.types[XPY_NONE_OBJECT] = object(L.types[XPY_TYPE_NONE], 16, 0xC0000000u);
    L.types[XPY_TRUE_OBJECT] = object(L.types[XPY_TYPE_BOOL], 32, 0xC0000000u);
    L.types[XPY_FALSE_OBJECT] = object(L.types[XPY_TYPE_BOOL], 32, 0xC0000000u);
    L.runtime = alloc(64);
    L.version = 0x030e07f0;
}
static uint64_t str_kind(const void *data, size_t length, unsigned kind, int ascii) {
    size_t header = ascii ? 40 : 56;
    uint64_t o = object(L.types[XPY_TYPE_UNICODE], header + (length + 1) * kind, 1);
    put(o + 16, length, 8);
    put(o + 32, (kind << 2) | (1u << 5) | ((unsigned)ascii << 6), 4);
    bytes(o + header, data, length * kind);
    return o;
}
static uint64_t ascii(const char *s) {
    return str_kind(s, strlen(s), 1, 1);
}
static uint64_t small_int(int64_t v) {
    uint64_t o = object(L.types[XPY_TYPE_LONG], 32, 3);
    uint64_t mag = v < 0 ? (uint64_t)-v : (uint64_t)v;
    put(o + 16, v == 0 ? 1 : ((uint64_t)1 << 3) | (v < 0 ? 2 : 0), 8);
    put(o + 24, mag, 4);
    return o;
}
static uint64_t bytes_object(const void *data, size_t n) {
    uint64_t o = object(L.types[XPY_TYPE_BYTES], 33 + n, 1);
    put(o + 16, n, 8);
    bytes(o + 32, data, n);
    return o;
}
static uint64_t list(const uint64_t *items, size_t n) {
    uint64_t o = object(L.types[XPY_TYPE_LIST], 40, 2), array = alloc(8 * (n + 1));
    put(o + 16, n, 8);
    put(o + 24, array, 8);
    for (size_t i = 0; i < n; ++i)
        put(array + 8 * i, items[i], 8);
    return o;
}
static void read_value(uint64_t address, struct xpy_value *v) {
    struct xpy_reader r = reader();
    xpy_value_read(&L, &r, address, v);
}
static void samples(void) {
    uint8_t a[XPY_SAMPLE_BYTES + 1], b[XPY_SAMPLE_BYTES + 1];
    size_t n, m;
    enum xpy_sample_kind k, q;
    struct xpy_reader r = reader();
    assert(!xpy_value_sample(&L, &r, L.types[XPY_NONE_OBJECT], NULL, 0, &n, &k));
    assert(!n && k == XPY_SAMPLE_NONE);
    r = reader();
    assert(!xpy_value_sample(&L, &r, L.types[XPY_TRUE_OBJECT], a, sizeof a, &n, &k));
    assert(n == 1 && k == XPY_SAMPLE_BOOL && a[0] == 1);
    r = reader();
    assert(!xpy_value_sample(&L, &r, L.types[XPY_FALSE_OBJECT], a, sizeof a, &n, &k));
    assert(n == 1 && k == XPY_SAMPLE_BOOL && a[0] == 0);
    uint64_t zero = small_int(0);
    put(zero + 16, 1, 8); /* zero has no digits, irrespective of allocated storage */
    r = reader();
    assert(!xpy_value_sample(&L, &r, zero, a, sizeof a, &n, &k));
    assert(n == 1 && k == XPY_SAMPLE_INT && a[0] == 1);
    uint64_t integer = small_int(-42);
    r = reader();
    assert(!xpy_value_sample(&L, &r, integer, a, sizeof a, &n, &k));
    assert(n == 5 && k == XPY_SAMPLE_INT && a[0] == 2 && a[1] == 42);
    struct xpy_local immediate = {.immediate = 1, .immediate_integer = -42};
    r = reader();
    assert(!xpy_local_sample(&L, &r, &immediate, b, sizeof b, &m, &q));
    assert(!attempts && n == m && k == q && !memcmp(a, b, n));
    immediate.immediate_integer = INT64_MIN;
    assert(!xpy_local_sample(&L, &r, &immediate, b, sizeof b, &m, &q) && m == 13 && b[0] == 2);
    immediate.immediate_integer = 0;
    assert(!xpy_local_sample(&L, &r, &immediate, b, sizeof b, &m, &q) && m == 1 && b[0] == 1);
    uint64_t large = object(L.types[XPY_TYPE_LONG], 24 + 40 * 4, 1);
    put(large + 16, 40u << 3, 8); put(large + 24 + 39 * 4, 1, 4);
    struct xpy_value va, vb;
    read_value(large, &va);
    r = reader();
    assert(!xpy_value_sample(&L, &r, large, a, sizeof a, &n, &k));
    put(large + 24, 7, 4); read_value(large, &vb);
    r = reader();
    assert(!xpy_value_sample(&L, &r, large, b, sizeof b, &m, &q));
    assert(va.truncated && !strcmp(va.display, vb.display));
    assert(n == m && k == q && memcmp(a, b, n));
    put(large + 24 + 39 * 4, 0, 4); r = reader();
    assert(!strcmp(xpy_value_sample(&L, &r, large, b, sizeof b, &m, &q), "InconsistentIntDigit") && !m);
    uint64_t real = object(L.types[XPY_TYPE_FLOAT], 24, 1);
    put(real + 16, UINT64_C(0x8000000000000000), 8); r = reader();
    assert(!xpy_value_sample(&L, &r, real, a, sizeof a, &n, &k));
    assert(k == XPY_SAMPLE_FLOAT && n == 8 && a[7] == 0x80);
    put(real + 16, UINT64_C(0x7ff8000000000001), 8); r = reader();
    assert(!xpy_value_sample(&L, &r, real, a, sizeof a, &n, &k));
    put(real + 16, UINT64_C(0x7ff8000000000002), 8); r = reader();
    assert(!xpy_value_sample(&L, &r, real, b, sizeof b, &m, &q));
    assert(n == m && k == q && memcmp(a, b, n));
    uint8_t raw[XPY_SAMPLE_BYTES + 1]; memset(raw, 'a', sizeof raw);
    raw[0] = 0; raw[100] = 0xff;
    uint64_t blob = bytes_object(raw, XPY_SAMPLE_BYTES);
    memset(a, 0xa5, sizeof a); r = reader();
    assert(!xpy_value_sample(&L, &r, blob, a, sizeof a, &n, &k));
    assert(k == XPY_SAMPLE_BYTES_KIND && n == XPY_SAMPLE_BYTES && !memcmp(a, raw, n) && a[n] == 0xa5);
    put(blob + 16, XPY_SAMPLE_BYTES + 1, 8); r = reader();
    assert(!strcmp(xpy_value_sample(&L, &r, blob, a, sizeof a, &n, &k), "PythonWatchSampleLimit") && !n);
    uint64_t text = str_kind(raw + 101, 300, 1, 1);
    read_value(text, &va); r = reader();
    assert(!xpy_value_sample(&L, &r, text, a, sizeof a, &n, &k));
    put(text + 40 + 299, 'b', 1); read_value(text, &vb); r = reader();
    assert(!xpy_value_sample(&L, &r, text, b, sizeof b, &m, &q));
    assert(n == 1200 && k == XPY_SAMPLE_STR && n == m && k == q && memcmp(a, b, n));
    assert(va.truncated && !strcmp(va.display, vb.display));
    uint8_t latin[] = { 'x', 0xe9 }, wide[] = { 'x', 0, 0xe9, 0 };
    uint64_t one = str_kind(latin, 2, 1, 0), two = str_kind(wide, 2, 2, 0);
    r = reader(); assert(!xpy_value_sample(&L, &r, one, a, sizeof a, &n, &k));
    r = reader(); assert(!xpy_value_sample(&L, &r, two, b, sizeof b, &m, &q));
    assert(n == m && k == q && !memcmp(a, b, n));
    uint8_t cps[] = {0, 0xd8, 0, 0, 0xff, 0xff, 0x10, 0}; /* lone surrogate and Unicode maximum */
    uint64_t unicode = str_kind(cps, 2, 4, 0);
    r = reader(); assert(!xpy_value_sample(&L, &r, unicode, a, sizeof a, &n, &k));
    assert(n == sizeof cps && !memcmp(a, cps, n));
    put(unicode + 56 + 4, 0x110000, 4); r = reader();
    assert(!strcmp(xpy_value_sample(&L, &r, unicode, a, sizeof a, &n, &k), "InconsistentStr"));
    uint64_t oversized = str_kind(raw + 101, 1025, 1, 1); r = reader();
    assert(!strcmp(xpy_value_sample(&L, &r, oversized, a, sizeof a, &n, &k), "PythonWatchSampleLimit") && !n);
    uint64_t subclass = object(type_object("Number", 1u << 24), 32, 1); r = reader();
    assert(!strcmp(xpy_value_sample(&L, &r, subclass, a, sizeof a, &n, &k), "PythonWatchValueUnsupported"));
    uint64_t container = list(NULL, 0); r = reader();
    assert(!strcmp(xpy_value_sample(&L, &r, container, a, sizeof a, &n, &k), "PythonWatchValueUnsupported"));
    r = reader(); assert(!xpy_value_sample(&L, &r, text, a, sizeof a, &n, &k));
    size_t reads = attempts;
    for (size_t i = 1; i <= reads; ++i) {
        r = reader(); fail_at = i;
        assert(xpy_value_sample(&L, &r, text, a, sizeof a, &n, &k) && !n);
    }
    fail_at = 0;
    put(integer + 16, 9, 8); r = reader(); /* zero sign with a nonzero digit count */
    assert(!strcmp(xpy_value_sample(&L, &r, integer, a, sizeof a, &n, &k), "InconsistentInt"));
}
static void values(void) {
    struct xpy_value v;
    read_value(L.types[XPY_NONE_OBJECT], &v);
    assert(!v.reason && !strcmp(v.display, "None") && v.immortal);
    read_value(L.types[XPY_TRUE_OBJECT], &v);
    assert(!strcmp(v.display, "True"));
    read_value(small_int(42), &v);
    assert(!v.reason && !strcmp(v.display, "int 42") && v.refcount == 3 && !v.immortal);
    read_value(small_int(0), &v);
    assert(!strcmp(v.display, "int 0"));
    read_value(small_int(-7), &v);
    assert(!strcmp(v.display, "int -7"));
    /* -(2**70 + 5): three 30-bit digits */
    uint64_t big = object(L.types[XPY_TYPE_LONG], 40, 1);
    put(big + 16, (3u << 3) | 2, 8);
    put(big + 24, 5, 4);
    put(big + 28, 0, 4);
    put(big + 32, 1u << 10, 4);
    read_value(big, &v);
    assert(!v.reason && !strcmp(v.display, "int -1180591620717411303429"));
    put(big + 28, 1u << 30, 4);
    read_value(big, &v);
    assert(!strcmp(v.reason, "InconsistentIntDigit") && strstr(v.display, "inconsistent"));
    double d = 3.25;
    uint64_t fl = object(L.types[XPY_TYPE_FLOAT], 24, 1), bits;
    memcpy(&bits, &d, 8);
    put(fl + 16, bits, 8);
    read_value(fl, &v);
    assert(!strcmp(v.display, "float 3.25"));
    d = 0.1;
    memcpy(&bits, &d, 8);
    put(fl + 16, bits, 8);
    read_value(fl, &v);
    assert(!strcmp(v.display, "float 0.1"));
    d = 2;
    memcpy(&bits, &d, 8);
    put(fl + 16, bits, 8);
    read_value(fl, &v);
    assert(!strcmp(v.display, "float 2.0"));
    read_value(ascii("it's"), &v);
    assert(!v.reason && !strcmp(v.display, "str 'it\\'s'") && v.count == 4);
    const unsigned char latin1[] = {'h', 0xe9, 'l', 'l', 'o', '\n'};
    read_value(str_kind(latin1, 6, 1, 0), &v);
    assert(!v.reason && !strcmp(v.display, "str 'h\xc3\xa9llo\\n'"));
    const uint16_t ucs2[] = {0x3bb, 0xd800};
    read_value(str_kind(ucs2, 2, 2, 0), &v);
    assert(!v.reason && !strcmp(v.display, "str '\xce\xbb\\ud800'"));
    const uint32_t ucs4[] = {0x1f600};
    read_value(str_kind(ucs4, 1, 4, 0), &v);
    assert(!v.reason && !strcmp(v.display, "str '\xf0\x9f\x98\x80'"));
    char longer[300];
    memset(longer, 'x', sizeof longer - 1);
    longer[sizeof longer - 1] = 0;
    read_value(ascii(longer), &v);
    assert(v.truncated && v.count == 299 && strstr(v.display, "...' (299 chars)") == NULL && strstr(v.display, "'... (299 chars)"));
    /* ascii flag with a non-1 kind is inconsistent */
    uint64_t bad = str_kind(ucs2, 2, 2, 0);
    put(bad + 32, (2u << 2) | (1u << 5) | (1u << 6), 4);
    read_value(bad, &v);
    assert(!strcmp(v.reason, "InconsistentStr"));
    /* non-compact (str subclass instance) uses its data pointer */
    uint64_t legacy = object(L.types[XPY_TYPE_UNICODE], 64, 1), data = alloc(8);
    put(legacy + 16, 3, 8);
    put(legacy + 32, (1u << 2), 4);
    put(legacy + 56, data, 8);
    bytes(data, "abc", 3);
    read_value(legacy, &v);
    assert(!v.reason && !strcmp(v.display, "str 'abc'"));
    put(legacy + 32, (1u << 2) | (1u << 6), 4); /* ASCII but not compact */
    read_value(legacy, &v);
    assert(!v.reason && !strcmp(v.display, "str 'abc'"));
    read_value(bytes_object("raw\0'b", 6), &v);
    assert(!v.reason && !strcmp(v.display, "bytes b'raw\\x00\\'b'"));
    uint64_t items[9];
    for (int i = 0; i < 9; ++i)
        items[i] = small_int(i);
    items[1] = ascii("one");
    items[2] = L.types[XPY_NONE_OBJECT];
    uint64_t lst = list(items, 9);
    read_value(lst, &v);
    assert(!v.reason && !strcmp(v.display, "list (9 items)") && v.item_count == 8 && v.truncated);
    assert(!strcmp(v.items[0].display, "0") && !strcmp(v.items[0].type, "int") && !strcmp(v.items[1].display, "'one'"));
    assert(!strcmp(v.items[2].display, "None") && !strcmp(v.items[3].key, "[3]"));
    /* a list containing itself is bounded by depth */
    uint64_t self = list(items, 1);
    put(self + 24, alloc(8), 8);
    {
        uint64_t arr = alloc(8);
        put(self + 24, arr, 8);
        put(arr, self, 8);
        read_value(self, &v);
        assert(!strcmp(v.items[0].display, "list (1 item)"));
    }
    uint64_t tup = object(L.types[XPY_TYPE_TUPLE], 40, 1);
    put(tup + 16, 2, 8);
    put(tup + 24, ascii("t"), 8);
    put(tup + 32, small_int(1), 8);
    read_value(tup, &v);
    assert(!strcmp(v.display, "tuple (2 items)") && !strcmp(v.items[0].display, "'t'") && !strcmp(v.items[1].display, "1"));
    /* combined dict with unicode keys: indices then {key, value} entries */
    uint64_t keys = alloc(32 + 8 + 5 * 16);
    put(keys + 8, 3, 1);  /* log2 size 8 */
    put(keys + 9, 3, 1);  /* 8 one-byte indices */
    put(keys + 10, 1, 1); /* DICT_KEYS_UNICODE */
    put(keys + 24, 2, 8);
    put(keys + 40, ascii("answer"), 8);
    put(keys + 48, small_int(42), 8);
    put(keys + 56, ascii("gone"), 8); /* deleted: value NULL */
    uint64_t dict = object(L.types[XPY_TYPE_DICT], 48, 1);
    put(dict + 16, 1, 8);
    put(dict + 32, keys, 8);
    read_value(dict, &v);
    assert(!v.reason && !strcmp(v.display, "dict (1 item)") && v.item_count == 1);
    assert(!strcmp(v.items[0].key, "'answer'") && !strcmp(v.items[0].display, "42"));
    /* split dict: values live in ma_values */
    uint64_t split_keys = alloc(32 + 8 + 16), vals = alloc(8 + 16);
    put(split_keys + 8, 3, 1);
    put(split_keys + 9, 3, 1);
    put(split_keys + 10, 2, 1);
    put(split_keys + 24, 1, 8);
    put(split_keys + 40, ascii("x"), 8);
    put(vals + 8, ascii("y"), 8);
    uint64_t split = object(L.types[XPY_TYPE_DICT], 48, 1);
    put(split + 16, 1, 8);
    put(split + 32, split_keys, 8);
    put(split + 40, vals, 8);
    read_value(split, &v);
    assert(!v.reason && !strcmp(v.items[0].key, "'x'") && !strcmp(v.items[0].display, "'y'"));
    put(split + 16, 5, 8); /* used > nentries */
    read_value(split, &v);
    assert(!strcmp(v.reason, "InconsistentDict"));
    /* freed, overwritten and type-less objects */
    uint64_t freed = small_int(9);
    put(freed, 0, 8);
    read_value(freed, &v);
    assert(!strcmp(v.reason, "FreedObject") && !strcmp(v.type, "freed"));
    put(freed, 0x00007f1234567890ull, 8);
    read_value(freed, &v);
    assert(!strcmp(v.reason, "ObjectHeaderInvalid"));
    put(freed, 1, 8);
    put(freed + 8, small_int(1), 8); /* ob_type is an int, not a type */
    read_value(freed, &v);
    assert(!strcmp(v.reason, "ObjectTypeInvalid"));
    put(freed + 8, 0x10, 8);
    read_value(freed, &v);
    assert(!strcmp(v.reason, "ObjectTypeUnreadable") || !strcmp(v.reason, "MemoryUnreadable"));
    /* list type without its fast-subclass flag */
    put(L.types[XPY_TYPE_LIST] + TP_FLAGS, 0, 8);
    read_value(lst, &v);
    assert(!strcmp(v.reason, "InconsistentTypeFlags"));
    put(L.types[XPY_TYPE_LIST] + TP_FLAGS, 1u << 25, 8);
    put(lst + 16, (uint64_t)-1, 8);
    read_value(lst, &v);
    assert(!strcmp(v.reason, "InconsistentList"));
    put(lst + 16, 9, 8);
    /* a user-defined object shows its type name only */
    uint64_t foo = object(type_object("Foo", 0), 16, 1);
    read_value(foo, &v);
    assert(!v.reason && !strcmp(v.display, "<Foo object>") && !strcmp(v.type, "Foo"));
    read_value(L.types[XPY_TYPE_LIST], &v);
    assert(!strcmp(v.display, "<class 'list'>"));
    /* an int subclass keeps its name */
    uint64_t sub = object(type_object("Color", 1u << 24), 32, 1);
    put(sub + 16, (1u << 3), 8);
    put(sub + 24, 2, 4);
    read_value(sub, &v);
    assert(!strcmp(v.display, "Color(int) 2"));
    /* CPython's shared empty keys (Py_EMPTY_KEYS): {} and dict() */
    uint64_t empty_keys = alloc(64);
    put(empty_keys + 9, 3, 1);
    put(empty_keys + 10, 1, 1);
    uint64_t empty = object(L.types[XPY_TYPE_DICT], 48, 1);
    put(empty + 32, empty_keys, 8);
    read_value(empty, &v);
    assert(!v.reason && !strcmp(v.display, "dict (0 items)"));
    put(empty + 16, 1, 8); /* used without entries stays inconsistent */
    read_value(empty, &v);
    assert(!strcmp(v.reason, "InconsistentDict"));
    /* exact bit length past the decimal bound: 29 digits, top digit 1 */
    uint64_t huge = object(L.types[XPY_TYPE_LONG], 24 + 29 * 4, 1);
    put(huge + 16, 29u << 3, 8);
    put(huge + 24 + 28 * 4, 1, 4);
    read_value(huge, &v);
    assert(!strcmp(v.display, "int <841 bits>") && v.truncated);
    /* bidi, zero-width and NBSP are escaped like str.__repr__ */
    const uint32_t hidden[] = {'a', 0x202e, 0x200b, 0xa0, 0xe0041, 'b'};
    read_value(str_kind(hidden, 6, 4, 0), &v);
    assert(!strcmp(v.display, "str 'a\\u202e\\u200b\\xa0\\U000e0041b'"));
    /* a long key is cut on a UTF-8 boundary with an ellipsis */
    uint8_t accents[60];
    for (int i = 0; i < 60; ++i)
        accents[i] = 0xe9;
    uint64_t long_keys = alloc(32 + 8 + 16);
    put(long_keys + 8, 3, 1);
    put(long_keys + 9, 3, 1);
    put(long_keys + 10, 1, 1);
    put(long_keys + 24, 1, 8);
    put(long_keys + 40, str_kind(accents, 60, 1, 0), 8);
    put(long_keys + 48, small_int(1), 8);
    uint64_t long_dict = object(L.types[XPY_TYPE_DICT], 48, 1);
    put(long_dict + 16, 1, 8);
    put(long_dict + 32, long_keys, 8);
    read_value(long_dict, &v);
    {
        size_t n = strlen(v.items[0].key);
        assert(n < sizeof v.items[0].key && !strcmp(v.items[0].key + n - 3, "...") && (unsigned char)v.items[0].key[n - 4] == 0xa9);
    }
    /* one unreadable item is that item's problem only */
    uint64_t mixed[3] = {small_int(1), small_int(2), small_int(3)};
    uint64_t mix = list(mixed, 3);
    put(mixed[1] + 8, BASE - 4096, 8); /* ob_type unreadable */
    read_value(mix, &v);
    assert(!v.reason && v.item_count == 3 && v.items[1].reason && !strcmp(v.items[2].display, "3"));
    /* subclass names for str and bytes */
    uint64_t text_type = type_object("Text", 1u << 28);
    uint64_t sub_str = str_kind("sub", 3, 1, 1);
    put(sub_str + 8, text_type, 8);
    read_value(sub_str, &v);
    assert(!strcmp(v.display, "Text(str) 'sub'"));
    /* every individual failed read is reported, never crashes */
    for (fail_at = 1; fail_at < 64; ++fail_at) {
        struct xpy_reader r = {.read = read_fake};
        attempts = 0;
        xpy_value_read(&L, &r, dict, &v);
        assert(v.reason || v.item_count == 0 || v.items[0].reason || r.error == NULL);
    }
    fail_at = 0;
}
static void lines(void) {
    /* firstlineno 10: short form (line 10, 2 units), one-line +1 (line 11,
     * 1 unit), no-column -3 (line 8, 1 unit), none (no line, 1 unit),
     * long +20 (line 28, 2 units) */
    const uint8_t t[] = {0x80 | (0 << 3) | 1, 0x00,
                         0x80 | (11 << 3) | 0, 0x01, 0x02,
                         0x80 | (13 << 3) | 0, 7,
                         0x80 | (15 << 3) | 0,
                         0x80 | (14 << 3) | 1, 40, 0, 1, 1};
    int line;
    assert(xpy_line_for(t, sizeof t, 10, 0, &line) && line == 10);
    assert(xpy_line_for(t, sizeof t, 10, 1, &line) && line == 10);
    assert(xpy_line_for(t, sizeof t, 10, 2, &line) && line == 11);
    assert(xpy_line_for(t, sizeof t, 10, 3, &line) && line == 8);
    assert(xpy_line_for(t, sizeof t, 10, 4, &line) && line == -1);
    assert(xpy_line_for(t, sizeof t, 10, 5, &line) && line == 28);
    assert(xpy_line_for(t, sizeof t, 10, 6, &line) && line == 28);
    assert(!xpy_line_for(t, sizeof t, 10, 7, &line));
    assert(!xpy_line_for(t, 9, 10, 5, &line)); /* truncated varint */
    const uint8_t continuation[] = {0x80 | (13 << 3), 0x40, 0x01}; /* varint 64: +32 */
    assert(xpy_line_for(continuation, sizeof continuation, 1, 0, &line) && line == 33);
    const uint8_t garbage[] = {0x01, 0x02};
    assert(!xpy_line_for(garbage, sizeof garbage, 1, 0, &line));
}
static uint64_t code(const char *qualname, const char *file, const uint8_t *table, size_t n, int first, uint32_t flags,
                     size_t units) {
    uint64_t co = object(L.types[XPY_TYPE_CODE], 208 + 2 * units, 1);
    put(co + 16, units, 8);
    put(co + 48, flags, 4);
    put(co + 68, (uint32_t)first, 4);
    put(co + 128, ascii(qualname), 8);
    put(co + 112, ascii(file), 8);
    put(co + 136, bytes_object(table, n), 8);
    return co;
}
static uint64_t frame(uint64_t at, uint64_t executable, uint64_t previous, uint64_t instr, uint8_t owner) {
    uint64_t f = at ? at : alloc(88);
    put(f, executable, 8);
    put(f + 8, previous, 8);
    put(f + 56, instr, 8);
    put(f + 74, owner, 1);
    return f;
}
static void stacks(void) {
    const uint8_t table[] = {0x80 | (13 << 3) | 7, 0, 0x80 | (11 << 3) | 7}; /* units 0-7 line 5, 8-15 line 6 */
    uint64_t inner = code("Outer.inner", "/w/demo.py", table, sizeof table, 5, 0, 16);
    uint64_t gen = code("gen", "/w/demo.py", table, sizeof table, 20, 0x20, 16);
    uint64_t module = code("<module>", "/w/demo.py", table, sizeof table, 1, 0, 16);
    /* native activations: two C-stack regions */
    struct xpy_range ranges[2] = {{BASE + 0x180000, BASE + 0x181000}, {BASE + 0x182000, BASE + 0x183000}};
    uint64_t base_frame = alloc(88);
    frame(base_frame, 0, 0, 0, XPY_OWNED_BY_INTERPRETER);
    uint64_t e2 = frame(BASE + 0x182100, 3 << 2, base_frame, 0, XPY_OWNED_BY_INTERPRETER);
    uint64_t m = frame(0, module | 1, e2, module + 208 + 2 * 9, XPY_OWNED_BY_THREAD);
    uint64_t e1 = frame(BASE + 0x180100, 3 << 2, m, 0, XPY_OWNED_BY_INTERPRETER);
    uint64_t g = frame(0, gen, e1, gen + 208 + 2, XPY_OWNED_BY_GENERATOR);
    uint64_t top = frame(0, inner, g, inner + 208 + 2 * 3, XPY_OWNED_BY_THREAD);
    uint64_t interp = alloc(128), other = alloc(128), ts = alloc(128), ts2 = alloc(128);
    put(L.runtime + 40, interp, 8);
    put(interp + 8, 0, 8);
    put(interp + 72, ts2, 8);
    put(ts2 + 8, ts, 8);
    put(ts2 + 16, interp, 8);
    put(ts2 + 72, 999, 8);
    put(ts + 16, interp, 8);
    put(ts + 72, 4242, 8);
    put(ts + 56, top, 8);
    put(interp + 0, other, 8);
    put(other + 8, 1, 8); /* a subinterpreter with no thread states */
    static struct xpy_stack s;
    struct xpy_reader r = reader();
    xpy_stack_read(&L, &r, 4242, ranges, 2, 0, &s);
    assert(!s.reason && s.thread_states == 1 && s.segment_count == 2 && s.count == 3);
    assert(s.segments[0].chain_complete && s.segments[1].chain_complete);
    assert(s.frames[0].identity_proved && s.frames[1].identity_proved && s.frames[2].identity_proved);
    assert(s.segments[0].anchor == 0 && s.segments[0].count == 2 && !s.segments[0].reason);
    assert(s.segments[0].entry_frame == e1 && s.segments[1].anchor == 1 && s.segments[1].entry_frame == e2);
    assert(!strcmp(s.frames[0].name, "Outer.inner") && s.frames[0].line == 5 && !strcmp(s.frames[0].file, "/w/demo.py"));
    assert(!strcmp(s.frames[1].name, "gen") && s.frames[1].code_flags == 0x20 && s.frames[1].owner == XPY_OWNED_BY_GENERATOR);
    assert(!strcmp(s.frames[2].name, "<module>") && s.frames[2].line == 2);
    assert(r.reads < 200);
    assert(s.entry_found[0] && s.entry_found[1]);
    /* first=1: segment 0 is proven but retains nothing; segment 1 keeps all */
    xpy_stack_read(&L, (r = reader(), &r), 4242, ranges, 2, 1, &s);
    assert(s.segment_count == 2 && s.segments[0].skipped && !s.segments[0].count && s.segments[0].anchor == 0);
    assert(!s.segments[0].chain_complete && !s.segments[1].chain_complete);
    assert(s.segments[1].count == 1 && s.segments[1].first == 0 && !strcmp(s.frames[0].name, "<module>") && s.frames[0].line == 2);
    /* entry frame outside every native activation: unanchored, partial */
    xpy_stack_read(&L, (r = reader(), &r), 4242, ranges + 1, 1, 0, &s);
    assert(s.segments[0].anchor == -1 && !strcmp(s.segments[0].reason, "EntryFrameOutsideNativeAnchors"));
    assert(s.segments[1].anchor == 0);
    /* inverted native order cannot be a proof */
    struct xpy_range swapped[2] = {ranges[1], ranges[0]};
    xpy_stack_read(&L, (r = reader(), &r), 4242, swapped, 2, 0, &s);
    assert(s.segments[0].anchor == 1 && !strcmp(s.segments[1].reason, "AnchorOrderInconsistent"));
    /* no native ranges: still read, never anchored */
    xpy_stack_read(&L, (r = reader(), &r), 4242, NULL, 0, 0, &s);
    assert(s.segment_count == 2 && s.segments[0].anchor == -1 && s.segments[1].anchor == -1);
    /* unknown tid */
    xpy_stack_read(&L, (r = reader(), &r), 7, ranges, 2, 0, &s);
    assert(!s.reason && s.thread_states == 0 && s.segment_count == 0);
    /* corrupted executable, instruction and owner */
    put(g, small_int(3), 8);
    xpy_stack_read(&L, (r = reader(), &r), 4242, ranges, 2, 0, &s);
    assert(!strcmp(s.frames[1].reason, "ExecutableNotCode") && !strcmp(s.segments[0].reason, "PartialFrames"));
    assert(!s.frames[1].identity_proved && s.segments[0].chain_complete);
    put(g, gen | 2, 8);
    xpy_stack_read(&L, (r = reader(), &r), 4242, ranges, 2, 0, &s);
    assert(!s.frames[1].identity_proved && !strcmp(s.frames[1].reason, "ExecutableStackRefInvalid"));
    put(g, gen, 8);
    put(top + 56, inner + 4096, 8);
    xpy_stack_read(&L, (r = reader(), &r), 4242, ranges, 2, 0, &s);
    assert(!strcmp(s.frames[0].reason, "InstructionOutsideCode") && !s.frames[0].line);
    put(top + 56, inner + 208 + 6, 8);
    put(g + 74, 9, 1);
    xpy_stack_read(&L, (r = reader(), &r), 4242, ranges, 2, 0, &s);
    assert(!strcmp(s.segments[0].reason, "FrameOwnerInvalid"));
    assert(!s.segments[0].chain_complete);
    put(g + 74, XPY_OWNED_BY_CSTACK, 1); /* only 3.14 has a C-stack owner */
    L.version = 0x031000a0;
    xpy_stack_read(&L, (r = reader(), &r), 4242, ranges, 2, 0, &s);
    assert(!strcmp(s.segments[0].reason, "FrameOwnerInvalid"));
    L.version = 0x030e07f0;
    put(g + 74, XPY_OWNED_BY_GENERATOR, 1);
    /* a cycle in the chain */
    put(m + 8, g, 8);
    xpy_stack_read(&L, (r = reader(), &r), 4242, ranges, 2, 0, &s);
    assert(!strcmp(s.segments[s.segment_count - 1].reason, "FrameCycle"));
    for (size_t i = 0; i < s.segment_count; ++i) assert(!s.segments[i].chain_complete);
    put(m + 8, e2, 8);
    /* deep recursion: retained and examined frames are bounded */
    uint64_t prev = e1;
    for (int i = 0; i < 5000; ++i)
        prev = frame(0, inner, prev, inner + 208, XPY_OWNED_BY_THREAD);
    put(ts + 56, prev, 8);
    xpy_stack_read(&L, (r = reader(), &r), 4242, ranges, 2, 0, &s);
    assert(s.count == XPY_SEGMENT_FRAMES && !strcmp(s.segments[0].reason, "FrameExaminedLimit"));
    assert(s.segments[0].examined == XPY_MAX_EXAMINED && r.reads < XPY_MAX_EXAMINED + 1200);
    put(ts + 56, top, 8);
    /* a thread-state cycle */
    put(ts + 8, ts2, 8);
    xpy_stack_read(&L, (r = reader(), &r), 4242, ranges, 2, 0, &s);
    assert(!strcmp(s.reason, "ThreadStateCycle"));
    put(ts + 8, 0, 8);
    /* every individual failed read is reported */
    for (fail_at = 1; fail_at < 160; ++fail_at) {
        struct xpy_reader fr = {.read = read_fake};
        attempts = 0;
        xpy_stack_read(&L, &fr, 4242, ranges, 2, 0, &s);
        if (fr.error) {
            int partial = s.reason != NULL;
            for (size_t i = 0; i < s.segment_count; ++i)
                partial |= s.segments[i].reason != NULL;
            assert(partial);
        }
    }
    fail_at = 0;
}
static void named_locals(void) {
    setup();
    const char *names[] = {"arg", "plain", "free", "cell", "empty", "gone", "small", "shadow", "shadow", "early_cell", "\xce\xb1"};
    const unsigned char kinds[] = {0x22, 0x20, 0x80, 0x40, 0x40, 0x20, 0x20, 0x30, 0x30, 0x60, 0x20};
    const size_t count = sizeof kinds;
    uint64_t co = object(L.types[XPY_TYPE_CODE], 256, 1);
    uint64_t nt = object(L.types[XPY_TYPE_TUPLE], 24 + count * 8, 1);
    uint64_t kt = bytes_object(kinds, count);
    uint64_t fr = alloc(80 + count * 8);
    uint64_t cell = object(L.types[XPY_TYPE_CELL], 24, 1);
    uint64_t empty = object(L.types[XPY_TYPE_CELL], 24, 1);
    uint64_t n42 = small_int(42), n99 = small_int(99);
    put(nt + 16, count, 8);
    for (size_t i = 0; i < count; ++i) {
        uint64_t name = i + 1 == count ? str_kind("\xb1\x03", 1, 2, 0) : ascii(names[i]);
        put(nt + 24 + i * 8, name, 8);
    }
    put(co + 48, 1, 4); put(co + 52, 1, 4);
    put(co + 96, nt, 8); put(co + 104, kt, 8);
    put(fr, co | 1, 8); put(fr + 64, fr + 80 + count * 8, 8);
    put(fr + 74, XPY_OWNED_BY_GENERATOR, 1);
    put(cell + 16, n99, 8);
    uint64_t values[] = {n42 | 1, n99, cell, cell | 1, empty, 1, ((uint64_t)-27 << 2) | 3, 1, n42, n99, n42};
    for (size_t i = 0; i < count; ++i) put(fr + 80 + i * 8, values[i], 8);
    struct xpy_locals out;
    struct xpy_reader r = reader();
    xpy_locals_read(&L, &r, fr, co, 0, 32, &out);
    assert(!out.reason && out.count == count && out.total == count && !out.truncated);
    size_t successful_reads = attempts;
    assert(out.items[0].scope == XPY_PARAMETER && out.items[0].address == n42);
    assert(out.items[1].scope == XPY_LOCAL && out.items[1].address == n99);
    assert(out.items[2].scope == XPY_FREE && out.items[2].address == n99);
    assert(out.items[3].scope == XPY_CELL && out.items[3].address == n99);
    assert(!strcmp(out.items[4].reason, "PythonUnboundLocal") && !out.items[4].address);
    assert(!strcmp(out.items[5].reason, "PythonUnboundLocal") && !out.items[5].address);
    assert(!out.items[6].address && out.items[6].immediate && !strcmp(out.items[6].value.display, "int -27"));
    assert(out.items[7].hidden && out.items[8].hidden && out.items[9].address == n99);
    assert(!strcmp(out.items[10].name, "\xce\xb1") && out.items[10].address == n42);
    r = reader(); xpy_locals_read(&L, &r, fr, co, 2, 3, &out);
    assert(!out.reason && out.start == 2 && out.count == 3 && out.truncated && out.items[0].ordinal == 2);
    r = reader(); xpy_locals_read(&L, &r, fr, co, count, 3, &out);
    assert(!out.reason && !out.count && !out.truncated);
    r = reader(); xpy_local_find(&L, &r, fr, co, "shadow", &out);
    assert(!out.reason && out.count == 1 && out.start == 8 && out.items[0].address == n42);
    r = reader(); xpy_local_find(&L, &r, fr, co, "\xce\xb1", &out);
    assert(!out.reason && out.count == 1 && out.items[0].ordinal == 10);
    r = reader(); xpy_local_find(&L, &r, fr, co, "gone", &out);
    assert(!out.reason && out.count == 1 && !strcmp(out.items[0].reason, "PythonUnboundLocal"));
    r = reader(); xpy_local_find(&L, &r, fr, co, "missing", &out);
    assert(!strcmp(out.reason, "PythonNameNotFound") && !out.count);
    const char *queries[] = {"", "arg()", "arg.attr", "arg[0]", "arg + 1", "1arg"};
    for (size_t i = 0; i < sizeof queries / sizeof *queries; ++i) {
        r = reader(); xpy_local_find(&L, &r, fr, co, queries[i], &out);
        assert(!strcmp(out.reason, "UnsupportedLanguageExpression") && !r.reads);
    }
    r = reader(); xpy_locals_read(&L, &r, fr, co + 16, 0, 32, &out);
    assert(!strcmp(out.reason, "StaleLanguageFrame"));
    put(co + 48, 0, 4);
    r = reader(); xpy_locals_read(&L, &r, fr, co, 0, 32, &out);
    assert(!strcmp(out.reason, "PythonMappingLocalsUnavailable")); put(co + 48, 1, 4);
    put(kt + 16, count - 1, 8);
    r = reader(); xpy_locals_read(&L, &r, fr, co, 0, 32, &out);
    assert(!strcmp(out.reason, "PythonLocalNamesInvalid")); put(kt + 16, count, 8);
    put(fr + 64, fr + 80 + 8, 8);
    r = reader(); xpy_locals_read(&L, &r, fr, co, 0, 3, &out);
    assert(!out.reason && !out.items[0].reason && !strcmp(out.items[1].reason, "PythonUninitializedLocal"));
    put(fr + 64, fr + 80 + count * 8, 8);
    put(fr + 80 + 2 * 8, n42, 8);
    r = reader(); xpy_local_find(&L, &r, fr, co, "free", &out);
    assert(!strcmp(out.items[0].reason, "PythonFreeCellInvalid")); put(fr + 80 + 2 * 8, cell, 8);
    put(fr + 80, 2, 8);
    r = reader(); xpy_local_find(&L, &r, fr, co, "arg", &out);
    assert(!strcmp(out.items[0].reason, "PythonStackRefInvalid")); put(fr + 80, n42 | 1, 8);
    /* Every individual failed read must survive in the result as evidence. */
    for (size_t fail = 1; fail <= successful_reads; ++fail) {
        r = reader(); fail_at = fail;
        xpy_locals_read(&L, &r, fr, co, 0, 32, &out);
        int unavailable = out.reason != NULL;
        for (size_t i = 0; i < out.count; ++i)
            unavailable |= out.items[i].name_reason != NULL ||
                (out.items[i].reason && strcmp(out.items[i].reason, "PythonUnboundLocal"));
        assert(unavailable);
    }
    fail_at = 0;
    r = reader(); r.reads = 16384;
    xpy_locals_read(&L, &r, fr, co, 0, 32, &out);
    assert(!strcmp(out.reason, "PythonReadLimit"));
    char long_name[700]; memset(long_name, 'z', sizeof long_name - 1); long_name[sizeof long_name - 1] = 0;
    put(nt + 24, ascii(long_name), 8);
    r = reader(); xpy_locals_read(&L, &r, fr, co, 0, 1, &out);
    assert(out.items[0].name_reason);
    r = reader(); xpy_local_find(&L, &r, fr, co, "missing", &out);
    assert(out.reason && strcmp(out.reason, "PythonNameNotFound"));
    put(nt + 16, 4097, 8); put(kt + 16, 4097, 8);
    r = reader(); xpy_locals_read(&L, &r, fr, co, 0, 32, &out);
    assert(!strcmp(out.reason, "PythonLocalLimit"));
}

static void layouts(void) {
    uint8_t p[XPY_DEBUG_OFFSETS_BYTES] = "xdebugpy";
    struct xpy_layout l;
    const uint8_t id[] = {1, 2, 3};
    uint64_t version = 0x030e07f0;
    memcpy(p + 8, &version, 8);
    const uint16_t *pos = xpy_published_positions(version);
    assert(pos);
    for (unsigned i = 0; i < XPY_PUBLISHED_COUNT; ++i) {
        uint64_t v = 8 * (i + 1);
        if (i == XPY_OB_SIZE_OF || i == XPY_LIST_SIZE || i == XPY_TUPLE_SIZE)
            v = 16;
        if (i == XPY_OB_TYPE)
            v = 8;
        if (i == XPY_STR_ASCII_SIZE)
            v = 40;
        if (i == XPY_FR_LOCALSPLUS) v = 80;
        if (i == XPY_FR_STACKPOINTER) v = 64;
        memcpy(p + pos[i], &v, 8);
    }
    assert(!xpy_layout_build(p, sizeof p, NULL, id, 3, &l) && l.fields[XPY_IS_ID] == 16 && !l.dwarf_verified);
    assert(!xpy_layout_check(&l, p, sizeof p, id, 3));
    assert(!strcmp(xpy_layout_check(&l, p, sizeof p, id, 2), "PythonBuildIdMismatch"));
    uint64_t other = 0x030e08f0;
    memcpy(p + 8, &other, 8);
    assert(!strcmp(xpy_layout_check(&l, p, sizeof p, id, 3), "PythonVersionMismatch"));
    other = 0x030f00f0;
    memcpy(p + 8, &other, 8);
    assert(!strcmp(xpy_layout_build(p, sizeof p, NULL, id, 3, &l), "PythonVersionUnsupported"));
    other = 0x031000a0; /* a prerelease needs DWARF */
    memcpy(p + 8, &other, 8);
    assert(!strcmp(xpy_layout_build(p, sizeof p, NULL, id, 3, &l), "PythonLayoutUnverified"));
    other = 0x030e00c1;
    memcpy(p + 8, &other, 8);
    assert(xpy_layout_build(p, sizeof p, NULL, id, 3, &l));
    memcpy(p + 8, &version, 8);
    p[16] = 1;
    assert(!strcmp(xpy_layout_build(p, sizeof p, NULL, id, 3, &l), "PythonFreeThreadedUnsupported"));
    p[16] = 0;
    p[0] = 'X';
    assert(!strcmp(xpy_layout_build(p, sizeof p, NULL, id, 3, &l), "PythonDebugOffsetsUnavailable"));
    p[0] = 'x';
    uint64_t wrong = 24;
    memcpy(p + pos[XPY_OB_SIZE_OF], &wrong, 8);
    assert(!strcmp(xpy_layout_build(p, sizeof p, NULL, id, 3, &l), "PythonLayoutMismatch"));
}
int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "--positions")) {
        /* For header cross-checks: version-independent field names and the
         * positions this reader uses for each supported minor version. */
        const uint64_t versions[] = {0x030e00f0, 0x031000a0};
        for (unsigned v = 0; v < 2; ++v) {
            const uint16_t *pos = xpy_published_positions(versions[v]);
            printf("%x", (unsigned)(versions[v] >> 16));
            for (unsigned i = 0; i < XPY_PUBLISHED_COUNT; ++i)
                printf(" %s=%u", xpy_field_names[i], pos[i]);
            printf("\n");
        }
        printf("unpublished");
        for (unsigned i = XPY_PUBLISHED_COUNT; i < XPY_FIELD_COUNT; ++i)
            printf(" %s=%llu", xpy_field_names[i], (unsigned long long)xpy_unpublished_3_14[i - XPY_PUBLISHED_COUNT]);
        printf("\n");
        return 0;
    }
    setup();
    values();
    samples();
    lines();
    stacks();
    named_locals();
    layouts();
    puts("python reader: ok");
    return 0;
}
