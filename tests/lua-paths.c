#define _POSIX_C_SOURCE 200809L
#include "../src/language/lua.h"
#include "lstate.h"
#include "lauxlib.h"
#include "lualib.h"
#include <assert.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static struct xl_layout layout;
static int memory_fd;
static size_t reads, fail_at, checks, fault_checks;
static int read_memory(void *unused, uint64_t address, void *out, size_t n) {
    (void)unused;
    if (++reads == fail_at) return -1;
    return pread(memory_fd, out, n, (off_t)address) == (ssize_t)n ? 0 : -1;
}
static struct xl_reader reader(void) {
    reads = 0;
    struct xl_reader r = {.read = read_memory}; return r;
}
static struct xl_locals *find(lua_State *L, const char *expression, struct xl_reader *r) {
    struct xl_locals *out = calloc(1, sizeof *out); assert(out);
    xl_local_find(&layout, r, (uintptr_t)L, 1, expression, out);
    return out;
}
static void why_is(const struct xl_locals *out, const char *expected) {
    if (!out->reason || strcmp(out->reason, expected)) {
        fprintf(stderr, "wanted %s, got %s\n", expected, out->reason ? out->reason : "value"); abort();
    }
}
static int probe(lua_State *L) {
    const char *expression = luaL_checkstring(L, 1);
    const char *expected_error = lua_isstring(L, 3) ? lua_tostring(L, 3) : NULL;
    assert(xl_expression_valid(expression) == !(expected_error && !strcmp(expected_error, "LuaExpressionUnsupported")));
    struct xl_reader r = reader(); struct xl_locals *out = find(L, expression, &r);
    if (expected_error) {
        why_is(out, expected_error);
        if (!strcmp(expected_error, "LuaExpressionUnsupported")) assert(!r.reads);
        free(out); ++checks; return 0;
    }
    if (out->reason) { fprintf(stderr, "check %zu %s: %s\n", checks, expression, out->reason); abort(); }
    assert(out->count == 1 && !out->items[0].reason && !out->items[0].name_truncated);
    unsigned char bytes[XL_SAMPLE_BYTES]; size_t size = 0; enum xl_sample_kind kind;
    const char *why = xl_local_sample(&layout, &r, &out->items[0], bytes, sizeof bytes, &size, &kind);
    int type = lua_type(L, 2);
    if (type == LUA_TNIL) assert(!why && kind == XL_SAMPLE_NIL && size == 0);
    else if (type == LUA_TBOOLEAN) assert(!why && kind == XL_SAMPLE_BOOLEAN && size == 1 && bytes[0] == lua_toboolean(L, 2));
    else if (type == LUA_TNUMBER) {
        uint64_t expected; double number = lua_tonumber(L, 2); memcpy(&expected, &number, 8);
        enum xl_sample_kind wanted = XL_SAMPLE_NUMBER;
#if LUA_VERSION_NUM == 504
        if (lua_isinteger(L, 2)) { expected = (uint64_t)lua_tointeger(L, 2); wanted = XL_SAMPLE_INTEGER; }
#endif
        assert(!why && kind == wanted && size == 8);
        for (unsigned i = 0; i < 8; ++i) assert(bytes[i] == (unsigned char)(expected >> (8 * i)));
    } else if (type == LUA_TSTRING) {
        size_t n; const char *text = lua_tolstring(L, 2, &n);
        if (n > sizeof bytes) assert(why && !strcmp(why, "LuaWatchSampleLimit") && !size);
        else assert(!why && kind == XL_SAMPLE_STRING && size == n && !memcmp(bytes, text, n));
    } else assert(why && !strcmp(why, "LuaWatchValueUnsupported"));
    size_t count = reads;
    assert(count <= XL_READ_LIMIT && r.bytes <= XL_BYTE_LIMIT);
    free(out);
    /* Fail every read in the successful lookup AND the complete sample.
     * Neither nil absence nor a prefix scalar is an acceptable fallback. */
    for (size_t i = 1; i <= count; ++i) {
        fail_at = i; r = reader(); out = find(L, expression, &r);
        why = out->reason ? out->reason : out->count != 1 ? "no row" :
            xl_local_sample(&layout, &r, &out->items[0], bytes, sizeof bytes, &size, &kind);
        assert(reads >= fail_at);
        if (!why) { fprintf(stderr, "%s masked read failure %zu/%zu\n", expression, i, count); abort(); }
        free(out); ++fault_checks;
    }
    fail_at = 0; ++checks; return 0;
}
static int corrupt(lua_State *L) {
    Table *table = (Table *)lua_topointer(L, 1); assert(table);
    unsigned char old_log = table->lsizenode;
    table->lsizenode = 8;
    struct xl_reader r = reader(); struct xl_locals *out = find(L, "object.a", &r);
    table->lsizenode = old_log;
    why_is(out, "LuaPathWorkLimit"); free(out); ++checks;
    /* Duplicate keys are malformed even if one would match early in the scan. */
    unsigned char *first = NULL, *second = NULL;
    size_t stride = layout.sizes[XL_T_NODE];
    for (size_t i = 0; i < (size_t)1 << table->lsizenode; ++i) {
        unsigned char *node = (unsigned char *)table->node + i * stride;
        unsigned char tag = node[layout.fields[XL_NODE_VALUE].offset + layout.fields[XL_TAG].offset];
        if (!(tag & 15)) continue;
        if (!first) first = node; else { second = node; break; }
    }
    assert(first && second);
    struct xl_field_info kt = layout.fields[XL_NODE_KEY_TAG], kb = layout.fields[XL_NODE_KEY_BITS];
    unsigned char saved_tag[8], saved_bits[8];
    memcpy(saved_tag, second + kt.offset, kt.size); memcpy(saved_bits, second + kb.offset, kb.size);
    memcpy(second + kt.offset, first + kt.offset, kt.size); memcpy(second + kb.offset, first + kb.offset, kb.size);
    r = reader(); out = find(L, "object.a", &r);
    /* The hash order is randomized; use the duplicated key's actual bytes. */
    if (!out->reason) {
        free(out); r = reader(); out = find(L, "object.b", &r);
    }
    memcpy(second + kt.offset, saved_tag, kt.size); memcpy(second + kb.offset, saved_bits, kb.size);
    why_is(out, "LuaPathKeyAmbiguous"); free(out); ++checks;
    return 0;
}
int main(int argc, char **argv) {
    (void)argc;
    assert(!xl_expression_valid(NULL) && !xl_expression_valid(""));
    assert(xl_expression_valid("root[-2147483648]") && xl_expression_valid("root[2147483647]"));
    assert(!xl_expression_valid("root[-2147483649]") && !xl_expression_valid("root[2147483648]"));
    memory_fd = open("/proc/self/mem", O_RDONLY); assert(memory_fd >= 0);
    int fd = open(argv[0], O_RDONLY); assert(fd >= 0);
    Dwarf *dwarf = dwarf_begin(fd, DWARF_C_READ); assert(dwarf);
    const uint8_t version[] = {5, LUA_VERSION_NUM == 504 ? 4 : 2, LUA_VERSION_NUM == 504 ? 9 : 4}, id[] = {1};
    const char *why = xl_layout_build(dwarf, id, sizeof id, version, &layout);
    if (why) { fprintf(stderr, "layout: %s\n", why); return 1; }
    assert(layout.fields[XL_TABLE_META].offset == offsetof(Table, metatable));
    lua_State *L = luaL_newstate(); assert(L); luaL_openlibs(L);
    lua_register(L, "probe", probe); lua_register(L, "corrupt", corrupt);
    const char script[] =
        "local object={a=7,b=false,child={value='abc', {name=8}},[-2]=17,[0]=19,[2147483647]=21,[-2147483648]=23}\n"
        "probe('object.a',object.a); probe('object.b',object.b); probe('object.missing',nil)\n"
        "probe('object[-2]',object[-2]); probe('object[0]',object[0]); probe('object[-0]',object[0])\n"
        "probe('object[2147483647]',object[2147483647]); probe('object[-2147483648]',object[-2147483648])\n"
        "probe('object.child[1].name',object.child[1].name); probe('object.child[2]',nil)\n"
        "probe('object.child.value',object.child.value); probe('object.child',object.child)\n"
        "object.child={value=string.rep('z',300)..'a'}; collectgarbage('collect'); probe('object.child.value',object.child.value)\n"
        "object.child.value=string.rep('z',300)..'b'; probe('object.child.value',object.child.value)\n"
        "object.child.value=string.rep('x',4096); probe('object.child.value',object.child.value)\n"
        "object.child.value=string.rep('x',4097); probe('object.child.value',object.child.value)\n"
        "object.child.value='a'..string.char(0,255)..'b'; probe('object.child.value',object.child.value)\n"
        "local longkey=string.rep('q',80); object[longkey]=41; probe('object.'..longkey,object[longkey])\n"
        "object.child.value=-0.0; probe('object.child.value',object.child.value)\n"
        "object.child.value=0/0; probe('object.child.value',object.child.value)\n"
        "object.child=nil; probe('object.child',nil); probe('object.child.value',nil,'LuaPathNotTable')\n"
        "local old=object; object={a=11}; collectgarbage('collect'); probe('object.a',object.a)\n"
        "do local object={a=99}; probe('object.a',object.a) end; probe('object.a',object.a)\n"
        "local function closure() local retained=object; probe('object.a',object.a) end; closure()\n"
        "local co=coroutine.create(function() local object={a=123}; probe('object.a',object.a); coroutine.yield(); probe('object.a',object.a) end)\n"
        "assert(coroutine.resume(co)); assert(coroutine.resume(co))\n"
        "object.self=object; probe('object.self.self.self.a',object.a)\n"
        "for _,bad in ipairs({'object()','object + 1','object[2147483648]','object[-2147483649]',\n"
        " 'object[1.0]','object[\"a\"]','object.','object[-]','object[1','object[+1]',\n"
        " 'object.self.self.self.self.a',string.rep('a',129)}) do probe(bad,nil,'LuaExpressionUnsupported') end\n"
        "local hits=0; setmetatable(object,{__index=function() hits=hits+1; return 123 end})\n"
        "probe('object.missing',nil,'LuaPathMetatableUnsupported'); probe('object.a',nil,'LuaPathMetatableUnsupported'); assert(hits==0)\n"
        "assert(object.missing==123 and hits==1); setmetatable(object,nil)\n"
        "object={a=7,b=8}; corrupt(object)\n"
        "local array={1,2,3,4,5,6,7,8}; array[6]=nil; array[7]=nil; array[8]=nil; local n=#array; probe('array[5]',array[5]); probe('array[8]',nil)\n";
    assert(luaL_loadbuffer(L, script, sizeof script - 1, "@owned-paths.lua") == LUA_OK);
    if (lua_pcall(L, 0, 0, 0) != LUA_OK) { fprintf(stderr, "%s\n", lua_tostring(L, -1)); return 1; }
    assert(checks >= 40 && fault_checks >= 100);
    printf("Lua %s table paths: %zu API oracles/refusals, %zu injected reads passed\n", LUA_RELEASE, checks, fault_checks);
    lua_close(L); dwarf_end(dwarf); close(fd); close(memory_fd); return 0;
}
