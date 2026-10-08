#define _GNU_SOURCE
#include "lstate.h"
#include "lauxlib.h"
#include "lualib.h"
#include <assert.h>
#include <stdio.h>
#include <sys/prctl.h>
#include <unistd.h>

__attribute__((noinline)) void states(lua_State *one, lua_State *two, StkId slot) {
    __asm__ volatile(".global xodb_lua_states_stop\n.type xodb_lua_states_stop,@function\nxodb_lua_states_stop:\nnop" : : "m"(one), "m"(two), "m"(slot) : "memory");
}
static int pause_io(lua_State *L) {
    (void)L;
    puts("io_waiting"); fflush(stdout);
    char byte;
    assert(read(STDIN_FILENO, &byte, 1) == 1);
    return 0;
}
int main(void) {
    assert(prctl(PR_SET_PTRACER, PR_SET_PTRACER_ANY) == 0);
    lua_State *one = luaL_newstate(), *two = luaL_newstate();
    assert(one && two); luaL_openlibs(one); luaL_openlibs(two);
    lua_register(one, "pause_io", pause_io);
    puts("ready"); fflush(stdout);
    char byte; assert(read(STDIN_FILENO, &byte, 1) == 1);
    printf("states %p %p\n", (void *)one, (void *)two); fflush(stdout);
    lua_pushinteger(one, 41);
#if LUA_VERSION_NUM == 504
    states(one, two, one->top.p - 1);
#else
    states(one, two, one->top - 1);
#endif
    lua_pop(one, 1);
    const char script[] = "local function inner() pause_io() end\ninner()\n";
    assert(luaL_loadbuffer(one, script, sizeof(script)-1, "@context.lua") == LUA_OK);
    assert(lua_pcall(one, 0, 0, 0) == LUA_OK);
    lua_close(two); lua_close(one);
    return 0;
}
