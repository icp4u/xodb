/* Private-display exit-race amplifier. Delay this preload's finalizer after
 * earlier library finalizers, allowing an incorrectly unjoined worker to run
 * inside the loader/ICD after their teardown. No production hooks or sleeps. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <vulkan/vulkan.h>

static _Atomic unsigned instances;
static int enabled(void) {
    const char *p = getenv("XODB_TEST_PRIVATE_DISPLAY");
    const char *r = getenv("XDG_RUNTIME_DIR");
    const char *e = getenv("XODB_TEST_SLOW_FINI");
    return p && !strcmp(p, "1") && r && strstr(r, "/.work/") && e && !strcmp(e, "1");
}
VKAPI_ATTR VkResult VKAPI_CALL vkCreateInstance(const VkInstanceCreateInfo *info,
        const VkAllocationCallbacks *alloc, VkInstance *instance) {
    PFN_vkCreateInstance real = dlsym(RTLD_NEXT, "vkCreateInstance");
    if (enabled()) atomic_fetch_add(&instances, 1);
    return real(info, alloc, instance);
}
__attribute__((destructor)) static void slow(void) {
    if (!enabled()) return;
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    unsigned seed = (unsigned)now.tv_nsec;
    unsigned delay = (unsigned)(400000ULL * rand_r(&seed) / (RAND_MAX + 1ULL));
    fprintf(stderr, "vkslowfini: begin instances=%u delay_us=%u\n", atomic_load(&instances), delay);
    usleep(delay);
    fprintf(stderr, "vkslowfini: end\n");
}
