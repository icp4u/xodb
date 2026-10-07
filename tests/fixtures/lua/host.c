#define _GNU_SOURCE
#include "lstate.h"
#include "lauxlib.h"
#include "lualib.h"
#include <assert.h>
#include <stdio.h>
#include <sys/prctl.h>
#include <unistd.h>

__attribute__((noinline)) void xodb_lua_probe(lua_State *L, TValue *value, const char *label) {
    __asm__ volatile(".global xodb_lua_stop\n.type xodb_lua_stop,@function\nxodb_lua_stop:\nnop" : : "m"(L), "m"(value), "m"(label) : "memory");
}
static void json_string(const char *s) {
    putchar('"');
    for (; *s; ++s) {
        unsigned char c = (unsigned char)*s;
        if (c < 32 || c >= 127 || c == '"' || c == '\\') printf("\\u%04x", c); else putchar(c);
    }
    putchar('"');
}
static void frames(lua_State *L) {
    putchar('['); lua_Debug ar;
    for (int i = 0; lua_getstack(L, i, &ar); ++i) {
        assert(lua_getinfo(L, "nSl", &ar));
        if (i) putchar(',');
        printf("{\"name\":"); json_string(ar.name ? ar.name : "");
        printf(",\"file\":"); json_string(ar.source ? ar.source : "");
        printf(",\"line\":%d,\"kind\":", ar.currentline); json_string(ar.what); putchar('}');
    }
    putchar(']');
}
static int inspect(lua_State *L) {
    const char *label = luaL_checkstring(L, 2);
    printf("{\"label\":"); json_string(label); printf(",\"version\":"); json_string(LUA_RELEASE);
    printf(",\"frames\":"); frames(L);
    printf(",\"offsets\":{\"ci_prev\":%zu,\"ci_pc\":%zu,\"tag\":%zu,\"tag_size\":%zu}",
           offsetof(CallInfo, previous), offsetof(CallInfo, u.l.savedpc), offsetof(TValue, tt_), sizeof(((TValue *)0)->tt_));
    if (lua_isthread(L, 1)) { printf(",\"value_frames\":"); frames(lua_tothread(L, 1)); }
    printf("}\n"); fflush(stdout);
#if LUA_VERSION_NUM == 504
    TValue *value = s2v(L->ci->func.p + 1);
#else
    TValue *value = L->ci->func + 1;
#endif
    xodb_lua_probe(L, value, label); return 0;
}
static int sandwich(lua_State *L) { lua_getglobal(L, "inner"); lua_call(L, 0, 0); return 0; }
int luaopen_xodb_probe(lua_State *L) {
    if (prctl(PR_SET_PTRACER, PR_SET_PTRACER_ANY)) return luaL_error(L, "fixture ptrace authorization failed");
    lua_register(L, "inspect", inspect); lua_register(L, "sandwich", sandwich);
    return 0;
}
#ifndef XODB_LUA_MODULE
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    if (prctl(PR_SET_PTRACER, PR_SET_PTRACER_ANY)) return 3;
    lua_State *L = luaL_newstate(); assert(L); luaL_openlibs(L);
    lua_register(L, "inspect", inspect); lua_register(L, "sandwich", sandwich);
    puts("ready"); fflush(stdout); if (getchar() != 'g') return 4;
    int result = luaL_loadfile(L, argv[1]);
    if (result == LUA_OK) result = lua_pcall(L, 0, 0, 0);
    if (result != LUA_OK) fprintf(stderr, "%s\n", lua_tostring(L, -1));
    lua_close(L); return result == LUA_OK ? 0 : 1;
}
#endif
