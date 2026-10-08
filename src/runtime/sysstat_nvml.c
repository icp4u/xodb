#define _GNU_SOURCE 1
#include "sysstat_nvml.h"
#include <dlfcn.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* Stable NVML ABI subset (nvml.h). No SDK or NVML link dependency. */
struct utilization { unsigned gpu, memory; };
struct memory { unsigned long long total, free, used; };
struct memory_v2 { unsigned version; unsigned long long total, reserved, free, used; };
struct nvml_api {
    void *lib;
    int (*init)(void), (*shutdown)(void);
    int (*device)(const char *, void **);
    int (*util)(void *, struct utilization *);
    int (*power)(void *, unsigned *);
    int (*temperature)(void *, unsigned, unsigned *);
    int (*memory)(void *, struct memory *);
    int (*memory_v2)(void *, struct memory_v2 *);
    int (*clock)(void *, unsigned, unsigned *);
    int (*name)(void *, char *, unsigned);
    int initialized;
    char detail[128];
};
struct xrt_sys_nvml {
    pthread_mutex_t lock;
    pthread_cond_t wake;
    atomic_bool stop;
    int pending, busy, ready;
    uint32_t count;
    int64_t started, finished, next;
    uint64_t cpu_ns;
    char detail[128];
    char pci[XRT_SYS_MAX_GPUS][32];
    struct xrt_sys_gpu input[XRT_SYS_MAX_GPUS], result[XRT_SYS_MAX_GPUS];
};
#define PERIOD_NS INT64_C(5000000000)
#define DEADLINE_NS INT64_C(200000000)
static int64_t clock_ns(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return (int64_t)t.tv_sec * 1000000000 + t.tv_nsec;
}
static void missing_f(struct xrt_sys_f64 *f, int rc) {
    f->v = 0; f->st = XRT_SYS_UNAVAILABLE;
    f->why = rc == 4 ? XRT_SYS_WHY_NEEDS_PRIVILEGE : XRT_SYS_WHY_NOT_SUPPORTED;
}
static void value(struct xrt_sys_f64 *f, int rc, unsigned v, double scale) {
    if (rc) missing_f(f, rc);
    else { f->v = v * scale; f->st = XRT_SYS_OK; f->why = 0; }
}
static void open_api(struct nvml_api *a) {
    a->lib = dlopen("libnvidia-ml.so.1", RTLD_NOW | RTLD_LOCAL);
    if (!a->lib) { snprintf(a->detail, sizeof a->detail, "NVML: libnvidia-ml.so.1 not loadable"); return; }
#define LOAD(member, symbol) do { *(void **)(&a->member) = dlsym(a->lib, symbol); } while (0)
    LOAD(init, "nvmlInit_v2"); LOAD(shutdown, "nvmlShutdown");
    LOAD(device, "nvmlDeviceGetHandleByPciBusId_v2");
    LOAD(util, "nvmlDeviceGetUtilizationRates"); LOAD(power, "nvmlDeviceGetPowerUsage");
    LOAD(temperature, "nvmlDeviceGetTemperature"); LOAD(memory, "nvmlDeviceGetMemoryInfo");
    LOAD(memory_v2, "nvmlDeviceGetMemoryInfo_v2");
    LOAD(clock, "nvmlDeviceGetClockInfo"); LOAD(name, "nvmlDeviceGetName");
#undef LOAD
    if (!a->init || !a->shutdown || !a->device) {
        snprintf(a->detail, sizeof a->detail, "NVML required ABI missing"); return;
    }
    const int rc = a->init();
    if (rc) { snprintf(a->detail, sizeof a->detail, "NVML initialization failed (code %d)", rc); return; }
    a->initialized = 1;
    if (!a->memory_v2 && a->memory) snprintf(a->detail, sizeof a->detail, "NVML v1 VRAM used includes reserved memory");
}
static void query(struct nvml_api *a, const char *pci, struct xrt_sys_gpu *gpu) {
    void *device = NULL;
    if (!a->initialized || a->device(pci, &device) != 0) return;
    if (a->name && a->name(device, gpu->name.s, sizeof gpu->name.s) == 0) {
        gpu->name.s[sizeof gpu->name.s - 1] = 0; gpu->name.st = XRT_SYS_OK; gpu->name.why = 0;
    }
    struct utilization util = {0}; unsigned x = 0; int rc;
    rc = a->util ? a->util(device, &util) : 3; value(&gpu->busy_pct, rc, util.gpu, 1);
    rc = a->power ? a->power(device, &x) : 3; value(&gpu->power_w, rc, x, .001);
    rc = a->temperature ? a->temperature(device, 0, &x) : 3; value(&gpu->temp_c, rc, x, 1);
    rc = a->clock ? a->clock(device, 0, &x) : 3; value(&gpu->graphics_mhz, rc, x, 1);
    rc = a->clock ? a->clock(device, 2, &x) : 3; value(&gpu->memory_mhz, rc, x, 1);
    struct memory memory = {0};
    if (a->memory_v2) {
        struct memory_v2 current = {.version = (unsigned)sizeof current | (2u << 24)};
        rc = a->memory_v2(device, &current);
        memory.total = current.total; memory.free = current.free; memory.used = current.used;
    } else rc = a->memory ? a->memory(device, &memory) : 3;
    if (!rc) {
        gpu->vram_used = (struct xrt_sys_u64){memory.used, XRT_SYS_OK, 0};
        gpu->vram_total = (struct xrt_sys_u64){memory.total, XRT_SYS_OK, 0};
    } else {
        gpu->vram_used.why = gpu->vram_total.why = rc == 4 ? XRT_SYS_WHY_NEEDS_PRIVILEGE : XRT_SYS_WHY_NOT_SUPPORTED;
    }
}
static void *worker(void *opaque) {
    struct xrt_sys_nvml *s = opaque;
    struct nvml_api api = {0}; int attempted = 0;
    for (;;) {
        pthread_mutex_lock(&s->lock);
        while (!s->pending && !atomic_load(&s->stop)) {
            struct timespec deadline; clock_gettime(CLOCK_REALTIME, &deadline); deadline.tv_sec++;
            pthread_cond_timedwait(&s->wake, &s->lock, &deadline);
        }
        if (atomic_load(&s->stop)) { pthread_mutex_unlock(&s->lock); break; }
        const uint32_t count = s->count;
        struct xrt_sys_gpu out[XRT_SYS_MAX_GPUS]; char pci[XRT_SYS_MAX_GPUS][32];
        memcpy(out, s->input, sizeof out); memcpy(pci, s->pci, sizeof pci);
        s->pending = 0;
        pthread_mutex_unlock(&s->lock);
        struct timespec c0, c1; clock_gettime(CLOCK_THREAD_CPUTIME_ID, &c0);
        if (!attempted) { open_api(&api); attempted = 1; }
        for (uint32_t i = 0; i < count && !atomic_load(&s->stop); ++i) query(&api, pci[i], &out[i]);
        pthread_mutex_lock(&s->lock);
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &c1);
        s->cpu_ns += (uint64_t)((int64_t)(c1.tv_sec-c0.tv_sec)*1000000000 + c1.tv_nsec-c0.tv_nsec);
        snprintf(s->detail, sizeof s->detail, "%s", api.detail);
        memcpy(s->result, out, sizeof out); s->finished = clock_ns(); s->busy = 0; s->ready = 1;
        pthread_mutex_unlock(&s->lock);
    }
    if (api.initialized) api.shutdown();
    if (api.lib) dlclose(api.lib);
    pthread_cond_destroy(&s->wake); pthread_mutex_destroy(&s->lock); free(s);
    return NULL;
}
uint64_t xrt_sys_nvml_cpu(struct xrt_sys_nvml *s) {
    if (!s || pthread_mutex_trylock(&s->lock)) return 0;
    const uint64_t n = s->cpu_ns; s->cpu_ns = 0; pthread_mutex_unlock(&s->lock); return n;
}
void xrt_sys_nvml_close(struct xrt_sys_nvml *s) {
    if (!s) return;
    /* Do not access s after publishing stop: worker may free it immediately. */
    atomic_store(&s->stop, 1);
}
static struct xrt_sys_nvml *create(void) {
    struct xrt_sys_nvml *s = calloc(1, sizeof *s); if (!s) return NULL;
    atomic_init(&s->stop, 0);
    if (pthread_mutex_init(&s->lock, NULL)) { free(s); return NULL; }
    if (pthread_cond_init(&s->wake, NULL)) { pthread_mutex_destroy(&s->lock); free(s); return NULL; }
    pthread_attr_t attr; pthread_attr_init(&attr); pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_t thread; int rc = pthread_create(&thread, &attr, worker, s); pthread_attr_destroy(&attr);
    if (rc) { pthread_cond_destroy(&s->wake); pthread_mutex_destroy(&s->lock); free(s); return NULL; }
    return s;
}
void xrt_sys_nvml_collect(struct xrt_sys_nvml **owner, struct xrt_sys_power *power,
                          const char pci[XRT_SYS_MAX_GPUS][32], struct xrt_sys_group *group, int64_t now) {
    uint32_t count = 0;
    for (uint32_t i = 0; i < power->gpu_count; ++i) if (!strcmp(power->gpu[i].driver, "nvidia")) count++;
    if (!count) return;
    if (!*owner) *owner = create();
    struct xrt_sys_nvml *s = *owner;
    if (!s || pthread_mutex_trylock(&s->lock)) return;
    int pending = !s->ready, timed_out = s->busy && now - s->started > DEADLINE_NS;
    if (s->ready) for (uint32_t i = 0; i < power->gpu_count; ++i) {
        struct xrt_sys_gpu *gpu = &power->gpu[i];
        if (strcmp(gpu->driver, "nvidia")) continue;
        for (uint32_t j = 0; j < s->count; ++j) if (!strcmp(gpu->card, s->result[j].card)) {
            *gpu = s->result[j];
            if (timed_out || now - s->finished > PERIOD_NS + INT64_C(1000000000)) {
                struct xrt_sys_f64 *fields[] = { &gpu->busy_pct, &gpu->power_w, &gpu->temp_c, &gpu->graphics_mhz, &gpu->memory_mhz };
                for (size_t k = 0; k < sizeof fields / sizeof fields[0]; ++k) if (fields[k]->st == XRT_SYS_OK) {
                    fields[k]->st = XRT_SYS_STALE; fields[k]->why = timed_out ? XRT_SYS_WHY_LIMIT : XRT_SYS_WHY_SLOW_SOURCE;
                }
                struct xrt_sys_u64 *memory[] = { &gpu->vram_used, &gpu->vram_total };
                for (size_t k = 0; k < 2; ++k) if (memory[k]->st == XRT_SYS_OK) {
                    memory[k]->st = XRT_SYS_STALE; memory[k]->why = timed_out ? XRT_SYS_WHY_LIMIT : XRT_SYS_WHY_SLOW_SOURCE;
                }
            }
        }
    }
    if (!s->busy && now >= s->next) {
        s->count = 0;
        for (uint32_t i = 0; i < power->gpu_count; ++i) if (!strcmp(power->gpu[i].driver, "nvidia")) {
            const uint32_t j = s->count++;
            s->input[j] = power->gpu[i]; memcpy(s->pci[j], pci[i], 32);
            /* A failed query must not retain the previous successful value. */
            missing_f(&s->input[j].busy_pct, 3); missing_f(&s->input[j].power_w, 3); missing_f(&s->input[j].temp_c, 3);
            missing_f(&s->input[j].graphics_mhz, 3); missing_f(&s->input[j].memory_mhz, 3);
            s->input[j].vram_used = s->input[j].vram_total = (struct xrt_sys_u64){0, XRT_SYS_UNAVAILABLE, XRT_SYS_WHY_NOT_SUPPORTED};
        }
        s->started = now; s->next = now + PERIOD_NS; s->busy = 1; s->pending = 1;
        pthread_cond_signal(&s->wake);
    }
    char explanation[128];
    snprintf(explanation, sizeof explanation, "%s", timed_out ? "NVML exceeded 200 ms; worker isolated, retry on completion" : pending ? "NVML pending; GPU fields unavailable until ready" : s->detail);
    pthread_mutex_unlock(&s->lock);
    if (explanation[0]) {
        size_t used = strnlen(group->detail, sizeof group->detail);
        if (used && used + 2 < sizeof group->detail) {
            memcpy(group->detail + used, "; ", 2); used += 2;
        }
        if (used < sizeof group->detail - 1) {
            const size_t n = strnlen(explanation, sizeof group->detail - used - 1);
            memcpy(group->detail + used, explanation, n); group->detail[used + n] = 0;
        }
    }
}
