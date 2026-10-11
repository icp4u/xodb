/* A spread of C types and locals for debug-info readers. */
#include <complex.h>
#include <stdbool.h>
#include <stddef.h>
#include "dep.h"
enum colour { RED, GREEN = 5, BLUE = -2 };
typedef enum colour colour_t;
typedef int (*binary_fn)(int, int);
union number { uint32_t u; float f; uint8_t bytes[4]; };
struct bits { unsigned low : 3; unsigned mid : 7; int sign : 2; _Bool flag : 1; };
struct point { int x, y; };
struct shape {
    const char *name;
    colour_t colour;
    struct point corners[4];
    union number scale;
    struct bits bits;
    binary_fn combine;
    struct shape *next;
    struct { short inner_a; long inner_b; } anonymous;
    unsigned char tail[];
};
typedef struct shape shape_t;
_Thread_local int types_tls = 41;
static const double types_table[3] = {1.5, 2.5, 3.5};
struct shape types_global = {"square", GREEN, {{0, 0}, {1, 0}, {1, 1}, {0, 1}}, {.u = 0x3f800000}, {5, 99, -1, 1}, dep_add, 0, {7, 8}};
long double types_long_double = 1.25L;
__int128 types_wide = ((__int128)1 << 100) + 3;
float _Complex types_complex;
static inline int types_square(int value) { return value * value; }
static int types_vla(int count)
{
    int values[count];
    for (int i = 0; i < count; i++) values[i] = types_square(i);
    return values[count - 1];
}
__attribute__((noinline)) uint64_t types_touch(uint64_t seed)
{
    static int calls;
    struct point here = {(int)(seed & 15), ++calls};
    union number view = {.f = (float)here.x};
    bool odd = seed & 1;
    const shape_t *shape = &types_global;
    volatile double total = types_table[here.x % 3] + (double)types_long_double;
    types_tls += odd;
    types_complex = 1.0f + 2.0f * I;
    return (uint64_t)types_vla(3 + here.x) + view.u + (uint64_t)shape->combine(here.x, here.y) + (uint64_t)total + (uint64_t)types_wide;
}
