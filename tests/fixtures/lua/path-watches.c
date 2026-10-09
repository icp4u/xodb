/* The public Lua API supplies raw-table/scalar ground truth before each stop. */
#define main named_fixture_main
#include "named.c"
#undef main
#include <stdint.h>
#include "lobject.h"

static void emit(lua_State *L, const char *expression, int comma) {
    if (comma) putchar(',');
    printf("{\"expression\":"); quoted(expression);
    unsigned char numeric[8]; const unsigned char *bytes = numeric; size_t size = 0; unsigned kind = 0;
    char display[256] = "nil";
    switch (lua_type(L, -1)) {
    case LUA_TNIL: break;
    case LUA_TBOOLEAN:
        kind = 1; size = 1; numeric[0] = lua_toboolean(L, -1); strcpy(display, numeric[0] ? "true" : "false"); break;
    case LUA_TNUMBER: {
        uint64_t bits; double number = lua_tonumber(L, -1); memcpy(&bits, &number, 8); kind = 3;
        snprintf(display, sizeof display, "number %.17g", number);
#if LUA_VERSION_NUM == 504
        if (lua_isinteger(L, -1)) {
            bits = (uint64_t)lua_tointeger(L, -1); kind = 2;
            snprintf(display, sizeof display, "integer %lld", (long long)lua_tointeger(L, -1));
        }
#endif
        size = 8; for (unsigned i = 0; i < 8; ++i) numeric[i] = (unsigned char)(bits >> (i * 8)); break;
    }
    case LUA_TSTRING: kind = 4; bytes = (const unsigned char *)lua_tolstring(L, -1, &size); strcpy(display, "string"); break;
    default: assert(!"non-scalar oracle");
    }
    printf(",\"kind\":%u,\"length\":%zu,\"display\":", kind, size); quoted(display);
    fputs(",\"bytes\":\"", stdout);
    for (size_t i = 0; i < size; ++i) printf("%02x", bytes[i]);
    fputs("\"}", stdout); lua_pop(L, 1);
}
static void raw_field(lua_State *L, int index, const char *name) {
    lua_pushstring(L, name); lua_rawget(L, index);
}
static int path_probe(lua_State *L) {
    printf("{\"phase\":%d,\"state\":\"%p\",\"root\":\"%p\",\"values\":[", (int)lua_tointeger(L, 1), (void *)L, lua_topointer(L, 3));
    lua_pushvalue(L, 2); emit(L, "x", 0);
    raw_field(L, 3, "a"); emit(L, "object.a", 1);
    raw_field(L, 3, "child");
    if (lua_istable(L, -1)) { raw_field(L, lua_gettop(L), "value"); lua_remove(L, -2); }
    else { lua_pop(L, 1); lua_pushnil(L); }
    emit(L, "object.child.value", 1);
    lua_rawgeti(L, 3, 1); emit(L, "object[1]", 1);
    raw_field(L, 3, "missing"); emit(L, "object.missing", 1);
    lua_rawgeti(L, 4, 1); emit(L, "large[1]", 1);
    raw_field(L, 4, "key1"); emit(L, "large.key1", 1);
    printf("],\"version\":%d,\"hash_capacity\":%llu}\n", LUA_VERSION_NUM, (unsigned long long)(UINT64_C(1) << ((const Table *)lua_topointer(L, 4))->lsizenode)); fflush(stdout); xodb_lua_named_stop(L); return 0;
}
int main(void) {
    lua_State *L = luaL_newstate(); assert(L); luaL_openlibs(L); lua_register(L, "path_probe", path_probe);
    puts("ready"); fflush(stdout); if (!getenv("XODB_LUA_NAMED_AUTO") && getchar() == EOF) return 1;
    const char script[] =
        "local large={42}; for i=1,2000 do large['key'..i]=i end\n"
        "local function watched(once)\n"
        " local x=7; local object={a=7,child={value=string.rep('a',300)..'b'},[1]=11}\n"
        " path_probe(0,x,object,large); if once then return end\n"
        " local old=object; object={a=8,child={value=string.rep('a',300)..'c'},[1]=12}; x=8\n"
        " for i=2001,4096 do large['key'..i]=i end; collectgarbage('collect'); path_probe(1,x,object,large); path_probe(2,x,object,large)\n"
        " object.a=nil; object.child=nil; object[1]=nil; large.key1=nil; path_probe(3,x,object,large)\n"
        " object.a=9; object.child={value='small'}; object[1]=13; local hits=0\n"
        " setmetatable(object,{__index=function() hits=hits+1; return 123 end}); path_probe(4,x,object,large); assert(hits==0)\n"
        " setmetatable(object,nil); large.key1=1; path_probe(5,x,object,large)\n"
        " do local object={a=99,child={value='inner'},[1]=14}; path_probe(6,x,object,large) end\n"
        " path_probe(7,x,object,large)\n"
        " local co=coroutine.create(function() local object={a=500,child={value='coroutine'},[1]=15}; path_probe(8,x,object,large) end)\n"
        " assert(coroutine.resume(co)); path_probe(9,x,object,large)\n"
        "end\n"
        "watched(false); path_probe(10,0,{},large); watched(true); path_probe(11,0,{},large)\n";
    assert(luaL_loadbuffer(L, script, sizeof script - 1, "@owned-path-watches.lua") == LUA_OK);
    if (lua_pcall(L, 0, 0, 0) != LUA_OK) { fprintf(stderr, "%s\n", lua_tostring(L, -1)); return 1; }
    lua_close(L); return 0;
}
