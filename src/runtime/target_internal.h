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
};
struct xrt_target {
    /* NULL for native targets. Remote handles retain only read-only snapshots. */
    struct xrt_connection *connection;
    uint32_t remote_id, remote_root;
    /* GCC/Clang __atomic accesses keep concurrent collector ownership safe.
     * Plain storage keeps this private layout translatable by Zig @cImport. */
    uint32_t remote_collectors;
    bool remote_shared;
    const struct xrt_arch *arch;
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
enum xrt_status xrt_patch_instruction(const struct xrt_target *t, uint64_t address,
                                      const uint8_t *bytes);
enum xrt_status xrt_patch_instruction_tid(const struct xrt_target *t, int32_t tid, uint64_t address,
                                          const uint8_t *bytes);
enum xrt_status xrt_rearm_inherited(struct xrt_target *t);
void xrt_sync_shared_patch(struct xrt_target *t, uint64_t id, bool patched);
enum xrt_status xrt_separate_vfork(struct xrt_target *t);
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
enum xrt_status xrt_configure_watches(struct xrt_target *t, int32_t tid);
enum xrt_status xrt_configure_arm_watches(struct xrt_target *t, int32_t tid, bool enabled);
enum xrt_status xrt_ensure_watches(struct xrt_target *t);
enum xrt_status xrt_watch_trap(struct xrt_target *t, int32_t tid, uint64_t pc,
                               const struct xrt_signal_info *info, bool *hit);
enum xrt_status xrt_start_arm_watch_completion(struct xrt_target *t, bool *started);
void xrt_publish_arm_watch(struct xrt_target *t, int32_t tid, const struct xrt_arm_watch_hit *hit,
                           bool completed);
enum xrt_status xrt_restore_debug(int32_t tid, const struct xrt_debug_registers *saved);
static inline uint64_t xrt_pc(const struct xrt_registers *regs)
{
    return regs->machine == XRT_M68K      ? regs->values.m68k.pc
           : regs->machine == XRT_AARCH64 ? regs->values.arm.pc
                                          : regs->values.x86.rip;
}
#endif
