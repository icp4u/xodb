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
static size_t checks, frames, shadow_checks, upvalue_checks, callbacks, vararg_checks;
static int read_memory(void *unused, uint64_t address, void *out, size_t n) {
    (void)unused;
    return pread(memory_fd, out, n, (off_t)address) == (ssize_t)n ? 0 : -1;
}
static struct xl_reader reader(void) { struct xl_reader r = {.read = read_memory}; return r; }
static void compare(lua_State *L, const struct xl_local *item) {
    const struct xl_value *v = &item->value;
    if (v->reason && !v->advisory) {
        fprintf(stderr, "value %s: %s\n", item->name, v->reason); abort();
    }
    switch (lua_type(L, -1)) {
    case LUA_TNIL: assert(!strcmp(v->display, "nil")); break;
    case LUA_TBOOLEAN: assert(!strcmp(v->display, lua_toboolean(L, -1) ? "true" : "false")); break;
    case LUA_TNUMBER: {
        char expected[128];
#if LUA_VERSION_NUM == 504
        if (lua_isinteger(L, -1)) snprintf(expected, sizeof expected, "integer %lld", (long long)lua_tointeger(L, -1)); else
#endif
        snprintf(expected, sizeof expected, "number %.17g", (double)lua_tonumber(L, -1));
        assert(!strcmp(expected, v->display)); break;
    }
    case LUA_TSTRING: {
        size_t length = 0; const char *text = lua_tolstring(L, -1, &length);
        char expected[256]; assert(length < 200);
        snprintf(expected, sizeof expected, "string \"%s\"", text);
        assert(v->count == length && !strcmp(expected, v->display)); break;
    }
    case LUA_TTABLE: assert(!strcmp(v->type, "table")); break;
    case LUA_TFUNCTION: assert(!strcmp(v->type, lua_iscfunction(L, -1) ? "C function" : "function")); break;
    case LUA_TTHREAD: assert(!strcmp(v->type, "thread")); break;
    default: assert(!"unexpected oracle value type");
    }
    ++checks;
}
static void inspect_state(lua_State *L) {
    struct xl_locals *out = calloc(1, sizeof *out); assert(out);
    struct xl_locals *selected = calloc(1, sizeof *selected); assert(selected);
    struct xl_reader r = reader();
    xl_locals_read(&layout, &r, (uintptr_t)L, 0, 0, 3, out);
    /* The current callback is C; suspended coroutines start in a Lua frame. */
    lua_Debug ar;
    for (size_t index = 0; lua_getstack(L, (int)index, &ar); ++index) {
        assert(lua_getinfo(L, "S", &ar));
        if (!strcmp(ar.what, "C")) continue;
        size_t start = 0, seen_locals = 0, seen_upvalues = 0, seen_varargs = 0, total = 0;
        char previous_name[544] = "";
        do {
            r = reader(); xl_locals_read(&layout, &r, (uintptr_t)L, index, start, 3, out);
            if (out->reason) { fprintf(stderr, "locals frame %zu: %s\n", index, out->reason); abort(); }
            assert(out->count <= 3 && out->count <= out->total && out->frame == index);
            if (start) assert(out->total == total); else total = out->total;
            for (size_t i = 0; i < out->count; ++i) {
                const struct xl_local *item = &out->items[i];
                if (item->kind == XL_VARARGS) {
                    size_t extra = 0;
                    while (lua_getlocal(L, &ar, -(int)extra - 1)) { ++extra; lua_pop(L, 1); }
                    assert(extra && extra == item->value.count && !item->address && !item->name[0] && !item->reason);
                    char expected[128]; snprintf(expected, sizeof expected, "(vararg) ×%zu", extra);
                    assert(!strcmp(item->value.display, expected) && !strcmp(item->value.type, "varargs"));
                    ++seen_varargs; ++vararg_checks; continue;
                }
                assert(!item->reason && !item->name_truncated && item->address);
                struct xl_reader binding_reader = reader();
                xl_local_binding(&layout, &binding_reader, (uintptr_t)L, index, item->kind, item->declaration, selected);
                assert(!selected->reason && selected->count == 1);
                assert(selected->items[0].kind == item->kind && selected->items[0].declaration == item->declaration);
                assert(selected->items[0].address == item->address && !strcmp(selected->items[0].name, item->name));
                assert(!strcmp(selected->items[0].value.display, item->value.display));
                const char *name;
                if (item->kind == XL_LOCAL) {
                    assert(item->ordinal == ++seen_locals);
                    name = lua_getlocal(L, &ar, (int)item->ordinal);
                    assert(name && !strcmp(name, item->name));
                    if (!strcmp(previous_name, item->name)) ++shadow_checks;
                    snprintf(previous_name, sizeof previous_name, "%s", item->name);
                } else {
                    assert(item->kind == XL_UPVALUE && item->ordinal == ++seen_upvalues);
                    assert(lua_getinfo(L, "f", &ar));
                    name = lua_getupvalue(L, -1, (int)item->ordinal);
                    assert(name && !strcmp(name, item->name));
                    ++upvalue_checks;
                }
                compare(L, item);
                lua_pop(L, item->kind == XL_UPVALUE ? 2 : 1);
            }
            start += out->count;
            assert(out->truncated == (start < total));
        } while (start < total);
        assert(seen_locals + seen_upvalues + seen_varargs == total);
        const char *vararg = lua_getlocal(L, &ar, -1);
        assert((vararg != NULL) == (seen_varargs != 0));
        if (vararg) lua_pop(L, 1);
        /* Lua may also expose anonymous temporaries; they are deliberately
         * excluded from named bindings and must not be mistaken for omission. */
        const char *extra = lua_getlocal(L, &ar, (int)seen_locals + 1);
        if (extra) { assert(extra[0] == '('); lua_pop(L, 1); }
        assert(lua_getinfo(L, "f", &ar));
        assert(!lua_getupvalue(L, -1, (int)seen_upvalues + 1)); lua_pop(L, 1);
        r = reader(); xl_locals_read(&layout, &r, (uintptr_t)L, index, total, 3, out);
        assert(!out->count && !out->truncated && out->total == total);
        /* Oracle chooses the last active local with a name, just as lexical
         * shadowing does. The resolver must never choose an outer duplicate. */
        for (size_t ordinal = 1; ordinal <= seen_locals + seen_upvalues; ++ordinal) {
            int is_up = ordinal > seen_locals;
            size_t slot = is_up ? ordinal - seen_locals : ordinal;
            if (is_up) assert(lua_getinfo(L, "f", &ar));
            const char *name = is_up ? lua_getupvalue(L, -1, (int)slot) : lua_getlocal(L, &ar, (int)slot);
            assert(name); char wanted[544]; snprintf(wanted, sizeof wanted, "%s", name);
            lua_pop(L, is_up ? 2 : 1);
            size_t resolved = slot; int resolved_up = is_up;
            for (size_t local = 1; local <= seen_locals; ++local) {
                const char *candidate = lua_getlocal(L, &ar, (int)local); assert(candidate);
                if (!strcmp(candidate, wanted)) { resolved = local; resolved_up = 0; }
                lua_pop(L, 1);
            }
            r = reader(); xl_local_find(&layout, &r, (uintptr_t)L, index, wanted, out);
            assert(!out->reason && out->count == 1 && !out->truncated);
            assert(out->items[0].ordinal == resolved && out->items[0].kind == (resolved_up ? XL_UPVALUE : XL_LOCAL));
            if (resolved_up) assert(lua_getinfo(L, "f", &ar));
            assert(resolved_up ? lua_getupvalue(L, -1, (int)resolved) : lua_getlocal(L, &ar, (int)resolved));
            compare(L, &out->items[0]); lua_pop(L, resolved_up ? 2 : 1);
        }
        r = reader(); xl_local_find(&layout, &r, (uintptr_t)L, index, "absent_binding_xyz", out);
        assert(out->reason && !strcmp(out->reason, "LuaNameNotFound") && !out->count);
        r = reader(); xl_local_find(&layout, &r, (uintptr_t)L, index, "f()", out);
        assert(out->reason && !strcmp(out->reason, "LuaExpressionUnsupported") && !r.reads);
        r = reader(); xl_local_binding(&layout, &r, (uintptr_t)L, index, XL_LOCAL, 4095, selected);
        assert(selected->reason && !strcmp(selected->reason, "LuaWatchBindingNotActive") && !selected->count);
        r = reader(); xl_local_binding(&layout, &r, (uintptr_t)L, index, XL_VARARGS, 0, selected);
        assert(selected->reason && !strcmp(selected->reason, "LuaWatchBindingInvalid") && !r.reads);
        ++frames;
    }
    r = reader(); r.reads = XL_READ_LIMIT;
    xl_locals_read(&layout, &r, (uintptr_t)L, 1, 0, 3, out);
    assert(out->reason && !strcmp(out->reason, "LuaReadBudget"));
    r = reader(); xl_locals_read(&layout, &r, (uintptr_t)L, XL_STACK_FRAMES, 0, 3, out);
    assert(out->reason && !strcmp(out->reason, "LuaLocalsRequestInvalid"));
    free(selected);free(out);
}
static void malformed(lua_State *L) {
    CallInfo *ci = L->ci; size_t index = 0;
    while (ci != &L->base_ci && !isLua(ci)) { ci = ci->previous; ++index; }
    assert(ci != &L->base_ci);
#if LUA_VERSION_NUM == 504
    LClosure *closure = clLvalue(s2v(ci->func.p));
#else
    LClosure *closure = clLvalue(ci->func);
#endif
    Proto *proto = closure->p;
    struct xl_locals *out = calloc(1, sizeof *out); assert(out);
    struct xl_reader r;
    unsigned char vararg = proto->is_vararg;
    proto->is_vararg = 2;
    r = reader(); xl_locals_read(&layout, &r, (uintptr_t)L, index, 0, 3, out);
    proto->is_vararg = vararg;
    assert(out->reason && !strcmp(out->reason, "LuaVarargMetadataInvalid"));
#if LUA_VERSION_NUM == 504
    if (vararg) {
        int extra = ci->u.l.nextraargs;
        ci->u.l.nextraargs = -1;
        r = reader(); xl_locals_read(&layout, &r, (uintptr_t)L, index, 0, 3, out);
        ci->u.l.nextraargs = extra;
        assert(out->reason && !strcmp(out->reason, "LuaVarargBoundsInvalid"));
    }
#else
    if (vararg) {
        StkId base = ci->u.l.base;
        ci->u.l.base = ci->func;
        r = reader(); xl_locals_read(&layout, &r, (uintptr_t)L, index, 0, 3, out);
        ci->u.l.base = base;
        assert(out->reason && !strcmp(out->reason, "LuaVarargBoundsInvalid"));
    }
#endif
    int nlocals = proto->sizelocvars; assert(nlocals > 0);
    proto->sizelocvars = 4097;
    r = reader(); xl_locals_read(&layout, &r, (uintptr_t)L, index, 0, 3, out);
    proto->sizelocvars = nlocals;
    assert(out->reason && !strcmp(out->reason, "LuaLocalsWorkLimit"));
    int finish = proto->locvars[0].endpc;
    proto->locvars[0].endpc = proto->sizecode + 1;
    r = reader(); xl_locals_read(&layout, &r, (uintptr_t)L, index, 0, 3, out);
    proto->locvars[0].endpc = finish;
    assert(out->reason && !strcmp(out->reason, "LuaLocalScopeInvalid"));
    proto->sizelocvars = 0;
    r = reader(); xl_locals_read(&layout, &r, (uintptr_t)L, index, 0, 3, out);
    proto->sizelocvars = nlocals;
    assert(out->reason && !strcmp(out->reason, "LuaLocalNamesUnavailable"));
    unsigned nup = closure->nupvalues; assert(nup < 255);
    closure->nupvalues++;
    r = reader(); xl_locals_read(&layout, &r, (uintptr_t)L, index, 0, 3, out);
    closure->nupvalues = (unsigned char)nup;
    assert(out->reason && !strcmp(out->reason, "LuaLocalsMetadataInvalid"));
    r = reader(); r.bytes = XL_BYTE_LIMIT;
    xl_locals_read(&layout, &r, (uintptr_t)L, index, 0, 3, out);
    assert(out->reason && !strcmp(out->reason, "LuaReadBudget"));
    r = reader(); xl_locals_read(&layout, &r, (uintptr_t)L, index, 0, 0, out);
    assert(out->reason && !strcmp(out->reason, "LuaLocalsRequestInvalid"));
    free(out);
}
static int probe(lua_State *L) { inspect_state(L); malformed(L); ++callbacks; return 0; }
static int inspect_coroutine(lua_State *L) {
    lua_State *co = lua_tothread(L, 1); assert(co && lua_status(co) == LUA_YIELD);
    inspect_state(co); ++callbacks; return 0;
}
int main(int argc, char **argv) {
    (void)argc;
    memory_fd = open("/proc/self/mem", O_RDONLY); assert(memory_fd >= 0);
    int fd = open(argv[0], O_RDONLY); assert(fd >= 0);
    Dwarf *dwarf = dwarf_begin(fd, DWARF_C_READ); assert(dwarf);
    const uint8_t version[] = {5, LUA_VERSION_NUM == 504 ? 4 : 2, LUA_VERSION_NUM == 504 ? 9 : 4}, id[] = {1};
    const char *why = xl_layout_build(dwarf, id, sizeof id, version, &layout);
    if (why) { fprintf(stderr, "layout: %s\n", why); return 1; }
    lua_State *L = luaL_newstate(); assert(L); luaL_openlibs(L);
    lua_register(L, "probe", probe); lua_register(L, "inspect_coroutine", inspect_coroutine);
    const char script[] =
        "local captured = 73\n"
        "local function recursive(n)\n"
        " local shadow=n; do local shadow=n+100\n"
        " local text='owned'; local yes=true; local empty=nil\n"
        " if n>0 then recursive(n-1) else probe(captured) end\n"
        " end\nend\nrecursive(3)\n"
        "local function make() local closed=321; return function(arg) probe(closed,arg) end end\n"
        "local closure=make(); closure(17)\n"
        "local co=coroutine.create(function() local retained=42; coroutine.yield(retained); probe(retained) end)\n"
        "assert(coroutine.resume(co)); inspect_coroutine(co); assert(coroutine.resume(co))\n"
        "do local expired=99 end; local active=21; probe(active)\n"
        "local function spread(n,...) local named=n; probe(...) end; spread(17,3,'x',nil); spread(17)\n";
    assert(luaL_loadbuffer(L, script, sizeof script-1, "@owned-locals.lua") == LUA_OK);
    if (lua_pcall(L, 0, 0, 0) != LUA_OK) { fprintf(stderr, "%s\n", lua_tostring(L, -1)); return 1; }
    assert(vararg_checks);
    assert(callbacks >= 5 && frames >= 8 && checks >= 40 && shadow_checks && upvalue_checks);
    printf("Lua %s named locals: %zu values, %zu frames, %zu shadow bindings, %zu upvalues, %zu callbacks passed\n", LUA_RELEASE, checks, frames, shadow_checks, upvalue_checks, callbacks);
    lua_close(L); dwarf_end(dwarf); close(fd); close(memory_fd); return 0;
}
