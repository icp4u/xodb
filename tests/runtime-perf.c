#define _GNU_SOURCE 1
#include "perf_internal.h"
#include "xrt_allocations.h"
#include "perf_wire.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/perf_event.h>
#include <sched.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
static void put(void *p, uint64_t n)
{
    memcpy(p, &n, 8);
}
struct decoding {
    size_t calls, records;
    bool overconsume;
};
static void consume(void *raw, const struct xrt_perf_ring *r, struct xrt_perf_consumed *out)
{
    struct decoding *d = raw;
    ++d->calls;
    if (d->overconsume) {
        *out = (struct xrt_perf_consumed){.bytes = r->head - r->tail + 8};
        return;
    }
    uint64_t used = 0;
    while (used < r->head - r->tail) {
        struct perf_event_header h;
        assert(r->head - r->tail - used >= sizeof(h));
        assert(xrt_perf_copy(r->data, r->size, r->tail + used, &h, sizeof(h)));
        assert(h.size >= sizeof(h) && !(h.size & 7) && h.size <= r->head - r->tail - used);
        used += h.size;
        ++d->records;
    }
    *out = (struct xrt_perf_consumed){.bytes = used};
}
static void rings(void)
{
    const size_t page = xrt_perf_page_size(), bytes = 2 * page;
    struct xrt_perf *p = xrt_perf_create(1, 1, page);
    assert(p);
    uint8_t *map = calloc(1, bytes);
    assert(map);
    p->count = 1;
    p->slots[0].map = map;
    p->slots[0].map_size = bytes;
    put(map + 1040, page);
    put(map + 1048, page);
    struct decoding d = {0};
    /* Wrapped header is copied without reading outside the data ring. */
    struct perf_event_header h = {.type = PERF_RECORD_SAMPLE, .size = 16};
    memcpy(map + 2 * page - 8, &h, 8);
    put(map + page, 42);
    p->slots[0].tail = page - 8;
    put(map + 1024, page + 8);
    assert(xrt_perf_drain(p, consume, &d) == XRT_PERF_DRAIN_OK && d.records == 1);
    assert(p->slots[0].tail == page + 8 && *(uint64_t *)(map + 1032) == page + 8);
    /* Decoder rejection cannot acknowledge bytes it never received. */
    d.overconsume = true;
    assert(xrt_perf_drain(p, consume, &d) == XRT_PERF_DRAIN_MALFORMED);
    assert(p->slots[0].tail == page + 8);
    d.overconsume = false;
    for (unsigned i = 0; i < 10000; ++i) {
        uint64_t offset = (i % 2) ? UINT64_MAX - i : page, size = (i % 3) ? UINT64_MAX - i : page;
        uint64_t head = (i % 5) ? UINT64_MAX - i : 0;
        put(map + 1040, offset);
        put(map + 1048, size);
        put(map + 1024, head);
        size_t calls = d.calls;
        assert(xrt_perf_drain(p, consume, &d) == XRT_PERF_DRAIN_MALFORMED);
        assert(d.calls == calls && p->slots[0].tail == page + 8);
    }
    xrt_perf_destroy(p);
    free(map);
    const uint8_t ring[] = {0, 1, 2, 3, 4, 5, 6, 7};
    uint8_t out[6];
    assert(xrt_perf_copy(ring, 8, UINT64_MAX - 1, out, 6));
    assert(!memcmp(out, (uint8_t[]){6, 7, 0, 1, 2, 3}, 6));
    assert(!xrt_perf_copy(ring, 7, 0, out, 6));
    assert(!xrt_perf_copy(ring, 4, 0, out, 6));
}
static void metadata(void)
{
    uint64_t n = 0;
    assert(xrt_perf_unsigned("18446744073709551615", 20, &n) && n == UINT64_MAX);
    assert(!xrt_perf_unsigned("18446744073709551616", 20, &n));
    assert(!xrt_perf_unsigned("1x", 2, &n));
    assert(xrt_allocation_retprobe("config:63\n", 10, &n) && n == (UINT64_C(1) << 63));
    assert(!xrt_allocation_retprobe("config:64", 9, &n));
    assert(!xrt_allocation_retprobe("config:0-2", 10, &n));
    assert(!xrt_syscall_format("ID: 1\n", 6, 1, true));
    assert(xrt_allocation_offset(-1, 0) != NULL);
}
static void rollback(void)
{
    struct xrt_perf *p = xrt_perf_create(1, 2, 8192);
    assert(p);
    int fds[2];
    assert(!pipe2(fds, O_CLOEXEC));
    p->count = 1;
    p->slots[0].thread.event_count = 2;
    p->slots[0].fds[0] = fds[0];
    p->slots[0].fds[1] = fds[1];
    assert(xrt_perf_fd_count(p) == 2);
    xrt_perf_destroy(p);
    for (unsigned i = 0; i < 2; ++i) {
        assert(fcntl(fds[i], F_GETFD) == -1);
        assert(errno == EBADF);
    }
}
static void live(void)
{
    int32_t tid = getpid();
    struct xrt_cpu_config cfg = {.tids = &tid,
                                 .thread_count = 1,
                                 .frequency_hz = 999,
                                 .data_pages = 4,
                                 .ring_budget_bytes = 65536,
                                 .exclude_kernel = true};
    struct xrt_cpu_acceptance accepted;
    struct xrt_perf_failure f;
    struct xrt_perf *p = xrt_cpu_start(&cfg, &accepted, &f);
    if (!p && (f.kind == XRT_PERF_PERMISSION || f.kind == XRT_PERF_UNAVAILABLE)) {
        printf("C perf live SKIP: %s errno=%d\n", f.syscall, f.error);
        return;
    }
    assert(p);
    struct xrt_perf_thread thread;
    assert(xrt_perf_thread(p, 0, &thread));
    assert(thread.tid == tid && thread.event_ids[0] && thread.start_time_known);
    struct timespec start, now;
    clock_gettime(CLOCK_MONOTONIC, &start);
    do {
        clock_gettime(CLOCK_MONOTONIC, &now);
    } while ((now.tv_sec - start.tv_sec) * 1000000000L + now.tv_nsec - start.tv_nsec < 50000000);
    assert(xrt_perf_stop(p, &f));
    struct decoding d = {0};
    assert(xrt_perf_drain(p, consume, &d) == XRT_PERF_DRAIN_OK && d.records);
    assert(xrt_perf_enable(p, &f));
    assert(!xrt_cpu_enroll(p, tid, &accepted, &f) && f.kind == XRT_PERF_CONFIGURATION);
    assert(!xrt_cpu_enroll(p, INT32_MAX, &accepted, &f) && f.kind == XRT_PERF_THREAD_GONE);
    assert(xrt_perf_fd_count(p) == 1);
    assert(xrt_perf_stop(p, &f));
    xrt_perf_destroy(p);
    int32_t tids[] = {tid, INT32_MAX};
    cfg.tids = tids;
    cfg.thread_count = 2;
    assert(!xrt_cpu_start(&cfg, &accepted, &f));
    assert(f.kind == XRT_PERF_THREAD_GONE && f.opened_then_closed == 1);
}
static void perf_limit_suffix(void)
{
    uint8_t bytes[8192];
    struct xrt_perf_info source = {.threads = 2, .page_size = 4096, .running = true};
    int32_t dropped[] = {40, 41};
    struct xrt_codec bare = xrt_codec(bytes, sizeof(bytes), false);
    xrt_wire_perf_info(&bare, &source);
    assert(bare.ok);
    const size_t info_size = bare.at;
    struct xrt_perf_limit_suffix suffix = {.kind = XRT_RING_LIMIT_CAPPED,
                                           .data_pages = 1,
                                           .planned = 1,
                                           .opened = 2,
                                           .unsampled_count = 2,
                                           .unsampled = dropped};
    struct xrt_codec out = xrt_codec(bytes, sizeof(bytes), false);
    xrt_wire_perf_info(&out, &source);
    xrt_wire_perf_limit(&out, &suffix);
    assert(out.ok && out.at > info_size);
    struct xrt_perf_info decoded = {0};
    int32_t got[4] = {0};
    struct xrt_perf_limit_suffix in_suffix = {.unsampled = got};
    struct xrt_codec in = xrt_codec(bytes, out.at, true);
    xrt_wire_perf_info(&in, &decoded);
    assert(in.ok && in.at == info_size && decoded.threads == 2 && decoded.running && !decoded.failed);
    xrt_wire_perf_limit(&in, &in_suffix);
    assert(in.ok && in.at == in.size);
    assert(in_suffix.kind == XRT_RING_LIMIT_CAPPED && in_suffix.data_pages == 1 && in_suffix.planned == 1);
    assert(in_suffix.opened == 2 && in_suffix.unsampled_count == 2 && got[0] == 40 && got[1] == 41);
    /* An unchanged suffix is one zero byte after the info. A change is that
     * byte set, then the same suffix. */
    uint8_t mark = 0;
    out = xrt_codec(bytes, sizeof(bytes), false);
    xrt_wire_perf_info(&out, &source);
    xrt_codec_u8(&out, &mark);
    assert(out.ok && out.at == info_size + 1);
    in = xrt_codec(bytes, out.at, true);
    xrt_wire_perf_info(&in, &decoded);
    xrt_codec_u8(&in, &mark);
    assert(in.ok && in.at == in.size && mark == 0 && decoded.threads == 2);
    mark = 1;
    out = xrt_codec(bytes, sizeof(bytes), false);
    xrt_wire_perf_info(&out, &source);
    xrt_codec_u8(&out, &mark);
    xrt_wire_perf_limit(&out, &suffix);
    assert(out.ok);
    memset(got, 0, sizeof(got));
    in = xrt_codec(bytes, out.at, true);
    xrt_wire_perf_info(&in, &decoded);
    xrt_codec_u8(&in, &mark);
    in_suffix = (struct xrt_perf_limit_suffix){.unsampled = got};
    xrt_wire_perf_limit(&in, &in_suffix);
    assert(in.ok && in.at == in.size && mark == 1 && got[0] == 40 && got[1] == 41);
    suffix.kind = XRT_RING_LIMIT_NONE;
    out = xrt_codec(bytes, sizeof(bytes), false);
    xrt_wire_perf_info(&out, &source);
    xrt_wire_perf_limit(&out, &suffix);
    assert(!out.ok);
}
static void asynchronous_failure(void)
{
    uint8_t bytes[256];
    struct xrt_perf_info source = {.threads = 1, .page_size = 4096, .failed = true};
    xrt_perf_fail(&source.failure, "enroll", ENOMEM, 123, "capture ring-data budget exhausted");
    struct xrt_codec out = xrt_codec(bytes, sizeof(bytes), false);
    xrt_wire_perf_info(&out, &source);
    assert(out.ok);
    struct xrt_perf_info decoded = {0};
    struct xrt_codec in = xrt_codec(bytes, out.at, true);
    xrt_wire_perf_info(&in, &decoded);
    assert(in.ok && in.at == in.size && decoded.failed);
    assert(decoded.failure.kind == XRT_PERF_RESOURCE && decoded.failure.error == ENOMEM &&
           decoded.failure.tid == 123);
    assert(!strcmp(decoded.failure.detail, "capture ring-data budget exhausted"));
    bytes[out.at - 1] = 255;
    in = xrt_codec(bytes, out.at, true);
    xrt_wire_perf_info(&in, &decoded);
    assert(!in.ok);
}
static void loss_counter_reads(void)
{
    struct xrt_perf *p = xrt_perf_create(1, 1, xrt_perf_page_size());
    assert(p);
    int first[2], second[2];
    assert(pipe2(first, O_NONBLOCK | O_CLOEXEC) == 0 && pipe2(second, O_NONBLOCK | O_CLOEXEC) == 0);
    p->count = 1;
    p->slots[0].thread.event_count = 2;
    p->slots[0].fds[0] = first[0]; p->slots[0].fds[1] = second[0];
    p->slots[0].lost_read_mask = 3;
    uint64_t data[2] = {100, 7}, lost = 0;
    assert(write(first[1], data, sizeof data) == sizeof data);
    data[1] = 11; assert(write(second[1], data, sizeof data) == sizeof data);
    assert(xrt_perf_read_lost(p, 0, &lost) && lost == 18);
    assert(!xrt_perf_read_lost(p, 1, &lost));
    assert(!xrt_perf_read_lost(p, 0, &lost)); /* failed read is not measured zero */
    assert(write(first[1], data, 8) == 8);
    assert(!xrt_perf_read_lost(p, 0, &lost)); /* short format rejected */
    p->slots[0].lost_read_mask = 0;
    assert(!xrt_perf_read_lost(p, 0, &lost)); /* unsupported format */
    close(first[1]); close(second[1]); xrt_perf_destroy(p);
}

static void kernel_stack_denial(void)
{
    int32_t tid = (int32_t)gettid();
    struct xrt_cpu_config cfg = {
        .tids = &tid, .thread_count = 1, .frequency_hz = 99, .max_frames = 8, .data_pages = 1,
        .ring_budget_bytes = 4096, .exclude_kernel = false, .callchain = true,
    };
    struct xrt_cpu_acceptance accepted;
    struct xrt_perf_failure failure = {0};
    assert(!setenv("XODB_TEST_KERNEL_STACKS", "deny", 1));
    assert(!xrt_cpu_start(&cfg, &accepted, &failure));
    assert(failure.kind == XRT_PERF_PERMISSION && failure.error == EPERM);
    assert(failure.opened_then_closed == 0);
    assert(failure.detail && strstr(failure.detail, "perf_event_paranoid"));
    /* User-only still opens while the hook is set. A swallowed refusal would
     * fail this open with the kernel-stack detail. */
    cfg.exclude_kernel = true;
    failure = (struct xrt_perf_failure){0};
    struct xrt_perf *opened = xrt_cpu_start(&cfg, &accepted, &failure);
    assert(opened);
    xrt_perf_destroy(opened);
    unsetenv("XODB_TEST_KERNEL_STACKS");
}

static int ring_hold(void *arg)
{
    (void)arg;
    for (;;)
        pause();
    return 0;
}
static int spawn_hold(void *stack, size_t bytes)
{
    int tid = clone(ring_hold, (char *)stack + bytes,
                    CLONE_VM | CLONE_FS | CLONE_FILES | CLONE_SIGHAND | CLONE_THREAD | CLONE_SYSVSEM, NULL);
    assert(tid > 0);
    return tid;
}
static void ring_limit_degrade(void)
{
    static char stacks[2][8192] __attribute__((aligned(16)));
    int32_t self = (int32_t)gettid();
    struct xrt_cpu_acceptance accepted;
    struct xrt_perf_failure failure = {0};
    struct xrt_cpu_config cfg = {
        .tids = &self, .thread_count = 1, .frequency_hz = 99, .data_pages = 4,
        .ring_budget_bytes = 262144, .exclude_kernel = true,
    };
    assert(!setenv("XODB_TEST_RING_MMAP", "shrink", 1));
    struct xrt_perf *shrunk = xrt_cpu_start(&cfg, &accepted, &failure);
    assert(shrunk);
    assert(xrt_cpu_ring_limit(shrunk) == XRT_RING_LIMIT_SHRUNK);
    assert(xrt_perf_ring_pages(shrunk) == 1);
    assert(xrt_perf_fd_count(shrunk) == 1 && shrunk->slots[0].owns_map);
    const char *notice = xrt_cpu_ring_notice(shrunk);
    assert(notice && strstr(notice, "perf_event_mlock_kb") && strstr(notice, "RLIMIT_MEMLOCK"));
    xrt_perf_destroy(shrunk);
    unsetenv("XODB_TEST_RING_MMAP");

    int32_t tids[2] = {self, spawn_hold(stacks[0], sizeof stacks[0])};
    cfg.tids = tids;
    cfg.thread_count = 2;
    failure = (struct xrt_perf_failure){0};
    assert(!setenv("XODB_TEST_RING_MMAP", "eperm", 1));
    struct xrt_perf *capped = xrt_cpu_start(&cfg, &accepted, &failure);
    if (!capped) {
        fprintf(stderr, "capped open failed: %s errno=%d %s\n", failure.syscall ? failure.syscall : "?",
                failure.error, failure.detail ? failure.detail : "");
    }
    assert(capped);
    assert(xrt_cpu_ring_limit(capped) == XRT_RING_LIMIT_CAPPED);
    assert(xrt_perf_ring_pages(capped) == 1);
    assert(xrt_perf_fd_count(capped) == 1 && capped->count == 1 && capped->slots[0].owns_map);
    notice = xrt_cpu_ring_notice(capped);
    assert(notice && strstr(notice, "perf_event_mlock_kb") && strstr(notice, "RLIMIT_MEMLOCK"));
    failure = (struct xrt_perf_failure){0};
    assert(!xrt_cpu_enroll(capped, tids[1], &accepted, &failure));
    assert(failure.error == EPERM && failure.detail && strstr(failure.detail, "perf_event_mlock_kb") &&
           strstr(failure.detail, "RLIMIT_MEMLOCK"));
    assert(xrt_perf_fd_count(capped) == 1);
    xrt_perf_destroy(capped);
    unsetenv("XODB_TEST_RING_MMAP");

    /* Three pages cannot hold a four-page data ring plus its metadata page.
     * Two data pages need three, so the open shrinks before mmap. */
    assert(!setenv("XODB_TEST_PIN_PAGES", "3", 1));
    cfg.tids = &self;
    cfg.thread_count = 1;
    cfg.data_pages = 4;
    failure = (struct xrt_perf_failure){0};
    struct xrt_perf *sized = xrt_cpu_start(&cfg, &accepted, &failure);
    assert(sized);
    assert(xrt_cpu_ring_limit(sized) == XRT_RING_LIMIT_SHRUNK);
    assert(xrt_perf_ring_pages(sized) == 2);
    notice = xrt_cpu_ring_notice(sized);
    assert(notice && strstr(notice, "sized in bytes") && strstr(notice, "perf_event_mlock_kb") &&
           strstr(notice, "RLIMIT_MEMLOCK") && !strstr(notice, "EPERM"));
    xrt_perf_destroy(sized);

    /* Two pages hold one one-page ring and not two, so the second thread is unopened. */
    assert(!setenv("XODB_TEST_PIN_PAGES", "2", 1));
    cfg.tids = tids;
    cfg.thread_count = 2;
    cfg.data_pages = 4;
    failure = (struct xrt_perf_failure){0};
    struct xrt_perf *prefix = xrt_cpu_start(&cfg, &accepted, &failure);
    assert(prefix);
    assert(xrt_cpu_ring_limit(prefix) == XRT_RING_LIMIT_CAPPED);
    assert(xrt_perf_ring_pages(prefix) == 1 && prefix->count == 1);
    notice = xrt_cpu_ring_notice(prefix);
    assert(notice && strstr(notice, "sized in bytes") && strstr(notice, "perf_event_mlock_kb") &&
           strstr(notice, "RLIMIT_MEMLOCK"));
    xrt_perf_destroy(prefix);
    unsetenv("XODB_TEST_PIN_PAGES");
}
static void pinned_fit_shared(void)
{
    assert(!setenv("XODB_TEST_PIN_PAGES", "3", 1));
    assert(xrt_perf_pinned_allowance() == 3);
    assert(xrt_perf_fit_pages(4, 1) == 2);
    assert(xrt_perf_fit_pages(16, 1) == 2);
    assert(xrt_perf_fit_pages(4, 2) == 1);
    assert(!setenv("XODB_TEST_PIN_PAGES", "1000", 1));
    assert(xrt_perf_fit_pages(16, 2) == 16);
    assert(xrt_perf_fit_pages(4, 0) == 4);
    /* Eight of ten pages are already mapped. One four-page ring needs five,
     * so two remain and the fit is one data page. A full reservation still
     * asks for one data page. A zero allowance ignores the reservation. */
    unsigned long left = 99;
    assert(!setenv("XODB_TEST_PIN_PAGES", "10", 1));
    assert(xrt_perf_pinned_remaining(&left) && left == 10);
    xrt_perf_pin_reserve(8);
    assert(xrt_perf_pinned_remaining(&left) && left == 2);
    assert(xrt_perf_fit_pages(4, 1) == 1);
    assert(xrt_perf_fit_pages(16, 1) == 1);
    xrt_perf_pin_reserve(2);
    assert(xrt_perf_pinned_remaining(&left) && left == 0);
    assert(xrt_perf_fit_pages(4, 1) == 1);
    xrt_perf_pin_release(10);
    assert(xrt_perf_pinned_remaining(&left) && left == 10);
    assert(!setenv("XODB_TEST_PIN_PAGES", "0", 1));
    xrt_perf_pin_reserve(8);
    assert(!xrt_perf_pinned_remaining(&left));
    assert(xrt_perf_fit_pages(16, 2) == 16);
    xrt_perf_pin_release(8);
    /* A mapped ring holds its metadata page plus its data pages. The next
     * collector, including a 16-page syscall ring, sizes against the rest.
     * Two one-page rings need four pages and only three remain, so the CPU
     * open keeps one thread. Destroying the rings returns the allowance. */
    assert(!setenv("XODB_TEST_PIN_PAGES", "8", 1));
    int32_t self = (int32_t)gettid();
    struct xrt_cpu_acceptance accepted;
    struct xrt_perf_failure failure = {0};
    struct xrt_cpu_config cfg = {
        .tids = &self, .thread_count = 1, .frequency_hz = 99, .data_pages = 4,
        .ring_budget_bytes = 262144, .exclude_kernel = true,
    };
    struct xrt_perf *held = xrt_cpu_start(&cfg, &accepted, &failure);
    assert(held);
    assert(xrt_cpu_ring_limit(held) == XRT_RING_LIMIT_NONE);
    assert(xrt_perf_ring_pages(held) == 4);
    assert(xrt_perf_pinned_remaining(&left) && left == 3);
    assert(xrt_perf_fit_pages(16, 1) == 2);
    assert(xrt_perf_fit_pages(4, 1) == 2);
    static char stack[8192] __attribute__((aligned(16)));
    int32_t tids[2] = {self, spawn_hold(stack, sizeof stack)};
    cfg.tids = tids;
    cfg.thread_count = 2;
    cfg.data_pages = 1;
    failure = (struct xrt_perf_failure){0};
    struct xrt_perf *prefix = xrt_cpu_start(&cfg, &accepted, &failure);
    assert(prefix);
    assert(xrt_cpu_ring_limit(prefix) == XRT_RING_LIMIT_CAPPED);
    assert(xrt_perf_ring_pages(prefix) == 1 && prefix->count == 1);
    const char *notice = xrt_cpu_ring_notice(prefix);
    assert(notice && strstr(notice, "sized in bytes") && strstr(notice, "perf_event_mlock_kb") &&
           strstr(notice, "RLIMIT_MEMLOCK"));
    xrt_perf_destroy(prefix);
    xrt_perf_destroy(held);
    assert(xrt_perf_pinned_remaining(&left) && left == 8);
    assert(xrt_perf_fit_pages(4, 1) == 4);
    unsetenv("XODB_TEST_PIN_PAGES");
}
static void offcpu_format(void)
{
    const char *text =
        "name: sched_switch\n"
        "ID: 317\n"
        "format:\n"
        "\tfield:unsigned short common_type;\toffset:0;\tsize:2;\tsigned:0;\n"
        "\tfield:pid_t prev_pid;\toffset:24;\tsize:4;\tsigned:1;\n"
        "\tfield:long prev_state;\toffset:32;\tsize:8;\tsigned:1;\n"
        "\tfield:pid_t next_pid;\toffset:56;\tsize:4;\tsigned:1;\n";
    struct xrt_offcpu_layout layout = {0};
    assert(xrt_offcpu_format(text, strlen(text), 317, &layout));
    assert(layout.id == 317);
    assert(layout.prev_pid_off == 24 && layout.next_pid_off == 56);
    assert(layout.prev_state_off == 32 && layout.prev_state_size == 8);
    assert(!xrt_offcpu_format(text, strlen(text), 1, &layout));
}
static void offcpu_denial(void)
{
    int32_t tid = (int32_t)gettid();
    struct xrt_offcpu_layout layout = {0};
    struct xrt_perf_failure failure = {0};
    assert(!setenv("XODB_TEST_OFF_CPU", "deny", 1));
    assert(!xrt_offcpu_start(&tid, 1, 4, 65536, &layout, &failure));
    assert(failure.kind == XRT_PERF_PERMISSION && failure.error == EPERM);
    assert(failure.opened_then_closed == 0);
    assert(failure.detail && strstr(failure.detail, "perf_event_paranoid"));
    assert(failure.detail && strstr(failure.detail, "tracepoint"));
    unsetenv("XODB_TEST_OFF_CPU");
}
int main(void)
{
    offcpu_format();
    offcpu_denial();
    kernel_stack_denial();
    pinned_fit_shared();
    ring_limit_degrade();
    loss_counter_reads();
    asynchronous_failure();
    perf_limit_suffix();
    rings();
    metadata();
    rollback();
    live();
    puts("C perf: wrapped rings, hostile headers, tail validation, metadata bounds, rollback, "
         "limit suffix and live collection passed");
    return 0;
}
