/* Two distinct calls intentionally reuse Lua's CallInfo/prototype slot. */
#define main named_fixture_main
#include "named.c"
#undef main
int main(void) {
    lua_State *L = luaL_newstate(); assert(L); luaL_openlibs(L);
    lua_register(L, "probe", probe);
    puts("ready"); fflush(stdout); if (getchar() == EOF) return 1;
    const char script[] =
        "local function reused(v) local x=v; probe(x) end\n"
        "reused(10); reused(20); probe(30)\n";
    assert(luaL_loadbuffer(L, script, sizeof script-1, "@owned-watch-reuse.lua") == LUA_OK);
    if (lua_pcall(L, 0, 0, 0) != LUA_OK) { fprintf(stderr, "%s\n", lua_tostring(L,-1)); return 1; }
    lua_close(L); return 0;
}
