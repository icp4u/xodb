#ifndef XODB_GHX_HOST_H
#define XODB_GHX_HOST_H

struct xsq_cancel;

/* One supervised decompile for the debugger host.
 *
 * Starts tools/ghx/ghx_supervise (which starts ghx_worker in its own process
 * group with PR_SET_PDEATHSIG), writes one DECOMPILE line and reads the
 * supervisor's RESULT. The worker never runs inside the target or the target
 * agent. The call is bounded: the supervisor enforces deadline_ms on the
 * worker, and the host gives the supervisor deadline_ms + grace_ms + 3 s before
 * SIGTERM, then grace_ms + 1 s more before SIGKILL; the supervisor is always
 * reaped before return. A set cancel flag stops the supervisor the same way
 * (the supervisor kills its worker; a killed supervisor's worker receives
 * SIGKILL from PR_SET_PDEATHSIG). */

enum xghx_status {
    XGHX_RESULT = 0,    /* the supervisor published a RESULT; see outcome.status */
    XGHX_CANCELLED,     /* cancel flag observed; supervisor stopped and reaped */
    XGHX_HOST_DEADLINE, /* supervisor exceeded the host bound; stopped and reaped */
    XGHX_SPAWN_FAILED,  /* pipes, output files or posix_spawn failed (errno in outcome) */
    XGHX_PROTOCOL,      /* supervisor exited without a RESULT line */
};

struct xghx_request {
    const char *supervisor, *worker, *sleighhome, *outdir;
    const char *line; /* one DECOMPILE request, without newline, no tabs in values */
    long deadline_ms, grace_ms, memory_mb;
};

struct xghx_outcome {
    char status[32];  /* RESULT status=: ok error timeout cancelled worker_died ... */
    char detail[256]; /* RESULT detail= or worker_status=, possibly empty */
    char file[4096];  /* RESULT file= */
    long worker_pid;  /* last WORKER pid=, 0 if none was reported */
    int supervisor_status; /* waitpid status, -1 if never started */
    int error;        /* errno for XGHX_SPAWN_FAILED */
    double ms;        /* host wall time */
};

enum xghx_status xghx_run(const struct xghx_request *request, const struct xsq_cancel *cancel,
                          struct xghx_outcome *outcome);
/* A heap cancellation flag for callers that cannot embed C11 atomics. */
struct xsq_cancel *xghx_cancel_new(void);
void xghx_cancel_free(struct xsq_cancel *cancel);
const char *xghx_status_name(enum xghx_status status);
/* Removes a private scratch tree without following symbolic links. */
int xghx_remove_tree(const char *path);

#endif
