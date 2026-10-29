#ifndef XODB_RUNTIME_PROCESS_H
#define XODB_RUNTIME_PROCESS_H

#include "xrt.h"
#include <stdbool.h>
#include <stdint.h>

/* Call once before installing the debugger's signal handlers, on the ptrace
 * owner thread. Subsequent launches/restarts restore these dispositions.
 * A fork that execs the runtime agent must apply them too: SIG_IGN survives
 * exec, and the agent records whatever it inherits. */
enum xrt_status xrt_process_save_launch_signals(void);
/* Apply the saved dispositions. No saved set is a no-op. A fork child calls
 * this before exec and must not exec when the result is not XRT_OK. */
enum xrt_status xrt_process_restore_launch_signals(void);

/* argv is a NULL-terminated native vector. On success, ownership of the seized
 * child transfers to the caller, which must wait for exec/exit and eventually
 * reap it. On failure, no child or gate descriptor remains and *pid is zero.
 * The child cannot exec before SEIZE. Its stdin is /dev/null and stdout goes
 * to stderr so target output cannot corrupt a debugger protocol stream. */
enum xrt_status xrt_process_launch(const char *const argv[], bool follow, int32_t *pid);
uintptr_t xrt_process_options(bool owned, bool follow);
struct xrt_arch;
enum xrt_status xrt_process_identify(int32_t tid, const struct xrt_arch **out);
enum xrt_status xrt_process_validate_native(int32_t tid);

/* A child this process spawned and will wait for itself. The in-session
 * orphan reap skips it so that wait still sees the exit status. A full
 * table returns false; the waiter then has to tolerate a missing status.
 * Spawn and fork of such a child go through xrt_spawn_owned_helper, which
 * notes the parent pid before it returns. A fork child (pid 0) is not noted. */
bool xrt_note_owned_helper(int32_t pid);
void xrt_drop_owned_helper(int32_t pid);
int xrt_spawn_owned_helper(int32_t *pid, int (*create)(int32_t *pid, void *context), void *context);

/* A transient /proc observation, not authoritative debugger stop state.
 * Missing tasks return PROCESS_GONE; denied/incomplete reads remain distinct.
 * Output is unchanged on failure. */
struct xrt_task_info {
    int32_t group;
    int32_t tracer;
    char state;
};
enum xrt_status xrt_task_inspect(int32_t tid, struct xrt_task_info *out);

/* Normalized kernel signal evidence; libc's siginfo_t union stays in C. */
struct xrt_signal_info {
    int32_t number;
    int32_t code;
    int32_t error_number;
    int32_t sender;
    uint64_t address;
    bool has_sender;
    bool has_address;
};
enum xrt_status xrt_signal_read(int32_t tid, struct xrt_signal_info *out);

#endif
