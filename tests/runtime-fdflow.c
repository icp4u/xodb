#define _GNU_SOURCE 1
#include "check.h"
#include "xrt_fdflow.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void put16(unsigned char *p, uint16_t n) {
  p[0] = (unsigned char)n;
  p[1] = (unsigned char)(n >> 8);
}
static void put32(unsigned char *p, uint32_t n) {
  put16(p, (uint16_t)n);
  put16(p + 2, (uint16_t)(n >> 16));
}
static void put64(unsigned char *p, uint64_t n) {
  put32(p, (uint32_t)n);
  put32(p + 4, (uint32_t)(n >> 32));
}
static struct xrt_fdflow_source sources[] = {
    {.id = 201,
     .type = 301,
     .number = 0,
     .argc = 3,
     .operation = XRT_FDFLOW_READ},
    {.id = 202,
     .type = 302,
     .number = 0,
     .exit = 1,
     .operation = XRT_FDFLOW_READ},
    {.id = 203, .type = 303, .argc = 6, .operation = XRT_FDFLOW_RAW},
    {.id = 204, .type = 304, .exit = 1, .operation = XRT_FDFLOW_RAW}};
static size_t sample(unsigned char *p, uint32_t source) {
  const struct xrt_fdflow_source *s = &sources[source];
  uint32_t raw = s->exit ? 24 : 16 + 8 * s->argc;
  size_t size = (36 + raw + 7) & ~(size_t)7;
  memset(p, 0, 128);
  put32(p, 9);
  put16(p + 6, (uint16_t)size);
  put32(p + 8, 100);
  put32(p + 12, 101);
  put64(p + 16, 1234);
  put64(p + 24, s->id);
  put32(p + 32, raw + 4);
  put16(p + 36, s->type);
  put32(p + 40, 101);
  put64(p + 44, s->number);
  if (s->exit)
    put64(p + 52, 17);
  else
    for (unsigned i = 0; i < s->argc; ++i)
      put64(p + 52 + 8 * i, 10 + i);
  return size;
}
static void records(void) {
  unsigned char storage[129], *p = storage + 1;
  struct xrt_fdflow_record r;
  for (uint32_t s = 0; s < 4; ++s) {
    size_t n = sample(p, s);
    CHECK(xrt_fdflow_decode(p, n, sources, 4, &r));
    CHECK(r.pid == 100 && r.tid == 101 && r.time_ns == 1234 &&
          r.operation == sources[s].operation);
    CHECK(r.kind == (sources[s].exit ? XRT_FDFLOW_EXIT : XRT_FDFLOW_ENTER));
    if (sources[s].exit)
      CHECK(r.result == 17);
    else
      CHECK(r.args[0] == 10);
    for (size_t short_size = 0; short_size < n; ++short_size)
      CHECK(!xrt_fdflow_decode(p, short_size, sources, 4, &r));
    put32(p + 40, 102);
    CHECK(!xrt_fdflow_decode(p, n, sources, 4, &r));
    sample(p, s);
    put64(p + 24, 999);
    CHECK(!xrt_fdflow_decode(p, n, sources, 4, &r));
    sample(p, s);
    put32(p + 32, 127);
    CHECK(!xrt_fdflow_decode(p, n, sources, 4, &r));
  }
  size_t n = sample(p, 0);
  put32(p + 44, 20);
  CHECK(!xrt_fdflow_decode(p, n, sources, 4, &r));
  n = sample(p, 3);
  put64(p + 52, (uint64_t)-9);
  CHECK(xrt_fdflow_decode(p, n, sources, 4, &r) && r.result == -9);
  n = sample(p, 0);
  sources[1].id = sources[0].id;
  CHECK(!xrt_fdflow_decode(p, n, sources, 4, &r));
  sources[1].id = 202;
  memset(p, 0, 128);
  put32(p, 2);
  put16(p + 6, 48);
  put64(p + 8, 201);
  put64(p + 16, 91);
  put32(p + 24, 999);
  put32(p + 28, 999);
  put64(p + 32, 5000);
  put64(p + 40, 201);
  CHECK(xrt_fdflow_decode(p, 48, sources, 4, &r) && r.kind == XRT_FDFLOW_LOST &&
        r.lost == 91);
  CHECK(!r.pid && !r.tid);
  put64(p + 40, 202);
  CHECK(!xrt_fdflow_decode(p, 48, sources, 4, &r));
  memset(p, 0, 128);
  put32(p, 5);
  put16(p + 6, 56);
  put64(p + 16, 201);
  put64(p + 24, 201);
  put64(p + 48, 201);
  CHECK(xrt_fdflow_decode(p, 56, sources, 4, &r) &&
        r.kind == XRT_FDFLOW_THROTTLED && !r.pid && !r.tid);
  put64(p + 48, 202);
  CHECK(!xrt_fdflow_decode(p, 56, sources, 4, &r));
  /* Bounded alignment/truncation/mutation fuzz; no target processes. */
  uint32_t seed = 1;
  for (unsigned i = 0; i < 20000; ++i) {
    n = sample(p, i % 4);
    seed = seed * 1664525u + 1013904223u;
    p[seed % 128] ^= (unsigned char)(seed >> 16);
    (void)xrt_fdflow_decode(p, i % 2 ? n : seed % 129, sources, 4, &r);
  }
}
static const char format[] =
    "name: sys_enter_read\nID: 301\nformat:\n"
    "field:unsigned short common_type;offset:0;size:2;signed:0;\n"
    "field:unsigned char common_flags;offset:2;size:1;signed:0;\n"
    "field:unsigned char common_preempt_count;offset:3;size:1;signed:0;\n"
    "field:int common_pid;offset:4;size:4;signed:1;\n"
    "field:int __syscall_nr;offset:8;size:4;signed:1;\n"
    "field:unsigned int fd;offset:16;size:8;signed:0;\n"
    "field:char * buf;offset:24;size:8;signed:0;\n"
    "field:size_t count;offset:32;size:8;signed:0;\n";
static void formats(void) {
  CHECK(
      xrt_fdflow_format(format, strlen(format), "sys_enter_read", &sources[0]));
  CHECK(!xrt_fdflow_format(format, strlen(format), "sys_enter_write",
                           &sources[0]));
  char bad[2048];
  strcpy(bad, format);
  strstr(bad, "offset:16")[7] = '7';
  CHECK(!xrt_fdflow_format(bad, strlen(bad), "sys_enter_read", &sources[0]));
  strcpy(bad, format);
  strcat(bad, "field:int __syscall_nr;offset:8;size:4;signed:1;\n");
  CHECK(!xrt_fdflow_format(bad, strlen(bad), "sys_enter_read", &sources[0]));
  strcpy(bad, format);
  strcat(bad, "field:__data_loc char[] __buf_val;offset:40;size:4;signed:1;\n");
  CHECK(!xrt_fdflow_format(bad, strlen(bad), "sys_enter_read", &sources[0]));
  strcpy(bad, format);
  bad[12] = 0;
  CHECK(!xrt_fdflow_format(bad, strlen(format), "sys_enter_read", &sources[0]));
  CHECK(!xrt_fdflow_format(format, strlen(format) - 1 - 55, "sys_enter_read",
                           &sources[0]));
}
static void cpus(int wrong) {
  int32_t ids[4];
  uint32_t count, total;
  CHECK(xrt_fdflow_cpu_list("0-2,8,10-11\n", 12, ids, 4, &count, &total));
  CHECK(count == 4 && total == (wrong ? 7u : 6u) && ids[0] == 0 && ids[3] == 8);
  const char *huge = "0-2147483647";
  CHECK(xrt_fdflow_cpu_list(huge, strlen(huge), ids, 4, &count, &total) &&
        count == 4 && total == 2147483648u);
  const char *bad[] = {"",     "1-0",        "0,0", "0-3,2", "1,",  "2x",
                       "1\n2", "2147483648", "1-",  "-1",    "0,,2"};
  for (unsigned i = 0; i < sizeof bad / sizeof *bad; ++i)
    CHECK(!xrt_fdflow_cpu_list(bad[i], strlen(bad[i]), ids, 4, &count, &total));
}
static void scope(void) {
  struct xrt_fdflow *flow = NULL;
  struct xrt_perf_failure why = {0};
  struct xrt_fdflow_options o = {.scoped = 1};
  CHECK(xrt_fdflow_open(&o, &flow, &why) == XRT_INVALID_ARGUMENT && !flow);
  int32_t tids[] = {123, 123};
  o.tids = tids;
  o.tid_count = 2;
  CHECK(xrt_fdflow_open(&o, &flow, &why) == XRT_INVALID_ARGUMENT && !flow);
  o.scoped = 0;
  o.tid_count = 1;
  CHECK(xrt_fdflow_open(&o, &flow, &why) == XRT_INVALID_ARGUMENT && !flow);
  o.scoped = 1;
  tids[0] = -1;
  CHECK(xrt_fdflow_open(&o, &flow, &why) == XRT_INVALID_ARGUMENT && !flow);
  struct xrt_perf *p = xrt_perf_create(1, 1, 4096);
  CHECK(p);
  struct xrt_perf_attr attr = {.size = 96, .flags = 1};
  CHECK(!xrt_perf_add_cpu(p, -1, &attr, 1, NULL, &why));
  CHECK(!xrt_perf_add_cpu(p, 0, &attr, 1, "", &why));
  CHECK(xrt_perf_fd_count(p) == 0);
  xrt_perf_destroy(p);
}
int main(int argc, char **argv) {
  records();
  formats();
  cpus(argc == 2 && !strcmp(argv[1], "--wrong-oracle"));
  scope();
  puts("system IO flow: bounded formats, CPU ranges, records, scope refusal "
       "PASS");
  return 0;
}
