#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include <stdio.h>
#include <sys/prctl.h>
extern int side_run(void);
__attribute__((noinline)) void main_stop(lua_State *L) { __asm__ volatile("" : : "r"(L) : "memory"); }
static int l_stop(lua_State *L) { main_stop(L); return 0; }
static int l_side(lua_State *L) { lua_pushinteger(L, side_run()); return 1; }
int main(void) {
    prctl(PR_SET_PTRACER, PR_SET_PTRACER_ANY);
    lua_State *L = luaL_newstate(); luaL_openlibs(L);
    lua_register(L, "stop", l_stop); lua_register(L, "side", l_side);
    puts("ready"); fflush(stdout); if (getchar() != 'g') return 4;
    int rc = luaL_dostring(L, "local function f(x)\n  stop()\n  side()\n  stop()\n  return x\nend\nreturn f({7})\n");
    if (rc) fprintf(stderr, "%s\n", lua_tostring(L, -1));
    lua_close(L); return rc;
}
