#define _GNU_SOURCE 1
#include "check.h"
#include "perf_internal.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifndef FDFLOW_IMPLEMENTATION
#define FDFLOW_IMPLEMENTATION "../src/runtime/fdflow.c"
#endif
#include FDFLOW_IMPLEMENTATION
static void put32(unsigned char *p, uint32_t n) {
    for (unsigned i = 0; i < 4; ++i)
        p[i] = (unsigned char)(n >> (8 * i));
}
static void put64(unsigned char *p, uint64_t n) {
    for (unsigned i = 0; i < 8; ++i)
        p[i] = (unsigned char)(n >> (8 * i));
}
static void sample(unsigned char *p, uint64_t time, unsigned cpu) {
    memset(p, 0, 104);
    put32(p, 9);
    p[6] = 104;
    put32(p + 8, 100 + cpu);
    put32(p + 12, 100 + cpu);
    put64(p + 16, time);
    put64(p + 24, 11 + cpu);
    put32(p + 32, 68);
    p[36] = 45;
    p[37] = 1;
    put32(p + 40, 100 + cpu);
    put64(p + 44, 1);
    put64(p + 52, 7);
}
int main(int argc, char **argv) {
    int wrong = argc == 2 && !strcmp(argv[1], "--wrong-oracle");
    struct xrt_fdflow *c = calloc(1, sizeof *c);
    CHECK(c);
    c->limit = 1;
    c->perf = xrt_perf_create(1, 2, 2 * xrt_perf_page_size());
    CHECK(c->perf);
    c->sources = calloc(2, sizeof *c->sources);
    c->cpus = calloc(2, sizeof *c->cpus);
    CHECK(c->sources && c->cpus);
    c->view.cpus = c->cpus;
    c->view.cpu_count = 2;
    c->view.active_cpus = 2;
    c->view.online_cpus = 2;
    c->view.running = 1;
    c->perf->count = 2;
    unsigned char *maps[2];
    size_t page = xrt_perf_page_size();
    const uint64_t times[2][3] = {{10, 40, 70}, {20, 30, 80}};
    for (unsigned i = 0; i < 2; ++i) {
        maps[i] = calloc(2, page);
        CHECK(maps[i]);
        c->perf->slots[i].map = maps[i];
        c->perf->slots[i].map_size = 2 * page;
        put64(maps[i] + 1040, page);
        put64(maps[i] + 1048, page);
        put64(maps[i] + 1024, 3 * 104);
        c->cpus[i].cpu = (int32_t)i;
        c->sources[i].source_cpu = i;
        c->sources[i].events[0] = (struct xrt_fdflow_source){.id = 11 + i, .type = 301, .argc = 6};
        for (unsigned j = 0; j < 3; ++j)
            sample(maps[i] + page + 104 * j, times[i][j], i);
    }
    uint64_t observed[6], late = 0;
    for (unsigned i = 0; i < 6; ++i) {
        struct xrt_fdflow_snapshot view;
        CHECK(xrt_fdflow_drain(c, &view) == XRT_OK && view.record_count == 1);
        observed[i] = view.records[0].time_ns;
        late = view.late;
    }
    c->limit = 16;
    struct xrt_fdflow_snapshot view;
    /* An event beyond this drain's cutoff stays in its ring. */
    sample(maps[0] + page + 312, 90, 0);
    sample(maps[1] + page + 312, flow_now(CLOCK_MONOTONIC) + UINT64_C(60000000000), 1);
    put64(maps[0] + 1024, 416);
    put64(maps[1] + 1024, 416);
    CHECK(xrt_fdflow_drain(c, &view) == XRT_OK);
    CHECK(view.record_count == 1 && view.records[0].time_ns == 90 && view.pending);
    CHECK(c->perf->slots[0].tail == 416 && c->perf->slots[1].tail == 312);
    sample(maps[1] + page + 312, 100, 1);
    CHECK(xrt_fdflow_drain(c, &view) == XRT_OK);
    CHECK(view.record_count == 1 && view.records[0].time_ns == 100 && !view.pending);
    CHECK(c->perf->slots[1].tail == 416);
    /* A genuinely delayed kernel commit remains explicitly late. */
    sample(maps[0] + page + 416, 95, 0);
    put64(maps[0] + 1024, 520);
    CHECK(xrt_fdflow_drain(c, &view) == XRT_OK && view.record_count == 1);
    CHECK(view.late == 1 && (view.flags & XRT_FDFLOW_LATE));
    /* Commit only the valid prefix; malformed bytes stop the capture. */
    sample(maps[0] + page + 520, 120, 0);
    sample(maps[0] + page + 624, 130, 0);
    maps[0][page + 624 + 6] = 7;
    put64(maps[0] + 1024, 728);
    CHECK(xrt_fdflow_drain(c, &view) == XRT_INVALID_STATE);
    CHECK(!view.running && !c->perf && view.record_count == 1);
    CHECK(view.records[0].time_ns == 120 && (view.flags & XRT_FDFLOW_BAD_RECORD));
    uint64_t committed;
    memcpy(&committed, maps[0] + 1032, 8);
    CHECK(committed == 624);
    xrt_fdflow_close(c);
    free(maps[0]);
    free(maps[1]);
    const uint64_t expected[6] = {10, 20, 30, 40, 70, 80};
    for (unsigned i = 0; i < 6; ++i) {
        fprintf(stderr, "order[%u]=%llu expected=%llu\n", i, (unsigned long long)observed[i],
                (unsigned long long)expected[i]);
        CHECK(observed[i] == expected[i]);
    }
    CHECK(!late && observed[2] == (wrong ? 31u : 30u));
    puts("CPU merge: capped order, cutoff, late commits and malformed prefix PASS");
    return 0;
}
