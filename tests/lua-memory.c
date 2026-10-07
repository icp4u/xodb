/* Synthetic storage tests need no Lua SDK. Live/header-oracle tests in
 * lua-reader.c establish actual runtime semantics independently. */
#include "../src/language/lua.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
#define BASE UINT64_C(0x100000)
static unsigned char bytes[8192];
static int memory(void *context, uint64_t address, void *out, size_t size) {
    (void)context;
    if (address < BASE || address - BASE > sizeof bytes || size > sizeof bytes - (address - BASE)) return -1;
    memcpy(out, bytes + (size_t)(address - BASE), size); return 0;
}
static void put(size_t at, uint64_t value, size_t size) {
    assert(size <= 8 && at <= sizeof bytes && size <= sizeof bytes - at);
    for (size_t i = 0; i < size; ++i) bytes[at + i] = (unsigned char)(value >> (8 * i));
}
static struct xl_reader reader(void) { struct xl_reader r = { .read = memory }; return r; }
static struct xl_layout profile(void) {
    struct xl_layout p = { .version = {5, 4, 9}, .build_id = {1}, .build_id_len = 1 };
#define FIELD(key, at, width) p.fields[XL_##key] = (struct xl_field_info){at, width}
    /* Deliberately unlike the real TValue: tag at 0 and payload at 8. */
    FIELD(TAG, 0, 1); FIELD(BITS, 8, 8); FIELD(GC_TAG, 8, 1);
    FIELD(STR_SHORT, 11, 1); FIELD(STR_LEN, 16, 8); FIELD(STR_DATA, 24, 1);
    FIELD(TABLE_FLAGS, 10, 1); FIELD(TABLE_LOG, 11, 1); FIELD(TABLE_SIZE, 12, 4);
    FIELD(TABLE_ARRAY, 16, 8); FIELD(TABLE_NODE, 24, 8); FIELD(TABLE_FREE, 32, 8);
    FIELD(NODE_VALUE, 0, 16); FIELD(NODE_KEY_TAG, 16, 1); FIELD(NODE_KEY_BITS, 24, 8);
    FIELD(STATE_TOP, 16, 8); FIELD(STATE_CI, 32, 8); FIELD(STATE_END, 40, 8);
    FIELD(STATE_STACK, 48, 8); FIELD(STATE_STATUS, 10, 1); FIELD(STATE_BASE, 96, 64);
    FIELD(CI_FUNC, 0, 8); FIELD(CI_TOP, 8, 8); FIELD(CI_PREV, 16, 8); FIELD(CI_NEXT, 24, 8);
    FIELD(CI_STATUS, 62, 2);
#undef FIELD
    p.sizes[XL_T_TVALUE] = p.sizes[XL_T_STACK] = 16; p.sizes[XL_T_NODE] = 32;
    return p;
}
static struct xl_value value(struct xl_layout *p, uint64_t tag, uint64_t payload) {
    put(0, tag, p->fields[XL_TAG].size); put(8, payload, 8);
    struct xl_reader r = reader(); struct xl_value v; xl_value_read(p, &r, BASE, &v); return v;
}
int main(void) {
    struct xl_layout p = profile(); struct xl_value v;
    v = value(&p, 3, (uint64_t)-42); assert(!v.reason && !strcmp(v.display, "integer -42"));
    v = value(&p, 1, UINT64_MAX); assert(!v.reason && !strcmp(v.display, "false"));
    v = value(&p, 17, UINT64_MAX); assert(!v.reason && !strcmp(v.display, "true"));
    v = value(&p, 0, UINT64_MAX); assert(!v.reason && !strcmp(v.display, "nil"));
    v = value(&p, 255, 0); assert(v.reason && !strcmp(v.reason, "LuaTagUnsupported"));
    v = value(&p, 68, BASE+512); assert(v.reason && !strcmp(v.reason, "LuaObjectTagMismatch"));
    put(512+8, 4, 1); put(512+11, 4, 1); memcpy(bytes+512+24, "a\0b\xff", 4);
    v = value(&p, 68, BASE+512); assert(!v.reason && !strcmp(v.display, "string \"a\\x00b\\xff\"") && v.count==4);
    put(512+8, 20, 1); put(512+11, 255, 1); put(512+16, 300, 8);
    memset(bytes+512+24, 'x', 300);
    v = value(&p, 84, BASE+512); assert(!v.reason && v.truncated && v.count==300);
    put(512+16, UINT64_MAX, 8); v = value(&p, 84, BASE+512);
    assert(v.reason && !strcmp(v.reason, "LuaStringLengthInvalid"));
    struct xl_reader r = reader(); r.reads = XL_READ_LIMIT;
    xl_value_read(&p, &r, BASE, &v); assert(v.reason && !strcmp(v.reason, "LuaReadBudget"));
    r = reader(); r.bytes = XL_BYTE_LIMIT;
    xl_value_read(&p, &r, BASE, &v); assert(v.reason && !strcmp(v.reason, "LuaReadBudget"));
    r = reader(); xl_value_read(&p, &r, UINT64_MAX-4, &v); assert(v.reason);
    p.version[1] = 2; p.version[2] = 4; p.fields[XL_TAG].size = 4;
    v = value(&p, 1, UINT64_C(0xdeadbeef00000001)); assert(!v.reason && !strcmp(v.display, "true"));
    v = value(&p, 1, 2); assert(v.reason && !strcmp(v.reason, "LuaBooleanInvalid"));
    p = profile(); memset(bytes, 0, sizeof bytes);
    put(256+8, 8, 1); put(256+32, BASE+512, 8); put(256+48, BASE+1024, 8); put(256+40, BASE+2048, 8);
    put(512, BASE+1024, 8); put(512+8, BASE+1536, 8); put(512+16, BASE+512, 8); put(512+24, BASE+512, 8); put(512+62, 2, 2);
    put(1024, 22, 1); put(1024+8, 0x1234, 8);
    struct xl_stack st; r = reader(); xl_stack_read(&p, &r, BASE+256, &st);
    assert(st.count==1 && st.reason && !strcmp(st.reason, "LuaCallInfoCycle"));
    put(512, BASE+9000, 8); r = reader(); xl_stack_read(&p, &r, BASE+256, &st);
    assert(st.reason && !strcmp(st.reason, "LuaCallInfoBoundsInvalid"));
    /* Reproducible malformed-object smoke corpus. The callback never grants
     * access outside this owned byte array; budgets bound every traversal. */
    uint64_t seed = 7; unsigned tags[] = {0,1,3,17,19,68,84,69,70,102,71,72,255};
    for (unsigned i = 0; i < 2000; ++i) {
        for (size_t j = 256; j < sizeof bytes; ++j) { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; bytes[j] = (unsigned char)seed; }
        unsigned tag = tags[i % (sizeof tags / sizeof *tags)];
        put(0, tag, 1); put(8, BASE+512, 8); put(512+8, tag & 63, 1);
        r = reader(); xl_value_read(&p, &r, BASE, &v);
        assert(r.reads <= XL_READ_LIMIT && r.bytes <= XL_BYTE_LIMIT && v.item_count <= XL_PREVIEW_ITEMS);
        assert(memchr(v.display, 0, sizeof v.display));
        r = reader(); xl_stack_read(&p, &r, BASE+512, &st);
        assert(r.reads <= XL_READ_LIMIT && r.bytes <= XL_BYTE_LIMIT && st.count <= XL_STACK_FRAMES);
    }
    puts("Lua synthetic storage, bounds, cycles and 2000 malformed objects passed");
    return 0;
}
