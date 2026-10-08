#define _POSIX_C_SOURCE 200809L
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void quoted(const char *s) {
    putchar('"');
    for (; *s; ++s) {
        unsigned char c = (unsigned char)*s;
        if (c == '"' || c == '\\') { putchar('\\'); putchar(c); }
        else if (c < 32 || c >= 127) printf("\\u%04x", c);
        else putchar(c);
    }
    putchar('"');
}
static void binding(lua_State *L, const char *scope, int ordinal, const char *name) {
    printf("{\"scope\":\"%s\",\"ordinal\":%d,\"name\":", scope, ordinal); quoted(name);
    fputs(",\"display\":", stdout);
    char text[256];
    switch (lua_type(L, -1)) {
    case LUA_TNIL: quoted("nil"); break;
    case LUA_TBOOLEAN: quoted(lua_toboolean(L, -1) ? "true" : "false"); break;
    case LUA_TNUMBER:
#if LUA_VERSION_NUM == 504
        if (lua_isinteger(L, -1)) snprintf(text, sizeof text, "integer %lld", (long long)lua_tointeger(L, -1)); else
#endif
        snprintf(text, sizeof text, "number %.17g", (double)lua_tonumber(L, -1));
        quoted(text); break;
    case LUA_TSTRING:
        snprintf(text, sizeof text, "string \"%s\"", lua_tostring(L, -1)); quoted(text); break;
    default: fputs("null", stdout);
    }
    putchar('}');
}
__attribute__((noinline)) void xodb_lua_named_stop(lua_State *L) {
    volatile lua_State *retained = L;
    __asm__ volatile("" : : "r"(retained) : "memory"); /* NAMED_STOP */
}
static void snapshot(lua_State *L) {
    printf("{\"state\":\"%p\",\"frames\":[", (void *)L);
    lua_Debug ar; int comma_frame = 0;
    for (int index = 0; lua_getstack(L, index, &ar); ++index) {
        assert(lua_getinfo(L, "S", &ar));
        if (!strcmp(ar.what, "C")) continue;
        if (comma_frame++) putchar(',');
        printf("{\"frame\":%d,\"bindings\":[", index);
        int comma = 0;
        for (int i = 1;; ++i) {
            const char *name = lua_getlocal(L, &ar, i);
            if (!name) break;
            if (name[0] != '(') {
                if (comma++) putchar(',');
                binding(L, "local", i, name);
            }
            lua_pop(L, 1);
        }
        assert(lua_getinfo(L, "f", &ar));
        for (int i = 1;; ++i) {
            const char *name = lua_getupvalue(L, -1, i);
            if (!name) break;
            if (comma++) putchar(',');
            binding(L, "upvalue", i, name); lua_pop(L, 1);
        }
        lua_pop(L, 1);
        unsigned extra = 0;
        while (lua_getlocal(L, &ar, -(int)extra - 1)) { ++extra; lua_pop(L, 1); }
        if (extra) {
            if (comma++) putchar(',');
            printf("{\"scope\":\"vararg\",\"ordinal\":0,\"name\":\"\",\"display\":\"(vararg) ×%u\"}", extra);
        }
        fputs("]}", stdout);
    }
    puts("]}"); fflush(stdout);
    xodb_lua_named_stop(L);
}
static int probe(lua_State *L) { snapshot(L); return 0; }
static int suspended(lua_State *L) {
    lua_State *co = lua_tothread(L, 1); assert(co && lua_status(co) == LUA_YIELD);
    snapshot(co); return 0;
}
int main(void) {
    lua_State *L = luaL_newstate(); assert(L); luaL_openlibs(L);
    lua_register(L, "probe", probe); lua_register(L, "inspect_coroutine", suspended);
    puts("ready"); fflush(stdout); if (!getenv("XODB_LUA_NAMED_AUTO") && getchar() == EOF) return 1;
    const char script[] =
        "local captured=73\n"
        "local function recurse(n) local shadow=n; do local shadow=n+100; local text='owned'; local yes=true; local empty=nil;\n"
        " if n>0 then recurse(n-1) else probe(captured) end end end\nrecurse(3)\n"
        "local function make() local closed=321; return function(arg) probe(closed,arg) end end\nlocal closure=make(); closure(17)\n"
        "local co=coroutine.create(function() local retained=42; coroutine.yield(retained); probe(retained) end)\n"
        "assert(coroutine.resume(co)); inspect_coroutine(co); assert(coroutine.resume(co))\n"
        "do local expired=99 end; local active=21; probe(active)\n"
        "local function spread(n,...) local named=n; probe(...) end; spread(17,3,'x',nil); spread(17)\n";
    assert(luaL_loadbuffer(L, script, sizeof script-1, "@owned-named.lua") == LUA_OK);
    if (lua_pcall(L, 0, 0, 0) != LUA_OK) { fprintf(stderr, "%s\n", lua_tostring(L, -1)); return 1; }
    lua_close(L); return 0;
}
