#ifndef XODB_RUNTIME_SYSSTAT_H
#define XODB_RUNTIME_SYSSTAT_H
/* Whole-system observer for the overview view: bounded, unprivileged,
 * read-only. One context samples; each sample fills a caller-owned snapshot
 * that stays valid until xrt_sys_snapshot_free.
 *
 * Honesty rule: every value carries a state. A zeroed struct is UNSET, never
 * OK, so nothing reads as a measured zero by accident. Rates are
 * instantaneous: computed between this sample and the previous sample of the
 * same context (interval_s). The first sample reports every rate as
 * UNAVAILABLE/FIRST_SAMPLE. History is the caller's job; there is no ring.
 *
 * Units: bytes, bytes per second, operations per second, percent 0..100
 * (process cpu_pct is percent of one logical CPU, so it can exceed 100),
 * degrees Celsius, MHz, watts, seconds.
 *
 * Threading: a context is owned by one thread; optional NVML uses one private
 * worker and never writes published snapshots. Snapshots are plain data and
 * can be copied to or read from any thread. */
#include "xrt.h"
#include <stdint.h>
#include <stddef.h>

#define XRT_SYS_ABI 1

enum xrt_sys_state {
    XRT_SYS_UNSET = 0,       /* not filled; treat as unavailable */
    XRT_SYS_OK = 1,          /* measured in this sample */
    XRT_SYS_UNAVAILABLE = 2, /* not measured; `why` says why */
    XRT_SYS_STALE = 3        /* carried from an earlier sample; `why` says why */
};

enum xrt_sys_reason {
    XRT_SYS_WHY_NONE = 0,
    XRT_SYS_WHY_NOT_COLLECTED,   /* group not requested in this sample */
    XRT_SYS_WHY_FIRST_SAMPLE,    /* a rate needs a previous sample */
    XRT_SYS_WHY_NOT_PRESENT,     /* kernel or hardware does not expose it */
    XRT_SYS_WHY_NEEDS_PRIVILEGE, /* EACCES/EPERM for this user */
    XRT_SYS_WHY_NOT_SUPPORTED,   /* Linux has no unprivileged source for it */
    XRT_SYS_WHY_PARSE_ERROR,     /* source present but unreadable format */
    XRT_SYS_WHY_LIMIT,           /* capacity or time budget reached */
    XRT_SYS_WHY_REDACTED,        /* hidden by redaction mode */
    XRT_SYS_WHY_GONE,            /* object vanished during the sample */
    XRT_SYS_WHY_IO_ERROR,        /* other read error */
    XRT_SYS_WHY_COUNTER_RESET,   /* counter went backwards; rate skipped */
    XRT_SYS_WHY_NO_MANAGER,      /* no supported service/package manager */
    XRT_SYS_WHY_SLOW_SOURCE,     /* STALE: source costs > 1 ms (i2c, SMART); refreshed every 5 s */
    XRT_SYS_WHY_TOO_SOON,        /* no clock tick elapsed since the previous sample */
    XRT_SYS_WHY_COUNT
};

/* Short stable lower-case text: "ok", "first sample", "needs privilege", ... */
const char *xrt_sys_reason_text(enum xrt_sys_reason);
const char *xrt_sys_state_text(enum xrt_sys_state);

struct xrt_sys_u64 { uint64_t v; uint8_t st, why; };
struct xrt_sys_f64 { double v; uint8_t st, why; };
/* Strings are always NUL-terminated; on non-OK state s is "". */
struct xrt_sys_name { char s[64]; uint8_t st, why; };

/* Group ids double as bit positions in masks (1u << id). */
enum xrt_sys_group_id {
    XRT_SYS_G_SUMMARY,
    XRT_SYS_G_CPU,
    XRT_SYS_G_MEMORY,
    XRT_SYS_G_DISKS,
    XRT_SYS_G_FILESYSTEMS,
    XRT_SYS_G_NETWORK,
    XRT_SYS_G_CONNECTIONS,
    XRT_SYS_G_POWER,      /* hwmon sensors, GPUs, RAPL */
    XRT_SYS_G_USERS,
    XRT_SYS_G_SERVICES,
    XRT_SYS_G_APPS,
    XRT_SYS_G_PROCESSES,
    XRT_SYS_G_SYSINFO,
    XRT_SYS_G_COUNT
};
#define XRT_SYS_ALL_GROUPS ((1u << XRT_SYS_G_COUNT) - 1u)
const char *xrt_sys_group_name(enum xrt_sys_group_id); /* "cpu", "memory", ... */

/* Per-group outcome of one sample. st=OK means the group was collected (its
 * fields still carry their own states). detail is a short human reason such
 * as "process metadata: permission denied"; never contains secrets. */
struct xrt_sys_group {
    uint8_t st, why;
    int32_t err;          /* errno of the deciding failure, else 0 */
    uint64_t cost_ns;     /* wall time spent on this group */
    uint64_t interval_ns; /* since this group's previous collection; 0 on its first */
    char detail[96];
};

struct xrt_sys_psi {  /* /proc/pressure/<x>; percent of wall time stalled */
    struct xrt_sys_f64 some_avg10, some_avg60, some_avg300;
    struct xrt_sys_f64 full_avg10, full_avg60, full_avg300;
    struct xrt_sys_f64 some_pct, full_pct; /* over this sample interval */
};

struct xrt_sys_summary {
    struct xrt_sys_f64 uptime_s, load1, load5, load15;
    struct xrt_sys_u64 boot_time_s;          /* unix seconds */
    struct xrt_sys_u64 processes, threads;   /* all tasks on the system */
    struct xrt_sys_u64 running, blocked;     /* procs_running/procs_blocked */
    struct xrt_sys_f64 context_switches_ps, interrupts_ps, forks_ps;
    struct xrt_sys_f64 cpu_busy_pct;         /* all CPUs */
    struct xrt_sys_f64 memory_used_pct;
};

struct xrt_sys_cpu_times { /* percent of this CPU over the interval */
    struct xrt_sys_f64 user, nice, system, idle, iowait, irq, softirq, steal, guest, busy;
};

#define XRT_SYS_MAX_CPUS 512
struct xrt_sys_cpu {
    int32_t id;                  /* logical cpu number */
    struct xrt_sys_u64 online;   /* 1 or 0 */
    struct xrt_sys_cpu_times t;
    struct xrt_sys_f64 freq_mhz, freq_min_mhz, freq_max_mhz;
    /* topology: package, die, core; l3_id groups a CCX (shared L3);
     * smt_index is the position within the core's thread siblings. */
    struct xrt_sys_u64 package_id, die_id, core_id, l3_id, smt_index;
    struct xrt_sys_f64 temp_c;   /* per-core sensor (coretemp); often absent */
};

struct xrt_sys_reading { char chip[32], label[48]; struct xrt_sys_f64 value; };

struct xrt_sys_cpus {
    struct xrt_sys_name model, freq_driver, governor, epp;
    struct xrt_sys_u64 logical, online, cores, packages, l3_groups;
    struct xrt_sys_cpu_times total;
    struct xrt_sys_f64 package_temp_c;       /* k10temp Tctl / coretemp Package */
    struct xrt_sys_psi psi;
    uint32_t temp_count;                     /* CPU-chip temps (Tccd1, ...) */
    struct xrt_sys_reading temps[16];
    uint32_t count;
    struct xrt_sys_cpu cpu[XRT_SYS_MAX_CPUS];
};

struct xrt_sys_memory {
    struct xrt_sys_u64 total, free, available, used; /* used = total - available */
    struct xrt_sys_u64 cached, buffers, shmem, slab_reclaimable, slab_unreclaimable;
    struct xrt_sys_u64 dirty, writeback, anon, mapped, page_tables;
    struct xrt_sys_u64 commit_limit, committed;
    struct xrt_sys_u64 swap_total, swap_free, swap_used, swap_cached;
    struct xrt_sys_u64 zswap_pool, zswap_stored; /* compressed / original bytes */
    struct xrt_sys_u64 zswap_enabled;            /* 1/0 from module parameter */
    struct xrt_sys_f64 page_faults_ps, major_faults_ps, swap_in_ps, swap_out_ps; /* pages/s */
    struct xrt_sys_psi psi;
};

#define XRT_SYS_MAX_DISKS 64
struct xrt_sys_disk {   /* whole block devices; partitions are in filesystems */
    char name[32];
    struct xrt_sys_name model;
    struct xrt_sys_u64 size_bytes, rotational, removable;
    struct xrt_sys_u64 read_bytes, write_bytes;     /* totals since boot */
    struct xrt_sys_f64 read_bps, write_bps, read_iops, write_iops;
    struct xrt_sys_f64 busy_pct;                    /* io_ticks delta / interval */
    struct xrt_sys_f64 queue_depth;                 /* weighted io_ticks delta / interval */
    struct xrt_sys_f64 avg_latency_ms;              /* (rd+wr ticks) / ops in interval */
    struct xrt_sys_u64 in_flight;
    struct xrt_sys_f64 temp_c;                      /* nvme hwmon Composite */
};
struct xrt_sys_disks {
    uint32_t count;
    struct xrt_sys_disk disk[XRT_SYS_MAX_DISKS];
    struct xrt_sys_psi psi;                          /* io pressure */
};

#define XRT_SYS_MAX_FILESYSTEMS 128
struct xrt_sys_filesystem {
    struct xrt_sys_name mount;   /* redacted unless a common system path */
    struct xrt_sys_name source;  /* /dev/... kept; others redacted */
    char fstype[24];
    struct xrt_sys_u64 total, free, avail, used, inodes_total, inodes_free, read_only;
    struct xrt_sys_f64 used_pct; /* used / (used + avail), as df */
};
struct xrt_sys_filesystems {
    uint32_t count, skipped_pseudo, skipped_duplicate;
    struct xrt_sys_filesystem fs[XRT_SYS_MAX_FILESYSTEMS];
};

#define XRT_SYS_MAX_IFACES 64
#define XRT_SYS_MAX_ADDRS 8
struct xrt_sys_iface {
    char name[32];
    struct xrt_sys_name operstate;          /* "up", "down", "unknown", ... */
    struct xrt_sys_u64 carrier, speed_mbps, mtu, loopback, physical;
    struct xrt_sys_name mac;                /* redacted in redaction mode */
    struct xrt_sys_u64 rx_bytes, tx_bytes;  /* totals */
    struct xrt_sys_f64 rx_bps, tx_bps, rx_pps, tx_pps, rx_errors_ps, tx_errors_ps, rx_drops_ps, tx_drops_ps;
    uint32_t addr_count;
    uint8_t addr_family[XRT_SYS_MAX_ADDRS]; /* 4 or 6 */
    struct xrt_sys_name addr[XRT_SYS_MAX_ADDRS]; /* "a.b.c.d/len"; redacted per rule */
    struct xrt_sys_name kind;               /* "physical", "loopback", "bridge", "virtual" (veth, tun, ...) */
};
struct xrt_sys_network {
    uint32_t count;
    struct xrt_sys_iface iface[XRT_SYS_MAX_IFACES];
    struct xrt_sys_f64 rx_bps, tx_bps;      /* physical interfaces only (no double counting) */
};

enum xrt_sys_proto { XRT_SYS_TCP = 1, XRT_SYS_UDP = 2, XRT_SYS_UNIX = 3 };
struct xrt_sys_conn {
    uint8_t proto, family;                  /* family 4, 6 or 0 for unix */
    char state[16];                         /* "ESTABLISHED", "LISTEN", "UNCONN", ... */
    struct xrt_sys_name local, remote;      /* "addr:port" or unix path */
    uint64_t inode;
    struct xrt_sys_u64 uid;
    struct xrt_sys_u64 pid;                 /* owner, via fd inode scan */
    char comm[16];                          /* owner comm when pid is OK */
    struct xrt_sys_u64 rx_queue, tx_queue;
};
struct xrt_sys_connections {
    uint32_t count, capacity, truncated;     /* truncated: dropped past capacity */
    struct xrt_sys_conn *conn;               /* owned by the snapshot */
    struct xrt_sys_u64 tcp, udp, unix_sockets, listening, established;
    struct xrt_sys_u64 owners_unresolved;    /* sockets whose owner we cannot see */
};

enum xrt_sys_sensor_kind {
    XRT_SYS_TEMP = 1, XRT_SYS_FAN, XRT_SYS_VOLTAGE, XRT_SYS_CURRENT,
    XRT_SYS_POWER_W, XRT_SYS_ENERGY_J, XRT_SYS_FREQ_MHZ, XRT_SYS_HUMIDITY, XRT_SYS_PWM_PCT
};
#define XRT_SYS_MAX_SENSORS 256
struct xrt_sys_sensor {
    char chip[32], label[48];               /* hwmon name, label or input name */
    uint8_t kind;                           /* xrt_sys_sensor_kind */
    struct xrt_sys_f64 value, max, crit;    /* units by kind: C, RPM, V, A, W, J, MHz, %RH, % */
};
#define XRT_SYS_MAX_GPUS 8
struct xrt_sys_gpu {
    char card[16], driver[24];
    struct xrt_sys_name name;               /* "1002:164e" or product name */
    struct xrt_sys_f64 busy_pct, power_w, temp_c;
    struct xrt_sys_f64 graphics_mhz, memory_mhz;
    struct xrt_sys_u64 vram_used, vram_total;
};
struct xrt_sys_power {
    uint32_t sensor_count;
    struct xrt_sys_sensor sensor[XRT_SYS_MAX_SENSORS];
    uint32_t gpu_count;
    struct xrt_sys_gpu gpu[XRT_SYS_MAX_GPUS];
    struct xrt_sys_f64 cpu_package_w;       /* RAPL energy delta; often needs privilege */
    struct xrt_sys_f64 ac_online, battery_pct;
};

#define XRT_SYS_MAX_USERS 64
struct xrt_sys_user {
    struct xrt_sys_name user, host;         /* host is always redacted in redaction mode */
    char line[32];
    struct xrt_sys_u64 pid, login_time_s;
};
struct xrt_sys_users { uint32_t count; struct xrt_sys_user user[XRT_SYS_MAX_USERS]; };

#define XRT_SYS_MAX_SERVICES 512
struct xrt_sys_path { char s[1024]; uint8_t st, why; };
struct xrt_sys_service {
    char name[64];                         /* stat comm; never a unit/config name */
    struct xrt_sys_name state, user;       /* process state; numeric effective uid */
    struct xrt_sys_u64 pid, start_ticks, uid, loginuid, rss;
    struct xrt_sys_f64 uptime_s, cpu_pct;   /* CPU: percent of one core */
    struct xrt_sys_path cgroup;
};
struct xrt_sys_services {
    struct xrt_sys_name manager;            /* "init: <PID 1 comm>", informational */
    uint32_t count, scanned, unreadable, truncated, visibility_limited; /* partial inventory */
    struct xrt_sys_service service[XRT_SYS_MAX_SERVICES];
};

struct xrt_sys_package { char name[64], version[48]; struct xrt_sys_u64 size; };
struct xrt_sys_apps {
    struct xrt_sys_name manager;            /* "pacman" */
    struct xrt_sys_u64 count, total_size;
    uint32_t list_count, list_capacity, truncated;
    struct xrt_sys_package *list;           /* largest first; owned by the snapshot */
};

struct xrt_sys_proc {
    int32_t pid;
    uint64_t start_ticks;                   /* identity = (pid, start_ticks) */
    struct xrt_sys_u64 ppid;
    struct xrt_sys_f64 start_s;             /* seconds after boot */
    char comm[32];
    struct xrt_sys_name cmdline;            /* truncated; spaces for NULs */
    char state;                             /* R S D Z T t I X ... */
    struct xrt_sys_u64 uid;                 /* effective uid; /proc/PID/status when the inode says root */
    struct xrt_sys_name user;
    struct xrt_sys_u64 threads, rss, pss, vsize;
    struct xrt_sys_f64 cpu_pct;             /* 100 = one logical CPU */
    struct xrt_sys_u64 cpu_time_ns;
    struct xrt_sys_f64 io_read_bps, io_write_bps;   /* /proc/PID/io storage bytes */
    struct xrt_sys_u64 io_read_bytes, io_write_bytes;
    struct xrt_sys_f64 net_bps;             /* no unprivileged per-process source */
    struct xrt_sys_u64 fds;
    struct xrt_sys_u64 nice, kernel_thread;  /* nice is biased by +20: 0..39 */
    struct xrt_sys_name cgroup;
};
struct xrt_sys_processes {
    uint32_t count, capacity, truncated;
    struct xrt_sys_proc *proc;              /* sorted by pid; owned by the snapshot */
};

struct xrt_sys_info {
    struct xrt_sys_name hostname;           /* only with XRT_SYS_SHOW_HOSTNAME */
    struct xrt_sys_name kernel, os, arch, cpu_model, init, package_manager;
    struct xrt_sys_u64 logical_cpus, physical_cores, memory_total;
    uint32_t gpu_count;
    struct xrt_sys_name gpu[XRT_SYS_MAX_GPUS]; /* "amdgpu 1002:164e" */
};

struct xrt_sys_self { /* collector cost for this sample */
    struct xrt_sys_f64 wall_ms, cpu_ms, cpu_pct_of_core; /* cpu over the interval */
    struct xrt_sys_u64 syscalls;            /* counted at our call sites: an estimate */
    struct xrt_sys_u64 files_opened, bytes_read, rss;
};

struct xrt_sys_snapshot {
    uint32_t abi;                           /* XRT_SYS_ABI */
    uint32_t groups;                        /* requested mask */
    uint32_t redacted;                      /* 1 when redaction mode was on */
    uint64_t sequence;                      /* 1 for the first sample */
    int64_t realtime_ns, monotonic_ns;
    struct xrt_sys_f64 interval_s;          /* since the previous sample */
    struct xrt_sys_group group[XRT_SYS_G_COUNT];
    struct xrt_sys_summary summary;
    struct xrt_sys_cpus cpu;
    struct xrt_sys_memory memory;
    struct xrt_sys_disks disks;
    struct xrt_sys_filesystems filesystems;
    struct xrt_sys_network network;
    struct xrt_sys_connections connections;
    struct xrt_sys_power power;
    struct xrt_sys_users users;
    struct xrt_sys_services services;
    struct xrt_sys_apps apps;
    struct xrt_sys_processes processes;
    struct xrt_sys_info info;
    struct xrt_sys_self self;
};

enum xrt_sys_flag {
    XRT_SYS_REDACT = 1u << 0,        /* hide users, hosts, cmdlines, MACs, non-loopback addrs, private mounts */
    XRT_SYS_SHOW_HOSTNAME = 1u << 1, /* otherwise hostname is REDACTED */
    XRT_SYS_PSS = 1u << 2,           /* read smaps_rollup (slow); otherwise pss NOT_COLLECTED */
    XRT_SYS_LIGHT_PROCESSES = 1u << 3 /* skip per-process io/fd counts; socket ownership still scans fds */
};

struct xrt_sys_limits {
    const char *root;           /* NULL: live system. Else a fixture tree with
                                   proc/, sys/, etc/, run/, var/ (tests). With a
                                   root, sockets, statvfs and getifaddrs are
                                   reported UNAVAILABLE/NOT_SUPPORTED. */
    uint32_t groups;            /* default XRT_SYS_ALL_GROUPS; change per sample */
    uint32_t flags;             /* xrt_sys_flag */
    uint32_t max_processes;     /* default 8192 */
    uint32_t max_connections;   /* default 8192 */
    uint32_t max_packages;      /* default 4096 (list only; count/size are full) */
    uint32_t max_fds_counted;   /* per process; default 4096, beyond: LIMIT */
    uint64_t budget_ns;         /* soft wall budget per sample; default 500 ms.
                                   Groups not reached are STALE/LIMIT. */
    uint32_t apps_rescan_s;     /* package db rescan period; default 60 */
    uint8_t sensor_timing_disabled; /* opt out of wall-time slow classification for deterministic fixtures */
};
void xrt_sys_limits_default(struct xrt_sys_limits *);

struct xrt_sys;
/* Copies limits (root string included). Returns NULL only on allocation failure. */
struct xrt_sys *xrt_sys_open(const struct xrt_sys_limits *);
void xrt_sys_close(struct xrt_sys *);
/* Change groups/flags between samples. A group's rates span from its own
 * previous collection (group[g].interval_ns), so a view can sample processes
 * at 1 Hz and CPU/network at 4 Hz from one context. */
void xrt_sys_configure(struct xrt_sys *, uint32_t groups, uint32_t flags);
/* Fills *out (any previous content is freed first, so pass a zeroed or
 * previously sampled snapshot). Returns XRT_OK unless allocation failed;
 * per-field failures are states, not errors. */
enum xrt_status xrt_sys_sample(struct xrt_sys *, struct xrt_sys_snapshot *out);
enum xrt_status xrt_sys_snapshot_copy(struct xrt_sys_snapshot *dst, const struct xrt_sys_snapshot *src);
void xrt_sys_snapshot_free(struct xrt_sys_snapshot *); /* leaves it zeroed */
/* Redact an owned copy without sampling or changing the collector/cache. */
void xrt_sys_snapshot_redact(struct xrt_sys_snapshot *);

/* JSON for MCP and tools. A value is a bare number/string when OK,
 * {"v":x,"state":"stale","why":"..."} when stale and
 * {"state":"unavailable","why":"needs privilege"} otherwise. */
enum xrt_sys_sort {
    XRT_SYS_SORT_PID, XRT_SYS_SORT_CPU, XRT_SYS_SORT_MEMORY,
    XRT_SYS_SORT_IO, XRT_SYS_SORT_FDS, XRT_SYS_SORT_THREADS, XRT_SYS_SORT_START
};
struct xrt_sys_json_opts {
    uint32_t groups;            /* subset of snapshot->groups to emit */
    uint32_t sort;              /* xrt_sys_sort, processes only */
    uint32_t limit;             /* max processes/connections/sensors rows; 0 = all */
    int32_t pid;                /* > 0: only this process (and its connections) */
};
/* Returns a malloc'd NUL-terminated string (caller frees) or NULL on OOM. */
char *xrt_sys_json(const struct xrt_sys_snapshot *, const struct xrt_sys_json_opts *);
#endif
