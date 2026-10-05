#ifndef XODB_RUNTIME_TARGET_H
#define XODB_RUNTIME_TARGET_H
#include "xrt_arch.h"
#include "xrt_process.h"
#include "xrt_xstate.h"
#include <stddef.h>

#define XRT_MAX_THREADS 1024
#define XRT_MAX_EVENTS 4096
#define XRT_MAX_BREAKPOINTS 128
#define XRT_MAX_WATCHPOINTS 4

enum xrt_state { XRT_IDLE, XRT_RUNNING, XRT_STOPPED, XRT_EXITED };
enum xrt_stop_reason {
    XRT_STOP_NONE,
    XRT_STOP_EXEC,
    XRT_STOP_INTERRUPT,
    XRT_STOP_SIGNAL,
    XRT_STOP_BREAKPOINT,
    XRT_STOP_WATCHPOINT,
    XRT_STOP_SINGLE_STEP,
    XRT_STOP_CLONE,
    XRT_STOP_FORK,
    XRT_STOP_VFORK,
    XRT_STOP_VFORK_DONE
};
enum xrt_event_kind {
    XRT_EVENT_LAUNCH,
    XRT_EVENT_ATTACH,
    XRT_EVENT_THREAD_START,
    XRT_EVENT_THREAD_EXITING,
    XRT_EVENT_STOP,
    XRT_EVENT_CONTINUED,
    XRT_EVENT_EXIT,
    XRT_EVENT_DETACH,
    XRT_EVENT_BREAKPOINT_SET,
    XRT_EVENT_BREAKPOINT_REMOVED,
    XRT_EVENT_BREAKPOINT_HIT,
    XRT_EVENT_WATCHPOINT_SET,
    XRT_EVENT_WATCHPOINT_REMOVED,
    XRT_EVENT_WATCHPOINT_HIT,
    XRT_EVENT_STEP_STARTED,
    XRT_EVENT_STEP_COMPLETE,
    XRT_EVENT_MEMORY_WRITTEN,
    XRT_EVENT_REGISTER_WRITTEN,
    XRT_EVENT_AGENT_ACTION,
    XRT_EVENT_IMAGE_REPLACED,
    XRT_EVENT_PROCESS_BIRTH,
    XRT_EVENT_PROCESS_SEPARATED
};
enum xrt_watch_kind { XRT_WATCH_WRITE, XRT_WATCH_READ_WRITE, XRT_WATCH_EXECUTE };
enum xrt_birth_kind { XRT_BIRTH_FORK, XRT_BIRTH_VFORK, XRT_BIRTH_CLONE_UNKNOWN };

struct xrt_debug_registers {
    uint64_t address[4], status, control;
};
struct xrt_arm_watch_hit {
    uint64_t pc, address, before[4];
    int32_t code;
    bool before_valid[4], other_threads_running;
};
struct xrt_thread {
    uint64_t id;
    int32_t tid;
    enum xrt_state state;
    int32_t signal;
    bool newborn, interrupt_pending;
    enum xrt_stop_reason reason;
    uint64_t breakpoint_address;
    bool has_saved_debug, has_arm_watch_slots, has_arm_watch_hit;
    struct xrt_debug_registers saved_debug;
    uint8_t arm_watch_slots;
    struct xrt_arm_watch_hit arm_watch_hit;
};
struct xrt_breakpoint {
    uint64_t id, address;
    uint8_t original[4];
    bool patched, enabled;
    uint64_t hit_count;
    bool pending, internal, temporary;
};
struct xrt_watchpoint {
    uint64_t id, address;
    uint8_t length;
    enum xrt_watch_kind kind;
    uint64_t previous;
    bool present;
};
struct xrt_birth {
    int32_t pid, parent_tid;
    enum xrt_birth_kind kind;
    bool stopped, exited;
    int32_t status;
    uint64_t unpatched_probe; /* zero means absent; probe IDs start at one. */
    bool has_saved_debug;
    struct xrt_debug_registers saved_debug;
    int32_t vm_errno;
};
struct xrt_event {
    uint64_t sequence, time_ns;
    int32_t tid;
    enum xrt_event_kind kind;
    int64_t detail;
    uint64_t pc, address, before, after;
    uint8_t size;
    bool other_threads_running, has_trap;
    uint64_t trap_pc, trap_address;
    int32_t trap_code;
    uint8_t watch_phase, watch_attribution; /* after/completed/interrupted; slot/single/candidate */
    bool before_valid, after_valid;
};

struct xrt_target;
/* Borrowed views are read-only and valid until the next operation on this
 * target or a member of its shared-VM family. One OS thread owns all calls.
 * Native structs are never the wire representation. */
struct xrt_target_view {
    int32_t pid;
    enum xrt_state state;
    bool owned, follow_processes, stepping, detach_pending, want_run;
    uint64_t generation, image_epoch, sequence, next_thread_id, next_probe_id;
    size_t thread_count, event_count, breakpoint_count, birth_count;
    const struct xrt_thread *threads;
    const struct xrt_event *events;
    const struct xrt_breakpoint *breakpoints;
    const struct xrt_watchpoint *watchpoints;
    const struct xrt_birth *births;
};
struct xrt_target *xrt_target_create(void);
/* A failed detach retains the handle for an explicit retry. */
enum xrt_status xrt_target_destroy(struct xrt_target *target);
void xrt_target_view(const struct xrt_target *target, struct xrt_target_view *out);
uint64_t xrt_now(void);
/* Host policy invalidation is explicit; there is no writable snapshot. */
void xrt_target_invalidate(struct xrt_target *target);
void xrt_target_event(struct xrt_target *target, enum xrt_event_kind kind, int32_t tid,
                      int64_t detail);
enum xrt_status xrt_target_expect(const struct xrt_target *target, uint64_t generation);
enum xrt_status xrt_target_launch(struct xrt_target *target, const char *const argv[]);
enum xrt_status xrt_target_attach(struct xrt_target *target, int32_t pid);
enum xrt_status xrt_target_interrupt(struct xrt_target *target);
enum xrt_status xrt_target_continue(struct xrt_target *target);
enum xrt_status xrt_target_step(struct xrt_target *target, int32_t tid);
enum xrt_status xrt_target_poll(struct xrt_target *target);
enum xrt_status xrt_target_wait_stopped(struct xrt_target *target);
enum xrt_status xrt_target_stopped_tid(const struct xrt_target *target, int32_t *tid);
enum xrt_status xrt_target_detach(struct xrt_target *target);
enum xrt_status xrt_target_detach_family(struct xrt_target *target);
enum xrt_status xrt_target_close(struct xrt_target *target);
/* Close/reset physical state while retaining monotonically increasing IDs,
 * generations and event sequence, for a host-requested restart. */
enum xrt_status xrt_target_reset(struct xrt_target *target);
enum xrt_status xrt_target_set_following(struct xrt_target *target, bool enabled);
bool xrt_target_shared_vm(const struct xrt_target *target);
const struct xrt_target *xrt_target_family_root(const struct xrt_target *target);
enum xrt_status xrt_target_adopt(struct xrt_target *parent, int32_t pid, struct xrt_target *child,
                                 struct xrt_birth *birth);
bool xrt_target_only_internal_stops(const struct xrt_target *target);

enum xrt_status xrt_target_breakpoint_set(struct xrt_target *target, uint64_t address,
                                          bool temporary, uint64_t *id);
enum xrt_status xrt_target_breakpoint_reserve(struct xrt_target *target, uint64_t *id);
enum xrt_status xrt_target_breakpoint_restore(struct xrt_target *target, uint64_t id, bool enabled);
enum xrt_status xrt_target_breakpoint_resolve(struct xrt_target *target, uint64_t id,
                                              uint64_t address);
enum xrt_status xrt_target_breakpoint_withdraw(struct xrt_target *target, uint64_t id);
enum xrt_status xrt_target_breakpoint_enable(struct xrt_target *target, uint64_t id, bool enabled);
enum xrt_status xrt_target_breakpoint_internal(struct xrt_target *target, uint64_t id,
                                               bool internal);
enum xrt_status xrt_target_breakpoint_remove(struct xrt_target *target, uint64_t id);
enum xrt_status xrt_target_watchpoint_set(struct xrt_target *target, uint64_t address,
                                          uint8_t length, enum xrt_watch_kind kind, uint64_t *id);
enum xrt_status xrt_target_watchpoint_remove(struct xrt_target *target, uint64_t id);
enum xrt_status xrt_target_watchpoint_capacity(const struct xrt_target *target, uint8_t *capacity);
enum xrt_status xrt_target_read(const struct xrt_target *target, uint64_t address, void *out,
                                size_t size, size_t *count);
enum xrt_status xrt_target_write(struct xrt_target *target, uint64_t address, const void *bytes,
                                 size_t size);
enum xrt_status xrt_target_registers(const struct xrt_target *target, int32_t tid,
                                     struct xrt_registers *out);
enum xrt_status xrt_target_register_write(struct xrt_target *target, int32_t tid, const char *name,
                                          size_t length, uint64_t value);
enum xrt_status xrt_target_extended(const struct xrt_target *target, int32_t tid,
                                    struct xrt_xstate *out);
enum xrt_status xrt_target_signal_info(const struct xrt_target *, int32_t tid,
                                       struct xrt_signal_info *out);
enum xrt_status xrt_target_signal_suppress(struct xrt_target *target, int32_t tid);
/* Host-decoded core files supply an immutable thread snapshot. Execution APIs
 * reject it, and closing it never signals or waits for a live PID. */
enum xrt_status xrt_target_core(struct xrt_target *target, int32_t pid,
                                const struct xrt_thread *threads, size_t count);
typedef void (*xrt_new_thread_observer)(void *context, const struct xrt_thread *thread,
                                        bool same_group);
void xrt_target_observer(struct xrt_target *target, xrt_new_thread_observer observer,
                         void *context);
#endif
