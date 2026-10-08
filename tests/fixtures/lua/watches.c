/* Reuse the independent debug-API oracle, with a watch-specific program. */
#define main named_fixture_main
#include "named.c"
#undef main
int main(void) {
    lua_State *L = luaL_newstate(); assert(L); luaL_openlibs(L);
    lua_register(L, "probe", probe);
    puts("ready"); fflush(stdout); if (getchar() == EOF) return 1;
    const char script[] =
        "local captured=73\n"
        "local function grow(n) local padding=string.rep('x',40); if n>0 then grow(n-1) else probe(padding) end end\n"
        "local function watched()\n"
        " local x=7; local text=string.rep('a',300)..'b'; local huge=string.rep('z',5000); local object={}\n"
        " local shadow=10; do local shadow=20; probe(captured)\n"
        "  shadow=21; x=8; text=string.rep('a',300)..'c'; captured=74; collectgarbage('collect'); probe(captured)\n"
        "  probe(captured) end\n"
        " probe(captured); huge='small'; object=false; x=nil; grow(12); probe(captured)\n"
        "end\n"
        "watched(); probe(captured); watched(); probe(captured)\n";
    assert(luaL_loadbuffer(L, script, sizeof script-1, "@owned-watches.lua") == LUA_OK);
    if (lua_pcall(L, 0, 0, 0) != LUA_OK) { fprintf(stderr, "%s\n", lua_tostring(L,-1)); return 1; }
    lua_close(L); return 0;
}
