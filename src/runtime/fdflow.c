#define _GNU_SOURCE 1
#include "xrt_fdflow.h"
#include "perf_internal.h"
#include <errno.h>
#include <limits.h>
#include <linux/perf_event.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

struct io_call {
  const char *name;
  uint16_t number;
  uint8_t operation;
};
static const struct io_call calls[] = {
    {"read", 0, XRT_FDFLOW_READ},      {"write", 1, XRT_FDFLOW_WRITE},
    {"pread64", 17, XRT_FDFLOW_READ},  {"pwrite64", 18, XRT_FDFLOW_WRITE},
    {"readv", 19, XRT_FDFLOW_READ},    {"writev", 20, XRT_FDFLOW_WRITE},
    {"preadv", 295, XRT_FDFLOW_READ},  {"pwritev", 296, XRT_FDFLOW_WRITE},
    {"preadv2", 327, XRT_FDFLOW_READ}, {"pwritev2", 328, XRT_FDFLOW_WRITE},
    {"sendto", 44, XRT_FDFLOW_WRITE},  {"recvfrom", 45, XRT_FDFLOW_READ},
    {"sendmsg", 46, XRT_FDFLOW_WRITE}, {"recvmsg", 47, XRT_FDFLOW_READ}};
_Static_assert(2 + sizeof calls / sizeof *calls == XRT_FDFLOW_EVENTS,
               "event table bound");
struct cpu_sources {
  struct xrt_fdflow_source events[XRT_FDFLOW_EVENTS];
  uint32_t source_cpu;
};
struct merge_cpu {
  struct xrt_perf_ring ring;
  struct xrt_fdflow_record next;
  uint64_t used;
  uint16_t size;
};
struct xrt_fdflow {
  struct xrt_perf *perf;
  struct cpu_sources *sources;
  struct xrt_fdflow_cpu *cpus;
  struct xrt_fdflow_record *records;
  struct merge_cpu *merge;
  uint32_t *heap;
  uint32_t capacity, limit;
  uint64_t last_time;
  int oom;
  struct xrt_fdflow_snapshot view;
};
static uint64_t flow_now(clockid_t clock) {
  struct timespec t;
  return clock_gettime(clock, &t)
             ? 0
             : (uint64_t)t.tv_sec * 1000000000u + (uint64_t)t.tv_nsec;
}
static uint64_t plus(uint64_t a, uint64_t b) {
  return UINT64_MAX - a < b ? UINT64_MAX : a + b;
}
static enum xrt_status fail(struct xrt_perf_failure *f, int error,
                            const char *reason) {
  xrt_perf_fail(f, "fd.flow", error, -1, reason);
  return error == EACCES || error == EPERM ? XRT_PERMISSION_DENIED
         : error == ENOMEM                 ? XRT_OUT_OF_MEMORY
                                           : XRT_FILE_UNAVAILABLE;
}
static int metadata(const char *group, const char *name,
                    struct xrt_fdflow_source *s, struct xrt_perf_failure *f) {
  char path[160], text[16384];
  size_t size;
  uint64_t type;
  snprintf(path, sizeof path, "/sys/kernel/tracing/events/%s/%s/id", group,
           name);
  if (!xrt_perf_read_file(path, text, sizeof text, &size)) {
    fail(f, errno, "tracepoint ID unavailable");
    return 0;
  }
  if (!xrt_perf_unsigned(text, size, &type) || !type || type > UINT16_MAX) {
    fail(f, EPROTO, "invalid tracepoint ID");
    return 0;
  }
  s->type = (uint16_t)type;
  snprintf(path, sizeof path, "/sys/kernel/tracing/events/%s/%s/format", group,
           name);
  if (!xrt_perf_read_file(path, text, sizeof text, &size)) {
    fail(f, errno, "tracepoint format unavailable");
    return 0;
  }
  if (!xrt_fdflow_format(text, size, name, s)) {
    fail(f, EPROTO, "unsupported IO tracepoint layout");
    return 0;
  }
  return 1;
}
static int filter_text(const struct xrt_fdflow_options *o, char out[8193]) {
  out[0] = 0;
  if (!o->scoped)
    return !o->tids && !o->tid_count;
  if (!o->tids || !o->tid_count || o->tid_count > 128)
    return 0;
  size_t used = 0;
  for (uint32_t i = 0; i < o->tid_count; ++i) {
    if (o->tids[i] <= 0)
      return 0;
    for (uint32_t j = 0; j < i; ++j)
      if (o->tids[i] == o->tids[j])
        return 0;
    int n = snprintf(out + used, 8193 - used, "%scommon_pid == %d",
                     i ? " || " : "", o->tids[i]);
    if (n < 0 || (size_t)n >= 8193 - used)
      return 0;
    used += (size_t)n;
  }
  return 1;
}
void xrt_fdflow_stop(struct xrt_fdflow *c) {
  if (!c)
    return;
  if (c->perf) {
    struct xrt_perf_failure f = {0};
    (void)xrt_perf_stop(c->perf, &f);
    /* Closing owns the stop guarantee even if a disable ioctl failed. */
    xrt_perf_destroy(c->perf);
    c->perf = NULL;
  }
  c->view.running = 0;
  c->view.pending = 0;
}
void xrt_fdflow_close(struct xrt_fdflow *c) {
  if (!c)
    return;
  xrt_perf_destroy(c->perf);
  free(c->sources);
  free(c->cpus);
  free(c->records);
  free(c->merge);
  free(c->heap);
  free(c);
}
enum xrt_status xrt_fdflow_open(const struct xrt_fdflow_options *o,
                                struct xrt_fdflow **out,
                                struct xrt_perf_failure *f) {
  struct xrt_perf_failure local_failure = {0};
  if (!f)
    f = &local_failure;
  if (out)
    *out = NULL;
  char filter[8193];
  if (!o || !out || !filter_text(o, filter) || o->record_limit > 262144 ||
      o->data_pages > 64 ||
      (o->data_pages && (o->data_pages & (o->data_pages - 1)))) {
    xrt_perf_fail(f, "fd.flow", EINVAL, -1, "invalid scope or capture limits");
    return XRT_INVALID_ARGUMENT;
  }
#if !defined(__x86_64__)
  fail(f, 0, "native Linux x86-64 IO tracepoints only");
  return XRT_UNSUPPORTED_ARCHITECTURE;
#endif
  struct xrt_fdflow_source spec[XRT_FDFLOW_EVENTS] = {0};
  spec[0].argc = 6;
  spec[1].exit = 1;
  if (!metadata("raw_syscalls", "sys_enter", &spec[0], f) ||
      !metadata("raw_syscalls", "sys_exit", &spec[1], f))
    return f->kind == XRT_PERF_PERMISSION ? XRT_PERMISSION_DENIED
                                          : XRT_FILE_UNAVAILABLE;
  /* Named entry events can copy user buffers on newer kernels. Raw entry
   * supplies only register arguments; a named exit corroborates native ABI
   * and operation, without subscribing to those payload-bearing events. */
  for (uint32_t i = 0; i < sizeof calls / sizeof *calls; ++i) {
    uint32_t slot = 2 + i;
    char name[80];
    spec[slot] = (struct xrt_fdflow_source){
        .number = calls[i].number, .operation = calls[i].operation, .exit = 1};
    snprintf(name, sizeof name, "sys_exit_%s", calls[i].name);
    if (!metadata("syscalls", name, &spec[slot], f))
      return f->kind == XRT_PERF_PERMISSION ? XRT_PERMISSION_DENIED
                                            : XRT_FILE_UNAVAILABLE;
  }
  for (uint32_t i = 0; i < XRT_FDFLOW_EVENTS; ++i)
    for (uint32_t j = 0; j < i; ++j)
      if (spec[i].type == spec[j].type)
        return fail(f, EPROTO, "duplicate tracepoint IDs");
  int32_t online[XRT_PERF_MAX_THREADS];
  uint32_t count, total;
  char text[16384];
  size_t size;
  if (!xrt_perf_read_file("/sys/devices/system/cpu/online", text, sizeof text,
                          &size))
    return fail(f, errno, "online CPU list unavailable");
  if (!xrt_fdflow_cpu_list(text, size, online, XRT_PERF_MAX_THREADS, &count,
                           &total))
    return fail(f, EPROTO, "invalid online CPU list");
  struct xrt_fdflow *c = calloc(1, sizeof *c);
  if (!c)
    return fail(f, ENOMEM, "flow owner allocation");
  c->limit = o->record_limit ? o->record_limit : 32768;
  c->sources = calloc(count, sizeof *c->sources);
  c->cpus = calloc(count, sizeof *c->cpus);
  c->perf =
      xrt_perf_create(o->data_pages ? o->data_pages : 64, count,
                      o->ring_budget ? o->ring_budget : 64u * 1024 * 1024);
  if (!c->sources || !c->cpus || !c->perf) {
    xrt_fdflow_close(c);
    return fail(f, ENOMEM, "flow CPU allocation");
  }
  c->view.cpus = c->cpus;
  c->view.cpu_count = count;
  c->view.online_cpus = total;
  c->view.scoped = !!o->scoped;
  struct xrt_perf_attr attrs[XRT_FDFLOW_EVENTS] = {0};
  for (uint32_t i = 0; i < XRT_FDFLOW_EVENTS; ++i) {
    attrs[i].size = 96;
    attrs[i].type = PERF_TYPE_TRACEPOINT;
    attrs[i].config = spec[i].type;
    attrs[i].sample_period = 1;
    attrs[i].read_format = PERF_FORMAT_LOST;
    attrs[i].sample_type =
        PERF_SAMPLE_TID | PERF_SAMPLE_TIME | PERF_SAMPLE_ID | PERF_SAMPLE_RAW;
    attrs[i].flags = 1 | (UINT64_C(1) << 18) | (UINT64_C(1) << 25);
    attrs[i].clockid = CLOCK_MONOTONIC;
  }
  struct xrt_perf_failure failure = {0};
  for (uint32_t i = 0; i < count; ++i) {
    c->cpus[i].cpu = online[i];
    int ok = xrt_perf_add_cpu(c->perf, online[i], attrs, XRT_FDFLOW_EVENTS,
                              o->scoped ? filter : NULL, &failure);
    if (!ok && failure.error == EINVAL && failure.syscall &&
        !strcmp(failure.syscall, "perf_event_open") && attrs[0].read_format) {
      for (uint32_t e = 0; e < XRT_FDFLOW_EVENTS; ++e)
        attrs[e].read_format = 0;
      ok = xrt_perf_add_cpu(c->perf, online[i], attrs, XRT_FDFLOW_EVENTS,
                            o->scoped ? filter : NULL, &failure);
      c->view.flags |= XRT_FDFLOW_LOSS_UNKNOWN;
    }
    if (!ok) {
      c->cpus[i].error = failure.error;
      continue;
    }
    uint32_t slot = c->view.active_cpus++;
    c->cpus[i].active = 1;
    c->sources[slot].source_cpu = i;
    struct xrt_perf_thread thread;
    if (!xrt_perf_thread(c->perf, slot, &thread) ||
        thread.event_count != XRT_FDFLOW_EVENTS) {
      xrt_fdflow_close(c);
      return fail(f, EPROTO, "CPU event identity unavailable");
    }
    for (uint32_t e = 0; e < XRT_FDFLOW_EVENTS; ++e) {
      c->sources[slot].events[e] = spec[e];
      c->sources[slot].events[e].id = thread.event_ids[e];
    }
  }
  if (!c->view.active_cpus) {
    if (f)
      *f = failure;
    xrt_fdflow_close(c);
    return failure.kind == XRT_PERF_PERMISSION ? XRT_PERMISSION_DENIED
                                               : XRT_FILE_UNAVAILABLE;
  }
  if (c->view.active_cpus != total)
    c->view.flags |= XRT_FDFLOW_CPU_PARTIAL;
  c->view.started_ns = flow_now(CLOCK_MONOTONIC);
  if (!xrt_perf_enable(c->perf, f)) {
    xrt_fdflow_close(c);
    return XRT_FILE_UNAVAILABLE;
  }
  struct xrt_perf_info info;
  xrt_perf_info(c->perf, &info);
  c->view.ring_bytes = info.allocated_ring_bytes;
  c->view.running = 1;
  c->view.reason = "native x86-64 supported IO; CPUs online at capture start; "
                   "compat IO unavailable";
  *out = c;
  return XRT_OK;
}
static int reserve(struct xrt_fdflow *c) {
  if (c->view.record_count < c->capacity)
    return 1;
  uint32_t next = c->capacity ? c->capacity * 2 : 1024;
  if (next > c->limit)
    next = c->limit;
  struct xrt_fdflow_record *r = realloc(c->records, (size_t)next * sizeof *r);
  if (!r) {
    c->oom = 1;
    return 0;
  }
  c->records = r;
  c->capacity = next;
  return 1;
}
/* Peek all CPUs before advancing any tail. The cutoff excludes records added
 * while the heads are being sampled. Kernel commits delayed past that cutoff
 * can still arrive late; those are exposed by the watermark check below. */
static int next_record(struct xrt_fdflow *c, uint32_t index, uint64_t cutoff) {
  struct merge_cpu *m = &c->merge[index];
  const struct xrt_perf_ring *ring = &m->ring;
  if (m->used == ring->head - ring->tail)
    return 0;
  unsigned char bytes[128];
  if (ring->head - ring->tail - m->used < 8 ||
      !xrt_perf_copy(ring->data, ring->size, ring->tail + m->used, bytes, 8))
    return -1;
  uint16_t size = (uint16_t)(bytes[6] | ((uint16_t)bytes[7] << 8));
  if (size < 8 || size > sizeof bytes ||
      size > ring->head - ring->tail - m->used ||
      !xrt_perf_copy(ring->data, ring->size, ring->tail + m->used, bytes, size))
    return -1;
  const struct cpu_sources *cpu = &c->sources[index];
  if (!xrt_fdflow_decode(bytes, size, cpu->events, XRT_FDFLOW_EVENTS, &m->next))
    return -1;
  m->size = size;
  m->next.cpu = (uint32_t)c->cpus[cpu->source_cpu].cpu;
  if (m->next.time_ns > cutoff) {
    c->view.pending = 1;
    return 0;
  }
  return 1;
}
static int earlier(const struct xrt_fdflow *c, uint32_t a, uint32_t b) {
  uint64_t x = c->merge[a].next.time_ns, y = c->merge[b].next.time_ns;
  return x < y || (x == y && a < b);
}
static void push_cpu(struct xrt_fdflow *c, uint32_t index, uint32_t count) {
  while (count) {
    uint32_t parent = (count - 1) / 2;
    if (!earlier(c, index, c->heap[parent]))
      break;
    c->heap[count] = c->heap[parent];
    count = parent;
  }
  c->heap[count] = index;
}
static void repair_heap(struct xrt_fdflow *c, uint32_t count) {
  uint32_t index = c->heap[0], at = 0;
  while (2 * at + 1 < count) {
    uint32_t child = 2 * at + 1;
    if (child + 1 < count && earlier(c, c->heap[child + 1], c->heap[child]))
      ++child;
    if (!earlier(c, c->heap[child], index))
      break;
    c->heap[at] = c->heap[child];
    at = child;
  }
  c->heap[at] = index;
}
static enum xrt_perf_drain_status merge_rings(struct xrt_fdflow *c) {
  uint32_t count = c->view.active_cpus, ready = 0;
  c->view.pending = 0;
  if (!c->merge)
    c->merge = calloc(count, sizeof *c->merge);
  if (!c->heap)
    c->heap = calloc(count, sizeof *c->heap);
  if (!c->merge || !c->heap) {
    c->oom = 1;
    return XRT_PERF_DRAIN_CAPACITY;
  }
  uint64_t cutoff = flow_now(CLOCK_MONOTONIC);
  for (uint32_t i = 0; i < count; ++i) {
    c->merge[i].used = 0;
    enum xrt_perf_drain_status status =
        xrt_perf_peek(c->perf, i, &c->merge[i].ring);
    if (status != XRT_PERF_DRAIN_OK)
      return status;
  }
  for (uint32_t i = 0; i < count; ++i) {
    int next = next_record(c, i, cutoff);
    if (next < 0)
      return XRT_PERF_DRAIN_MALFORMED;
    if (next)
      push_cpu(c, i, ready++);
  }
  enum xrt_perf_drain_status status = XRT_PERF_DRAIN_OK;
  while (ready) {
    if (c->view.record_count == c->limit || !reserve(c)) {
      status = XRT_PERF_DRAIN_CAPACITY;
      break;
    }
    uint32_t index = c->heap[0];
    struct merge_cpu *m = &c->merge[index];
    c->records[c->view.record_count++] = m->next;
    if (m->next.kind == XRT_FDFLOW_LOST)
      c->view.lost_records = plus(c->view.lost_records, m->next.lost);
    if (m->next.kind == XRT_FDFLOW_THROTTLED)
      c->view.flags |= XRT_FDFLOW_THROTTLE;
    c->view.records_seen = plus(c->view.records_seen, 1);
    m->used += m->size;
    int next = next_record(c, index, cutoff);
    if (next < 0) {
      status = XRT_PERF_DRAIN_MALFORMED;
      break;
    }
    if (!next)
      c->heap[0] = c->heap[--ready];
    if (ready)
      repair_heap(c, ready);
  }
  for (uint32_t i = 0; i < count; ++i) {
    struct merge_cpu *m = &c->merge[i];
    if (m->used && xrt_perf_commit(c->perf, &m->ring,
                                  (struct xrt_perf_consumed){m->used, status}) !=
                       XRT_PERF_DRAIN_OK)
      status = XRT_PERF_DRAIN_MALFORMED;
  }
  if (status == XRT_PERF_DRAIN_CAPACITY)
    c->view.pending = 1;
  return status;
}
enum xrt_status xrt_fdflow_drain(struct xrt_fdflow *c,
                                 struct xrt_fdflow_snapshot *out) {
  if (!c || !out)
    return XRT_INVALID_ARGUMENT;
  if (!c->perf) {
    c->view.record_count = 0;
    *out = c->view;
    return XRT_OK;
  }
  uint64_t before = flow_now(CLOCK_THREAD_CPUTIME_ID);
  c->view.record_count = 0;
  c->oom = 0;
  enum xrt_perf_drain_status status = merge_rings(c);
  if (status == XRT_PERF_DRAIN_CAPACITY)
    c->view.flags |= XRT_FDFLOW_CAPACITY;
  enum xrt_status result = c->oom ? XRT_OUT_OF_MEMORY : XRT_OK;
  if (status != XRT_PERF_DRAIN_OK && status != XRT_PERF_DRAIN_CAPACITY) {
    ++c->view.invalid;
    c->view.flags |= XRT_FDFLOW_BAD_RECORD;
    c->view.reason = "malformed or incomplete CPU ring; capture stopped";
    result = XRT_INVALID_STATE;
  }
  uint64_t lost = 0;
  for (uint32_t i = 0; i < c->view.active_cpus; ++i) {
    uint64_t count;
    if (xrt_perf_read_lost(c->perf, i, &count))
      lost = plus(lost, count);
    else
      c->view.flags |= XRT_FDFLOW_LOSS_UNKNOWN;
  }
  if (lost < c->view.lost_records)
    lost = c->view.lost_records;
  if (lost > c->view.lost)
    c->view.lost = lost;
  if (c->view.lost)
    c->view.flags |= XRT_FDFLOW_LOSS;
  for (uint32_t i = 0; i < c->view.record_count; ++i) {
    uint64_t t = c->records[i].time_ns;
    if (t < c->last_time) {
      ++c->view.late;
      c->view.flags |= XRT_FDFLOW_LATE;
    } else
      c->last_time = t;
  }
  c->view.records = c->records;
  c->view.taken_ns = flow_now(CLOCK_MONOTONIC);
  c->view.drain_cpu_ns =
      plus(c->view.drain_cpu_ns, flow_now(CLOCK_THREAD_CPUTIME_ID) - before);
  if (result == XRT_INVALID_STATE)
    xrt_fdflow_stop(c);
  *out = c->view;
  return result;
}
