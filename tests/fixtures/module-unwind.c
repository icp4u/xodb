#define _GNU_SOURCE 1
#include "check.h"
#include <dlfcn.h>
#include <stdint.h>
#include <string.h>
typedef void (*walk_fn)(void **, unsigned, unsigned, uintptr_t *, void (*)(uintptr_t *, unsigned));
static const char *oracle_path;
__attribute__((noinline)) void unwind_stop(void) { __asm__ volatile("" ::: "memory"); }
__attribute__((noinline)) static void capture(uintptr_t *pcs, unsigned count) {
    pcs[count] = (uintptr_t)__builtin_return_address(0);
    FILE *out = fopen(oracle_path, "w"); CHECK(out);
    for (unsigned i = count + 1; i > 0; --i) CHECK(fprintf(out, "%llx\n", (unsigned long long)pcs[i-1]) > 0);
    CHECK(!fclose(out));
    unwind_stop();
    __asm__ volatile("" ::: "memory");
}
int main(int argc, char **argv) {
    CHECK(argc == 5);
    oracle_path = argv[2];
    unsigned count = (unsigned)strtoul(argv[3], NULL, 10); CHECK(count > 0 && count <= 80);
    void *functions[80], *handles[80]; uintptr_t pcs[81];
    for (unsigned i = 0; i < count; ++i) {
        char path[4096]; CHECK(snprintf(path, sizeof path, "%s/lib%02u.so", argv[1], i) > 0);
        handles[i] = dlopen(path, RTLD_NOW | RTLD_LOCAL); CHECK(handles[i]);
        functions[i] = dlsym(handles[i], "walk"); CHECK(functions[i]);
    }
    if (!strcmp(argv[4], "chain")) ((walk_fn)functions[0])(functions, 0, count, pcs, capture);
    else {
        for (unsigned i = 0; i < count; ++i) ((walk_fn)functions[i])(&functions[i], 0, 1, pcs, capture);
        ((walk_fn)functions[0])(functions, 0, 1, pcs, capture);
        ((walk_fn)functions[1])(&functions[1], 0, 1, pcs, capture);
    }
    for (unsigned i = 0; i < count; ++i) CHECK(!dlclose(handles[i]));
    return 0;
}
