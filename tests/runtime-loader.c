#define _GNU_SOURCE 1
#include "xrt_loader.h"
#include "xrt_remote.h"
#include "xrt_files.h"
#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

__attribute__((noinline)) void loader_ready(void) { __asm__ volatile ("" ::: "memory"); }
static void check(enum xrt_status status)
{
    if (status != XRT_OK) {
        fprintf(stderr, "runtime loader status: %d\n", status);
        abort();
    }
}
static void *worker_maps(void *target)
{
    int fd = -1;
    const struct xrt_file_request request = {.kind = XRT_FILE_MAPS};
    check(xrt_target_file(target, &request, &fd));
    assert(fd >= 0);
    close(fd);
    return NULL;
}
int main(int argc, char **argv)
{
    if (argc == 2 && !strcmp(argv[1], "fixture")) {
        loader_ready();
        for (;;) pause();
    }
    struct xrt_target *target = NULL;
    if (argc > 2 && !strcmp(argv[1], "transport")) {
        check(xrt_target_remote((const char *const *)(argv + 2), &target));
        check(xrt_target_destroy(target));
        puts("Agent HELLO/CREATE/DESTROY succeeded");
        return 0;
    }
    if (getenv("XODB_TEST_NO_LIVE")) {
        puts("SKIP loader live test: XODB_TEST_NO_LIVE");
        return 0;
    }
    if (argc == 2) {
        const char *agent[] = {argv[1], "--stdio", NULL};
        check(xrt_target_remote(agent, &target));
    } else target = xrt_target_create();
    assert(target);
    const char *child[] = {argv[0], "fixture", NULL};
    check(xrt_target_launch(target, child));
    struct xrt_loader early, ready;
    check(xrt_target_loader(target, &early, NULL));
    assert(early.main_phdr && early.interpreter && early.debug_address && early.break_address);
    assert(early.bytes < 16384 && early.reads < 64);
    uint64_t id = 0;
    check(xrt_target_breakpoint_set(target, (uint64_t)(uintptr_t)loader_ready, false, &id));
    check(xrt_target_continue(target));
    check(xrt_target_wait_stopped(target));
    check(xrt_target_loader(target, &ready, NULL));
    assert(ready.debug_address == early.debug_address && ready.break_address == early.break_address);
    assert(ready.bytes < early.bytes && ready.reads < early.reads);
    printf("Loader bootstrap: %llu bytes/%llu reads; DT_DEBUG: %llu bytes/%llu reads\n",
           (unsigned long long)early.bytes, (unsigned long long)early.reads,
           (unsigned long long)ready.bytes, (unsigned long long)ready.reads);
    volatile sig_atomic_t cancel = 1;
    assert(xrt_target_loader(target, &ready, &cancel) == XRT_DISCOVERY_CANCELLED);
    if (xrt_target_is_remote(target)) {
        /* An expired owner budget must not fail a concurrent profiling reader
         * on the shared connection, nor remain installed after its scope. */
        struct xrt_file_budget budget = {.limit_bytes = 4096, .deadline_ns = 1};
        xrt_target_file_budget(target, &budget);
        const struct xrt_file_request request = {.kind = XRT_FILE_MAPS};
        int fd = -1;
        assert(xrt_target_file(target, &request, &fd) == XRT_DISCOVERY_PENDING && fd == -1);
        pthread_t worker;
        assert(!pthread_create(&worker, NULL, worker_maps, target));
        assert(!pthread_join(worker, NULL));
        xrt_target_file_budget(target, NULL);
        worker_maps(target);
    }
    check(xrt_target_destroy(target));
    return 0;
}
