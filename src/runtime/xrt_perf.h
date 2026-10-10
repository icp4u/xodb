#ifndef XODB_RUNTIME_PERF_H
#define XODB_RUNTIME_PERF_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#define XRT_PERF_MAX_THREADS 1024
#define XRT_PERF_MAX_EVENTS 32
/* Linux UAPI byte layout, without compiler-specific bitfields. */
struct xrt_perf_attr {
    uint32_t type, size;
    uint64_t config, sample_period, sample_type, read_format, flags;
    uint32_t wakeup_events, bp_type;
    uint64_t config1, config2, branch_sample_type, sample_regs_user;
    uint32_t sample_stack_user;
    int32_t clockid;
    uint64_t sample_regs_intr;
    uint32_t aux_watermark;
    uint16_t sample_max_stack, reserved_2;
    uint32_t aux_sample_size, aux_action;
    uint64_t sig_data, config3, config4;
};
enum xrt_perf_failure_kind {
    XRT_PERF_UNAVAILABLE,
    XRT_PERF_PERMISSION,
    XRT_PERF_CONFIGURATION,
    XRT_PERF_THREAD_GONE,
    XRT_PERF_RESOURCE,
    XRT_PERF_OTHER
};
struct xrt_perf_failure {
    enum xrt_perf_failure_kind kind;
    const char *syscall, *detail; /* static strings */
    int32_t error, tid;
    uint16_t opened_then_closed;
};
struct xrt_target;
struct xrt_perf;
struct xrt_perf_thread {
    int32_t tid;
    uint64_t event_ids[XRT_PERF_MAX_EVENTS], start_time_ticks, debugger_id, enrolled_ns;
    size_t event_count;
    bool start_time_known, retiring;
};
struct xrt_perf_info {
    size_t threads, page_size;
    uint64_t allocated_ring_bytes, ring_data_bytes, data_offset;
    uint32_t mmap_version;
    bool running;
    bool failed;
    struct xrt_perf_failure failure;
};
/* Thread APIs take explicit positive TIDs; CPU enrollment is separate below.
 * Handles and their mmap/fd ownership remain in C.
 * Callbacks may decode borrowed bytes, but never retain them or reenter handle
 * operations. They return a validated consumed prefix; C publishes the tail. */
struct xrt_perf_ring {
    const uint8_t *data;
    size_t size, index;
    uint64_t head, tail;
    const struct xrt_perf_thread *thread;
};
enum xrt_perf_drain_status {
    XRT_PERF_DRAIN_OK,
    XRT_PERF_DRAIN_CAPACITY,
    XRT_PERF_DRAIN_MALFORMED,
    XRT_PERF_DRAIN_INCOMPLETE,
    XRT_PERF_DRAIN_STOP
};
struct xrt_perf_consumed {
    uint64_t bytes;
    enum xrt_perf_drain_status status;
};
typedef struct xrt_perf_consumed (*xrt_perf_decoder)(void *, const struct xrt_perf_ring *);
typedef int (*xrt_perf_opener)(void *, int32_t tid, int group_fd, size_t event_index,
                               const struct xrt_perf_attr *);
struct xrt_perf *xrt_perf_create(unsigned data_pages, size_t max_threads, uint64_t budget);
void xrt_perf_destroy(struct xrt_perf *);
void xrt_perf_info(const struct xrt_perf *, struct xrt_perf_info *);
bool xrt_perf_thread(const struct xrt_perf *, size_t index, struct xrt_perf_thread *);
bool xrt_perf_add(struct xrt_perf *, int32_t tid, const struct xrt_perf_attr *, size_t events,
                  xrt_perf_opener, void *context, struct xrt_perf_failure *);
/* Local system-wide CPU enrollment. A non-NULL tracepoint filter is installed
 * on every event while disabled, before any record can be collected. This is
 * also the owned-TID scope used by live tests. No remote enrollment or inherit.
 * The ring's thread.tid is -1; the caller retains its CPU-to-ring-index map. */
bool xrt_perf_add_cpu(struct xrt_perf *, int32_t cpu, const struct xrt_perf_attr *, size_t events,
                      const char *tracepoint_filter, struct xrt_perf_failure *);
bool xrt_perf_enable(struct xrt_perf *, struct xrt_perf_failure *);
bool xrt_perf_stop(struct xrt_perf *, struct xrt_perf_failure *);
bool xrt_perf_retire(struct xrt_perf *, size_t index, struct xrt_perf_failure *);
size_t xrt_perf_fd_count(const struct xrt_perf *);
/* Local per-thread cumulative loss, even when the producer is idle. False if
 * the requested read format is unsupported, unavailable or the read fails. */
bool xrt_perf_read_lost(struct xrt_perf *, size_t index, uint64_t *lost);
enum xrt_perf_drain_status xrt_perf_drain(struct xrt_perf *, xrt_perf_decoder, void *context);
/* Wrap-copy for host record decoders; false for invalid lengths or ring sizes. */
bool xrt_perf_copy(const uint8_t *ring, size_t size, uint64_t tail, void *out, size_t length);
size_t xrt_perf_page_size(void);
uint64_t xrt_perf_timestamp(const struct xrt_perf *, uint64_t producer_ns);
struct xrt_cpu_config {
    const int32_t *tids;
    size_t thread_count;
    unsigned event; /* task clock=0, CPU clock=1, CPU cycles=2; no fallback */
    uint32_t frequency_hz, user_stack_bytes;
    uint16_t max_frames;
    uint8_t data_pages;
    uint64_t ring_budget_bytes, user_regs_mask;
    bool exclude_kernel, mmap_data, callchain, include_weight, context_switch, follow_threads;
};
struct xrt_cpu_acceptance {
    struct xrt_perf_attr attr;
    uint32_t kernel_max_sample_rate, kernel_max_stack;
};
struct xrt_perf *xrt_cpu_start(const struct xrt_cpu_config *, struct xrt_cpu_acceptance *,
                               struct xrt_perf_failure *);
bool xrt_cpu_enroll(struct xrt_perf *, int32_t tid, const struct xrt_cpu_acceptance *,
                    struct xrt_perf_failure *);
/* Shared error/metadata helpers for the syscall and allocation collectors. */
void xrt_perf_fail(struct xrt_perf_failure *, const char *call, int error, int32_t tid,
                   const char *detail);
bool xrt_perf_read_file(const char *path, char *out, size_t capacity, size_t *size);
bool xrt_perf_unsigned(const char *, size_t size, uint64_t *out);
bool xrt_syscall_format(const char *, size_t size, uint32_t id, bool enter);
struct xrt_perf *xrt_syscalls_start(int32_t pid, const int32_t *tids, size_t count,
                                    uint16_t *enter_type, uint16_t *exit_type,
                                    struct xrt_perf_failure *);
/* Like xrt_syscalls_start, requesting per-FD loss counters where supported.
 * xrt_perf_read_lost reports whether those counters are actually available. */
struct xrt_perf *xrt_syscalls_start_loss(int32_t pid, const int32_t *tids, size_t count,
                                         uint16_t *enter_type, uint16_t *exit_type,
                                         struct xrt_perf_failure *);
/* A collector must be closed before its remote target handle is destroyed. */
struct xrt_perf *xrt_cpu_start_target(const struct xrt_target *, const struct xrt_cpu_config *,
                                      struct xrt_cpu_acceptance *, struct xrt_perf_failure *);
struct xrt_perf *xrt_syscalls_start_target(const struct xrt_target *, int32_t, const int32_t *,
                                           size_t, uint16_t *, uint16_t *,
                                           struct xrt_perf_failure *);
#endif
