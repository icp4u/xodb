// Owned fixture. Android uses the real Bionic ZIP loader; host uses ordinary .so files.
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
static int (*open_tick(const char *path, const char *symbol))(int) {
    void *handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!handle) { fprintf(stderr, "APK_FIXTURE_LOAD_FAILED: %s\n", dlerror()); exit(2); }
    int (*fn)(int) = (int (*)(int))dlsym(handle, symbol);
    if (!fn) { fprintf(stderr, "APK_FIXTURE_SYMBOL_FAILED: %s\n", dlerror()); exit(3); }
    return fn;
}
__attribute__((noinline)) void fixture_ready(void) { __asm__ volatile(""); }
int main(int argc, char **argv) {
    char left[4096], right[4096];
#ifdef __ANDROID__
    if (argc != 2) return 1;
    if (snprintf(left, sizeof left, "%s!/lib/arm64-v8a/left.so", argv[1]) >= (int)sizeof left ||
        snprintf(right, sizeof right, "%s!/lib/arm64-v8a/right.so", argv[1]) >= (int)sizeof right) return 1;
#else
    if (argc != 3) return 1;
    if (snprintf(left, sizeof left, "%s", argv[1]) >= (int)sizeof left ||
        snprintf(right, sizeof right, "%s", argv[2]) >= (int)sizeof right) return 1;
#endif
    int (*a)(int) = open_tick(left, "apk_left_tick");
    int (*b)(int) = open_tick(right, "apk_right_tick");
    fprintf(stderr, "APK_FIXTURE_READY pid=%d\n", getpid());
    fixture_ready();
    for (int i = 0; i < 1000; ++i) { a(5); b(3); usleep(10000); }
    return 0;
}
