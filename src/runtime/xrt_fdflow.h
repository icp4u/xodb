#ifndef XODB_RUNTIME_FDFLOW_H
#define XODB_RUNTIME_FDFLOW_H
/* System-wide native Linux x86-64 IO tracepoint records. One owner drains;
 * returned arrays are borrowed until the next drain/close. No target buffers
 * are read. A syscall byte count and a polled inode association are different
 * evidence: polling cannot prove the kernel file selected by concurrent fdget.
 */
#include "xrt.h"
#include "xrt_perf.h"

#define XRT_FDFLOW_EVENTS 16u
#define XRT_FDFLOW_LOSS 1u
#define XRT_FDFLOW_LOSS_UNKNOWN 2u
#define XRT_FDFLOW_THROTTLE 4u
#define XRT_FDFLOW_BAD_RECORD 8u
#define XRT_FDFLOW_CPU_PARTIAL 16u
#define XRT_FDFLOW_CAPACITY 32u
#define XRT_FDFLOW_LATE 64u
#define XRT_FDFLOW_RAW 0u
#define XRT_FDFLOW_READ 1u
#define XRT_FDFLOW_WRITE 2u

struct xrt_fdflow_source {
  uint64_t id;
  uint16_t type, number;
  uint8_t operation, argc, exit;
};
enum xrt_fdflow_kind {
  XRT_FDFLOW_ENTER,
  XRT_FDFLOW_EXIT,
  XRT_FDFLOW_LOST,
  XRT_FDFLOW_THROTTLED
};
struct xrt_fdflow_record {
  uint64_t time_ns, args[6], lost;
  int64_t number, result;
  int32_t pid, tid;
  uint32_t kind, operation, cpu;
};
struct xrt_fdflow_cpu {
  int32_t cpu, error;
  int active;
};
struct xrt_fdflow_snapshot {
  const struct xrt_fdflow_record *records;
  const struct xrt_fdflow_cpu *cpus;
  /* CPU coverage is fixed at open; active_cpus is retained after stop. */
  uint32_t record_count, cpu_count, online_cpus, active_cpus, flags;
  uint64_t records_seen, lost, lost_records, invalid, late, ring_bytes;
  uint64_t started_ns, taken_ns, drain_cpu_ns;
  int running, pending, scoped;
  const char *reason;
};
struct xrt_fdflow_options {
  /* Scoped tests must set scoped even if their TID list becomes empty.
   * Empty/invalid explicit scope refuses; it never falls back to all tasks. */
  const int32_t *tids;
  uint32_t tid_count; /* scoped: 1..128 distinct positive TIDs */
  int scoped;
  uint32_t record_limit; /* default32768, maximum262144 per drain */
  uint32_t data_pages;   /* default64, power of two, 1..64 per CPU */
  uint64_t ring_budget;  /* default64MiB; allocation grows with active CPUs */
};
struct xrt_fdflow;
enum xrt_status xrt_fdflow_open(const struct xrt_fdflow_options *,
                                struct xrt_fdflow **,
                                struct xrt_perf_failure *);
enum xrt_status xrt_fdflow_drain(struct xrt_fdflow *,
                                 struct xrt_fdflow_snapshot *);
/* Stop closes all perf handles and drops unread ring bytes. Drain before stop
 * when the final tail matters; a later drain returns retained counters only. */
void xrt_fdflow_stop(struct xrt_fdflow *);
void xrt_fdflow_close(struct xrt_fdflow *);

/* Pure protocol helpers. All fields are bounds checked before access. */
int xrt_fdflow_format(const char *, size_t, const char *name,
                      const struct xrt_fdflow_source *);
int xrt_fdflow_decode(const void *, size_t, const struct xrt_fdflow_source *,
                      uint32_t, struct xrt_fdflow_record *);
int xrt_fdflow_cpu_list(const char *, size_t, int32_t *, uint32_t capacity,
                        uint32_t *count, uint32_t *total);
#endif
