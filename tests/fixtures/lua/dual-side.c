/* A second, symbol-hidden Lua copy inside the same image (e.g. middleware). */
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
__attribute__((noinline)) void side_stop(lua_State *L) { __asm__ volatile("" : : "r"(L) : "memory"); }
static int l_stop(lua_State *L) { side_stop(L); return 0; }
int side_run(void) {
    lua_State *L = luaL_newstate(); luaL_openlibs(L);
    lua_register(L, "stop", l_stop);
    int rc = luaL_dostring(L, "local function g(t)\n  stop()\n  return #t\nend\nlocal t = {1, 2, 'side'}\nreturn g(t)\n");
    lua_close(L); return rc;
}
