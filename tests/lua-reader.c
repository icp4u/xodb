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
static unsigned value_checks, stack_checks, stack_frames;
static void *retired_table;
static size_t retired_size;
static int retired;
static void *allocate(void *ctx, void *p, size_t old, size_t n) {
    (void)ctx;
    if (!n) {
        if (p == retired_table && p) {
            memset(p, 0xa5, old); retired = 1; retired_size = old;
        } else free(p);
        return NULL;
    }
    return realloc(p, n);
}
static int read_memory(void *ctx, uint64_t address, void *out, size_t n) {
    (void)ctx;
    return pread(memory_fd, out, n, (off_t)address) == (ssize_t)n ? 0 : -1;
}
static struct xl_reader reader(void) {
    struct xl_reader r = { .read = read_memory }; return r;
}
static TValue *argument(lua_State *L, int i) {
#if LUA_VERSION_NUM == 504
    return s2v(L->ci->func.p + i);
#else
    return L->ci->func + i;
#endif
}
static void check_stack(lua_State *L) {
    struct xl_stack stack; struct xl_reader r = reader();
    xl_stack_read(&layout, &r, (uintptr_t)L, &stack);
    if (stack.reason && strcmp(stack.reason, "LuaFunctionNameUnavailable")) {
        fprintf(stderr, "stack: %s frames=%zu\n", stack.reason, stack.count); abort();
    }
    lua_Debug ar; unsigned index = 0;
    for (; lua_getstack(L, (int)index, &ar); ++index) {
        assert(index < stack.count); assert(lua_getinfo(L, "Sln", &ar));
        struct xl_frame *f = &stack.frames[index];
        int is_c = !strcmp(ar.what, "C");
        if (f->is_c != is_c || (!is_c && (f->line != ar.currentline || strcmp(f->file, ar.source)))) {
            fprintf(stderr, "frame %u C=%d/%d line=%d/%d file=%s/%s reason=%s\n", index,
                    f->is_c, is_c, f->line, ar.currentline, f->file, ar.source, f->reason ? f->reason : "none"); abort();
        }
        printf("frame %u C=%d line=%d source=%s tail=%d\n", index, f->is_c, f->line, f->file, f->tail_call);
        ++stack_frames;
    }
    assert(index == stack.count); ++stack_checks;
    /* A saved PC at code[0] means entry, not a corrupt instruction pointer.
     * This cooperating oracle changes only its own frame and restores it
     * before asking Lua to execute or inspect anything else. */
    for (CallInfo *ci = L->ci; ci != &L->base_ci; ci = ci->previous) {
        if (!isLua(ci)) continue;
#if LUA_VERSION_NUM == 504
        Proto *proto = clLvalue(s2v(ci->func.p))->p;
#else
        Proto *proto = clLvalue(ci->func)->p;
#endif
        const Instruction *saved = ci->u.l.savedpc;
        ci->u.l.savedpc = proto->code;
        r = reader(); xl_stack_read(&layout, &r, (uintptr_t)L, &stack);
        ci->u.l.savedpc = saved;
        int found = 0;
        for (size_t i = 0; i < stack.count; ++i) if (stack.frames[i].ci == (uintptr_t)ci) {
            assert(stack.frames[i].reason && !strcmp(stack.frames[i].reason, "LuaFrameNotStarted"));
            assert(stack.frames[i].line == proto->linedefined); found = 1;
        }
        assert(found);
        break;
    }

    luaL_traceback(L, L, "ground truth", 0); puts(lua_tostring(L, -1)); lua_pop(L, 1);
    lua_State snapshot = *L; CallInfo bad = *L->ci;
    snapshot.ci = &bad; bad.previous = &bad; bad.next = &bad;
    r = reader(); xl_stack_read(&layout, &r, (uintptr_t)&snapshot, &stack);
    assert(stack.reason && !strcmp(stack.reason, "LuaCallInfoCycle"));
    bad.previous = NULL;
    r = reader(); xl_stack_read(&layout, &r, (uintptr_t)&snapshot, &stack);
    assert(stack.reason && !strcmp(stack.reason, "LuaCallInfoInvalid"));
    bad.previous = L->ci->previous;
    r = reader(); xl_stack_read(&layout, &r, (uintptr_t)&snapshot, &stack);
    assert(stack.reason && !strcmp(stack.reason, "LuaCallInfoLinkMismatch"));
}
static int inspect(lua_State *L) {
    int count = lua_gettop(L);
    for (int i = 1; i <= count; ++i) {
        struct xl_reader r = reader(); struct xl_value v;
        xl_value_read(&layout, &r, (uintptr_t)argument(L, i), &v);
        if (v.advisory) assert(v.reason && (!strcmp(v.reason, "LuaStringExtentUnproved") || !strcmp(v.reason, "LuaTableExtentUnproved")) && v.truncated);
        if (v.reason && !v.advisory) { fprintf(stderr, "value %d: %s\n", i, v.reason); abort(); }
        int type = lua_type(L, i);
        const char *want = type == LUA_TNIL ? "nil" : type == LUA_TBOOLEAN ? "boolean" :
            type == LUA_TNUMBER ? "number" : type == LUA_TSTRING ? "string" : type == LUA_TTABLE ? "table" :
            type == LUA_TFUNCTION ? (lua_iscfunction(L, i) ? "C function" : "function") :
            type == LUA_TUSERDATA ? "userdata" : type == LUA_TTHREAD ? "thread" : "lightuserdata";
#if LUA_VERSION_NUM == 504
        if (lua_isinteger(L, i)) want = "integer";
#endif
        assert(!strcmp(v.type, want));
        if (type == LUA_TSTRING) { size_t length; lua_tolstring(L, i, &length); assert(v.count == length); }
        if (type == LUA_TBOOLEAN) assert(!strcmp(v.display, lua_toboolean(L, i) ? "true" : "false"));
        if (type == LUA_TNUMBER) {
            char expected[128];
#if LUA_VERSION_NUM == 504
            if (lua_isinteger(L, i)) snprintf(expected, sizeof expected, "integer %lld", (long long)lua_tointeger(L, i)); else
#endif
            snprintf(expected, sizeof expected, "number %.17g", (double)lua_tonumber(L, i));
            assert(!strcmp(v.display, expected));
        }
        printf("value %d %s children=%zu truncated=%d\n", i, v.display, v.item_count, v.truncated);
        for (size_t j = 0; j < v.item_count; ++j) {
            printf("  %s: %s reason=%s\n", v.items[j].key, v.items[j].display, v.items[j].reason ? v.items[j].reason : "none");
            assert(!v.items[j].reason || (v.items[j].advisory &&
                (!strcmp(v.items[j].reason, "LuaStringExtentUnproved") || !strcmp(v.items[j].reason, "LuaTableExtentUnproved"))));
        }
        assert(r.reads <= XL_READ_LIMIT && r.bytes <= XL_BYTE_LIMIT); ++value_checks;
    }
    check_stack(L);
    struct xl_reader r = reader(); struct xl_value state;
    xl_state_read(&layout, &r, (uintptr_t)L, &state);
    assert(!state.reason && !strcmp(state.type, "thread"));
    return 0;
}
static int sandwich(lua_State *L) { lua_getglobal(L, "inner"); lua_call(L, 0, 0); return 0; }
static void adversarial(lua_State *L) {
    struct xl_reader r; struct xl_value v; struct xl_stack st;
    r = reader(); xl_value_read(&layout, &r, UINT64_MAX - 1, &v); assert(v.reason);
    r = reader(); r.reads = XL_READ_LIMIT; xl_value_read(&layout, &r, (uintptr_t)argument(L, 0), &v);
    assert(v.reason && !strcmp(v.reason, "LuaReadBudget"));
    lua_pushinteger(L, 42); TValue corrupt = *argument(L, 1);
    corrupt.tt_ = 255; r = reader(); xl_value_read(&layout, &r, (uintptr_t)&corrupt, &v);
    assert(v.reason && !strcmp(v.reason, "LuaTagUnsupported")); lua_pop(L, 1);
    lua_newtable(L); corrupt = *argument(L, 1);
    /* Retain the actual collected table allocation in the fixture allocator
     * and poison it after Lua frees it. Unchanged stale bytes cannot prove
     * liveness, so that is deliberately not what this regression asserts. */
    retired_table = corrupt.value_.gc; lua_pop(L, 1); lua_gc(L, LUA_GCCOLLECT, 0);
    assert(retired && retired_size == sizeof(Table));
    r = reader(); xl_value_read(&layout, &r, (uintptr_t)&corrupt, &v);
    assert(v.reason && !strcmp(v.reason, "LuaObjectTagMismatch"));
    free(retired_table); retired_table = NULL;
    lua_State snapshot = *L; CallInfo bad = L->base_ci; bad.previous = &bad; bad.next = &bad;
    snapshot.ci = &bad;
    r = reader(); xl_stack_read(&layout, &r, (uintptr_t)&snapshot, &st); assert(st.reason);
    printf("adversarial address, read budget, invalid tag, poisoned stale object, detached CallInfo: pass\n");
}
int main(int argc, char **argv) {
    (void)argc; memory_fd = open("/proc/self/mem", O_RDONLY); assert(memory_fd >= 0);
    int fd = open(argv[0], O_RDONLY); assert(fd >= 0); Dwarf *d = dwarf_begin(fd, DWARF_C_READ); assert(d);
    uint8_t version[] = {5, LUA_VERSION_NUM == 504 ? 4 : 2, LUA_VERSION_NUM == 504 ? 9 : 4};
    const uint8_t id[] = {1, 2, 3, 4};
    const char *err = xl_layout_build(d, id, sizeof id, version, &layout);
    if (err) { fprintf(stderr, "layout: %s\n", err); return 1; }
    assert(!xl_layout_check(&layout, id, sizeof id, version));
    uint8_t wrong[] = {5, 3, 6}; assert(xl_layout_check(&layout, id, sizeof id, wrong));
    uint8_t bad_id[] = {1, 2, 3, 5}; assert(xl_layout_check(&layout, bad_id, sizeof bad_id, version));
    lua_State *L = lua_newstate(allocate, NULL); assert(L); luaL_openlibs(L);
    lua_register(L, "inspect", inspect); lua_register(L, "sandwich", sandwich);
    const char script[] =
        "local captured = 73\n"
        "local function closure() return captured end\n"
        "local function nested(n)\n"
        " if n > 0 then nested(n-1) else inspect(nil, false, true, 42, -73, 3.5, 'hi', string.rep('x',300), 'a\\0b\\255', {1,2,x='hi'}, closure, inspect, coroutine.running()) end\n"
        "end\n"
        "nested(3)\n"
        "function inner() inspect('C-Lua-C') end\n"
        "sandwich()\n"
        "local function tail(n) if n==0 then inspect('tail') else return tail(n-1) end end\n"
        "tail(3)\n"
        "local co=coroutine.create(function() inspect('coroutine'); coroutine.yield(); inspect('resumed') end)\n"
        "assert(coroutine.resume(co)); assert(coroutine.resume(co))\n"
        "assert(pcall(function() inspect('pcall') end))\n"
        "xpcall(function() error('owned fixture error') end, function(e) inspect(e) end)\n"
        "inspect(io.tmpfile())\n";
    assert(luaL_loadbuffer(L, script, sizeof script - 1, "@lua-reader-fixture.lua") == LUA_OK);
    if (lua_pcall(L, 0, 0, 0) != LUA_OK) { fprintf(stderr, "%s\n", lua_tostring(L, -1)); return 1; }
    /* Enough instructions for periodic absolute entries, and a large line
     * gap that requires an additional absolute entry in Lua 5.4. */
    char long_script[16384]; size_t used = 0;
    used += (size_t)snprintf(long_script + used, sizeof long_script - used, "local function longlines()\nlocal n=0\n");
    for (unsigned i = 0; i < 260; ++i)
        used += (size_t)snprintf(long_script + used, sizeof long_script - used, "n=n+%u\n", i);
    for (unsigned i = 0; i < 650; ++i) long_script[used++] = '\n';
    used += (size_t)snprintf(long_script + used, sizeof long_script - used, "inspect(n)\nend\nlonglines()\n");
    assert(used < sizeof long_script);
    assert(luaL_loadbuffer(L, long_script, used, "@lua-absolute-lines.lua") == LUA_OK);
    assert(lua_pcall(L, 0, 0, 0) == LUA_OK);
    adversarial(L); lua_close(L); dwarf_end(d); close(fd); close(memory_fd);
    printf("Lua %s: %u values, %u stacks, %u exact frame positions passed\n", LUA_RELEASE, value_checks, stack_checks, stack_frames);
    return 0;
}
