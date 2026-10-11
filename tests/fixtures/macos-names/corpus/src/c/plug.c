/* libplug.dylib: loaded with dlopen and unloaded with dlclose on request. */
#include <stdint.h>
volatile uint64_t plug_state = 0x706c7567;
static uint64_t plug_helper(uint64_t value) { return value ^ plug_state; }
__attribute__((noinline)) uint64_t plug_entry(uint64_t value)
{
    plug_state++;
    return plug_helper(value) + 1;
}
