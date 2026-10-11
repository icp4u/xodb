/* libdep.dylib: linked by cprog at build time. */
#include <string.h>
#include "dep.h"
volatile uint64_t dep_counter = 100;
static int dep_private(int value) { return value * 3 + 1; }
__attribute__((noinline)) int dep_add(int a, int b)
{
    dep_counter++;
    return dep_private(a) + b;
}
__attribute__((noinline)) struct dep_record dep_make(uint32_t id, const char *tag)
{
    struct dep_record record = {id, 2, 1, "", 0.5};
    strncpy(record.tag, tag, sizeof record.tag - 1);
    record.weight += (double)id;
    return record;
}
