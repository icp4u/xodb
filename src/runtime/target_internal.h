#ifndef XODB_RUNTIME_TARGET_INTERNAL_H
#define XODB_RUNTIME_TARGET_INTERNAL_H
#include "xrt_target.h"
#include "remote_internal.h"
#include "xrt_memory.h"
#include <assert.h>
#include <errno.h>
#include <signal.h>
#include <string.h>
#include <sys/ptrace.h>
#include <sys/wait.h>
#include <unistd.h>

#define TRY(expr)                                                                                  \
    do {                                                                                           \
        enum xrt_status result_ = (expr);                                                          \
        if (result_ != XRT_OK)                                                                     \
            return result_;                                                                        \
    } while (0)
struct xrt_step {
    int32_t tid;
    uint64_t rearm;
    bool stop_after, interrupted, has_watch, has_exec_entry;
    struct xrt_arm_watch_hit watch;
    uint64_t exec_entry_pc;
    /* software is set only after the resume has been issued. probe_owned marks
     * temporary probes this step planted and must remove. A user probe already
     * at a successor keeps probe_owned clear. */
    uint8_t software, successor_count, probe_owned[2];
    uint64_t successor_pc[2], probe_id[2];
};
/* One unpublished plant. original holds the full prepared image, not only the
 * bytes a short rollback managed to restore. */
struct xrt_plant_cleanup {
    uint8_t active;
    uint64_t address;
    uint8_t width;
    uint8_t original[4];
};
struct xrt_target {
    /* NULL for native targets. Remote handles retain only read-only snapshots. */
    struct xrt_connection *connection;
    uint32_t remote_id, remote_root;
    /* GCC/Clang __atomic accesses keep concurrent collector ownership safe.
     * Plain storage keeps this private layout translatable by Zig @cImport. */
    uint32_t remote_collectors;
    uint32_t remote_files;
    bool remote_shared;
    const struct xrt_arch *arch;
    uint8_t identity_admitted;
    struct xrt_reg_io *reg_io;
    struct xrt_mutation_result last_mutation;
    struct xrt_plant_cleanup plant_cleanup;
    enum xrt_status (*patch)(void *ctx, int32_t tid, uint64_t address, const void *bytes,
                             size_t size, size_t *accepted);
    void *patch_ctx;
    bool core, owned, follow_processes;
    int32_t pid;
    struct xrt_birth births[XRT_MAX_THREADS];
    size_t birth_count;
    bool inherited_rearm, detach_pending;
    uint64_t birth_image_epoch;
    struct xrt_breakpoint birth_breakpoints[XRT_MAX_BREAKPOINTS];
    size_t birth_breakpoint_count;
    struct xrt_watchpoint birth_watchpoints[4];
    uint64_t birth_next_probe_id;
    struct xrt_target *vfork_parent, *vfork_children[XRT_MAX_THREADS];
    /* Non-x86 shared vfork. The child stays traced until VFORK_DONE.
     * release means the shared image currently holds original bytes while the
     * breakpoint records still say patched. hold_detach asks the next child
     * stop to detach rather than resume. */
    int32_t vfork_hold;
    uint8_t vfork_release, vfork_hold_detach;
    int32_t reap_tids[2048];
    size_t reap_count;
    enum xrt_state state;
    bool want_run;
    struct xrt_thread threads[XRT_MAX_THREADS];
    size_t thread_count;
    uint64_t next_thread_id;
    struct xrt_event events[XRT_MAX_EVENTS];
    size_t event_count;
    uint64_t sequence, generation, image_epoch;
    struct xrt_breakpoint breakpoints[XRT_MAX_BREAKPOINTS];
    size_t breakpoint_count;
    struct xrt_watchpoint watchpoints[4];
    uint64_t next_probe_id;
    bool stepping;
    struct xrt_step step;
    bool watchpoints_dirty, watch_cancelled;
    xrt_new_thread_observer observer;
    void *observer_context;
};

enum xrt_status xrt_trace(unsigned request, int32_t tid, uintptr_t address, uintptr_t data);
int xrt_thread_index(const struct xrt_target *t, int32_t tid);
int xrt_breakpoint_index(const struct xrt_target *t, uint64_t id);
int xrt_breakpoint_at(const struct xrt_target *t, uint64_t address);
enum xrt_status xrt_add_thread(struct xrt_target *t, int32_t tid, bool newborn);
enum xrt_status xrt_memory_mutation_allowed(const struct xrt_target *t);
enum xrt_status xrt_execution_allowed(const struct xrt_target *t);
enum xrt_status xrt_patch_instruction(struct xrt_target *t, uint64_t address, const uint8_t *bytes,
                                      size_t width);
enum xrt_status xrt_patch_instruction_tid(struct xrt_target *t, int32_t tid, uint64_t address,
                                          const uint8_t *bytes, size_t width);
enum xrt_status xrt_target_patch_span(struct xrt_target *t, int32_t tid, uint64_t address,
                                      const uint8_t *bytes, size_t width, size_t *accepted);
enum xrt_status xrt_target_commit_bytes(struct xrt_target *t, uint64_t address,
                                        const uint8_t bytes[4], const uint8_t rollback[4],
                                        uint8_t width);
enum xrt_status xrt_target_commit_plant(struct xrt_target *t, uint64_t address,
                                        const struct xrt_probe_encoding *encoding,
                                        const uint8_t original[4]);
enum xrt_status xrt_target_commit_owned(struct xrt_target *t, uint64_t address,
                                        const uint8_t bytes[4], const uint8_t rollback[4],
                                        uint8_t width);
void xrt_target_apply_exec_identity(struct xrt_target *t, enum xrt_status validate_status);
enum xrt_status xrt_target_retry_plant_cleanup(struct xrt_target *t);
enum xrt_status xrt_target_settle_plant_cleanup(struct xrt_target *t, int drop_if_exited);
enum xrt_status xrt_rearm_inherited(struct xrt_target *t);
void xrt_sync_shared_patch(struct xrt_target *t, uint64_t id, bool patched);
enum xrt_status xrt_separate_vfork(struct xrt_target *t);
/* Kill a child still traced across a shared vfork. The process is going away. */
void xrt_drop_vfork_hold(struct xrt_target *t);
/* Detach that child. It keeps running. ESRCH means it is already gone. */
enum xrt_status xrt_detach_held_vfork(struct xrt_target *t);
size_t xrt_shared_family(struct xrt_target *t, struct xrt_target *out[32]);
enum xrt_status xrt_poll_births(struct xrt_target *t);
enum xrt_status xrt_stop_peers(struct xrt_target *t);
void xrt_recompute_state(struct xrt_target *t);
void xrt_reap_detached(struct xrt_target *t);
void xrt_remember_reap(struct xrt_target *t, int32_t tid);
bool xrt_traced_member(int32_t tid, int32_t group);
bool xrt_task_zombie(int32_t tid);
enum xrt_status xrt_begin_step(struct xrt_target *t, int32_t tid, bool stop_after);
enum xrt_status xrt_finish_step(struct xrt_target *t, bool completed);
/* Plant count temporary internal probes. On failure every probe this call
 * planted is removed, or the cleanup record stays and the status is not OK. */
enum xrt_status xrt_software_plant(struct xrt_target *t, const uint64_t *pcs, uint8_t count,
                                   uint64_t ids[2], uint8_t owned[2]);
/* *handled is 0 if this stop is not a software-step successor, 1 if the step
 * completed in the stopped state, and 2 if stop_after was clear and the thread
 * was resumed. */
enum xrt_status xrt_software_step_hit(struct xrt_target *t, int thread_index, uint64_t pc,
                                      int *handled);
enum xrt_status xrt_configure_watches(struct xrt_target *t, int32_t tid);
enum xrt_status xrt_configure_arm_watches(struct xrt_target *t, int32_t tid, bool enabled);
enum xrt_status xrt_ensure_watches(struct xrt_target *t);
enum xrt_status xrt_watch_trap(struct xrt_target *t, int32_t tid, uint64_t pc,
                               const struct xrt_signal_info *info, bool *hit);
enum xrt_status xrt_start_arm_watch_completion(struct xrt_target *t, bool *started);
void xrt_publish_arm_watch(struct xrt_target *t, int32_t tid, const struct xrt_arm_watch_hit *hit,
                           bool completed);
enum xrt_status xrt_restore_debug(int32_t tid, const struct xrt_debug_registers *saved);
#endif
