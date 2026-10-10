#define _GNU_SOURCE 1
#include "check.h"
#include <dlfcn.h>
#include <stdint.h>

__attribute__((noinline)) void modules_stop(void) { __asm__ volatile("" ::: "memory"); }
int main(int argc, char **argv)
{
    CHECK(argc == 3);
    FILE *oracle = fopen(argv[2], "w"); CHECK(oracle);
    int (*functions[12])(void);
    void *handles[12];
    for (unsigned i = 0; i < 12; ++i) {
        char path[4096], name[64];
        CHECK(snprintf(path, sizeof(path), "%s/lib%02u.so", argv[1], i) > 0);
        handles[i] = dlopen(path, RTLD_NOW | RTLD_LOCAL); CHECK(handles[i]);
        snprintf(name, sizeof(name), "module_marker_%u", i);
        functions[i] = dlsym(handles[i], name); CHECK(functions[i]);
        CHECK(functions[i]() == 1000 + (int)i);
        CHECK(fprintf(oracle, "%s %llx\n", name, (unsigned long long)(uintptr_t)functions[i]) > 0);
    }
    CHECK(fclose(oracle) == 0);
    modules_stop();
    for (unsigned i = 0; i < 12; ++i) {
        CHECK(functions[i]() == 1000 + (int)i);
        CHECK(dlclose(handles[i]) == 0);
    }
    return 0;
}
