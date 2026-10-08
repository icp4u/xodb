#define _GNU_SOURCE 1
#include "perf_internal.h"
#include "xrt_allocations.h"
#include "perf_wire.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/perf_event.h>
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
static struct xrt_perf_consumed consume(void *raw, const struct xrt_perf_ring *r)
{
    struct decoding *d = raw;
    ++d->calls;
    if (d->overconsume)
        return (struct xrt_perf_consumed){.bytes = r->head - r->tail + 8};
    uint64_t used = 0;
    while (used < r->head - r->tail) {
        struct perf_event_header h;
        assert(r->head - r->tail - used >= sizeof(h));
        assert(xrt_perf_copy(r->data, r->size, r->tail + used, &h, sizeof(h)));
        assert(h.size >= sizeof(h) && !(h.size & 7) && h.size <= r->head - r->tail - used);
        used += h.size;
        ++d->records;
    }
    return (struct xrt_perf_consumed){.bytes = used};
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

int main(void)
{
    loss_counter_reads();
    asynchronous_failure();
    rings();
    metadata();
    rollback();
    live();
    puts("C perf: wrapped rings, hostile headers, tail validation, metadata bounds, rollback and "
         "live collection passed");
    return 0;
}
