#include <assert.h>
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

__attribute__((noinline)) static void stopped(lua_State *one, lua_State *two)
{
    __asm__ volatile(".global xodb_unanchored_stop\n.type xodb_unanchored_stop,@function\nxodb_unanchored_stop:\nnop" : : "m"(one), "m"(two) : "memory");
}
static lua_State *suspended(lua_State *root)
{
    lua_State *thread = lua_newthread(root);
    lua_getglobal(thread, "suspended");
#if LUA_VERSION_NUM >= 504
    int results = 0;
    assert(lua_resume(thread, NULL, 0, &results) == LUA_YIELD);
#else
    assert(lua_resume(thread, NULL, 0) == LUA_YIELD);
#endif
    return thread;
}
int main(void)
{
    lua_State *root = luaL_newstate();
    assert(root);
    luaL_openlibs(root);
    assert(luaL_dostring(root, "function suspended() local retained = 42; coroutine.yield(retained); return retained end") == LUA_OK);
    lua_State *one = suspended(root), *two = suspended(root);
    stopped(one, two);
    lua_close(root);
    return 0;
}
