/* Second translation unit of cprog: static and variadic functions. */
#include <stdarg.h>
#include "dep.h"
static uint64_t rotate(uint64_t value, unsigned by) { return value << by | value >> (64 - by); }
__attribute__((noinline)) uint64_t util_mix(uint64_t value, unsigned rounds)
{
    static uint64_t calls;
    calls++;
    for (unsigned i = 0; i < rounds; i++) value = rotate(value, 7) ^ (value + calls);
    return value;
}
__attribute__((noinline)) int util_sum(int count, ...)
{
    va_list list;
    int total = 0;
    va_start(list, count);
    for (int i = 0; i < count; i++) total += va_arg(list, int);
    va_end(list);
    return total;
}
