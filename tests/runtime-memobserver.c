#define _GNU_SOURCE 1
#include "xrt_memobserver.h"
#include <assert.h>
#include <dirent.h>
#include <stdio.h>
#include <stdint.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static uint64_t now(void)
{
    struct timespec t; assert(clock_gettime(CLOCK_MONOTONIC, &t) == 0);
    return (uint64_t)t.tv_sec * 1000000000u + (uint64_t)t.tv_nsec;
}
static void yield(void)
{
    struct timespec t = {.tv_nsec = 1000000}; nanosleep(&t, NULL);
}
static unsigned descriptors(void)
{
    DIR *d = opendir("/proc/self/fd"); assert(d);
    unsigned count = 0; struct dirent *e;
    while ((e = readdir(d))) if (e->d_name[0] != '.') ++count;
    closedir(d); return count;
}
static struct xrt_mem_scope wait_scope(struct xrt_memobserver *o, uint64_t ticket)
{
    uint64_t deadline = now() + UINT64_C(15000000000);
    while (now() < deadline) {
        struct xrt_mem_view v;
        if (xrt_memobserver_acquire(o, &v)) {
            for (unsigned i = 0; i < XRT_MEM_SCOPES; ++i) if (v.scopes[i].ticket == ticket && v.scopes[i].sequence) {
                struct xrt_mem_scope result = v.scopes[i];
                assert(result.snapshot && !result.error);
                /* Copy only scalar evidence; the returned pointer is not used. */
                result.error = (int32_t)result.snapshot->maps_status.state;
                result.snapshot = NULL;
                xrt_memobserver_release(o);
                return result;
            }
            xrt_memobserver_release(o);
        }
        yield();
    }
    assert(!"memory worker did not publish before test watchdog");
    return (struct xrt_mem_scope){0};
}
static uint64_t request(struct xrt_memobserver *o, const struct xrt_mem_request *r)
{
    uint64_t end = now() + UINT64_C(15000000000), ticket;
    while (!(ticket = xrt_memobserver_process(o, r))) { assert(now() < end); yield(); }
    return ticket;
}
int main(void)
{
    assert(xrt_memobserver_period(0) == UINT64_C(1000000000));
    assert(xrt_memobserver_period(UINT64_C(8000000)) == UINT64_C(1000000000));
    assert(xrt_memobserver_period(UINT64_C(40000000)) == UINT64_C(5000000000));
    assert(xrt_memobserver_period(UINT64_MAX) == UINT64_C(60000000000));
    unsigned before = descriptors();
    size_t page = (size_t)sysconf(_SC_PAGESIZE);
    char *memory = mmap(NULL, 2 * page, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    assert(memory != MAP_FAILED); memory[0] = 1; memory[page] = 2;
    struct xrt_memobserver *o = xrt_memobserver_open(NULL, NULL); assert(o);
    struct xrt_mem_view v;
    while (!xrt_memobserver_acquire(o, &v)) yield();
    assert(!v.system && !v.system_sequence);
    for (unsigned i = 0; i < XRT_MEM_SCOPES; ++i) assert(!v.scopes[i].ticket && !v.scopes[i].snapshot);
    xrt_memobserver_release(o);
    struct xrt_mem_request r = {.pid = getpid(), .range_start = (uintptr_t)memory, .range_end = (uintptr_t)memory + 2 * page};
    uint64_t first = request(o, &r);
    struct xrt_mem_scope scope = wait_scope(o, first);
    assert(scope.bound_start && scope.error == XRT_MEM_OK && scope.refresh_ns >= UINT64_C(1000000000));
    assert(scope.cost_limited == (scope.refresh_ns > UINT64_C(1000000000)));
    r.start_ticks = scope.bound_start;
    assert(request(o, &r) == first); /* A second reader adopts the same pinned scope. */
    struct xrt_mem_request metadata = {.pid = r.pid, .flags = XRT_MEM_SKIP_PAGES, .start_ticks = r.start_ticks};
    assert(request(o, &metadata) == first);
    while (!xrt_memobserver_acquire(o, &v)) yield();
    unsigned scopes = 0;
    for (unsigned i = 0; i < XRT_MEM_SCOPES; ++i) if (v.scopes[i].ticket) {
        ++scopes;
        assert(v.scopes[i].snapshot->scanned_bytes == 2 * page && v.scopes[i].snapshot->pages_status.state == XRT_MEM_OK);
    }
    assert(scopes == 1 && v.system_sequence && v.system);
    xrt_memobserver_release(o);
    metadata.flags |= XRT_MEM_NUMA;
    uint64_t numa = request(o, &metadata);
    assert(numa != first); /* A request for additional data cannot reuse a cache without it. */
    scope = wait_scope(o, numa); assert(scope.error == XRT_MEM_OK);
    r.start_ticks++;
    uint64_t wrong = request(o, &r); assert(wrong != first);
    scope = wait_scope(o, wrong); assert(scope.error == XRT_MEM_IDENTITY_CHANGED);
    xrt_memobserver_close(o);
    /* Closing an idle worker and closing while a fresh request is in flight
     * both return with its worker joined and all publication storage freed. */
    o = xrt_memobserver_open(NULL, NULL); assert(o); xrt_memobserver_close(o);
    o = xrt_memobserver_open(NULL, NULL); assert(o); r.start_ticks = 0;
    (void)request(o, &r); xrt_memobserver_close(o);
    /* Reaped targets keep their identity while demand wakes exit detection.
     * No fixed latency assertion: the loop's timeout is only a watchdog. */
    int control[2]; assert(pipe(control) == 0);
    pid_t child = fork(); assert(child >= 0);
    if (!child) {
        close(control[1]); char byte;
        (void)read(control[0], &byte, 1); close(control[0]); _exit(0);
    }
    close(control[0]);
    o = xrt_memobserver_open(NULL, NULL); assert(o);
    r.pid = child; r.start_ticks = 0;
    first = request(o, &r); scope = wait_scope(o, first);
    assert(scope.error == XRT_MEM_OK && scope.bound_start);
    r.start_ticks = scope.bound_start;
    close(control[1]); int status; assert(waitpid(child, &status, 0) == child && WIFEXITED(status));
    uint64_t exited_at = now(), deadline = exited_at + UINT64_C(15000000000);
    int exited = 0;
    while (!exited) {
        assert(now() < deadline && request(o, &r) == first);
        if (xrt_memobserver_acquire(o, &v)) {
            for (unsigned i = 0; i < XRT_MEM_SCOPES; ++i) if (v.scopes[i].ticket == first && v.scopes[i].sequence > scope.sequence) {
                assert(v.scopes[i].bound_start == r.start_ticks && v.scopes[i].snapshot);
                exited = v.scopes[i].snapshot->maps_status.state == XRT_MEM_EXITED;
                if (exited) assert(!v.scopes[i].snapshot->vma_count && !v.scopes[i].snapshot->name[0]);
            }
            xrt_memobserver_release(o);
        }
        if (!exited) yield();
    }
    printf("memory observer: reaped publication after %llu ns; prior refresh %llu ns\n",
        (unsigned long long)(now() - exited_at), (unsigned long long)scope.refresh_ns);
    xrt_memobserver_close(o);
    assert(munmap(memory, 2 * page) == 0);
    assert(descriptors() == before);
    puts("memory observer: lazy publication, shared scope, metadata reuse, pinned identity and teardown passed");
    return 0;
}
