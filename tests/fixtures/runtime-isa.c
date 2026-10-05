#include <stdint.h>
struct value { int32_t value; const char *name; } state = {7, "cross-isa"};
__attribute__((noinline)) void change_value(int32_t add)
{
    state.value += add;
}
int main(void)
{
    change_value(5);
    return state.value == 12 ? 0 : 1;
}
