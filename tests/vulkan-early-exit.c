/* Test-only deterministic early-start race window. No production delay hook.
 * On a private display, the first spawned worker is held at vkCreateInstance
 * (or vkEnumeratePhysicalDevices with XODB_TEST_EARLY_PHASE=probe) until its
 * owner calls pthread_join. pthread_create does not return until
 * the worker reached that call (or unexpectedly finished without reaching it).
 * Thus even an immediate argument error must dispose of the in-flight worker.
 * Other threads, including loader/driver threads, are untouched. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t changed = PTHREAD_COND_INITIALIZER;
static int claimed, entered, released, finished, joined;
static pthread_t worker;
static void *(*entry)(void *);
static void *argument;
static _Thread_local int early_worker;
static _Thread_local unsigned instance_depth;

static int enabled(void) {
    const char *p = getenv("XODB_TEST_PRIVATE_DISPLAY");
    const char *r = getenv("XDG_RUNTIME_DIR");
    const char *e = getenv("XODB_TEST_EARLY_EXIT");
    return p && !strcmp(p, "1") && r && strstr(r, "/.work/") && e && !strcmp(e, "1");
}

static void *run(void *unused) {
    (void)unused;
    early_worker = 1;
    void *result = entry(argument);
    pthread_mutex_lock(&lock);
    finished = 1;
    pthread_cond_broadcast(&changed);
    pthread_mutex_unlock(&lock);
    return result;
}

int pthread_create(pthread_t *thread, const pthread_attr_t *attr,
                   void *(*start)(void *), void *arg) {
    int (*real)(pthread_t *, const pthread_attr_t *, void *(*)(void *), void *) =
        dlsym(RTLD_NEXT, "pthread_create");
    if (!enabled()) return real(thread, attr, start, arg);
    pthread_mutex_lock(&lock);
    if (claimed) {
        pthread_mutex_unlock(&lock);
        return real(thread, attr, start, arg);
    }
    claimed = 1;
    entry = start;
    argument = arg;
    int result = real(thread, attr, run, NULL);
    if (!result) {
        worker = *thread;
        while (!entered && !finished) pthread_cond_wait(&changed, &lock);
    }
    pthread_mutex_unlock(&lock);
    return result;
}

int pthread_join(pthread_t thread, void **result) {
    int (*real)(pthread_t, void **) = dlsym(RTLD_NEXT, "pthread_join");
    if (!enabled()) return real(thread, result);
    pthread_mutex_lock(&lock);
    int ours = claimed && pthread_equal(thread, worker);
    if (ours) {
        released = 1;
        pthread_cond_broadcast(&changed);
    }
    pthread_mutex_unlock(&lock);
    int status = real(thread, result);
    if (ours && !status) {
        pthread_mutex_lock(&lock);
        joined = 1;
        pthread_mutex_unlock(&lock);
    }
    return status;
}

static void barrier(const char *phase) {
    const char *requested = getenv("XODB_TEST_EARLY_PHASE");
    if (!requested) requested = "instance";
    if (early_worker && !strcmp(phase, requested)) {
        pthread_mutex_lock(&lock);
        entered = 1;
        pthread_cond_broadcast(&changed);
        while (!released) pthread_cond_wait(&changed, &lock);
        pthread_mutex_unlock(&lock);
    }
}

VKAPI_ATTR VkResult VKAPI_CALL vkCreateInstance(const VkInstanceCreateInfo *info,
        const VkAllocationCallbacks *alloc, VkInstance *instance) {
    PFN_vkCreateInstance real = dlsym(RTLD_NEXT, "vkCreateInstance");
    barrier("instance");
    ++instance_depth;
    VkResult result = real(info, alloc, instance);
    --instance_depth;
    return result;
}

VKAPI_ATTR VkResult VKAPI_CALL vkEnumeratePhysicalDevices(VkInstance instance,
        uint32_t *count, VkPhysicalDevice *devices) {
    PFN_vkEnumeratePhysicalDevices real = dlsym(RTLD_NEXT, "vkEnumeratePhysicalDevices");
    // A loader/ICD's internal enumeration during instance creation is not
    // the application's later probe; do not confuse the two checkpoints.
    if (!instance_depth) barrier("probe");
    return real(instance, count, devices);
}

__attribute__((destructor)) static void summary(void) {
    if (!enabled()) return;
    pthread_mutex_lock(&lock);
    fprintf(stderr, "vkearly: {\"claimed\":%d,\"entered\":%d,\"finished\":%d,\"joined\":%d}\n",
            claimed, entered, finished, joined);
    /* Avoid running real loader destructors concurrently with an abandoned
     * worker in the negative control. Report the lifetime violation exactly. */
    int abandoned = claimed && (!finished || !joined);
    pthread_mutex_unlock(&lock);
    if (abandoned) _Exit(86);
}
