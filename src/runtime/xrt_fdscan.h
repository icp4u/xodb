#ifndef XODB_RUNTIME_FDSCAN_H
#define XODB_RUNTIME_FDSCAN_H
/* Descriptor activity from unprivileged /proc polling: every process's fd
 * table (readlink), fdinfo offsets and flags, and /proc/PID/io counters,
 * with deltas against the previous sample of the same process identity.
 *
 * One owner thread polls. Each poll fills a borrowed snapshot that stays valid
 * until the next poll or destroy; xrt_fd_snapshot_copy() makes an owned,
 * immutable copy for other threads. Memory is bounded by the limits given at
 * creation; arrays grow with observed demand. Work per scan is bounded by its time budget. Anything cut by a
 * limit is counted, never silently dropped.
 *
 * Polling sees only the fd set at each sample: an open and close between two
 * samples is invisible, and pipes/sockets have no offsets. xrt_fdevent's
 * syscall evidence is separate: its fd-number history spans reuse and must
 * not be attributed to the current paths in this polling snapshot.
 *
 * Rates are bytes (or fd changes) per second over each process's own
 * interval. A process carried over unscanned (time budget) keeps its last
 * measured rates and is flagged stale; its counts (opened, closed, deltas)
 * are zero. */
#include "xrt.h"
#include <stddef.h>
#include <stdint.h>

enum xrt_fd_kind {
    XRT_FD_REGULAR,
    XRT_FD_DIRECTORY,
    XRT_FD_SOCKET,
    XRT_FD_PIPE,
    XRT_FD_ANON,   /* anon_inode:[eventfd], [eventpoll], inotify, ... */
    XRT_FD_MEMFD,
    XRT_FD_DEVICE, /* character or block special */
    XRT_FD_OTHER,  /* namespaces, unreadable targets */
    XRT_FD_KINDS
};
enum xrt_fd_source { XRT_FD_SOURCE_POLL };
/* Per-process history keeps FDS, CHURN and IO; system totals keep all five. */
enum xrt_fd_metric { XRT_FD_METRIC_FDS, XRT_FD_METRIC_CHURN, XRT_FD_METRIC_IO, XRT_FD_METRIC_READ, XRT_FD_METRIC_WRITE };

/* struct xrt_fd.flags */
#define XRT_FD_DELETED 1u /* unlinked (st_nlink 0) but still held */
#define XRT_FD_OPENED 2u  /* a different open file than in the previous sample */
#define XRT_FD_INFO 4u    /* pos and open_flags were read */
#define XRT_FD_STAT 8u    /* mode, device, inode, size and disk were read */
#define XRT_FD_LINK_CUT 16u /* link text dropped: string arena full */
#define XRT_FD_INFO_STALE 32u /* retained pos/flags/rate; not measured this scan */
#define XRT_FD_LINK_STALE 64u /* retained link text; name may have changed */
#define XRT_FD_STAT_STALE 128u /* retained stat fields; not measured this scan */

/* struct xrt_fd_process.flags */
#define XRT_FDP_NO_IO 2u     /* /proc/PID/io denied */
#define XRT_FDP_NEW 4u       /* first sample of this identity: no deltas yet */
#define XRT_FDP_STALE 8u     /* retained (time budget or quiet-count hint) */
#define XRT_FDP_TRUNCATED 16u /* fd table cut at the fd limit */
#define XRT_FDP_OFFSETS_STALE 128u /* some seekable offsets were retained; rate sum is partial */
#define XRT_FDP_QUIET 64u  /* count/io unchanged: hint only, fd identities not refreshed */
#define XRT_FDP_LEAKING 32u  /* fd count rising steadily; see growth */

#define XRT_FD_HISTORY 32

/* An open file is identified by its fd number and, for path targets, the
 * device and inode behind it; pipes, sockets and anonymous inodes by their
 * link text. A rename or unlink keeps the identity; a reopen onto the same
 * number is a close plus an open. */
struct xrt_fd {
    int32_t fd;
    uint8_t kind, flags;
    uint16_t link_length;
    uint32_t link;       /* offset into snapshot strings, NUL terminated */
    uint32_t open_flags; /* fdinfo flags: O_ACCMODE, O_APPEND, O_NONBLOCK, ... */
    uint32_t mode;       /* st_mode */
    uint32_t generation; /* scan sequence that first saw this open */
    uint64_t device, inode;
    int64_t size, disk;  /* st_size and st_blocks * 512 */
    uint64_t pos;
    uint64_t info_sampled_ns, info_interval_ns; /* offset samples have their own clock */
    uint64_t advance;    /* forward offset movement over info_interval_ns; zero while stale */
    float rate;          /* advance per second; kept while the owner is stale */
};

struct xrt_fd_history {
    uint32_t samples;                   /* valid entries, oldest first */
    uint32_t ms[XRT_FD_HISTORY];        /* scanner clock, milliseconds */
    uint32_t fds[XRT_FD_HISTORY];
    uint32_t churn[XRT_FD_HISTORY];     /* opened + closed in that interval */
    float io[XRT_FD_HISTORY];           /* rchar + wchar bytes per second */
    uint16_t kinds[XRT_FD_HISTORY][XRT_FD_KINDS]; /* saturating */
};

enum xrt_fd_cgroup_status {
    XRT_FD_CGROUP_UNAVAILABLE, XRT_FD_CGROUP_CURRENT, XRT_FD_CGROUP_STALE,
    XRT_FD_CGROUP_DENIED, XRT_FD_CGROUP_TRUNCATED, XRT_FD_CGROUP_UNSUPPORTED,
    XRT_FD_CGROUP_MALFORMED
};
struct xrt_fd_process {
    int32_t pid, ppid;
    uint32_t uid, flags;
    uint64_t start;      /* /proc/PID/stat starttime: identity together with pid */
    char comm[16];
    uint32_t cmdline;    /* offset into strings: NUL-separated arguments */
    uint32_t cmdline_length;
    uint32_t cgroup, cgroup_length; /* exact cgroup-v2 path in snapshot strings */
    enum xrt_fd_cgroup_status cgroup_status;
    int32_t cgroup_error;
    uint32_t first, count; /* fds[first .. first + count), ascending fd */
    uint32_t kinds[XRT_FD_KINDS];
    uint64_t rchar, wchar, read_bytes, write_bytes; /* cumulative /proc/PID/io */
    uint64_t full_sequence; /* most recent path/seekable-offset refresh */
    uint64_t sampled_ns, interval_ns;   /* CLOCK_MONOTONIC; since this identity's previous sample */
    uint64_t d_rchar, d_wchar, advance; /* over interval_ns */
    uint32_t opened, closed;            /* fd-set changes over interval_ns */
    int32_t d_count;
    float read_rate, write_rate, advance_rate, churn_rate; /* per second; kept while stale */
    /* Growth above the lowest fd count within the history window, by kind,
     * and the lowest count ever seen for this identity. */
    uint32_t growth, lifetime_low;
    uint32_t grew[XRT_FD_KINDS];
    struct xrt_fd_history history;
};

/* Processes without fd tables: other users' (denied) and kernel threads. */
struct xrt_fd_unseen {
    int32_t pid;
    uint32_t uid;
    uint64_t start;
    uint8_t kernel; /* kernel thread rather than a denied process */
    uint8_t stale;  /* carried over (time budget) */
};

struct xrt_fd_snapshot {
    enum xrt_fd_source source;
    uint64_t sequence;
    uint64_t taken_ns;    /* CLOCK_MONOTONIC */
    uint64_t interval_ns; /* since the previous scan; 0 on the first */
    uint64_t scan_ns, scan_cpu_ns;
    const struct xrt_fd_process *processes; /* visible ones, ascending pid */
    uint32_t process_count;
    const struct xrt_fd *fds;
    uint32_t fd_count;
    const char *strings;
    uint32_t strings_length;
    const struct xrt_fd_unseen *unseen; /* ascending pid */
    uint32_t unseen_count;
    uint32_t hidden;         /* other users' processes: /proc denies their fd tables */
    uint32_t kernel_threads;
    uint32_t unscanned;      /* listed but never sampled yet (time budget) */
    uint32_t gone;           /* exited during the scan */
    uint32_t stale;          /* visible but not rescanned (time budget) */
    uint32_t dropped_processes, dropped_fds, cut_strings; /* limits reached */
    uint32_t kinds[XRT_FD_KINDS];
    uint64_t opened, closed;  /* counted in this scan */
    float read_rate, write_rate, advance_rate, churn_rate; /* sum of process rates */
};

/* A file aggregated over its holders: (device, inode) for files, pipes and
 * sockets. Anonymous inodes share one inode system-wide, so each anon fd is
 * its own entry. */
struct xrt_fd_file {
    uint64_t device, inode;
    int64_t size, disk;
    uint8_t kind, flags; /* XRT_FD_DELETED and per-field stale flags */
    uint32_t sample;     /* index into snapshot fds of one holder */
    uint32_t holders;    /* distinct processes */
    uint32_t fds;
    uint64_t holder_set; /* hash of the holder pids: equal sets, equal hashes */
    float rate, read_rate, write_rate; /* by access mode; O_RDWR counts in rate only */
};

struct xrt_fdscan_options {
    uint32_t max_processes; /* visible, and separately unseen; 0: 16384 */
    uint32_t max_fds;       /* 0: 262144 */
    uint32_t max_strings;   /* bytes per snapshot; 0: 16 MiB */
    uint32_t budget_ms;     /* 0: unbounded scan time */
    const int32_t *pids;    /* restrict to these processes; NULL: all of /proc */
    uint32_t pid_count;
    uint64_t expected_start; /* nonzero: exactly one pid; pin its proc directory and require this start tick */
    int adaptive; /* opt-in: requested metadata fresh, background metadata explicitly stale */
    int include_self;
    int cgroups; /* opt-in exact cgroup-v2 paths for graph grouping */
    const char *proc;       /* procfs root; NULL: "/proc" */
};

struct xrt_fdscan;
enum xrt_status xrt_fdscan_create(const struct xrt_fdscan_options *, struct xrt_fdscan **);
void xrt_fdscan_destroy(struct xrt_fdscan *);
/* Scan now. The snapshot borrows scanner memory until the next poll. */
enum xrt_status xrt_fdscan_poll(struct xrt_fdscan *, struct xrt_fd_snapshot *);
/* Change the scan time budget (0: unbounded) from the next poll. */
void xrt_fdscan_budget(struct xrt_fdscan *, uint32_t ms);
void xrt_fdscan_cgroups(struct xrt_fdscan *, int enabled);
/* Also reread fdinfo for every fd of this process (0: none). */
void xrt_fdscan_detail(struct xrt_fdscan *, int32_t pid);
/* Replace the foreground process set; copied, no borrowed pointer. Adaptive
 * scans refresh their paths and seekable offsets. Nonseekable fdinfo stays
 * stale unless detail() requests it. Background entries use one identity
 * operation per cached descriptor, fdinfo only at periodic refresh, and a
 * same-count/no-IO hint may retain the whole process marked stale. A path/offset
 * refresh occurs at least every eight scan sequences when the budget reaches
 * that process. Zero count means none; all != 0 requests every process. */
#define XRT_FD_INTEREST_MAX 128u
enum xrt_status xrt_fdscan_interest(struct xrt_fdscan *, const int32_t *pids,
                                    uint32_t count, int all);
/* Files of the latest snapshot, highest rate first. Borrowed. */
enum xrt_status xrt_fdscan_files(struct xrt_fdscan *, const struct xrt_fd_file **, uint32_t *count);
/* System totals per scan, oldest first; returns the number written. */
uint32_t xrt_fdscan_totals(const struct xrt_fdscan *, enum xrt_fd_metric, float *out, uint32_t n);
/* An owned, immutable copy of a snapshot in one allocation, for readers on
 * other threads. NULL when out of memory. */
struct xrt_fd_snapshot *xrt_fd_snapshot_copy(const struct xrt_fd_snapshot *);
void xrt_fd_snapshot_free(struct xrt_fd_snapshot *);
const char *xrt_fd_kind_name(enum xrt_fd_kind);
/* Growth above the lowest fd count within the history window. */
uint32_t xrt_fd_growth(const struct xrt_fd_process *);
#endif
