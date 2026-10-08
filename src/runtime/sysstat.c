#define _GNU_SOURCE 1
#define _FILE_OFFSET_BITS 64
/* Whole-system observer: /proc, /sys, sock_diag, statvfs, utmp, package db.
 * Read-only and unprivileged; every failure becomes a field state. */
#include "xrt_sysstat.h"
#include "sysstat_nvml.h"
#include <arpa/inet.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <inttypes.h>
#include <limits.h>
#include <linux/inet_diag.h>
#include <linux/netlink.h>
#include <linux/rtnetlink.h>
#include <linux/sock_diag.h>
#include <linux/unix_diag.h>
#include <net/if.h>
#include <netinet/in.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/syscall.h>
#include <sys/utsname.h>
#include <time.h>
#include <unistd.h>
#include <utmp.h>

#define OK(f, val) ((f).v = (val), (f).st = XRT_SYS_OK, (f).why = XRT_SYS_WHY_NONE)
#define NA(f, w) ((f).st = XRT_SYS_UNAVAILABLE, (f).why = (uint8_t)(w))
#define ISOK(f) ((f).st == XRT_SYS_OK)
#define COUNT_OF(a) (sizeof(a) / sizeof((a)[0]))

enum { CPU_FIELDS = 10, DISK_FIELDS = 11, IF_FIELDS = 8, MAX_SENSOR_SRC = XRT_SYS_MAX_SENSORS,
       MAX_SOCK_MAP = 1 << 18, BUF = 1 << 16 };
#define SLOW_SENSOR_NS 1000000LL                /* sustained reads slower than 1 ms ... */
#define SLOW_SENSOR_READS 3u                    /* isolated preemption is not a slow source */
#define SLOW_SENSOR_PERIOD_NS 5000000000LL      /* ... are refreshed every 5 s */

struct service_prev { uint64_t pid, start, ticks; int64_t mono; };
struct psi_prev { uint64_t some, full; uint8_t have_some, have_full; };
struct disk_prev {
    char name[32];
    uint64_t f[DISK_FIELDS];
    uint64_t attr_seq; /* static attributes below were read at this sample */
    struct xrt_sys_u64 size_bytes, rotational, removable;
    struct xrt_sys_name model;
};
struct if_prev { char name[32]; uint64_t f[IF_FIELDS]; };
struct sensor_src {
    char chip[32], label[48], path[160];
    uint8_t kind;
    double scale;
    struct xrt_sys_f64 max, crit;
    char device[32]; /* hwmon device link basename, e.g. nvme0 */
    int64_t read_mono; /* slow sources (i2c, SMART) are throttled */
    uint8_t slow_reads; /* consecutive successful reads over the wall-time threshold */
    struct xrt_sys_f64 last;
};
struct sock_owner { uint64_t inode; int32_t pid; };
struct pw { uint32_t uid; char name[32]; };
/* Bounded read-only /proc stat handles avoid repeated path walks at 1 Hz.
 * A proc descriptor pins the task: an exited task returns ESRCH, never a
 * replacement with the same PID. Failed/uncached opens retain the slow path. */
#define PROC_STAT_SLOTS 4096
struct proc_stat_fd { int32_t pid; int fd; uint64_t seen; };
struct topo { struct xrt_sys_u64 package_id, die_id, core_id, l3_id, smt_index; struct xrt_sys_f64 fmin, fmax; uint8_t done; };

struct xrt_sys {
    struct xrt_sys_limits lim;
    struct xrt_sys_nvml *nvml;
    char root[PATH_MAX];
    int live;
    long hz, page;
    uid_t euid;
    uint64_t seq, proc_seq;
    struct proc_stat_fd stat_fd[PROC_STAT_SLOTS];
    uint32_t stat_fd_count, stat_fd_limit;
    int64_t group_mono[XRT_SYS_G_COUNT]; /* last time each group was collected */
    int64_t t0;
    /* per-sample counters */
    uint64_t syscalls, opened, bytes;
    /* cpu */
    uint64_t cpu_prev[XRT_SYS_MAX_CPUS + 1][CPU_FIELDS];
    uint8_t cpu_have[XRT_SYS_MAX_CPUS + 1];
    uint64_t ctxt, intr, forks;
    uint8_t stat_have;
    struct topo topo[XRT_SYS_MAX_CPUS];
    uint32_t topo_online;
    struct psi_prev psi[3]; /* cpu, memory, io */
    uint64_t vm_prev[4];
    uint8_t vm_have;
    struct disk_prev disk_prev[XRT_SYS_MAX_DISKS];
    uint32_t disk_prev_count;
    struct if_prev if_prev[XRT_SYS_MAX_IFACES];
    uint32_t if_prev_count;
    struct sensor_src sensors[MAX_SENSOR_SRC];
    uint32_t sensor_count;
    int64_t sensor_scan_mono;
    uint64_t rapl_prev, rapl_range;
    int64_t rapl_mono;
    uint8_t rapl_have;
    /* processes from the previous sample, sorted by pid */
    struct xrt_sys_proc *prev;
    uint32_t prev_count;
    struct sock_owner *owners;
    uint32_t owner_count, owner_cap;
    uint8_t owners_limited, owners_denied; /* map overflow; an own process's fds were unreadable */
    struct pw *pw;
    uint32_t pw_count;
    int64_t pw_mtime;
    /* package db cache */
    struct xrt_sys_package *pkgs;
    uint32_t pkg_count;
    uint64_t pkg_total;
    int64_t pkg_scan_mono, pkg_mtime;
    uint8_t pkg_state, pkg_why;
    char pkg_detail[96];
    /* Only identities/counters persist; rows are rebuilt from /proc each sample. */
    struct service_prev svc_prev[XRT_SYS_MAX_SERVICES];
    uint32_t svc_prev_count;
    int64_t self_cpu_prev, self_mono_prev;
    struct xrt_sys_name model;
    struct xrt_sys_u64 proc_count;
    int64_t proc_count_mono;
    char buf[BUF];
};

const char *xrt_sys_reason_text(enum xrt_sys_reason why)
{
    static const char *const text[] = {"ok", "not collected", "first sample", "not present",
                                       "needs privilege", "not supported", "parse error", "limit reached",
                                       "redacted", "gone", "io error", "counter reset", "no manager",
                                       "slow source, refreshed every 5 s", "interval too short"};
    return (unsigned)why < COUNT_OF(text) ? text[why] : "unknown";
}
const char *xrt_sys_state_text(enum xrt_sys_state st)
{
    static const char *const text[] = {"unset", "ok", "unavailable", "stale"};
    return (unsigned)st < COUNT_OF(text) ? text[st] : "unknown";
}
const char *xrt_sys_group_name(enum xrt_sys_group_id g)
{
    static const char *const text[] = {"summary", "cpu", "memory", "disks", "filesystems", "network", "connections",
                                       "power", "users", "services", "apps", "processes", "sysinfo"};
    return (unsigned)g < COUNT_OF(text) ? text[g] : "unknown";
}

static uint8_t why_errno(int e)
{
    if (e == EACCES || e == EPERM) return XRT_SYS_WHY_NEEDS_PRIVILEGE;
    if (e == ENOENT || e == ENOTDIR || e == ENODEV || e == ENXIO || e == EINVAL || e == EOPNOTSUPP) return XRT_SYS_WHY_NOT_PRESENT;
    if (e == ESRCH) return XRT_SYS_WHY_GONE;
    if (e == EBADMSG) return XRT_SYS_WHY_PARSE_ERROR;
    return XRT_SYS_WHY_IO_ERROR;
}

static int64_t mono_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000 + ts.tv_nsec;
}
static int64_t clock_ns(clockid_t id)
{
    struct timespec ts;
    if (clock_gettime(id, &ts) != 0) return 0;
    return (int64_t)ts.tv_sec * 1000000000 + ts.tv_nsec;
}

static void copy_str(char *dst, size_t cap, const char *src)
{
    size_t n = strlen(src);
    if (n >= cap) n = cap - 1;
    memcpy(dst, src, n);
    dst[n] = 0;
}
static void set_name(struct xrt_sys_name *f, const char *s)
{
    copy_str(f->s, sizeof f->s, s);
    f->st = XRT_SYS_OK;
    f->why = XRT_SYS_WHY_NONE;
}
static void na_name(struct xrt_sys_name *f, uint8_t why)
{
    f->s[0] = 0;
    NA(*f, why);
}
static void trim(char *s)
{
    size_t n = strlen(s);
    while (n && (s[n - 1] == '\n' || s[n - 1] == ' ' || s[n - 1] == '\t')) s[--n] = 0;
}

static const char *path_of(struct xrt_sys *s, const char *path, char *out, size_t cap)
{
    if (s->live) return path;
    size_t r = strlen(s->root), n = strlen(path);
    if (r + n + 1 > cap) n = cap - r - 1; /* root is bounded at open */
    memcpy(out, s->root, r);
    memcpy(out + r, path, n);
    out[r + n] = 0;
    return out;
}
static int sys_open(struct xrt_sys *s, const char *path, int flags)
{
    char full[PATH_MAX];
    s->syscalls++;
    int fd = open(path_of(s, path, full, sizeof full), O_RDONLY | O_CLOEXEC | flags);
    if (fd >= 0) s->opened++;
    return fd;
}
static int sys_openat(struct xrt_sys *s, int dir, const char *name, int flags)
{
    s->syscalls++;
    int fd = openat(dir, name, O_RDONLY | O_CLOEXEC | flags);
    if (fd >= 0) s->opened++;
    return fd;
}
static void sys_close(struct xrt_sys *s, int fd)
{
    s->syscalls++;
    close(fd);
}
/* Reads up to cap-1 bytes; NUL-terminates. Returns length or -errno. */
static ssize_t read_fd(struct xrt_sys *s, int fd, char *buf, size_t cap)
{
    size_t n = 0;
    while (n + 1 < cap) {
        s->syscalls++;
        ssize_t r = read(fd, buf + n, cap - 1 - n);
        if (r < 0) {
            if (errno == EINTR) continue;
            int e = errno;
            buf[n] = 0;
            return -e;
        }
        if (r == 0) break;
        n += (size_t)r;
        if ((size_t)r < cap - 1 - (n - (size_t)r)) break; /* short read: proc/sysfs/regular EOF */
    }
    buf[n] = 0;
    s->bytes += n;
    return (ssize_t)n;
}
static ssize_t rd(struct xrt_sys *s, const char *path, char *buf, size_t cap)
{
    int fd = sys_open(s, path, 0);
    if (fd < 0) {
        buf[0] = 0;
        return -errno;
    }
    ssize_t n = read_fd(s, fd, buf, cap);
    sys_close(s, fd);
    return n;
}
static ssize_t rdat(struct xrt_sys *s, int dir, const char *name, char *buf, size_t cap)
{
    int fd = sys_openat(s, dir, name, 0);
    if (fd < 0) {
        buf[0] = 0;
        return -errno;
    }
    ssize_t n = read_fd(s, fd, buf, cap);
    sys_close(s, fd);
    return n;
}
static ssize_t rdf(struct xrt_sys *s, char *buf, size_t cap, const char *fmt, ...) __attribute__((format(printf, 4, 5)));
static ssize_t rdf(struct xrt_sys *s, char *buf, size_t cap, const char *fmt, ...)
{
    char path[PATH_MAX];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(path, sizeof path, fmt, ap);
    va_end(ap);
    return rd(s, path, buf, cap);
}
/* Integer file -> value or -errno (-EBADMSG on bad text). */
static int parse_i64(const char *t, int64_t *v)
{
    char *end;
    errno = 0;
    long long x = strtoll(t, &end, 10);
    if (end == t || errno) return -EBADMSG;
    *v = x;
    return 0;
}
static int read_i64(struct xrt_sys *s, const char *path, int64_t *v)
{
    char b[64];
    ssize_t n = rd(s, path, b, sizeof b);
    if (n < 0) return (int)n;
    return parse_i64(b, v);
}
static void get_u64(struct xrt_sys *s, struct xrt_sys_u64 *f, const char *path)
{
    int64_t v;
    int r = read_i64(s, path, &v);
    if (r == 0 && v >= 0) OK(*f, (uint64_t)v);
    else NA(*f, r ? why_errno(-r) : XRT_SYS_WHY_PARSE_ERROR);
}
static void get_f64(struct xrt_sys *s, struct xrt_sys_f64 *f, const char *path, double scale)
{
    int64_t v;
    int r = read_i64(s, path, &v);
    if (r == 0) OK(*f, (double)v * scale);
    else NA(*f, why_errno(-r));
}
static void get_name(struct xrt_sys *s, struct xrt_sys_name *f, const char *path)
{
    char b[256];
    ssize_t n = rd(s, path, b, sizeof b);
    if (n < 0) {
        na_name(f, why_errno((int)-n));
        return;
    }
    trim(b);
    set_name(f, b);
}

static void rate(struct xrt_sys_f64 *f, uint64_t now, uint64_t prev, int have, double dt, double scale)
{
    if (!have || dt <= 0) NA(*f, XRT_SYS_WHY_FIRST_SAMPLE);
    else if (now < prev) NA(*f, XRT_SYS_WHY_COUNTER_RESET);
    else OK(*f, (double)(now - prev) * scale / dt);
}
static void detail(struct xrt_sys_group *g, int err, const char *fmt, ...) __attribute__((format(printf, 3, 4)));
static void detail(struct xrt_sys_group *g, int err, const char *fmt, ...)
{
    size_t n = strlen(g->detail);
    if (n && n + 3 < sizeof g->detail) {
        memcpy(g->detail + n, "; ", 3);
        n += 2;
    }
    if (n + 1 >= sizeof g->detail) return;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(g->detail + n, sizeof g->detail - n, fmt, ap);
    va_end(ap);
    if (err && !g->err) g->err = err;
}

/* The group's primary source failed: the group itself is unavailable. */
static void fail(struct xrt_sys_group *g, int err, const char *what)
{
    g->st = XRT_SYS_UNAVAILABLE;
    g->why = why_errno(err);
    detail(g, err, "%s: %s", what, strerror(err));
}

/* ---- redaction ---- */
static int system_mount(const char *m)
{
    static const char *const keep[] = {"/", "/boot", "/efi", "/home", "/tmp", "/usr", "/opt", "/srv", "/var", "/nix", "/root"};
    for (size_t i = 0; i < COUNT_OF(keep); ++i)
        if (!strcmp(m, keep[i])) return 1;
    return !strncmp(m, "/boot/", 6) || !strncmp(m, "/var/", 5) || !strncmp(m, "/usr/", 5);
}
static int loopback_addr(int family, const void *a)
{
    if (family == AF_INET) {
        const uint8_t *b = a;
        return b[0] == 127 || !(b[0] | b[1] | b[2] | b[3]);
    }
    const struct in6_addr *x = a;
    static const uint8_t zero[16];
    if (IN6_IS_ADDR_LOOPBACK(x) || !memcmp(x, zero, 16)) return 1;
    return IN6_IS_ADDR_V4MAPPED(x) && x->s6_addr[12] == 127;
}

/* ---- PSI ---- */
static void psi_read(struct xrt_sys *s, int which, struct xrt_sys_psi *p, double dt, int have_dt)
{
    static const char *const name[] = {"/proc/pressure/cpu", "/proc/pressure/memory", "/proc/pressure/io"};
    struct psi_prev *pp = &s->psi[which];
    char b[512];
    ssize_t n = rd(s, name[which], b, sizeof b);
    struct xrt_sys_f64 *some[] = {&p->some_avg10, &p->some_avg60, &p->some_avg300, &p->some_pct};
    struct xrt_sys_f64 *full[] = {&p->full_avg10, &p->full_avg60, &p->full_avg300, &p->full_pct};
    for (int i = 0; i < 4; ++i) {
        NA(*some[i], n < 0 ? why_errno((int)-n) : XRT_SYS_WHY_NOT_PRESENT);
        NA(*full[i], n < 0 ? why_errno((int)-n) : XRT_SYS_WHY_NOT_PRESENT);
    }
    if (n < 0) {
        pp->have_some = pp->have_full = 0;
        return;
    }
    for (char *line = b; line && *line;) {
        char *next = strchr(line, '\n');
        if (next) *next++ = 0;
        double a10, a60, a300;
        unsigned long long total;
        int is_full = !strncmp(line, "full ", 5);
        if ((is_full || !strncmp(line, "some ", 5)) &&
            sscanf(line + 5, "avg10=%lf avg60=%lf avg300=%lf total=%llu", &a10, &a60, &a300, &total) == 4) {
            struct xrt_sys_f64 **f = is_full ? full : some;
            OK(*f[0], a10);
            OK(*f[1], a60);
            OK(*f[2], a300);
            uint64_t *prev = is_full ? &pp->full : &pp->some;
            uint8_t *have = is_full ? &pp->have_full : &pp->have_some;
            rate(f[3], total, *prev, *have && have_dt, dt, 1e-4); /* us per s -> percent */
            *prev = total;
            *have = 1;
        }
        line = next;
    }
}

/* ---- /proc/stat: cpu times and summary counters ---- */
static void cpu_times(struct xrt_sys_cpu_times *t, const uint64_t *now, const uint64_t *prev, int have)
{
    struct xrt_sys_f64 *f[] = {&t->user, &t->nice, &t->system, &t->idle, &t->iowait, &t->irq, &t->softirq, &t->steal};
    uint64_t total = 0, d[CPU_FIELDS];
    int reset = 0;
    for (int i = 0; i < CPU_FIELDS; ++i) {
        d[i] = have && now[i] >= prev[i] ? now[i] - prev[i] : 0;
        if (have && now[i] < prev[i]) reset = 1;
    }
    /* user and nice include guest and guest_nice; total excludes them once */
    for (int i = 0; i < 8; ++i) total += d[i];
    for (int i = 0; i < 8; ++i) {
        if (!have) NA(*f[i], XRT_SYS_WHY_FIRST_SAMPLE);
        else if (reset) NA(*f[i], XRT_SYS_WHY_COUNTER_RESET);
        else if (!total) NA(*f[i], XRT_SYS_WHY_TOO_SOON);
        else OK(*f[i], 100.0 * (double)d[i] / (double)total);
    }
    if (ISOK(t->user)) {
        OK(t->guest, 100.0 * (double)(d[8] + d[9]) / (double)total);
        OK(t->busy, 100.0 - t->idle.v - t->iowait.v);
        if (t->busy.v < 0) t->busy.v = 0;
    } else {
        NA(t->guest, t->user.why);
        NA(t->busy, t->user.why);
    }
}

static void parse_stat(struct xrt_sys *s, struct xrt_sys_snapshot *snap, double dt, int have_dt, int summary)
{
    struct xrt_sys_cpus *c = &snap->cpu;
    struct xrt_sys_summary *sm = &snap->summary;
    ssize_t n = rd(s, "/proc/stat", s->buf, sizeof s->buf);
    if (n < 0) {
        if (snap->groups & (1u << XRT_SYS_G_CPU)) fail(&snap->group[XRT_SYS_G_CPU], (int)-n, "/proc/stat");
        if (summary) detail(&snap->group[XRT_SYS_G_SUMMARY], (int)-n, "/proc/stat: %s", strerror((int)-n));
        return;
    }
    uint8_t seen[XRT_SYS_MAX_CPUS] = {0};
    for (char *line = s->buf; line && *line;) {
        char *next = strchr(line, '\n');
        if (next) *next++ = 0;
        unsigned long long v[CPU_FIELDS] = {0}, x;
        if (!strncmp(line, "cpu", 3)) {
            int id = -1, off = 0;
            if (line[3] == ' ') off = 3;
            else if (sscanf(line + 3, "%d%n", &id, &off) == 1) off += 3;
            else id = -2;
            if (id >= -1 && id < XRT_SYS_MAX_CPUS) {
                int got = sscanf(line + off, "%llu %llu %llu %llu %llu %llu %llu %llu %llu %llu", &v[0], &v[1], &v[2],
                                 &v[3], &v[4], &v[5], &v[6], &v[7], &v[8], &v[9]);
                if (got >= 4) {
                    uint64_t now[CPU_FIELDS];
                    for (int i = 0; i < CPU_FIELDS; ++i) now[i] = v[i];
                    int slot = id + 1;
                    int have = s->cpu_have[slot]; /* ratios of deltas: no interval needed */
                    if (id < 0) cpu_times(&c->total, now, s->cpu_prev[slot], have);
                    else {
                        seen[id] = 1;
                        if ((uint32_t)id + 1 > c->count) c->count = (uint32_t)id + 1;
                        cpu_times(&c->cpu[id].t, now, s->cpu_prev[slot], have);
                    }
                    memcpy(s->cpu_prev[slot], now, sizeof now);
                    s->cpu_have[slot] = 1;
                }
            }
        } else if (!summary) {
            /* summary counters keep their own previous values */
        } else if (sscanf(line, "ctxt %llu", &x) == 1) {
            rate(&sm->context_switches_ps, x, s->ctxt, s->stat_have && have_dt, dt, 1);
            s->ctxt = x;
        } else if (sscanf(line, "intr %llu", &x) == 1) {
            rate(&sm->interrupts_ps, x, s->intr, s->stat_have && have_dt, dt, 1);
            s->intr = x;
        } else if (sscanf(line, "processes %llu", &x) == 1) {
            rate(&sm->forks_ps, x, s->forks, s->stat_have && have_dt, dt, 1);
            s->forks = x;
        } else if (sscanf(line, "procs_running %llu", &x) == 1) OK(sm->running, x);
        else if (sscanf(line, "procs_blocked %llu", &x) == 1) OK(sm->blocked, x);
        else if (sscanf(line, "btime %llu", &x) == 1) OK(sm->boot_time_s, x);
        line = next;
    }
    if (summary) s->stat_have = 1;
    uint32_t online = 0;
    for (uint32_t i = 0; i < c->count; ++i) {
        c->cpu[i].id = (int32_t)i;
        OK(c->cpu[i].online, seen[i]);
        if (seen[i]) online++;
        else {
            struct xrt_sys_cpu_times *t = &c->cpu[i].t;
            struct xrt_sys_f64 *f[] = {&t->user, &t->nice, &t->system, &t->idle, &t->iowait, &t->irq, &t->softirq, &t->steal, &t->guest, &t->busy};
            for (size_t k = 0; k < COUNT_OF(f); ++k) NA(*f[k], XRT_SYS_WHY_NOT_PRESENT);
            s->cpu_have[i + 1] = 0;
        }
    }
    OK(c->online, online);
    if (ISOK(c->total.busy)) OK(sm->cpu_busy_pct, c->total.busy.v);
    else NA(sm->cpu_busy_pct, c->total.busy.why);
}

/* ---- hwmon ---- */
static const struct { const char *prefix; uint8_t kind; double scale; } sensor_kinds[] = {
    {"temp", XRT_SYS_TEMP, 1e-3},       {"fan", XRT_SYS_FAN, 1},          {"in", XRT_SYS_VOLTAGE, 1e-3},
    {"curr", XRT_SYS_CURRENT, 1e-3},    {"power", XRT_SYS_POWER_W, 1e-6}, {"energy", XRT_SYS_ENERGY_J, 1e-6},
    {"freq", XRT_SYS_FREQ_MHZ, 1e-6},   {"humidity", XRT_SYS_HUMIDITY, 1e-3},
};
static int name_cmp(const void *a, const void *b) { return strcmp(*(char *const *)a, *(char *const *)b); }

/* Lists directory names into a malloc'd array of strings (sorted). */
static char **list_dir(struct xrt_sys *s, const char *path, size_t *count, int *err)
{
    *count = 0;
    *err = 0;
    int fd = sys_open(s, path, O_DIRECTORY);
    if (fd < 0) {
        *err = errno;
        return NULL;
    }
    DIR *d = fdopendir(fd);
    if (!d) {
        *err = errno;
        sys_close(s, fd);
        return NULL;
    }
    size_t cap = 0;
    char **v = NULL;
    struct dirent *e;
    s->syscalls++;
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.') continue;
        if (*count == cap) {
            cap = cap ? cap * 2 : 32;
            char **nv = realloc(v, cap * sizeof *v);
            if (!nv) break;
            v = nv;
        }
        if (!(v[*count] = strdup(e->d_name))) break;
        ++*count;
        if (*count % 64 == 0) s->syscalls++;
    }
    s->syscalls++;
    closedir(d);
    if (*count) qsort(v, *count, sizeof *v, name_cmp);
    return v;
}
static void free_list(char **v, size_t n)
{
    for (size_t i = 0; i < n; ++i) free(v[i]);
    free(v);
}

static void scan_sensors(struct xrt_sys *s)
{
    struct sensor_src *old = s->sensor_count ? malloc(s->sensor_count * sizeof *old) : NULL;
    uint32_t old_count = old ? s->sensor_count : 0;
    if (old) memcpy(old, s->sensors, old_count * sizeof *old);
    s->sensor_count = 0;
    size_t nh;
    int err;
    char **hw = list_dir(s, "/sys/class/hwmon", &nh, &err);
    for (size_t h = 0; h < nh; ++h) {
        char base[96], chip[32], devlink[PATH_MAX], full[PATH_MAX], b[128];
        snprintf(base, sizeof base, "/sys/class/hwmon/%s", hw[h]);
        if (rdf(s, b, sizeof b, "%s/name", base) < 0) continue;
        trim(b);
        copy_str(chip, sizeof chip, b);
        char lp[160];
        snprintf(lp, sizeof lp, "%s/device", base);
        s->syscalls++;
        ssize_t ln = readlink(path_of(s, lp, full, sizeof full), devlink, sizeof devlink - 1);
        char dev[32] = "";
        if (ln > 0) {
            devlink[ln] = 0;
            const char *slash = strrchr(devlink, '/');
            copy_str(dev, sizeof dev, slash ? slash + 1 : devlink);
        }
        size_t nf;
        char **files = list_dir(s, base, &nf, &err);
        for (size_t f = 0; f < nf && s->sensor_count < MAX_SENSOR_SRC; ++f) {
            for (size_t k = 0; k < COUNT_OF(sensor_kinds); ++k) {
                size_t pl = strlen(sensor_kinds[k].prefix);
                const char *name = files[f];
                if (strncmp(name, sensor_kinds[k].prefix, pl) || name[pl] < '0' || name[pl] > '9') continue;
                char *end;
                long idx = strtol(name + pl, &end, 10);
                const char *suffix = sensor_kinds[k].kind == XRT_SYS_POWER_W ? "_average" : "_input";
                int power_input = sensor_kinds[k].kind == XRT_SYS_POWER_W && !strcmp(end, "_input");
                if (strcmp(end, suffix) && !power_input) continue;
                if (power_input) { /* prefer _average when both exist */
                    char alt[64];
                    snprintf(alt, sizeof alt, "%s%ld_average", sensor_kinds[k].prefix, idx);
                    int dup = 0;
                    for (size_t j = 0; j < nf; ++j) dup |= !strcmp(files[j], alt);
                    if (dup) continue;
                }
                struct sensor_src *src = &s->sensors[s->sensor_count++];
                memset(src, 0, sizeof *src);
                copy_str(src->chip, sizeof src->chip, chip);
                copy_str(src->device, sizeof src->device, dev);
                src->kind = sensor_kinds[k].kind;
                src->scale = sensor_kinds[k].scale;
                snprintf(src->path, sizeof src->path, "%s/%s", base, name);
                if (rdf(s, b, sizeof b, "%s/%s%ld_label", base, sensor_kinds[k].prefix, idx) >= 0) {
                    trim(b);
                    copy_str(src->label, sizeof src->label, b);
                } else snprintf(src->label, sizeof src->label, "%s%ld", sensor_kinds[k].prefix, idx);
                const struct sensor_src *was = NULL;
                for (uint32_t j = 0; j < old_count && !was; ++j)
                    if (!strcmp(old[j].path, src->path)) was = &old[j];
                if (was) { /* limits are static; slow chips make re-reading them costly */
                    src->max = was->max;
                    src->crit = was->crit;
                    src->slow_reads = was->slow_reads;
                    src->read_mono = was->read_mono;
                    src->last = was->last;
                } else {
                    char p[256];
                    snprintf(p, sizeof p, "%s/%s%ld_max", base, sensor_kinds[k].prefix, idx);
                    get_f64(s, &src->max, p, src->scale);
                    snprintf(p, sizeof p, "%s/%s%ld_crit", base, sensor_kinds[k].prefix, idx);
                    get_f64(s, &src->crit, p, src->scale);
                }
            }
        }
        free_list(files, nf);
    }
    free_list(hw, nh);
    free(old);
    s->sensor_scan_mono = mono_ns();
}

static void read_sensors(struct xrt_sys *s, struct xrt_sys_snapshot *snap)
{
    if (!s->sensor_scan_mono || mono_ns() - s->sensor_scan_mono >= 60000000000LL) scan_sensors(s);
    struct xrt_sys_power *p = &snap->power;
    p->sensor_count = 0;
    for (uint32_t i = 0; i < s->sensor_count; ++i) {
        struct sensor_src *src = &s->sensors[i];
        struct xrt_sys_sensor *o = &p->sensor[p->sensor_count++];
        copy_str(o->chip, sizeof o->chip, src->chip);
        copy_str(o->label, sizeof o->label, src->label);
        o->kind = src->kind;
        int64_t now = mono_ns();
        if (!s->lim.sensor_timing_disabled && src->slow_reads >= SLOW_SENSOR_READS && src->read_mono &&
            now - src->read_mono < SLOW_SENSOR_PERIOD_NS &&
            src->last.st == XRT_SYS_OK) {
            o->value = src->last;
            o->value.st = XRT_SYS_STALE;
            o->value.why = XRT_SYS_WHY_SLOW_SOURCE;
        } else {
            get_f64(s, &o->value, src->path, src->scale);
            int64_t end = mono_ns();
            if (s->lim.sensor_timing_disabled || o->value.st != XRT_SYS_OK || end - now <= SLOW_SENSOR_NS)
                src->slow_reads = 0;
            else if (src->slow_reads < SLOW_SENSOR_READS)
                src->slow_reads++;
            src->read_mono = now;
            src->last = o->value;
        }
        o->max = src->max;
        o->crit = src->crit;
    }
}

/* ---- CPU ---- */
static void read_topology(struct xrt_sys *s, uint32_t cpu, struct topo *t)
{
    char p[128], b[256];
    snprintf(p, sizeof p, "/sys/devices/system/cpu/cpu%u/topology/physical_package_id", cpu);
    get_u64(s, &t->package_id, p);
    snprintf(p, sizeof p, "/sys/devices/system/cpu/cpu%u/topology/die_id", cpu);
    get_u64(s, &t->die_id, p);
    snprintf(p, sizeof p, "/sys/devices/system/cpu/cpu%u/topology/core_id", cpu);
    get_u64(s, &t->core_id, p);
    snprintf(p, sizeof p, "/sys/devices/system/cpu/cpu%u/cache/index3/id", cpu);
    get_u64(s, &t->l3_id, p);
    ssize_t n = rdf(s, b, sizeof b, "/sys/devices/system/cpu/cpu%u/topology/thread_siblings_list", cpu);
    if (n < 0) NA(t->smt_index, why_errno((int)-n));
    else {
        /* position of cpu within the sibling list "a,b" or "a-b" */
        unsigned idx = 0, found = 0;
        for (char *q = b; *q;) {
            char *end;
            long lo = strtol(q, &end, 10), hi = lo;
            if (end == q) break;
            if (*end == '-') hi = strtol(end + 1, &end, 10);
            for (long x = lo; x <= hi; ++x, ++idx)
                if (x == (long)cpu) found = 1, hi = x;
            if (found) break;
            q = *end == ',' ? end + 1 : end;
            if (!*end) break;
        }
        if (found) OK(t->smt_index, idx - 1);
        else NA(t->smt_index, XRT_SYS_WHY_PARSE_ERROR);
    }
    snprintf(p, sizeof p, "/sys/devices/system/cpu/cpu%u/cpufreq/cpuinfo_min_freq", cpu);
    get_f64(s, &t->fmin, p, 1e-3);
    snprintf(p, sizeof p, "/sys/devices/system/cpu/cpu%u/cpufreq/cpuinfo_max_freq", cpu);
    get_f64(s, &t->fmax, p, 1e-3);
    t->done = 1;
}

static void cpu_model(struct xrt_sys *s, struct xrt_sys_name *model)
{
    ssize_t n = rd(s, "/proc/cpuinfo", s->buf, 8192);
    if (n < 0) {
        na_name(model, why_errno((int)-n));
        return;
    }
    static const char *const keys[] = {"model name", "Model Name", "cpu model", "Processor", "uarch", "isa"};
    for (size_t k = 0; k < COUNT_OF(keys); ++k) {
        for (char *line = s->buf; line && *line; line = strchr(line, '\n') ? strchr(line, '\n') + 1 : NULL) {
            size_t kl = strlen(keys[k]);
            if (strncmp(line, keys[k], kl) || (line[kl] != '\t' && line[kl] != ' ' && line[kl] != ':')) continue;
            char *colon = strchr(line, ':'), *nl = strchr(line, '\n');
            if (!colon || (nl && colon > nl)) continue;
            char v[64];
            size_t len = nl ? (size_t)(nl - colon - 1) : strlen(colon + 1);
            if (len >= sizeof v) len = sizeof v - 1;
            memcpy(v, colon + 1, len);
            v[len] = 0;
            char *t = v;
            while (*t == ' ') ++t;
            trim(t);
            if (*t) {
                set_name(model, t);
                return;
            }
        }
    }
    na_name(model, XRT_SYS_WHY_NOT_PRESENT);
}

static void collect_cpu(struct xrt_sys *s, struct xrt_sys_snapshot *snap)
{
    struct xrt_sys_cpus *c = &snap->cpu;
    if (c->count) OK(c->logical, c->count);
    else NA(c->logical, XRT_SYS_WHY_NOT_PRESENT); /* /proc/stat unreadable */
    if (c->online.v != s->topo_online) {
        for (uint32_t i = 0; i < XRT_SYS_MAX_CPUS; ++i) s->topo[i].done = 0;
        s->topo_online = (uint32_t)c->online.v;
    }
    if (!ISOK(s->model)) cpu_model(s, &s->model); /* /proc/cpuinfo is costly and static */
    c->model = s->model;
    get_name(s, &c->freq_driver, "/sys/devices/system/cpu/cpu0/cpufreq/scaling_driver");
    get_name(s, &c->governor, "/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor");
    get_name(s, &c->epp, "/sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference");
    uint64_t pk_seen = 0, l3_seen[8] = {0}, cores = 0, pk_ok = 1, l3_ok = 1;
    for (uint32_t i = 0; i < c->count; ++i) {
        struct xrt_sys_cpu *u = &c->cpu[i];
        struct topo *t = &s->topo[i];
        if (!ISOK(u->online) || !u->online.v) {
            NA(u->freq_mhz, XRT_SYS_WHY_NOT_PRESENT);
            NA(u->freq_min_mhz, XRT_SYS_WHY_NOT_PRESENT);
            NA(u->freq_max_mhz, XRT_SYS_WHY_NOT_PRESENT);
            NA(u->package_id, XRT_SYS_WHY_NOT_PRESENT);
            NA(u->die_id, XRT_SYS_WHY_NOT_PRESENT);
            NA(u->core_id, XRT_SYS_WHY_NOT_PRESENT);
            NA(u->l3_id, XRT_SYS_WHY_NOT_PRESENT);
            NA(u->smt_index, XRT_SYS_WHY_NOT_PRESENT);
            NA(u->temp_c, XRT_SYS_WHY_NOT_PRESENT);
            continue;
        }
        if (!t->done) read_topology(s, i, t);
        char p[128];
        snprintf(p, sizeof p, "/sys/devices/system/cpu/cpu%u/cpufreq/scaling_cur_freq", i);
        get_f64(s, &u->freq_mhz, p, 1e-3);
        u->freq_min_mhz = t->fmin;
        u->freq_max_mhz = t->fmax;
        u->package_id = t->package_id;
        u->die_id = t->die_id;
        u->core_id = t->core_id;
        u->l3_id = t->l3_id;
        u->smt_index = t->smt_index;
        NA(u->temp_c, XRT_SYS_WHY_NOT_PRESENT);
        if (ISOK(t->package_id) && t->package_id.v < 64) pk_seen |= 1ull << t->package_id.v;
        else pk_ok = 0;
        if (ISOK(t->l3_id) && t->l3_id.v < 512) l3_seen[t->l3_id.v / 64] |= 1ull << (t->l3_id.v % 64);
        else l3_ok = 0;
        if (ISOK(t->smt_index) && t->smt_index.v == 0) cores++;
    }
    if (pk_ok && pk_seen) OK(c->packages, (uint64_t)__builtin_popcountll(pk_seen));
    else NA(c->packages, XRT_SYS_WHY_NOT_PRESENT);
    uint64_t l3 = 0;
    for (int i = 0; i < 8; ++i) l3 += (uint64_t)__builtin_popcountll(l3_seen[i]);
    if (l3_ok && l3) OK(c->l3_groups, l3);
    else NA(c->l3_groups, XRT_SYS_WHY_NOT_PRESENT);
    if (cores) OK(c->cores, cores);
    else NA(c->cores, XRT_SYS_WHY_NOT_PRESENT);
    /* CPU temperatures from hwmon (k10temp, zenpower, coretemp). */
    NA(c->package_temp_c, XRT_SYS_WHY_NOT_PRESENT);
    c->temp_count = 0;
    for (uint32_t i = 0; i < snap->power.sensor_count; ++i) {
        struct xrt_sys_sensor *x = &snap->power.sensor[i];
        if (x->kind != XRT_SYS_TEMP) continue;
        int amd = !strcmp(x->chip, "k10temp") || !strcmp(x->chip, "zenpower");
        if (!amd && strcmp(x->chip, "coretemp")) continue;
        uint32_t slot = c->temp_count;
        if (slot < COUNT_OF(c->temps)) {
            struct xrt_sys_reading r;
            memset(&r, 0, sizeof r);
            copy_str(r.chip, sizeof r.chip, x->chip);
            copy_str(r.label, sizeof r.label, x->label);
            r.value = x->value;
            c->temps[slot] = r;
            c->temp_count = slot + 1;
        }
        if ((!strcmp(x->label, "Tctl") || !strcmp(x->label, "Tdie") || !strncmp(x->label, "Package id", 10)) &&
            c->package_temp_c.st != XRT_SYS_OK)
            c->package_temp_c = x->value;
        int core;
        if (sscanf(x->label, "Core %d", &core) == 1)
            for (uint32_t k = 0; k < c->count; ++k)
                if (ISOK(c->cpu[k].core_id) && c->cpu[k].core_id.v == (uint64_t)core) c->cpu[k].temp_c = x->value;
    }
}

/* ---- memory ---- */
static void collect_memory(struct xrt_sys *s, struct xrt_sys_snapshot *snap, double dt, int have_dt)
{
    struct xrt_sys_memory *m = &snap->memory;
    struct { const char *key; struct xrt_sys_u64 *f; } keys[] = {
        {"MemTotal", &m->total},          {"MemFree", &m->free},           {"MemAvailable", &m->available},
        {"Cached", &m->cached},           {"Buffers", &m->buffers},        {"Shmem", &m->shmem},
        {"SReclaimable", &m->slab_reclaimable}, {"SUnreclaim", &m->slab_unreclaimable},
        {"Dirty", &m->dirty},             {"Writeback", &m->writeback},    {"AnonPages", &m->anon},
        {"Mapped", &m->mapped},           {"PageTables", &m->page_tables}, {"CommitLimit", &m->commit_limit},
        {"Committed_AS", &m->committed},  {"SwapTotal", &m->swap_total},   {"SwapFree", &m->swap_free},
        {"SwapCached", &m->swap_cached},  {"Zswap", &m->zswap_pool},       {"Zswapped", &m->zswap_stored},
    };
    for (size_t i = 0; i < COUNT_OF(keys); ++i) NA(*keys[i].f, XRT_SYS_WHY_NOT_PRESENT);
    ssize_t n = rd(s, "/proc/meminfo", s->buf, sizeof s->buf);
    if (n < 0) {
        for (size_t i = 0; i < COUNT_OF(keys); ++i) NA(*keys[i].f, why_errno((int)-n));
        fail(&snap->group[XRT_SYS_G_MEMORY], (int)-n, "/proc/meminfo");
    }
    for (char *line = n > 0 ? s->buf : NULL; line && *line;) {
        char *next = strchr(line, '\n');
        if (next) *next++ = 0;
        char *colon = strchr(line, ':');
        if (colon) {
            *colon = 0;
            unsigned long long v;
            if (sscanf(colon + 1, "%llu", &v) == 1)
                for (size_t i = 0; i < COUNT_OF(keys); ++i)
                    if (!strcmp(line, keys[i].key)) OK(*keys[i].f, v * 1024);
        }
        line = next;
    }
    if (ISOK(m->total) && ISOK(m->available)) OK(m->used, m->total.v - (m->available.v < m->total.v ? m->available.v : m->total.v));
    else NA(m->used, XRT_SYS_WHY_NOT_PRESENT);
    if (ISOK(m->swap_total) && ISOK(m->swap_free)) OK(m->swap_used, m->swap_total.v - m->swap_free.v);
    else NA(m->swap_used, XRT_SYS_WHY_NOT_PRESENT);
    char b[16];
    ssize_t z = rd(s, "/sys/module/zswap/parameters/enabled", b, sizeof b);
    if (z < 0) NA(m->zswap_enabled, why_errno((int)-z));
    else OK(m->zswap_enabled, b[0] == 'Y' || b[0] == '1');
    /* vmstat: pgfault, pgmajfault, pswpin, pswpout */
    static const char *const vk[] = {"pgfault", "pgmajfault", "pswpin", "pswpout"};
    struct xrt_sys_f64 *vf[] = {&m->page_faults_ps, &m->major_faults_ps, &m->swap_in_ps, &m->swap_out_ps};
    uint64_t now[4] = {0};
    int got = 0;
    n = rd(s, "/proc/vmstat", s->buf, sizeof s->buf);
    for (char *line = n > 0 ? s->buf : NULL; line && *line;) {
        char *next = strchr(line, '\n');
        if (next) *next++ = 0;
        for (int i = 0; i < 4; ++i) {
            size_t kl = strlen(vk[i]);
            unsigned long long v;
            if (!strncmp(line, vk[i], kl) && line[kl] == ' ' && sscanf(line + kl, "%llu", &v) == 1) {
                now[i] = v;
                got |= 1 << i;
            }
        }
        line = next;
    }
    for (int i = 0; i < 4; ++i) {
        if (!(got & (1 << i))) NA(*vf[i], n < 0 ? why_errno((int)-n) : XRT_SYS_WHY_NOT_PRESENT);
        else rate(vf[i], now[i], s->vm_prev[i], s->vm_have && have_dt, dt, 1);
    }
    memcpy(s->vm_prev, now, sizeof now);
    s->vm_have = got == 15;
    psi_read(s, 1, &m->psi, dt, have_dt);
}

/* ---- disks ---- */
static void collect_disks(struct xrt_sys *s, struct xrt_sys_snapshot *snap, double dt, int have_dt)
{
    struct xrt_sys_disks *d = &snap->disks;
    size_t nb;
    int err;
    char **blocks = list_dir(s, "/sys/block", &nb, &err);
    if (!blocks && err) fail(&snap->group[XRT_SYS_G_DISKS], err, "/sys/block");
    ssize_t n = rd(s, "/proc/diskstats", s->buf, sizeof s->buf);
    if (n < 0) fail(&snap->group[XRT_SYS_G_DISKS], (int)-n, "/proc/diskstats");
    struct disk_prev next_prev[XRT_SYS_MAX_DISKS];
    uint32_t next_count = 0;
    for (char *line = n > 0 ? s->buf : NULL; line && *line;) {
        char *next = strchr(line, '\n');
        if (next) *next++ = 0;
        unsigned maj, min;
        char name[64];
        unsigned long long f[DISK_FIELDS] = {0};
        /* reads merged sectors ms writes merged sectors ms inflight io_ms weighted_ms */
        int got = sscanf(line, "%u %u %63s %llu %llu %llu %llu %llu %llu %llu %llu %llu %llu %llu", &maj, &min, name,
                         &f[0], &f[1], &f[2], &f[3], &f[4], &f[5], &f[6], &f[7], &f[8], &f[9], &f[10]);
        line = next;
        if (got < 14) continue;
        int whole = 0;
        for (size_t i = 0; i < nb; ++i) whole |= !strcmp(blocks[i], name);
        if (!whole || d->count >= XRT_SYS_MAX_DISKS) continue;
        struct xrt_sys_disk *k = &d->disk[d->count];
        memset(k, 0, sizeof *k);
        copy_str(k->name, sizeof k->name, name);
        struct disk_prev *old = NULL;
        for (uint32_t i = 0; i < s->disk_prev_count; ++i)
            if (!strcmp(s->disk_prev[i].name, name)) old = &s->disk_prev[i];
        if (old && s->seq - old->attr_seq < 64) { /* size, model and kind: re-read every 64 samples */
            k->size_bytes = old->size_bytes;
            k->rotational = old->rotational;
            k->removable = old->removable;
            k->model = old->model;
        } else {
            char p[160];
            snprintf(p, sizeof p, "/sys/block/%s/size", name);
            get_u64(s, &k->size_bytes, p);
            if (ISOK(k->size_bytes)) k->size_bytes.v *= 512;
            snprintf(p, sizeof p, "/sys/block/%s/queue/rotational", name);
            get_u64(s, &k->rotational, p);
            snprintf(p, sizeof p, "/sys/block/%s/removable", name);
            get_u64(s, &k->removable, p);
            snprintf(p, sizeof p, "/sys/block/%s/device/model", name);
            get_name(s, &k->model, p);
        }
        uint64_t attr_seq = old && s->seq - old->attr_seq < 64 ? old->attr_seq : s->seq;
        if ((!strncmp(name, "loop", 4) || !strncmp(name, "ram", 3) || !strncmp(name, "nbd", 3)) &&
            (!ISOK(k->size_bytes) || !k->size_bytes.v))
            continue; /* unattached */
        d->count++;
        OK(k->read_bytes, f[2] * 512);
        OK(k->write_bytes, f[6] * 512);
        OK(k->in_flight, f[8]);
        int have = old && have_dt;
        uint64_t zero[DISK_FIELDS] = {0};
        const uint64_t *o = old ? old->f : zero;
        uint64_t now[DISK_FIELDS];
        for (int i = 0; i < DISK_FIELDS; ++i) now[i] = f[i];
        rate(&k->read_bps, now[2], o[2], have, dt, 512);
        rate(&k->write_bps, now[6], o[6], have, dt, 512);
        rate(&k->read_iops, now[0], o[0], have, dt, 1);
        rate(&k->write_iops, now[4], o[4], have, dt, 1);
        rate(&k->busy_pct, now[9], o[9], have, dt, 0.1); /* ms per s -> percent */
        if (ISOK(k->busy_pct) && k->busy_pct.v > 100) k->busy_pct.v = 100;
        rate(&k->queue_depth, now[10], o[10], have, dt, 1e-3);
        int reset = 0;
        for (int i = 0; i < DISK_FIELDS; ++i) reset |= i != 8 && have && now[i] < o[i]; /* 8: in flight */
        if (!have) NA(k->avg_latency_ms, XRT_SYS_WHY_FIRST_SAMPLE);
        else if (reset) NA(k->avg_latency_ms, XRT_SYS_WHY_COUNTER_RESET);
        else {
            uint64_t ops = (now[0] - o[0]) + (now[4] - o[4]);
            uint64_t ms = (now[3] - o[3]) + (now[7] - o[7]);
            if (ops) OK(k->avg_latency_ms, (double)ms / (double)ops);
            else NA(k->avg_latency_ms, XRT_SYS_WHY_NOT_PRESENT); /* no operation completed */
        }
        NA(k->temp_c, XRT_SYS_WHY_NOT_PRESENT);
        for (uint32_t i = 0; i < snap->power.sensor_count && i < s->sensor_count; ++i) {
            struct sensor_src *src = &s->sensors[i];
            size_t dl = strlen(src->device);
            if (src->kind == XRT_SYS_TEMP && dl && !strncmp(name, src->device, dl) && name[dl] == 'n' &&
                (ISOK(snap->power.sensor[i].value) || snap->power.sensor[i].value.st == XRT_SYS_STALE) &&
                k->temp_c.st != XRT_SYS_OK && k->temp_c.st != XRT_SYS_STALE)
                k->temp_c = snap->power.sensor[i].value;
        }
        if (next_count < XRT_SYS_MAX_DISKS) {
            struct disk_prev *np = &next_prev[next_count++];
            copy_str(np->name, sizeof np->name, name);
            memcpy(np->f, now, sizeof now);
            np->attr_seq = attr_seq;
            np->size_bytes = k->size_bytes;
            np->rotational = k->rotational;
            np->removable = k->removable;
            np->model = k->model;
        }
    }
    memcpy(s->disk_prev, next_prev, next_count * sizeof next_prev[0]);
    s->disk_prev_count = next_count;
    free_list(blocks, nb);
    psi_read(s, 2, &d->psi, dt, have_dt);
}

/* ---- filesystems ---- */
static int pseudo_fs(const char *t)
{
    static const char *const pseudo[] = {"proc", "sysfs", "devtmpfs", "devpts", "tmpfs", "cgroup", "cgroup2",
                                         "securityfs", "pstore", "efivarfs", "bpf", "debugfs", "tracefs",
                                         "configfs", "fusectl", "mqueue", "hugetlbfs", "autofs", "binfmt_misc",
                                         "rpc_pipefs", "nsfs", "ramfs", "selinuxfs", "fuse.gvfsd-fuse",
                                         "fuse.portal", "nfsd"};
    for (size_t i = 0; i < COUNT_OF(pseudo); ++i)
        if (!strcmp(t, pseudo[i])) return 1;
    return 0;
}
static int network_fs(const char *t)
{
    return !strcmp(t, "nfs") || !strcmp(t, "nfs4") || !strcmp(t, "cifs") || !strcmp(t, "smb3") || !strcmp(t, "9p") ||
           !strcmp(t, "ceph") || !strcmp(t, "glusterfs") || !strncmp(t, "fuse.", 5) || !strcmp(t, "fuse");
}
static void unescape(char *s)
{
    char *o = s;
    for (; *s; ++s) {
        if (s[0] == '\\' && s[1] >= '0' && s[1] <= '3' && s[2] >= '0' && s[2] <= '7' && s[3] >= '0' && s[3] <= '7') {
            *o++ = (char)((s[1] - '0') * 64 + (s[2] - '0') * 8 + (s[3] - '0'));
            s += 3;
        } else *o++ = *s;
    }
    *o = 0;
}
static void collect_filesystems(struct xrt_sys *s, struct xrt_sys_snapshot *snap)
{
    struct xrt_sys_filesystems *fs = &snap->filesystems;
    int redact = (s->lim.flags & XRT_SYS_REDACT) != 0;
    ssize_t n = rd(s, "/proc/self/mountinfo", s->buf, sizeof s->buf);
    if (n < 0) {
        fail(&snap->group[XRT_SYS_G_FILESYSTEMS], (int)-n, "mountinfo");
        return;
    }
    char devs[XRT_SYS_MAX_FILESYSTEMS][24];
    for (char *line = s->buf; line && *line;) {
        char *next = strchr(line, '\n');
        if (next) *next++ = 0;
        char dev[24], mnt[1024], type[64], src[512];
        char *sep = strstr(line, " - ");
        char *head = line;
        line = next;
        if (!sep) continue;
        *sep = 0;
        if (sscanf(sep + 3, "%63s %511s", type, src) != 2) continue;
        if (sscanf(head, "%*u %*u %23s %*s %1023s", dev, mnt) != 2) continue;
        if (pseudo_fs(type)) {
            fs->skipped_pseudo++;
            continue;
        }
        int dup = 0;
        for (uint32_t i = 0; i < fs->count; ++i) dup |= !strcmp(devs[i], dev);
        if (dup) {
            fs->skipped_duplicate++;
            continue;
        }
        if (fs->count >= XRT_SYS_MAX_FILESYSTEMS) {
            detail(&snap->group[XRT_SYS_G_FILESYSTEMS], 0, "more than %d filesystems", XRT_SYS_MAX_FILESYSTEMS);
            break;
        }
        unescape(mnt);
        unescape(src);
        copy_str(devs[fs->count], sizeof devs[0], dev);
        struct xrt_sys_filesystem *f = &fs->fs[fs->count++];
        memset(f, 0, sizeof *f);
        copy_str(f->fstype, sizeof f->fstype, type);
        if (redact && !system_mount(mnt)) na_name(&f->mount, XRT_SYS_WHY_REDACTED);
        else set_name(&f->mount, mnt);
        if (redact && strncmp(src, "/dev/", 5)) na_name(&f->source, XRT_SYS_WHY_REDACTED);
        else set_name(&f->source, src);
        struct xrt_sys_u64 *v[] = {&f->total, &f->free, &f->avail, &f->used, &f->inodes_total, &f->inodes_free, &f->read_only};
        uint8_t why = 0;
        struct statvfs st;
        if (!s->live) why = XRT_SYS_WHY_NOT_SUPPORTED;
        else if (network_fs(type)) why = XRT_SYS_WHY_LIMIT; /* statvfs may block on a dead server */
        else {
            s->syscalls++;
            if (statvfs(mnt, &st) != 0) why = why_errno(errno);
        }
        if (why) {
            for (size_t i = 0; i < COUNT_OF(v); ++i) NA(*v[i], why);
            NA(f->used_pct, why);
            continue;
        }
        uint64_t fr = st.f_frsize ? st.f_frsize : st.f_bsize;
        OK(f->total, (uint64_t)st.f_blocks * fr);
        OK(f->free, (uint64_t)st.f_bfree * fr);
        OK(f->avail, (uint64_t)st.f_bavail * fr);
        OK(f->used, (uint64_t)(st.f_blocks - st.f_bfree) * fr);
        OK(f->inodes_total, (uint64_t)st.f_files);
        OK(f->inodes_free, (uint64_t)st.f_ffree);
        OK(f->read_only, (st.f_flag & ST_RDONLY) != 0);
        uint64_t denom = f->used.v + f->avail.v;
        if (denom) OK(f->used_pct, 100.0 * (double)f->used.v / (double)denom);
        else NA(f->used_pct, XRT_SYS_WHY_NOT_PRESENT);
    }
}

/* ---- network ---- */
static void collect_network(struct xrt_sys *s, struct xrt_sys_snapshot *snap, double dt, int have_dt)
{
    struct xrt_sys_network *net = &snap->network;
    int redact = (s->lim.flags & XRT_SYS_REDACT) != 0;
    ssize_t n = rd(s, "/proc/net/dev", s->buf, sizeof s->buf);
    if (n < 0) {
        fail(&snap->group[XRT_SYS_G_NETWORK], (int)-n, "/proc/net/dev");
        return;
    }
    struct if_prev next_prev[XRT_SYS_MAX_IFACES];
    uint32_t next_count = 0;
    double rx = 0, tx = 0;
    int totals_ok = have_dt, physical_count = 0;
    uint8_t totals_why = XRT_SYS_WHY_FIRST_SAMPLE;
    for (char *line = s->buf; line && *line;) {
        char *next = strchr(line, '\n');
        if (next) *next++ = 0;
        char *colon = strchr(line, ':');
        if (!colon) {
            line = next;
            continue;
        }
        *colon = 0;
        char *nm = line;
        while (*nm == ' ') ++nm;
        unsigned long long v[16] = {0};
        int got = sscanf(colon + 1, "%llu %llu %llu %llu %llu %llu %llu %llu %llu %llu %llu %llu %llu %llu %llu %llu", &v[0],
                         &v[1], &v[2], &v[3], &v[4], &v[5], &v[6], &v[7], &v[8], &v[9], &v[10], &v[11], &v[12], &v[13],
                         &v[14], &v[15]);
        line = next;
        if (got < 16 || net->count >= XRT_SYS_MAX_IFACES) continue;
        struct xrt_sys_iface *f = &net->iface[net->count++];
        memset(f, 0, sizeof *f);
        copy_str(f->name, sizeof f->name, nm);
        /* rx bytes packets errs drop ..., tx bytes(8) packets(9) errs(10) drop(11) */
        uint64_t now[IF_FIELDS] = {v[0], v[1], v[2], v[3], v[8], v[9], v[10], v[11]};
        OK(f->rx_bytes, now[0]);
        OK(f->tx_bytes, now[4]);
        struct if_prev *old = NULL;
        for (uint32_t i = 0; i < s->if_prev_count; ++i)
            if (!strcmp(s->if_prev[i].name, nm)) old = &s->if_prev[i];
        uint64_t zero[IF_FIELDS] = {0};
        const uint64_t *o = old ? old->f : zero;
        int have = old && have_dt;
        rate(&f->rx_bps, now[0], o[0], have, dt, 1);
        rate(&f->rx_pps, now[1], o[1], have, dt, 1);
        rate(&f->rx_errors_ps, now[2], o[2], have, dt, 1);
        rate(&f->rx_drops_ps, now[3], o[3], have, dt, 1);
        rate(&f->tx_bps, now[4], o[4], have, dt, 1);
        rate(&f->tx_pps, now[5], o[5], have, dt, 1);
        rate(&f->tx_errors_ps, now[6], o[6], have, dt, 1);
        rate(&f->tx_drops_ps, now[7], o[7], have, dt, 1);
        char p[160];
        snprintf(p, sizeof p, "/sys/class/net/%s/operstate", nm);
        get_name(s, &f->operstate, p);
        snprintf(p, sizeof p, "/sys/class/net/%s/carrier", nm);
        get_u64(s, &f->carrier, p);
        snprintf(p, sizeof p, "/sys/class/net/%s/speed", nm);
        int64_t sp;
        int r = read_i64(s, p, &sp);
        if (r == 0 && sp > 0) OK(f->speed_mbps, (uint64_t)sp);
        else NA(f->speed_mbps, r ? why_errno(-r) : XRT_SYS_WHY_NOT_PRESENT); /* -1: unknown */
        snprintf(p, sizeof p, "/sys/class/net/%s/mtu", nm);
        get_u64(s, &f->mtu, p);
        snprintf(p, sizeof p, "/sys/class/net/%s/flags", nm);
        char b[32];
        ssize_t fl = rd(s, p, b, sizeof b);
        if (fl > 0) OK(f->loopback, (strtoul(b, NULL, 0) & IFF_LOOPBACK) != 0);
        else NA(f->loopback, fl < 0 ? why_errno((int)-fl) : XRT_SYS_WHY_PARSE_ERROR);
        snprintf(p, sizeof p, "/sys/class/net/%s/device", nm);
        char full[PATH_MAX];
        struct stat st;
        s->syscalls++;
        char dirp[160];
        snprintf(dirp, sizeof dirp, "/sys/class/net/%s", nm);
        s->syscalls += 2;
        if (lstat(path_of(s, dirp, full, sizeof full), &st) != 0) {
            NA(f->physical, why_errno(errno));
            na_name(&f->kind, f->physical.why);
        } else {
            OK(f->physical, lstat(path_of(s, p, full, sizeof full), &st) == 0);
            snprintf(p, sizeof p, "/sys/class/net/%s/bridge", nm);
            s->syscalls++;
            int bridge = lstat(path_of(s, p, full, sizeof full), &st) == 0;
            set_name(&f->kind, ISOK(f->loopback) && f->loopback.v ? "loopback" : f->physical.v ? "physical"
                               : bridge ? "bridge" : "virtual");
        }
        if (redact && !f->loopback.v) na_name(&f->mac, XRT_SYS_WHY_REDACTED);
        else {
            snprintf(p, sizeof p, "/sys/class/net/%s/address", nm);
            get_name(s, &f->mac, p);
        }
        /* totals count physical links only: bridges, veth and tunnels repeat their traffic */
        int counted = ISOK(f->physical) && f->physical.v;
        if (!ISOK(f->physical)) { totals_ok = 0; totals_why = f->physical.why; }
        physical_count += counted;
        if (counted && have) {
            rx += f->rx_bps.v;
            tx += f->tx_bps.v;
        }
        if (counted && (!ISOK(f->rx_bps) || !ISOK(f->tx_bps))) {
            totals_ok = 0;
            totals_why = !ISOK(f->rx_bps) ? f->rx_bps.why : f->tx_bps.why;
        }
        if (next_count < XRT_SYS_MAX_IFACES) {
            copy_str(next_prev[next_count].name, sizeof next_prev[0].name, nm);
            memcpy(next_prev[next_count].f, now, sizeof now);
            next_count++;
        }
    }
    memcpy(s->if_prev, next_prev, next_count * sizeof next_prev[0]);
    s->if_prev_count = next_count;
    if (!physical_count) { totals_ok = 0; if (totals_why == XRT_SYS_WHY_FIRST_SAMPLE) totals_why = XRT_SYS_WHY_NOT_PRESENT; }
    if (totals_ok) {
        OK(net->rx_bps, rx);
        OK(net->tx_bps, tx);
    } else {
        NA(net->rx_bps, totals_why);
        NA(net->tx_bps, totals_why);
    }
    if (!s->live) {
        detail(&snap->group[XRT_SYS_G_NETWORK], 0, "addresses need the live system");
        return;
    }
    struct ifaddrs *ifa = NULL;
    s->syscalls += 4;
    if (getifaddrs(&ifa) != 0) {
        detail(&snap->group[XRT_SYS_G_NETWORK], errno, "getifaddrs: %s", strerror(errno));
        return;
    }
    for (struct ifaddrs *a = ifa; a; a = a->ifa_next) {
        if (!a->ifa_addr || (a->ifa_addr->sa_family != AF_INET && a->ifa_addr->sa_family != AF_INET6)) continue;
        for (uint32_t i = 0; i < net->count; ++i) {
            struct xrt_sys_iface *f = &net->iface[i];
            if (strcmp(f->name, a->ifa_name) || f->addr_count >= XRT_SYS_MAX_ADDRS) continue;
            int fam = a->ifa_addr->sa_family;
            const void *raw = fam == AF_INET ? (const void *)&((struct sockaddr_in *)a->ifa_addr)->sin_addr
                                             : (const void *)&((struct sockaddr_in6 *)a->ifa_addr)->sin6_addr;
            uint32_t k = f->addr_count++;
            f->addr_family[k] = fam == AF_INET ? 4 : 6;
            if (redact && !loopback_addr(fam, raw)) {
                na_name(&f->addr[k], XRT_SYS_WHY_REDACTED);
                continue;
            }
            char text[INET6_ADDRSTRLEN];
            inet_ntop(fam, raw, text, sizeof text);
            int len = 0;
            if (a->ifa_netmask) {
                const uint8_t *m = fam == AF_INET ? (const uint8_t *)&((struct sockaddr_in *)a->ifa_netmask)->sin_addr
                                                  : (const uint8_t *)&((struct sockaddr_in6 *)a->ifa_netmask)->sin6_addr;
                for (int j = 0; j < (fam == AF_INET ? 4 : 16); ++j) len += __builtin_popcount(m[j]);
            }
            char out[64];
            snprintf(out, sizeof out, "%s/%d", text, len);
            set_name(&f->addr[k], out);
        }
    }
    freeifaddrs(ifa);
}

/* ---- processes ---- */
static int pw_cmp(const void *a, const void *b)
{
    uint32_t x = ((const struct pw *)a)->uid, y = ((const struct pw *)b)->uid;
    return x < y ? -1 : x > y;
}
static void load_passwd(struct xrt_sys *s)
{
    char full[PATH_MAX];
    struct stat st;
    s->syscalls++;
    if (stat(path_of(s, "/etc/passwd", full, sizeof full), &st) != 0) return;
    if (s->pw && st.st_mtime == s->pw_mtime) return;
    char *b = malloc(1 << 20);
    if (!b) return;
    ssize_t n = rd(s, "/etc/passwd", b, 1 << 20);
    free(s->pw);
    s->pw = NULL;
    s->pw_count = 0;
    uint32_t cap = 0;
    for (char *line = n > 0 ? b : NULL; line && *line;) {
        char *next = strchr(line, '\n');
        if (next) *next++ = 0;
        char *c1 = strchr(line, ':'), *c2 = c1 ? strchr(c1 + 1, ':') : NULL;
        if (c1 && c2 && c1 - line < 32) {
            if (s->pw_count == cap) {
                cap = cap ? cap * 2 : 64;
                struct pw *np = realloc(s->pw, cap * sizeof *np);
                if (!np) break;
                s->pw = np;
            }
            struct pw *p = &s->pw[s->pw_count++];
            memcpy(p->name, line, (size_t)(c1 - line));
            p->name[c1 - line] = 0;
            p->uid = (uint32_t)strtoul(c2 + 1, NULL, 10);
        }
        line = next;
    }
    free(b);
    if (s->pw_count) qsort(s->pw, s->pw_count, sizeof *s->pw, pw_cmp);
    s->pw_mtime = st.st_mtime;
}
static const char *user_name(struct xrt_sys *s, uint32_t uid)
{
    struct pw key = {.uid = uid};
    struct pw *p = s->pw_count ? bsearch(&key, s->pw, s->pw_count, sizeof *s->pw, pw_cmp) : NULL;
    return p ? p->name : NULL;
}
static int proc_cmp(const void *a, const void *b)
{
    int32_t x = ((const struct xrt_sys_proc *)a)->pid, y = ((const struct xrt_sys_proc *)b)->pid;
    return x < y ? -1 : x > y;
}
static void add_owner(struct xrt_sys *s, uint64_t inode, int32_t pid)
{
    if (s->owner_count == s->owner_cap) {
        if (s->owner_cap >= MAX_SOCK_MAP) {
            s->owners_limited = 1;
            return;
        }
        uint32_t cap = s->owner_cap ? s->owner_cap * 2 : 1024;
        struct sock_owner *n = realloc(s->owners, cap * sizeof *n);
        if (!n) {
            s->owners_limited = 1;
            return;
        }
        s->owners = n;
        s->owner_cap = cap;
    }
    s->owners[s->owner_count++] = (struct sock_owner){inode, pid};
}
struct linux_dirent64 { uint64_t ino; int64_t off; unsigned short reclen; unsigned char type; char name[]; };
/* Effective uid from /proc/PID/status. The /proc/PID inodes of a non-dumpable
 * task are owned by root whatever its real owner, so fstat alone would lie. */
static int status_uid(struct xrt_sys *s, int pfd, const char *pidname, uint32_t *uid)
{
    char path[48], b[2048];
    snprintf(path, sizeof path, "%s/status", pidname);
    ssize_t n = rdat(s, pfd, path, b, sizeof b);
    if (n < 0) return (int)n;
    char *u = strstr(b, "\nUid:");
    unsigned real, eff;
    if (!u || sscanf(u + 5, "%u %u", &real, &eff) != 2) return -EBADMSG;
    *uid = eff;
    return 0;
}
/* Counts entries of /proc/PID/fd; with links, records socket inodes. Returns
 * count or -errno; *limited when max was reached. */
static int64_t scan_fds(struct xrt_sys *s, int pfd, const char *pidname, int32_t pid, int links, int *limited)
{
    *limited = 0;
    char path[48];
    snprintf(path, sizeof path, "%s/fd", pidname);
    if (!links && s->live) {
        /* Linux 6.2+ reports the open descriptor count as the size of /proc/PID/fd */
        struct stat st;
        s->syscalls++;
        if (fstatat(pfd, path, &st, 0) != 0) return -errno;
        if (st.st_size > 0) return (int64_t)st.st_size;
    }
    int fd = sys_openat(s, pfd, path, O_DIRECTORY);
    if (fd < 0) return -errno;
    char buf[8192];
    int64_t count = 0;
    for (;;) {
        s->syscalls++;
        long n = syscall(SYS_getdents64, fd, buf, sizeof buf);
        if (n < 0) {
            int e = errno;
            sys_close(s, fd);
            return count ? count : -e;
        }
        if (n == 0) break;
        for (long off = 0; off < n;) {
            struct linux_dirent64 *e = (struct linux_dirent64 *)(buf + off);
            off += e->reclen;
            if (e->name[0] == '.') continue;
            if ((uint64_t)count >= s->lim.max_fds_counted) {
                *limited = 1;
                /* stop counting, but keep resolving socket owners (bounded by
                 * the owner map) so no socket is mislabelled "not present" */
                if (!links || s->owners_limited) break;
            } else count++;
            if (links && e->type == DT_LNK) {
                char t[64];
                s->syscalls++;
                ssize_t ln = readlinkat(fd, e->name, t, sizeof t - 1);
                if (ln > 8 && !memcmp(t, "socket:[", 8)) {
                    t[ln] = 0;
                    add_owner(s, strtoull(t + 8, NULL, 10), pid);
                }
            }
        }
        if (*limited && (!links || s->owners_limited)) break;
    }
    sys_close(s, fd);
    return count;
}
static int owner_cmp(const void *a, const void *b)
{
    uint64_t x = ((const struct sock_owner *)a)->inode, y = ((const struct sock_owner *)b)->inode;
    return x < y ? -1 : x > y;
}

static void read_cmdline(struct xrt_sys *s, int pfd, const char *pidname, struct xrt_sys_name *f)
{
    char b[sizeof f->s], path[48];
    snprintf(path, sizeof path, "%s/cmdline", pidname);
    int fd = sys_openat(s, pfd, path, 0);
    if (fd < 0) {
        na_name(f, why_errno(errno));
        return;
    }
    s->syscalls++;
    ssize_t n = read(fd, b, sizeof b - 1);
    sys_close(s, fd);
    if (n < 0) {
        na_name(f, why_errno(errno));
        return;
    }
    if (n == 0) { /* kernel thread or zombie */
        na_name(f, XRT_SYS_WHY_NOT_PRESENT);
        return;
    }
    s->bytes += (uint64_t)n;
    while (n > 0 && b[n - 1] == 0) --n;
    for (ssize_t i = 0; i < n; ++i)
        if (b[i] == 0 || b[i] == '\n' || b[i] == '\t') b[i] = ' ';
    b[n] = 0;
    set_name(f, b);
}
static void read_cgroup(struct xrt_sys *s, int pfd, const char *pidname, struct xrt_sys_name *f)
{
    char b[512], path[48];
    snprintf(path, sizeof path, "%s/cgroup", pidname);
    ssize_t n = rdat(s, pfd, path, b, sizeof b);
    if (n < 0) {
        na_name(f, why_errno((int)-n));
        return;
    }
    /* cgroup v2 line "0::/path"; otherwise the first line's path */
    char *p = !strncmp(b, "0::", 3) ? b + 3 : strstr(b, "\n0::");
    if (p && p != b + 3) p += 4;
    if (!p) {
        char *c1 = strchr(b, ':'), *c2 = c1 ? strchr(c1 + 1, ':') : NULL;
        p = c2 ? c2 + 1 : NULL;
    }
    if (!p) {
        na_name(f, XRT_SYS_WHY_PARSE_ERROR);
        return;
    }
    char *nl = strchr(p, '\n');
    if (nl) *nl = 0;
    set_name(f, p);
}

static struct proc_stat_fd *stat_slot(struct xrt_sys *s, int32_t pid) {
    if (!s->stat_fd_limit) return NULL;
    const size_t first = ((uint32_t)pid * UINT32_C(2654435761)) & (PROC_STAT_SLOTS - 1);
    struct proc_stat_fd *empty = NULL;
    for (size_t n = 0; n < 16; ++n) {
        struct proc_stat_fd *slot = &s->stat_fd[(first+n) & (PROC_STAT_SLOTS-1)];
        if (slot->pid == pid) return slot;
        if (!slot->pid && !empty) empty = slot;
    }
    return s->stat_fd_count < s->stat_fd_limit ? empty : NULL;
}
static void stat_drop(struct xrt_sys *s, struct proc_stat_fd *slot) {
    if (!slot || !slot->pid) return;
    sys_close(s, slot->fd); slot->pid = 0; s->stat_fd_count--;
}
static ssize_t stat_read(struct xrt_sys *s, int fd) {
    ssize_t n;
    do { s->syscalls++; n = pread(fd, s->buf, 1023, 0); } while (n < 0 && errno == EINTR);
    s->buf[n > 0 ? n : 0] = 0;
    if (n > 0) s->bytes += (uint64_t)n;
    return n;
}

static void collect_processes(struct xrt_sys *s, struct xrt_sys_snapshot *snap, double dt, int have_dt, int links,
                              int want_procs, uint64_t deadline)
{
    struct xrt_sys_processes *ps = &snap->processes;
    struct xrt_sys_group *g = &snap->group[XRT_SYS_G_PROCESSES];
    int redact = (s->lim.flags & XRT_SYS_REDACT) != 0;
    if (want_procs) s->proc_seq++;
    s->owner_count = 0;
    s->owners_limited = 0;
    s->owners_denied = 0;
    if (want_procs) {
        ps->capacity = s->lim.max_processes;
        ps->proc = calloc(ps->capacity ? ps->capacity : 1, sizeof *ps->proc);
        if (!ps->proc) {
            ps->capacity = 0;
            detail(g, ENOMEM, "out of memory");
        }
        load_passwd(s);
    }
    int pfd = sys_open(s, "/proc", O_DIRECTORY);
    if (pfd < 0) {
        int e = errno;
        if (want_procs) fail(g, e, "/proc");
        if (links) detail(&snap->group[XRT_SYS_G_CONNECTIONS], e, "/proc: %s; socket owners unresolved", strerror(e));
        return;
    }
    char buf[65536];
    uint64_t total = 0;
    int stop = 0;
    for (;;) {
        s->syscalls++;
        long n = syscall(SYS_getdents64, pfd, buf, sizeof buf);
        if (n <= 0) break;
        for (long off = 0; off < n; ) {
            struct linux_dirent64 *e = (struct linux_dirent64 *)(buf + off);
            off += e->reclen;
            if (e->name[0] < '1' || e->name[0] > '9') continue;
            total++;
            if (stop) continue;
            if ((total & 63) == 0 && (uint64_t)mono_ns() > deadline) {
                stop = 1;
                detail(g, 0, "sample budget reached after %llu processes", (unsigned long long)total);
            }
            int32_t pid = (int32_t)strtol(e->name, NULL, 10);
            struct xrt_sys_proc *p = NULL;
            if (want_procs) {
                if (ps->count >= ps->capacity) {
                    ps->truncated++;
                    if (!links) continue;
                } else p = &ps->proc[ps->count];
            }
            if (!p) {
                int lim;
                uint32_t eu;
                if (scan_fds(s, pfd, e->name, pid, 1, &lim) < 0 && status_uid(s, pfd, e->name, &eu) == 0 && eu == s->euid)
                    s->owners_denied = 1;
                continue;
            }
            /* stat alone for most processes: open "PID/stat", read once, fstat for the owner */
            char sp[32];
            snprintf(sp, sizeof sp, "%s/stat", e->name);
            struct proc_stat_fd *slot = stat_slot(s, pid);
            int sfd = slot && slot->pid ? slot->fd : sys_openat(s, pfd, sp, 0);
            if (sfd < 0) continue; /* exited */
            ssize_t sn = stat_read(s, sfd);
            if (sn <= 0 && slot && slot->pid) {
                /* The pinned task exited. Re-open the current path, if any. */
                stat_drop(s, slot);
                sfd = sys_openat(s, pfd, sp, 0);
                if (sfd < 0) continue;
                sn = stat_read(s, sfd);
            }
            if (slot && sn > 0) {
                if (!slot->pid) { slot->pid = pid; slot->fd = sfd; s->stat_fd_count++; }
                slot->seen = s->proc_seq;
            }
            /* the owner is cached by identity like the command line below */
            struct xrt_sys_proc *cached = NULL;
            {
                struct xrt_sys_proc key = {.pid = pid};
                cached = s->prev_count ? bsearch(&key, s->prev, s->prev_count, sizeof *s->prev, proc_cmp) : NULL;
            }
            struct stat dst;
            int uid_ok = 0, uid_err = 0, uid_cached = 0;
            if (cached && ISOK(cached->uid) && (s->proc_seq + (uint64_t)pid) % 16 != 0) {
                dst.st_uid = (uid_t)cached->uid.v;
                uid_ok = uid_cached = 1;
            } else {
                s->syscalls++;
                uid_ok = fstat(sfd, &dst) == 0;
                uid_err = errno;
            }
            if (!slot || !slot->pid) sys_close(s, sfd);
            char *rp = sn > 0 ? strrchr(s->buf, ')') : NULL;
            char *lp = sn > 0 ? strchr(s->buf, '(') : NULL;
            if (!rp || !lp) continue; /* vanished between readdir and read */
            memset(p, 0, sizeof *p);
            p->pid = pid;
            size_t cl = (size_t)(rp - lp - 1);
            if (cl >= sizeof p->comm) cl = sizeof p->comm - 1;
            memcpy(p->comm, lp + 1, cl);
            p->comm[cl] = 0;
            char state;
            int ppid;
            unsigned flags;
            unsigned long long ut, st, start, vsize;
            long nice, threads, rss;
            int got = sscanf(rp + 2,
                             "%c %d %*d %*d %*d %*d %u %*u %*u %*u %*u %llu %llu %*d %*d %*d %ld %ld %*d %llu %llu %ld",
                             &state, &ppid, &flags, &ut, &st, &nice, &threads, &start, &vsize, &rss);
            if (got != 10) continue;
            p->state = state;
            p->start_ticks = start;
            OK(p->ppid, (uint64_t)ppid);
            OK(p->start_s, (double)start / (double)s->hz);
            OK(p->threads, (uint64_t)threads);
            OK(p->vsize, vsize);
            OK(p->rss, (uint64_t)rss * (uint64_t)s->page);
            OK(p->nice, (uint64_t)(nice + 20));
            OK(p->kernel_thread, (flags & 0x00200000u) != 0);
            uint64_t ticks = ut + st;
            OK(p->cpu_time_ns, ticks * (1000000000ull / (uint64_t)s->hz));
            const struct xrt_sys_proc *old = cached && cached->start_ticks == start ? cached : NULL;
            if (old && have_dt) rate(&p->cpu_pct, p->cpu_time_ns.v, old->cpu_time_ns.v, 1, dt, 1e-7);
            else NA(p->cpu_pct, XRT_SYS_WHY_FIRST_SAMPLE);
            if (uid_cached && (!old || strcmp(old->comm, p->comm))) { /* new identity or exec: re-check owner */
                int fd2 = sys_openat(s, pfd, sp, 0);
                s->syscalls++;
                uid_ok = fd2 >= 0 && fstat(fd2, &dst) == 0;
                uid_err = errno;
                if (fd2 >= 0) sys_close(s, fd2);
                uid_cached = 0;
            }
            if (uid_ok && !uid_cached && dst.st_uid == 0 && !p->kernel_thread.v) {
                /* root-owned inode: genuine root or a non-dumpable task */
                uint32_t eu;
                int r = status_uid(s, pfd, e->name, &eu);
                if (r == 0) dst.st_uid = eu;
                else {
                    uid_ok = 0;
                    uid_err = -r;
                }
            }
            if (uid_ok) OK(p->uid, dst.st_uid);
            else NA(p->uid, why_errno(uid_err));
            const char *un = ISOK(p->uid) ? user_name(s, (uint32_t)p->uid.v) : NULL;
            if (redact) na_name(&p->user, XRT_SYS_WHY_REDACTED);
            else if (un) set_name(&p->user, un);
            else na_name(&p->user, XRT_SYS_WHY_NOT_PRESENT);
            /* cmdline, cgroup and access denials rarely change: reuse unless
             * comm changed (exec), refreshing each process every 16 samples */
            int fresh = !old || strcmp(old->comm, p->comm) || (s->proc_seq + (uint64_t)pid) % 16 == 0;
            char leaf[48];
            if (redact) na_name(&p->cmdline, XRT_SYS_WHY_REDACTED);
            else if (!fresh && old->cmdline.why != XRT_SYS_WHY_REDACTED) p->cmdline = old->cmdline;
            else read_cmdline(s, pfd, e->name, &p->cmdline);
            if (!fresh) p->cgroup = old->cgroup;
            else read_cgroup(s, pfd, e->name, &p->cgroup);
            /* io: owner-only; remember a denial instead of retrying each sample */
            if (s->lim.flags & XRT_SYS_LIGHT_PROCESSES) {
                NA(p->io_read_bytes, XRT_SYS_WHY_NOT_COLLECTED);
                NA(p->io_write_bytes, XRT_SYS_WHY_NOT_COLLECTED);
            } else if (old && old->io_read_bytes.why == XRT_SYS_WHY_NEEDS_PRIVILEGE && !fresh) {
                NA(p->io_read_bytes, XRT_SYS_WHY_NEEDS_PRIVILEGE);
                NA(p->io_write_bytes, XRT_SYS_WHY_NEEDS_PRIVILEGE);
            } else {
                char b[512];
                snprintf(leaf, sizeof leaf, "%s/io", e->name);
                ssize_t in = rdat(s, pfd, leaf, b, sizeof b);
                unsigned long long rb, wb;
                char *r = in > 0 ? strstr(b, "\nread_bytes: ") : NULL, *w = in > 0 ? strstr(b, "\nwrite_bytes: ") : NULL;
                if (r && w && sscanf(r + 13, "%llu", &rb) == 1 && sscanf(w + 14, "%llu", &wb) == 1) {
                    OK(p->io_read_bytes, rb);
                    OK(p->io_write_bytes, wb);
                } else {
                    uint8_t why = in < 0 ? why_errno((int)-in) : XRT_SYS_WHY_PARSE_ERROR;
                    NA(p->io_read_bytes, why);
                    NA(p->io_write_bytes, why);
                }
            }
            if (ISOK(p->io_read_bytes) && old && have_dt && ISOK(old->io_read_bytes)) {
                rate(&p->io_read_bps, p->io_read_bytes.v, old->io_read_bytes.v, 1, dt, 1);
                rate(&p->io_write_bps, p->io_write_bytes.v, old->io_write_bytes.v, 1, dt, 1);
            } else {
                uint8_t why = ISOK(p->io_read_bytes) ? XRT_SYS_WHY_FIRST_SAMPLE : p->io_read_bytes.why;
                NA(p->io_read_bps, why);
                NA(p->io_write_bps, why);
            }
            NA(p->net_bps, XRT_SYS_WHY_NOT_SUPPORTED);
            if ((s->lim.flags & XRT_SYS_LIGHT_PROCESSES) && !links) NA(p->fds, XRT_SYS_WHY_NOT_COLLECTED);
            else if (old && old->fds.why == XRT_SYS_WHY_NEEDS_PRIVILEGE && !fresh) {
                NA(p->fds, XRT_SYS_WHY_NEEDS_PRIVILEGE);
                if (links && ISOK(p->uid) && p->uid.v == s->euid) s->owners_denied = 1;
            }
            else {
                int lim;
                int64_t fds = scan_fds(s, pfd, e->name, pid, links, &lim);
                if (links && fds < 0 && ISOK(p->uid) && p->uid.v == s->euid) s->owners_denied = 1;
                if (fds < 0) NA(p->fds, why_errno((int)-fds));
                else if (lim) {
                    p->fds.v = (uint64_t)fds;
                    p->fds.st = XRT_SYS_STALE; /* lower bound */
                    p->fds.why = XRT_SYS_WHY_LIMIT;
                } else OK(p->fds, (uint64_t)fds);
            }
            if (s->lim.flags & XRT_SYS_PSS) {
                char b[1024];
                snprintf(leaf, sizeof leaf, "%s/smaps_rollup", e->name);
                ssize_t in = rdat(s, pfd, leaf, b, sizeof b);
                char *q = in > 0 ? strstr(b, "\nPss:") : NULL;
                unsigned long long kb;
                if (q && sscanf(q + 5, "%llu", &kb) == 1) OK(p->pss, kb * 1024);
                else NA(p->pss, in < 0 ? why_errno((int)-in) : XRT_SYS_WHY_NOT_PRESENT);
            } else NA(p->pss, XRT_SYS_WHY_NOT_COLLECTED);
            ps->count++;
        }
    }
    sys_close(s, pfd);
    if (want_procs) for (size_t i = 0; i < PROC_STAT_SLOTS; ++i)
        if (s->stat_fd[i].pid && s->stat_fd[i].seen != s->proc_seq) stat_drop(s, &s->stat_fd[i]);
    if (want_procs) {
        qsort(ps->proc, ps->count, sizeof *ps->proc, proc_cmp);
        OK(snap->summary.processes, total);
        /* keep a private copy for next-sample rates */
        struct xrt_sys_proc *keep = ps->count ? malloc(ps->count * sizeof *keep) : NULL;
        free(s->prev);
        s->prev = keep;
        s->prev_count = keep ? ps->count : 0;
        if (keep) memcpy(keep, ps->proc, ps->count * sizeof *keep);
        if (stop) ps->truncated += (uint32_t)(total - ps->count - ps->truncated);
    }
    if (s->owner_count) qsort(s->owners, s->owner_count, sizeof *s->owners, owner_cmp);
}

/* ---- connections ---- */
static const char *tcp_state(uint8_t st, int udp)
{
    static const char *const names[] = {"UNKNOWN", "ESTABLISHED", "SYN_SENT", "SYN_RECV", "FIN_WAIT1", "FIN_WAIT2", "TIME_WAIT",
                                        "CLOSE", "CLOSE_WAIT", "LAST_ACK", "LISTEN", "CLOSING", "NEW_SYN_RECV"};
    if (udp) return st == 1 ? "ESTABLISHED" : st == 7 ? "UNCONN" : st < COUNT_OF(names) ? names[st] : "UNKNOWN";
    return st < COUNT_OF(names) ? names[st] : "UNKNOWN";
}
static void endpoint(struct xrt_sys_name *f, int fam, const void *addr, uint16_t port, int redact)
{
    if (redact && !loopback_addr(fam, addr)) {
        na_name(f, XRT_SYS_WHY_REDACTED);
        return;
    }
    char t[INET6_ADDRSTRLEN], o[64];
    inet_ntop(fam, addr, t, sizeof t);
    snprintf(o, sizeof o, fam == AF_INET6 ? "[%s]:%u" : "%s:%u", t, port);
    set_name(f, o);
}
static void conn_owner(struct xrt_sys *s, struct xrt_sys_snapshot *snap, struct xrt_sys_conn *c, int uid_known)
{
    struct xrt_sys_connections *cs = &snap->connections;
    if (!c->inode) {
        NA(c->pid, XRT_SYS_WHY_NOT_PRESENT); /* TIME_WAIT etc.: no owning file */
        return;
    }
    struct sock_owner key = {.inode = c->inode};
    struct sock_owner *o = s->owner_count ? bsearch(&key, s->owners, s->owner_count, sizeof *s->owners, owner_cmp) : NULL;
    if (o) {
        OK(c->pid, (uint64_t)o->pid);
        struct xrt_sys_proc pk = {.pid = o->pid};
        const struct xrt_sys_proc *p =
            snap->processes.count ? bsearch(&pk, snap->processes.proc, snap->processes.count, sizeof pk, proc_cmp) : NULL;
        if (p) copy_str(c->comm, sizeof c->comm, p->comm);
        return;
    }
    cs->owners_unresolved.v++;
    if (s->owners_limited) NA(c->pid, XRT_SYS_WHY_LIMIT);
    else if (s->euid != 0 && (!uid_known || !ISOK(c->uid) || c->uid.v != s->euid)) NA(c->pid, XRT_SYS_WHY_NEEDS_PRIVILEGE);
    else if (s->owners_denied) NA(c->pid, XRT_SYS_WHY_NEEDS_PRIVILEGE); /* e.g. our own non-dumpable process */
    else NA(c->pid, XRT_SYS_WHY_NOT_PRESENT);
}
static struct xrt_sys_conn *conn_slot(struct xrt_sys_snapshot *snap)
{
    struct xrt_sys_connections *cs = &snap->connections;
    if (cs->count >= cs->capacity) {
        cs->truncated++;
        return NULL;
    }
    struct xrt_sys_conn *c = &cs->conn[cs->count++];
    memset(c, 0, sizeof *c);
    return c;
}
/* One sock_diag dump; returns 0 or -errno. */
static int diag_dump(struct xrt_sys *s, struct xrt_sys_snapshot *snap, int fd, int family, int proto)
{
    struct { struct nlmsghdr h; union { struct inet_diag_req_v2 in; struct unix_diag_req un; } r; } req;
    memset(&req, 0, sizeof req);
    req.h.nlmsg_type = SOCK_DIAG_BY_FAMILY;
    req.h.nlmsg_flags = NLM_F_REQUEST | NLM_F_DUMP;
    if (family == AF_UNIX) {
        req.h.nlmsg_len = NLMSG_LENGTH(sizeof req.r.un);
        req.r.un.sdiag_family = AF_UNIX;
        req.r.un.udiag_states = ~0u;
        req.r.un.udiag_show = UDIAG_SHOW_NAME | UDIAG_SHOW_RQLEN | UDIAG_SHOW_UID;
    } else {
        req.h.nlmsg_len = NLMSG_LENGTH(sizeof req.r.in);
        req.r.in.sdiag_family = (uint8_t)family;
        req.r.in.sdiag_protocol = (uint8_t)proto;
        req.r.in.idiag_states = ~0u;
    }
    struct sockaddr_nl nl = {.nl_family = AF_NETLINK};
    s->syscalls++;
    if (sendto(fd, &req, req.h.nlmsg_len, 0, (struct sockaddr *)&nl, sizeof nl) < 0) return -errno;
    struct xrt_sys_connections *cs = &snap->connections;
    int redact = (s->lim.flags & XRT_SYS_REDACT) != 0;
    for (;;) {
        s->syscalls++;
        ssize_t n = recv(fd, s->buf, sizeof s->buf, 0);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -errno;
        }
        s->bytes += (uint64_t)n;
        for (struct nlmsghdr *h = (struct nlmsghdr *)s->buf; NLMSG_OK(h, (size_t)n); h = NLMSG_NEXT(h, n)) {
            if (h->nlmsg_type == NLMSG_DONE) return 0;
            if (h->nlmsg_type == NLMSG_ERROR) {
                struct nlmsgerr *e = NLMSG_DATA(h);
                return e->error ? e->error : -EIO;
            }
            if (family == AF_UNIX) {
                struct unix_diag_msg *m = NLMSG_DATA(h);
                cs->unix_sockets.v++;
                struct xrt_sys_conn *c = conn_slot(snap);
                if (!c) continue;
                c->proto = XRT_SYS_UNIX;
                c->inode = m->udiag_ino;
                const char *st = m->udiag_state == 10 ? "LISTEN" : m->udiag_state == 1 ? "ESTABLISHED" : "UNCONN";
                copy_str(c->state, sizeof c->state, st);
                if (m->udiag_state == 10) cs->listening.v++;
                if (m->udiag_state == 1) cs->established.v++;
                na_name(&c->local, XRT_SYS_WHY_NOT_PRESENT);
                na_name(&c->remote, XRT_SYS_WHY_NOT_PRESENT);
                NA(c->uid, XRT_SYS_WHY_NOT_PRESENT);
                NA(c->rx_queue, XRT_SYS_WHY_NOT_PRESENT);
                NA(c->tx_queue, XRT_SYS_WHY_NOT_PRESENT);
                int len = (int)(h->nlmsg_len - NLMSG_LENGTH(sizeof *m));
                for (struct rtattr *a = (struct rtattr *)(m + 1); RTA_OK(a, len); a = RTA_NEXT(a, len)) {
                    if (a->rta_type == UNIX_DIAG_NAME) {
                        char path[sizeof c->local.s];
                        size_t pl = RTA_PAYLOAD(a);
                        const char *src = RTA_DATA(a);
                        if (pl >= sizeof path) pl = sizeof path - 1;
                        memcpy(path, src, pl);
                        path[pl] = 0;
                        if (pl && path[0] == 0) path[0] = '@';
                        for (size_t i = 1; i < pl; ++i) if (!path[i]) path[i] = '@';
                        int keep = !strncmp(path, "/run/", 5) || !strncmp(path, "/var/run/", 9) ||
                                   !strncmp(path, "/tmp/.X11-unix/", 15) || !strncmp(path, "/dev/", 5);
                        if (keep && strstr(path, "/user/")) keep = 0;
                        if (redact && !keep) na_name(&c->local, XRT_SYS_WHY_REDACTED);
                        else set_name(&c->local, path);
                    } else if (a->rta_type == UNIX_DIAG_RQLEN && RTA_PAYLOAD(a) >= sizeof(struct unix_diag_rqlen)) {
                        struct unix_diag_rqlen *q = RTA_DATA(a);
                        OK(c->rx_queue, q->udiag_rqueue);
                        OK(c->tx_queue, q->udiag_wqueue);
                    } else if (a->rta_type == UNIX_DIAG_UID && RTA_PAYLOAD(a) >= 4) {
                        uint32_t u;
                        memcpy(&u, RTA_DATA(a), 4);
                        OK(c->uid, u);
                    }
                }
                conn_owner(s, snap, c, ISOK(c->uid));
                continue;
            }
            struct inet_diag_msg *m = NLMSG_DATA(h);
            int udp = proto == IPPROTO_UDP;
            if (udp) cs->udp.v++;
            else cs->tcp.v++;
            if (m->idiag_state == 10) cs->listening.v++;
            if (m->idiag_state == 1) cs->established.v++;
            struct xrt_sys_conn *c = conn_slot(snap);
            if (!c) continue;
            c->proto = udp ? XRT_SYS_UDP : XRT_SYS_TCP;
            c->family = family == AF_INET ? 4 : 6;
            copy_str(c->state, sizeof c->state, tcp_state(m->idiag_state, udp));
            endpoint(&c->local, family, m->id.idiag_src, ntohs(m->id.idiag_sport), redact);
            endpoint(&c->remote, family, m->id.idiag_dst, ntohs(m->id.idiag_dport), redact);
            c->inode = m->idiag_inode;
            OK(c->uid, m->idiag_uid);
            OK(c->rx_queue, m->idiag_rqueue);
            OK(c->tx_queue, m->idiag_wqueue);
            conn_owner(s, snap, c, 1);
        }
    }
}
static void collect_connections(struct xrt_sys *s, struct xrt_sys_snapshot *snap)
{
    struct xrt_sys_connections *cs = &snap->connections;
    struct xrt_sys_group *g = &snap->group[XRT_SYS_G_CONNECTIONS];
    struct xrt_sys_u64 *t[] = {&cs->tcp, &cs->udp, &cs->unix_sockets, &cs->listening, &cs->established, &cs->owners_unresolved};
    if (!s->live) {
        for (size_t i = 0; i < COUNT_OF(t); ++i) NA(*t[i], XRT_SYS_WHY_NOT_SUPPORTED);
        detail(g, 0, "sock_diag needs the live system");
        g->st = XRT_SYS_UNAVAILABLE;
        g->why = XRT_SYS_WHY_NOT_SUPPORTED;
        return;
    }
    cs->capacity = s->lim.max_connections;
    cs->conn = calloc(cs->capacity ? cs->capacity : 1, sizeof *cs->conn);
    if (!cs->conn) cs->capacity = 0;
    for (size_t i = 0; i < COUNT_OF(t); ++i) OK(*t[i], 0);
    s->syscalls++;
    int fd = socket(AF_NETLINK, SOCK_DGRAM | SOCK_CLOEXEC, NETLINK_SOCK_DIAG);
    if (fd < 0) {
        for (size_t i = 0; i < COUNT_OF(t); ++i) NA(*t[i], why_errno(errno));
        detail(g, errno, "sock_diag: %s", strerror(errno));
        return;
    }
    struct timeval tv = {.tv_sec = 0, .tv_usec = 250000};
    s->syscalls++;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    static const struct { int family, proto; } dumps[] = {
        {AF_INET, IPPROTO_TCP}, {AF_INET6, IPPROTO_TCP}, {AF_INET, IPPROTO_UDP}, {AF_INET6, IPPROTO_UDP}, {AF_UNIX, 0}};
    for (size_t i = 0; i < COUNT_OF(dumps); ++i) {
        int r = diag_dump(s, snap, fd, dumps[i].family, dumps[i].proto);
        if (r < 0) {
            struct xrt_sys_u64 *f = dumps[i].family == AF_UNIX ? &cs->unix_sockets : dumps[i].proto == IPPROTO_UDP ? &cs->udp : &cs->tcp;
            NA(*f, why_errno(-r));
            detail(g, -r, "sock_diag %s/%s: %s", dumps[i].family == AF_UNIX ? "unix" : dumps[i].family == AF_INET ? "inet" : "inet6",
                   dumps[i].proto == IPPROTO_UDP ? "udp" : "tcp", strerror(-r));
        }
    }
    sys_close(s, fd);
    if (s->owners_limited) detail(g, 0, "socket owner map limit reached");
}

/* ---- power: GPUs, RAPL, supplies ---- */
static void collect_power(struct xrt_sys *s, struct xrt_sys_snapshot *snap, double dt)
{
    struct xrt_sys_power *p = &snap->power;
    struct xrt_sys_group *g = &snap->group[XRT_SYS_G_POWER];
    size_t n;
    int err;
    char **drm = list_dir(s, "/sys/class/drm", &n, &err);
    char gpu_pci[XRT_SYS_MAX_GPUS][32] = {{0}};
    p->gpu_count = 0;
    for (size_t i = 0; i < n && p->gpu_count < XRT_SYS_MAX_GPUS; ++i) {
        unsigned card;
        char tail;
        if (sscanf(drm[i], "card%u%c", &card, &tail) != 1) continue;
        struct xrt_sys_gpu *u = &p->gpu[p->gpu_count++];
        memset(u, 0, sizeof *u);
        copy_str(u->card, sizeof u->card, drm[i]);
        char b[512], base[96], pth[256];
        snprintf(base, sizeof base, "/sys/class/drm/%s/device", drm[i]);
        char pci[32] = "";
        if (rdf(s, b, sizeof b, "%s/uevent", base) > 0) {
            char *d = strstr(b, "DRIVER="), *q = strstr(b, "PCI_ID=");
            if (d) {
                sscanf(d + 7, "%23s", u->driver);
            }
            if (q) sscanf(q + 7, "%31s", pci);
            char *slot = strstr(b, "PCI_SLOT_NAME=");
            if (slot) sscanf(slot + 14, "%31s", gpu_pci[p->gpu_count - 1]);
        }
        for (char *c = pci; *c; ++c) if (*c >= 'A' && *c <= 'Z') *c = (char)(*c - 'A' + 'a');
        if (pci[0]) set_name(&u->name, pci);
        else na_name(&u->name, XRT_SYS_WHY_NOT_PRESENT);
        NA(u->graphics_mhz, XRT_SYS_WHY_NOT_SUPPORTED);
        NA(u->memory_mhz, XRT_SYS_WHY_NOT_SUPPORTED);
        if (!strcmp(u->driver, "nvidia")) {
            NA(u->busy_pct, XRT_SYS_WHY_NOT_SUPPORTED);
            NA(u->power_w, XRT_SYS_WHY_NOT_SUPPORTED);
            NA(u->temp_c, XRT_SYS_WHY_NOT_SUPPORTED);
            NA(u->vram_used, XRT_SYS_WHY_NOT_SUPPORTED);
            NA(u->vram_total, XRT_SYS_WHY_NOT_SUPPORTED);

            continue;
        }
        snprintf(pth, sizeof pth, "%s/gpu_busy_percent", base);
        get_f64(s, &u->busy_pct, pth, 1);
        snprintf(pth, sizeof pth, "%s/mem_info_vram_used", base);
        get_u64(s, &u->vram_used, pth);
        snprintf(pth, sizeof pth, "%s/mem_info_vram_total", base);
        get_u64(s, &u->vram_total, pth);
        NA(u->power_w, XRT_SYS_WHY_NOT_PRESENT);
        NA(u->temp_c, XRT_SYS_WHY_NOT_PRESENT);
        /* match the GPU's hwmon by device path */
        char full[PATH_MAX], gpudev[PATH_MAX];
        s->syscalls++;
        ssize_t gl = readlink(path_of(s, base, full, sizeof full), gpudev, sizeof gpudev - 1);
        if (gl <= 0) continue;
        gpudev[gl] = 0;
        const char *gb = strrchr(gpudev, '/');
        gb = gb ? gb + 1 : gpudev;
        for (uint32_t k = 0; k < s->sensor_count && k < p->sensor_count; ++k) {
            if (strcmp(s->sensors[k].device, gb)) continue;
            if (s->sensors[k].kind == XRT_SYS_POWER_W && !ISOK(u->power_w)) u->power_w = p->sensor[k].value;
            if (s->sensors[k].kind == XRT_SYS_TEMP && !ISOK(u->temp_c)) u->temp_c = p->sensor[k].value;
        }
    }
    free_list(drm, n);
    /* RAPL package energy */
    char b[64];
    ssize_t r = rd(s, "/sys/class/powercap/intel-rapl:0/energy_uj", b, sizeof b);
    if (r < 0) {
        NA(p->cpu_package_w, why_errno((int)-r));
        if (-r == EACCES || -r == EPERM) detail(g, (int)-r, "RAPL energy_uj: permission denied (root only)");
        s->rapl_have = 0;
    } else {
        uint64_t e = strtoull(b, NULL, 10);
        int64_t now = mono_ns();
        if (!s->rapl_range) {
            int64_t v;
            s->rapl_range = read_i64(s, "/sys/class/powercap/intel-rapl:0/max_energy_range_uj", &v) == 0 ? (uint64_t)v : 0;
        }
        if (!s->rapl_have) NA(p->cpu_package_w, XRT_SYS_WHY_FIRST_SAMPLE);
        else {
            uint64_t d = e >= s->rapl_prev ? e - s->rapl_prev : s->rapl_range ? s->rapl_range - s->rapl_prev + e : 0;
            double sec = (double)(now - s->rapl_mono) * 1e-9;
            if (sec > 0) OK(p->cpu_package_w, (double)d * 1e-6 / sec);
            else NA(p->cpu_package_w, XRT_SYS_WHY_FIRST_SAMPLE);
        }
        s->rapl_prev = e;
        s->rapl_mono = now;
        s->rapl_have = 1;
    }
    (void)dt;
    /* power supplies */
    NA(p->ac_online, XRT_SYS_WHY_NOT_PRESENT);
    NA(p->battery_pct, XRT_SYS_WHY_NOT_PRESENT);
    char **ps = list_dir(s, "/sys/class/power_supply", &n, &err);
    for (size_t i = 0; i < n; ++i) {
        char t[32], pth[160];
        if (rdf(s, t, sizeof t, "/sys/class/power_supply/%s/type", ps[i]) < 0) continue;
        trim(t);
        if (!strcmp(t, "Mains")) {
            snprintf(pth, sizeof pth, "/sys/class/power_supply/%s/online", ps[i]);
            get_f64(s, &p->ac_online, pth, 1);
        } else if (!strcmp(t, "Battery") && !ISOK(p->battery_pct)) {
            snprintf(pth, sizeof pth, "/sys/class/power_supply/%s/capacity", ps[i]);
            get_f64(s, &p->battery_pct, pth, 1);
        }
    }
    free_list(ps, n);
    if (s->live) xrt_sys_nvml_collect(&s->nvml, p, gpu_pci, g, mono_ns());
}

/* ---- users ---- */
static void collect_users(struct xrt_sys *s, struct xrt_sys_snapshot *snap)
{
    struct xrt_sys_users *u = &snap->users;
    int redact = (s->lim.flags & XRT_SYS_REDACT) != 0;
    int fd = sys_open(s, "/run/utmp", 0);
    if (fd < 0) fd = sys_open(s, "/var/run/utmp", 0);
    if (fd < 0) {
        snap->group[XRT_SYS_G_USERS].st = XRT_SYS_UNAVAILABLE;
        snap->group[XRT_SYS_G_USERS].why = why_errno(errno);
        detail(&snap->group[XRT_SYS_G_USERS], errno, "utmp: %s", strerror(errno));
        return;
    }
    struct utmp rec;
    char raw[sizeof rec + 1];
    for (;;) {
        ssize_t n = read_fd(s, fd, raw, sizeof raw);
        if (n < (ssize_t)sizeof rec) break;
        memcpy(&rec, raw, sizeof rec);
        if (rec.ut_type != USER_PROCESS || u->count >= XRT_SYS_MAX_USERS) continue;
        struct xrt_sys_user *e = &u->user[u->count++];
        memset(e, 0, sizeof *e);
        char name[sizeof rec.ut_user + 1], host[sizeof rec.ut_host + 1];
        memcpy(name, rec.ut_user, sizeof rec.ut_user);
        name[sizeof rec.ut_user] = 0;
        memcpy(host, rec.ut_host, sizeof rec.ut_host);
        host[sizeof rec.ut_host] = 0;
        size_t ll = strnlen(rec.ut_line, sizeof rec.ut_line);
        if (ll >= sizeof e->line) ll = sizeof e->line - 1;
        memcpy(e->line, rec.ut_line, ll);
        e->line[ll] = 0;
        if (redact) {
            na_name(&e->user, XRT_SYS_WHY_REDACTED);
            na_name(&e->host, XRT_SYS_WHY_REDACTED);
        } else {
            set_name(&e->user, name);
            if (host[0]) set_name(&e->host, host);
            else na_name(&e->host, XRT_SYS_WHY_NOT_PRESENT);
        }
        OK(e->pid, (uint64_t)rec.ut_pid);
        OK(e->login_time_s, (uint64_t)rec.ut_tv.tv_sec);
    }
    sys_close(s, fd);
}

/* ---- services: observable daemon candidates, independent of init ---- */
struct service_stat {
    char name[64], state;
    int ppid, session;
    long long tty, rss;
    unsigned flags;
    uint64_t start, ticks;
};
static int service_stat(struct xrt_sys *s, int fd, uint64_t pid, struct service_stat *st)
{
    char b[2048];
    ssize_t n = rdat(s, fd, "stat", b, sizeof b);
    if (n < 0) return (int)n;
    if (n == sizeof b - 1) return -EOVERFLOW;
    char *end, *l = strchr(b, '('), *r = strrchr(b, ')');
    unsigned long long id = strtoull(b, &end, 10), ut, kt, start;
    int group;
    if (!l || !r || l >= r || end != l - 1 || id != pid || r[1] != ' ' ||
        sscanf(r + 2, "%c %d %d %d %lld %*s %u %*s %*s %*s %*s %llu %llu %*s %*s %*s %*s %*s %*s %llu %*s %lld",
               &st->state, &st->ppid, &group, &st->session, &st->tty, &st->flags, &ut, &kt, &start, &st->rss) != 10 ||
        UINT64_MAX - ut < kt) return -EBADMSG;
    size_t len = (size_t)(r - l - 1);
    if (len >= sizeof st->name) return -EOVERFLOW;
    memcpy(st->name, l + 1, len); st->name[len] = 0;
    st->start = start; st->ticks = ut + kt;
    return 0;
}
static uint8_t service_why(int err)
{
    return err == EOVERFLOW ? XRT_SYS_WHY_LIMIT : why_errno(err);
}
/* Component comparisons avoid treating a name like user.slice-backup as a slice. */
static int service_user_cgroup(const char *path)
{
    for (const char *p = path; *p;) {
        while (*p == '/') ++p;
        const char *end = strchr(p, '/');
        size_t n = end ? (size_t)(end - p) : strlen(p);
        if ((n == 10 && !strncmp(p, "user.slice", n)) ||
            (n > 11 && !strncmp(p, "user-", 5) && !strncmp(p + n - 6, ".slice", 6)) ||
            (n == 7 && !strncmp(p, "session", n)) ||
            (n > 14 && !strncmp(p, "session-", 8) && !strncmp(p + n - 6, ".scope", 6))) return 1;
        if (!end) break;
        p = end + 1;
    }
    return 0;
}
/* v2, then name=systemd, then the first v1 hierarchy for display. Any user
 * hierarchy excludes high-UID rows even with an unset loginuid; system UIDs
 * may still qualify. */
static int service_cgroup(struct xrt_sys *s, int fd, struct xrt_sys_path *out)
{
    char b[8192];
    ssize_t n = rdat(s, fd, "cgroup", b, sizeof b);
    uint8_t why = n < 0 ? service_why((int)-n) : n == sizeof b - 1 ? XRT_SYS_WHY_LIMIT : XRT_SYS_WHY_PARSE_ERROR;
    if (n <= 0 || n == sizeof b - 1) { NA(*out, why); return -1; }
    int best = 0, user = 0;
    for (char *line = b; line && *line;) {
        char *next = strchr(line, '\n');
        if (next) *next++ = 0;
        char *a = strchr(line, ':'), *c = a ? strchr(a + 1, ':') : NULL;
        if (!a || !c || c[1] != '/') { NA(*out, XRT_SYS_WHY_PARSE_ERROR); out->s[0] = 0; return -1; }
        *c = 0;
        int rank = !strcmp(line, "0:") ? 3 : !strcmp(a + 1, "name=systemd") ? 2 : 1;
        user |= service_user_cgroup(c + 1);
        if (rank > best) {
            best = rank;
            if (strlen(c + 1) >= sizeof out->s) { out->s[0] = 0; NA(*out, XRT_SYS_WHY_LIMIT); }
            else { copy_str(out->s, sizeof out->s, c + 1); out->st = XRT_SYS_OK; out->why = XRT_SYS_WHY_NONE; }
        }
        line = next;
    }
    return best ? !user : -1;
}
static int service_cmp(const void *a, const void *b)
{
    uint64_t x = ((const struct xrt_sys_service *)a)->pid.v, y = ((const struct xrt_sys_service *)b)->pid.v;
    return x < y ? -1 : x > y;
}
/* Audit login UID is inherited across setsid/reparenting. High-UID
 * candidates require an explicitly unset value; cgroups alone never suffice. */
static void service_loginuid(struct xrt_sys *s, int fd, struct xrt_sys_u64 *out)
{
    char b[64];
    ssize_t n = rdat(s, fd, "loginuid", b, sizeof b);
    if (n < 0) { NA(*out, service_why((int)-n)); return; }
    if (n == sizeof b - 1) { NA(*out, XRT_SYS_WHY_LIMIT); return; }
    char *end;
    errno = 0;
    unsigned long long uid = strtoull(b, &end, 10);
    while (*end == ' ' || *end == '\n' || *end == '\t') ++end;
    if (!n || b[0] < '0' || b[0] > '9' || *end || errno || uid > UINT32_MAX) { NA(*out, XRT_SYS_WHY_PARSE_ERROR); return; }
    OK(*out, uid);
}
static int services_hidden(struct xrt_sys *s)
{
    char b[16384];
    if (rd(s, "/proc/mounts", b, sizeof b) < 0) return 0;
    for (char *line = b; line && *line;) {
        char *next = strchr(line, '\n');
        if (next) *next++ = 0;
        char mount[256], type[32], options[1024];
        if (sscanf(line, "%*s %255s %31s %1023s", mount, type, options) == 3 &&
            !strcmp(mount, "/proc") && !strcmp(type, "proc")) {
            for (char *option = options; option && *option;) {
                char *comma = strchr(option, ',');
                if (comma) *comma++ = 0;
                if (!strcmp(option, "hidepid=2") || !strcmp(option, "hidepid=invisible") ||
                    !strcmp(option, "hidepid=4") || !strcmp(option, "hidepid=ptraceable")) return 1;
                option = comma;
            }
        }
        line = next;
    }
    return 0;
}
static void redact_uid(struct xrt_sys_u64 *uid)
{
    if (ISOK(*uid) && uid->v != 0) { uid->v = 0; NA(*uid, XRT_SYS_WHY_REDACTED); }
}
static void redact_services(struct xrt_sys_services *sv)
{
    na_name(&sv->manager, XRT_SYS_WHY_REDACTED);
    for (uint32_t i = 0; i < sv->count; ++i) {
        struct xrt_sys_service *v = &sv->service[i];
        copy_str(v->name, sizeof v->name, "service");
        na_name(&v->user, XRT_SYS_WHY_REDACTED);
        redact_uid(&v->uid);
        if (v->loginuid.v != UINT32_MAX) redact_uid(&v->loginuid);
        v->cgroup.s[0] = 0;
        NA(v->cgroup, XRT_SYS_WHY_REDACTED);
    }
}
static void collect_services(struct xrt_sys *s, struct xrt_sys_snapshot *snap, uint64_t deadline)
{
    struct xrt_sys_group *g = &snap->group[XRT_SYS_G_SERVICES];
    struct xrt_sys_services *sv = &snap->services;
    struct service_prev next[XRT_SYS_MAX_SERVICES];
    uint32_t next_count = 0;
    uint8_t omit_why = XRT_SYS_WHY_NONE;
    memset(sv, 0, sizeof *sv);
    sv->visibility_limited = (uint32_t)services_hidden(s);
    char b[2048], db[8192];
    ssize_t n = rd(s, "/proc/1/comm", b, sizeof b);
    if (n > 0 && n < (ssize_t)sizeof sv->manager.s - 7) {
        trim(b);
        snprintf(sv->manager.s, sizeof sv->manager.s, "init: %.*s", (int)sizeof sv->manager.s - 7, b);
        sv->manager.st = XRT_SYS_OK;
    } else na_name(&sv->manager, n < 0 ? service_why((int)-n) : XRT_SYS_WHY_PARSE_ERROR);
    double uptime = 0;
    n = rd(s, "/proc/uptime", b, sizeof b);
    uint8_t up_why = n < 0 ? service_why((int)-n) : XRT_SYS_WHY_PARSE_ERROR;
    int have_uptime = n > 0 && sscanf(b, "%lf", &uptime) == 1 && uptime >= 0 && uptime < 1e15;
    int proc = sys_open(s, "/proc", O_DIRECTORY);
    if (proc < 0) {
        g->st = XRT_SYS_UNAVAILABLE; g->why = why_errno(errno);
        detail(g, errno, "cannot enumerate /proc"); s->svc_prev_count = 0; return;
    }
    struct service_stat init;
    int initfd = sys_openat(s, proc, "1", O_DIRECTORY);
    int init_session = initfd >= 0 && service_stat(s, initfd, 1, &init) == 0 ? init.session : -1;
    if (initfd >= 0) sys_close(s, initfd);
    int done = 0;
    while (!done) {
        if ((uint64_t)mono_ns() >= deadline) { sv->truncated = 1; break; }
        s->syscalls++;
        long len = syscall(SYS_getdents64, proc, db, sizeof db);
        if (len < 0) { omit_why = why_errno(errno); sv->unreadable++; break; }
        if (!len) break;
        for (long off = 0; off < len;) {
            struct linux_dirent64 *d = (struct linux_dirent64 *)(db + off);
            off += d->reclen;
            if (d->name[0] < '0' || d->name[0] > '9') continue;
            char *end;
            unsigned long pid = strtoul(d->name, &end, 10);
            if (*end || pid <= 1 || pid > INT_MAX) continue;
            if (sv->scanned >= s->lim.max_processes || (uint64_t)mono_ns() >= deadline) {
                sv->truncated = 1; done = 1; break;
            }
            sv->scanned++;
            int fd = sys_openat(s, proc, d->name, O_DIRECTORY);
            struct service_stat st, again;
            int err = fd < 0 ? -errno : service_stat(s, fd, pid, &st);
            if (err) {
                sv->unreadable++; omit_why = service_why(-err);
                if (fd >= 0) sys_close(s, fd);
                continue;
            }
            /* An orphaned daemon may retain the session of a departed leader.
             * In that case its positive SID must differ from PID 1's SID. */
            if (st.ppid != 1 || st.tty != 0 || (st.flags & 0x00200000u) ||
                !(st.session == (int)pid || (st.session > 0 && init_session >= 0 && st.session != init_session))) {
                if (st.ppid == 1 && st.tty == 0 && st.session != (int)pid && init_session < 0) {
                    sv->unreadable++; omit_why = XRT_SYS_WHY_NOT_PRESENT;
                }
                sys_close(s, fd); continue;
            }
            struct xrt_sys_service row = {0};
            unsigned real, effective;
            n = rdat(s, fd, "status", b, sizeof b);
            char *uid = n >= 0 ? strstr(b, "\nUid:") : NULL;
            if (uid) uid += 5;
            else if (n >= 4 && !strncmp(b, "Uid:", 4)) uid = b + 4;
            if (uid && sscanf(uid, "%u %u", &real, &effective) == 2) {
                OK(row.uid, effective);
                snprintf(row.user.s, sizeof row.user.s, "uid:%u", effective);
                row.user.st = XRT_SYS_OK;
            } else {
                uint8_t why = n < 0 ? service_why((int)-n) : XRT_SYS_WHY_PARSE_ERROR;
                NA(row.uid, why); na_name(&row.user, why);
            }
            int non_user = service_cgroup(s, fd, &row.cgroup);
            service_loginuid(s, fd, &row.loginuid);
            if (!ISOK(row.uid) || row.uid.v >= 1000) {
                /* Cgroups alone do not establish service provenance: both /
                 * and numeric elogind sessions can contain orphaned user apps. */
                uint8_t unknown = XRT_SYS_WHY_NONE;
                int qualifies = 0;
                if (!ISOK(row.uid)) unknown = row.uid.why;
                else if (!ISOK(row.loginuid)) unknown = row.loginuid.why;
                else if (row.loginuid.v == UINT32_MAX) {
                    if (non_user < 0) unknown = row.cgroup.why;
                    else qualifies = non_user;
                }
                if (!qualifies) {
                    if (unknown) { sv->unreadable++; omit_why = unknown; }
                    sys_close(s, fd); continue;
                }
            }
            err = service_stat(s, fd, pid, &again);
            sys_close(s, fd);
            if (err || again.start != st.start) { sv->unreadable++; omit_why = err ? service_why(-err) : XRT_SYS_WHY_GONE; continue; }
            if (sv->count == XRT_SYS_MAX_SERVICES) { sv->truncated = 1; done = 1; break; }
            copy_str(row.name, sizeof row.name, st.name);
            char state[2] = {st.state, 0}; set_name(&row.state, state);
            OK(row.pid, pid); OK(row.start_ticks, st.start);
            if (st.rss >= 0 && (uint64_t)st.rss <= UINT64_MAX / (uint64_t)s->page) OK(row.rss, (uint64_t)st.rss * (uint64_t)s->page);
            else NA(row.rss, XRT_SYS_WHY_PARSE_ERROR);
            double born = (double)st.start / (double)s->hz;
            if (have_uptime && uptime >= born) OK(row.uptime_s, uptime - born);
            else NA(row.uptime_s, have_uptime ? XRT_SYS_WHY_PARSE_ERROR : up_why);
            NA(row.cpu_pct, XRT_SYS_WHY_FIRST_SAMPLE);
            int64_t now = mono_ns();
            for (uint32_t i = 0; i < s->svc_prev_count; ++i) {
                const struct service_prev *old = &s->svc_prev[i];
                if (old->pid != pid || old->start != st.start) continue;
                if (st.ticks < old->ticks) NA(row.cpu_pct, XRT_SYS_WHY_COUNTER_RESET);
                else if (now <= old->mono) NA(row.cpu_pct, XRT_SYS_WHY_TOO_SOON);
                else OK(row.cpu_pct, (double)(st.ticks - old->ticks) / (double)s->hz * 1e11 / (double)(now - old->mono));
                break;
            }
            next[next_count++] = (struct service_prev){pid, st.start, st.ticks, now};
            sv->service[sv->count++] = row;
        }
    }
    sys_close(s, proc);
    memcpy(s->svc_prev, next, next_count * sizeof next[0]); s->svc_prev_count = next_count;
    qsort(sv->service, sv->count, sizeof sv->service[0], service_cmp);
    if (sv->truncated || sv->unreadable || sv->visibility_limited) {
        g->why = sv->truncated ? XRT_SYS_WHY_LIMIT : sv->unreadable ? omit_why : XRT_SYS_WHY_NEEDS_PRIVILEGE;
        g->st = sv->count ? XRT_SYS_OK : XRT_SYS_UNAVAILABLE;
        detail(g, 0, "partial: %u scanned, %u unreadable%s%s", sv->scanned, sv->unreadable,
               sv->truncated ? ", limit" : "", sv->visibility_limited ? "; hidepid may hide other users' daemons" : "");
    }
}

/* ---- installed apps (pacman) ---- */
static int pkg_cmp(const void *a, const void *b)
{
    uint64_t x = ((const struct xrt_sys_package *)a)->size.v, y = ((const struct xrt_sys_package *)b)->size.v;
    return x > y ? -1 : x < y;
}
static void scan_pacman(struct xrt_sys *s)
{
    free(s->pkgs);
    s->pkgs = NULL;
    s->pkg_count = 0;
    s->pkg_total = 0;
    s->pkg_detail[0] = 0;
    size_t n;
    int err;
    char **dirs = list_dir(s, "/var/lib/pacman/local", &n, &err);
    if (!dirs) {
        s->pkg_state = XRT_SYS_UNAVAILABLE;
        s->pkg_why = err == ENOENT ? XRT_SYS_WHY_NO_MANAGER : why_errno(err);
        snprintf(s->pkg_detail, sizeof s->pkg_detail, "%s", err == ENOENT ? "no pacman database (only pacman is supported)" : strerror(err));
        return;
    }
    s->pkgs = calloc(n ? n : 1, sizeof *s->pkgs);
    char b[4096];
    for (size_t i = 0; s->pkgs && i < n; ++i) {
        if (rdf(s, b, sizeof b, "/var/lib/pacman/local/%s/desc", dirs[i]) <= 0) continue;
        struct xrt_sys_package *p = &s->pkgs[s->pkg_count];
        memset(p, 0, sizeof *p);
        char *v;
        if ((v = strstr(b, "%NAME%\n"))) sscanf(v + 7, "%63s", p->name);
        if ((v = strstr(b, "%VERSION%\n"))) sscanf(v + 10, "%47s", p->version);
        unsigned long long sz;
        if ((v = strstr(b, "%SIZE%\n")) && sscanf(v + 7, "%llu", &sz) == 1) {
            OK(p->size, sz);
            s->pkg_total += sz;
        } else NA(p->size, XRT_SYS_WHY_NOT_PRESENT);
        if (p->name[0]) s->pkg_count++;
    }
    free_list(dirs, n);
    if (s->pkg_count) qsort(s->pkgs, s->pkg_count, sizeof *s->pkgs, pkg_cmp);
    s->pkg_state = XRT_SYS_OK;
}
static void collect_apps(struct xrt_sys *s, struct xrt_sys_snapshot *snap)
{
    struct xrt_sys_apps *a = &snap->apps;
    int64_t now = mono_ns();
    if (!s->pkg_scan_mono || now - s->pkg_scan_mono >= (int64_t)s->lim.apps_rescan_s * 1000000000LL) {
        char full[PATH_MAX];
        struct stat st;
        s->syscalls++;
        int64_t mt = stat(path_of(s, "/var/lib/pacman/local", full, sizeof full), &st) == 0 ? (int64_t)st.st_mtime : -1;
        if (!s->pkg_scan_mono || mt != s->pkg_mtime) scan_pacman(s);
        s->pkg_mtime = mt;
        s->pkg_scan_mono = now;
    }
    struct xrt_sys_group *g = &snap->group[XRT_SYS_G_APPS];
    if (s->pkg_state != XRT_SYS_OK) {
        na_name(&a->manager, s->pkg_why);
        NA(a->count, s->pkg_why);
        NA(a->total_size, s->pkg_why);
        g->st = XRT_SYS_UNAVAILABLE;
        g->why = s->pkg_why;
        detail(g, 0, "%s", s->pkg_detail);
        return;
    }
    set_name(&a->manager, "pacman");
    OK(a->count, s->pkg_count);
    OK(a->total_size, s->pkg_total);
    a->list_capacity = s->lim.max_packages;
    uint32_t k = s->pkg_count < a->list_capacity ? s->pkg_count : a->list_capacity;
    a->truncated = s->pkg_count - k;
    a->list = k ? malloc(k * sizeof *a->list) : NULL;
    if (a->list) memcpy(a->list, s->pkgs, k * sizeof *a->list);
    a->list_count = a->list ? k : 0;
}

/* ---- system info ---- */
static void collect_info(struct xrt_sys *s, struct xrt_sys_snapshot *snap)
{
    struct xrt_sys_info *in = &snap->info;
    if (s->lim.flags & XRT_SYS_SHOW_HOSTNAME) get_name(s, &in->hostname, "/proc/sys/kernel/hostname");
    else na_name(&in->hostname, XRT_SYS_WHY_REDACTED);
    get_name(s, &in->kernel, "/proc/sys/kernel/osrelease");
    struct utsname u;
    if (s->live && uname(&u) == 0) set_name(&in->arch, u.machine);
    else get_name(s, &in->arch, "/proc/sys/kernel/arch");
    char b[4096];
    ssize_t n = rd(s, "/etc/os-release", b, sizeof b);
    if (n < 0) n = rd(s, "/usr/lib/os-release", b, sizeof b);
    char *pn = n > 0 ? strstr(b, "PRETTY_NAME=") : NULL;
    if (pn && (pn == b || pn[-1] == '\n')) {
        pn += 12;
        if (*pn == '"') ++pn;
        char *e = strpbrk(pn, "\"\n");
        if (e) *e = 0;
        set_name(&in->os, pn);
    } else na_name(&in->os, n < 0 ? why_errno((int)-n) : XRT_SYS_WHY_NOT_PRESENT);
    if (!ISOK(s->model)) cpu_model(s, &s->model);
    in->cpu_model = s->model;
    get_name(s, &in->init, "/proc/1/comm");
    char full[PATH_MAX];
    struct stat st;
    s->syscalls++;
    if (stat(path_of(s, "/var/lib/pacman/local", full, sizeof full), &st) == 0) set_name(&in->package_manager, "pacman");
    else na_name(&in->package_manager, XRT_SYS_WHY_NO_MANAGER);
    long nc = 0;
    if (snap->cpu.logical.st == XRT_SYS_OK) nc = (long)snap->cpu.online.v;
    else if (s->live) nc = sysconf(_SC_NPROCESSORS_ONLN);
    if (nc > 0) OK(in->logical_cpus, (uint64_t)nc);
    else NA(in->logical_cpus, XRT_SYS_WHY_NOT_COLLECTED);
    if (ISOK(snap->cpu.cores)) in->physical_cores = snap->cpu.cores;
    else NA(in->physical_cores, XRT_SYS_WHY_NOT_COLLECTED);
    if (ISOK(snap->memory.total)) in->memory_total = snap->memory.total;
    else {
        n = rd(s, "/proc/meminfo", b, 256);
        unsigned long long kb;
        if (n > 0 && sscanf(b, "MemTotal: %llu", &kb) == 1) OK(in->memory_total, kb * 1024);
        else NA(in->memory_total, XRT_SYS_WHY_NOT_PRESENT);
    }
    size_t nd;
    int err;
    char **drm = list_dir(s, "/sys/class/drm", &nd, &err);
    for (size_t i = 0; i < nd && in->gpu_count < XRT_SYS_MAX_GPUS; ++i) {
        unsigned card;
        char tail;
        if (sscanf(drm[i], "card%u%c", &card, &tail) != 1) continue;
        char ue[512], drv[24] = "?", pci[32] = "?", o[64];
        if (rdf(s, ue, sizeof ue, "/sys/class/drm/%s/device/uevent", drm[i]) > 0) {
            char *d = strstr(ue, "DRIVER="), *q = strstr(ue, "PCI_ID=");
            if (d) sscanf(d + 7, "%23s", drv);
            if (q) sscanf(q + 7, "%31s", pci);
        }
        for (char *c = pci; *c; ++c) if (*c >= 'A' && *c <= 'Z') *c = (char)(*c - 'A' + 'a');
        snprintf(o, sizeof o, "%s %s", drv, pci);
        set_name(&in->gpu[in->gpu_count++], o);
    }
    free_list(drm, nd);
}

/* ---- summary ---- */
static void collect_summary(struct xrt_sys *s, struct xrt_sys_snapshot *snap)
{
    struct xrt_sys_summary *sm = &snap->summary;
    char b[256];
    ssize_t n = rd(s, "/proc/uptime", b, sizeof b);
    double up;
    if (n > 0 && sscanf(b, "%lf", &up) == 1) OK(sm->uptime_s, up);
    else NA(sm->uptime_s, n < 0 ? why_errno((int)-n) : XRT_SYS_WHY_PARSE_ERROR);
    n = rd(s, "/proc/loadavg", b, sizeof b);
    double l1, l5, l15;
    unsigned run, tasks;
    if (n > 0 && sscanf(b, "%lf %lf %lf %u/%u", &l1, &l5, &l15, &run, &tasks) == 5) {
        OK(sm->load1, l1);
        OK(sm->load5, l5);
        OK(sm->load15, l15);
        OK(sm->threads, tasks);
    } else {
        uint8_t w = n < 0 ? why_errno((int)-n) : XRT_SYS_WHY_PARSE_ERROR;
        NA(sm->load1, w);
        NA(sm->load5, w);
        NA(sm->load15, w);
        NA(sm->threads, w);
    }
    int64_t now = mono_ns();
    if (ISOK(sm->processes)) {
        s->proc_count = sm->processes; /* from the processes group */
        s->proc_count_mono = now;
    } else if (ISOK(s->proc_count) && now - s->proc_count_mono < SLOW_SENSOR_PERIOD_NS) {
        sm->processes = s->proc_count; /* listing /proc costs ~2 us per process */
        sm->processes.st = XRT_SYS_STALE;
        sm->processes.why = XRT_SYS_WHY_SLOW_SOURCE;
    } else {
        /* count /proc entries without reading them */
        int fd = sys_open(s, "/proc", O_DIRECTORY);
        uint64_t count = 0;
        if (fd >= 0) {
            char buf[16384];
            for (;;) {
                s->syscalls++;
                long r = syscall(SYS_getdents64, fd, buf, sizeof buf);
                if (r <= 0) break;
                for (long off = 0; off < r;) {
                    struct linux_dirent64 *e = (struct linux_dirent64 *)(buf + off);
                    off += e->reclen;
                    if (e->name[0] >= '1' && e->name[0] <= '9') count++;
                }
            }
            sys_close(s, fd);
            OK(sm->processes, count);
            s->proc_count = sm->processes;
            s->proc_count_mono = now;
        } else NA(sm->processes, why_errno(errno));
    }
    if (ISOK(snap->memory.total) && ISOK(snap->memory.used) && snap->memory.total.v)
        OK(sm->memory_used_pct, 100.0 * (double)snap->memory.used.v / (double)snap->memory.total.v);
    else {
        int64_t tot = 0, av = 0;
        n = rd(s, "/proc/meminfo", s->buf, 512);
        char *a = n > 0 ? strstr(s->buf, "MemAvailable:") : NULL;
        if (n > 0 && sscanf(s->buf, "MemTotal: %" SCNd64, &tot) == 1 && a && sscanf(a + 13, "%" SCNd64, &av) == 1 && tot > 0)
            OK(sm->memory_used_pct, 100.0 * (double)(tot - av) / (double)tot);
        else NA(sm->memory_used_pct, XRT_SYS_WHY_NOT_PRESENT);
    }
    if (!sm->cpu_busy_pct.st) NA(sm->cpu_busy_pct, XRT_SYS_WHY_NOT_COLLECTED);
}

/* ---- lifecycle ---- */
void xrt_sys_limits_default(struct xrt_sys_limits *l)
{
    memset(l, 0, sizeof *l);
    l->groups = XRT_SYS_ALL_GROUPS;
    l->max_processes = 8192;
    l->max_connections = 8192;
    l->max_packages = 4096;
    l->max_fds_counted = 4096;
    l->budget_ns = 500000000ull;
    l->apps_rescan_s = 60;
}
struct xrt_sys *xrt_sys_open(const struct xrt_sys_limits *lim)
{
    struct xrt_sys *s = calloc(1, sizeof *s);
    if (!s) return NULL;
    if (lim) s->lim = *lim;
    else xrt_sys_limits_default(&s->lim);
    if (s->lim.root && s->lim.root[0] && strcmp(s->lim.root, "/")) {
        copy_str(s->root, sizeof s->root, s->lim.root);
        size_t n = strlen(s->root);
        while (n > 1 && s->root[n - 1] == '/') s->root[--n] = 0;
    } else s->live = 1;
    s->lim.root = NULL;
    if (s->lim.max_processes > 65536) s->lim.max_processes = 65536;
    if (s->lim.max_connections > 65536) s->lim.max_connections = 65536;
    if (s->lim.max_packages > 65536) s->lim.max_packages = 65536;
    if (!s->lim.max_fds_counted) s->lim.max_fds_counted = 4096;
    if (!s->lim.budget_ns) s->lim.budget_ns = 500000000ull;
    if (!s->lim.apps_rescan_s) s->lim.apps_rescan_s = 60;
    s->hz = s->live ? sysconf(_SC_CLK_TCK) : 100;
    if (s->hz <= 0) s->hz = 100;
    s->page = sysconf(_SC_PAGESIZE);
    if (s->page <= 0) s->page = 4096;
    s->euid = geteuid();
    struct rlimit files;
    if (s->live && getrlimit(RLIMIT_NOFILE, &files) == 0) {
        s->stat_fd_limit = (uint32_t)(files.rlim_cur / 8 > 2048 ? 2048 : files.rlim_cur / 8);
        if (s->stat_fd_limit > s->lim.max_processes) s->stat_fd_limit = s->lim.max_processes;
    }
    return s;
}
void xrt_sys_close(struct xrt_sys *s)
{
    if (!s) return;
    xrt_sys_nvml_close(s->nvml);
    for (size_t i = 0; i < PROC_STAT_SLOTS; ++i) if (s->stat_fd[i].pid) close(s->stat_fd[i].fd);
    free(s->prev);
    free(s->owners);
    free(s->pw);
    free(s->pkgs);
    free(s);
}
void xrt_sys_configure(struct xrt_sys *s, uint32_t groups, uint32_t flags)
{
    s->lim.groups = groups & XRT_SYS_ALL_GROUPS;
    s->lim.flags = flags;
}
void xrt_sys_snapshot_free(struct xrt_sys_snapshot *snap)
{
    free(snap->processes.proc);
    free(snap->connections.conn);
    free(snap->apps.list);
    memset(snap, 0, sizeof *snap);
}
enum xrt_status xrt_sys_snapshot_copy(struct xrt_sys_snapshot *dst, const struct xrt_sys_snapshot *src)
{
    if (dst == src) return XRT_OK;
    struct xrt_sys_snapshot tmp = *src;
    tmp.processes.proc = NULL;
    tmp.connections.conn = NULL;
    tmp.apps.list = NULL;
    if (src->processes.count && !(tmp.processes.proc = malloc(src->processes.count * sizeof *tmp.processes.proc))) goto oom;
    if (src->connections.count && !(tmp.connections.conn = malloc(src->connections.count * sizeof *tmp.connections.conn))) goto oom;
    if (src->apps.list_count && !(tmp.apps.list = malloc(src->apps.list_count * sizeof *tmp.apps.list))) goto oom;
    if (tmp.processes.proc) memcpy(tmp.processes.proc, src->processes.proc, src->processes.count * sizeof *tmp.processes.proc);
    if (tmp.connections.conn) memcpy(tmp.connections.conn, src->connections.conn, src->connections.count * sizeof *tmp.connections.conn);
    if (tmp.apps.list) memcpy(tmp.apps.list, src->apps.list, src->apps.list_count * sizeof *tmp.apps.list);
    tmp.processes.capacity = src->processes.count;
    tmp.connections.capacity = src->connections.count;
    tmp.apps.list_capacity = src->apps.list_count;
    if (dst != src) xrt_sys_snapshot_free(dst);
    *dst = tmp;
    return XRT_OK;
oom:
    free(tmp.processes.proc);
    free(tmp.connections.conn);
    free(tmp.apps.list);
    return XRT_OUT_OF_MEMORY;
}

void xrt_sys_snapshot_redact(struct xrt_sys_snapshot *snap)
{
    snap->redacted = 1;
    na_name(&snap->info.hostname, XRT_SYS_WHY_REDACTED);
    na_name(&snap->info.kernel, XRT_SYS_WHY_REDACTED);
    na_name(&snap->info.os, XRT_SYS_WHY_REDACTED);
    for (uint32_t i = 0; i < snap->processes.count; ++i) {
        struct xrt_sys_proc *p = &snap->processes.proc[i];
        na_name(&p->user, XRT_SYS_WHY_REDACTED);
        na_name(&p->cmdline, XRT_SYS_WHY_REDACTED);
        na_name(&p->cgroup, XRT_SYS_WHY_REDACTED);
        if (!ISOK(p->uid) || p->uid.v != 0) copy_str(p->comm, sizeof p->comm, "process");
        redact_uid(&p->uid);
    }
    for (uint32_t i = 0; i < snap->connections.count; ++i) {
        struct xrt_sys_conn *p = &snap->connections.conn[i];
        na_name(&p->local, XRT_SYS_WHY_REDACTED);
        na_name(&p->remote, XRT_SYS_WHY_REDACTED);
        copy_str(p->comm, sizeof p->comm, "process");
    }
    for (uint32_t i = 0; i < snap->network.count; ++i) {
        struct xrt_sys_iface *p = &snap->network.iface[i];
        na_name(&p->mac, XRT_SYS_WHY_REDACTED);
        for (uint32_t j = 0; j < p->addr_count; ++j) na_name(&p->addr[j], XRT_SYS_WHY_REDACTED);
    }
    for (uint32_t i = 0; i < snap->filesystems.count; ++i) {
        struct xrt_sys_filesystem *p = &snap->filesystems.fs[i];
        if (!system_mount(p->mount.s)) na_name(&p->mount, XRT_SYS_WHY_REDACTED);
        if (strncmp(p->source.s, "/dev/", 5)) na_name(&p->source, XRT_SYS_WHY_REDACTED);
    }
    for (uint32_t i = 0; i < snap->users.count; ++i) {
        na_name(&snap->users.user[i].user, XRT_SYS_WHY_REDACTED);
        na_name(&snap->users.user[i].host, XRT_SYS_WHY_REDACTED);
    }
    redact_services(&snap->services);
}

enum xrt_status xrt_sys_sample(struct xrt_sys *s, struct xrt_sys_snapshot *snap)
{
    xrt_sys_snapshot_free(snap);
    s->syscalls = s->opened = s->bytes = 0;
    int64_t t0 = mono_ns(), c0 = clock_ns(CLOCK_THREAD_CPUTIME_ID);
    uint64_t deadline = (uint64_t)t0 + s->lim.budget_ns;
    uint32_t want = s->lim.groups;
    s->seq++;
    snap->abi = XRT_SYS_ABI;
    snap->groups = want;
    snap->redacted = (s->lim.flags & XRT_SYS_REDACT) != 0;
    snap->sequence = s->seq;
    snap->realtime_ns = clock_ns(CLOCK_REALTIME);
    snap->monotonic_ns = t0;
    double dt[XRT_SYS_G_COUNT];
    int have[XRT_SYS_G_COUNT];
    for (int g = 0; g < XRT_SYS_G_COUNT; ++g) {
        have[g] = s->group_mono[g] != 0;
        dt[g] = have[g] ? (double)(t0 - s->group_mono[g]) * 1e-9 : 0;
        struct xrt_sys_group *gr = &snap->group[g];
        if (!(want & (1u << g))) {
            gr->st = XRT_SYS_UNAVAILABLE;
            gr->why = XRT_SYS_WHY_NOT_COLLECTED; /* its rates resume from its own last collection */
        } else if (have[g]) gr->interval_ns = (uint64_t)(t0 - s->group_mono[g]);
    }
    /* Interval of the main tick: the oldest requested group drives it. */
    int any = 0;
    for (int g = 0; g < XRT_SYS_G_COUNT; ++g)
        if ((want & (1u << g)) && have[g]) {
            OK(snap->interval_s, dt[g]);
            any = 1;
            break;
        }
    if (!any) NA(snap->interval_s, XRT_SYS_WHY_FIRST_SAMPLE);
#define WANT(g) (want & (1u << (g)))
#define BEGIN(g)                                                                                       \
    int64_t g##_start = mono_ns();                                                                    \
    if ((uint64_t)g##_start > deadline) {                                                             \
        snap->group[g].st = XRT_SYS_UNAVAILABLE;                                                      \
        snap->group[g].why = XRT_SYS_WHY_LIMIT;                                                       \
        detail(&snap->group[g], 0, "sample budget exhausted before this group");                      \
    } else
#define END(g)                                                                                         \
    do {                                                                                              \
        if (!snap->group[g].st) {                                                                     \
            snap->group[g].st = XRT_SYS_OK;                                                           \
            s->group_mono[g] = t0;                                                                    \
        } else if (snap->group[g].st == XRT_SYS_OK) s->group_mono[g] = t0;                           \
        snap->group[g].cost_ns += (uint64_t)(mono_ns() - g##_start);                                  \
    } while (0)
    if (WANT(XRT_SYS_G_CPU) || WANT(XRT_SYS_G_SUMMARY)) {
        int g = WANT(XRT_SYS_G_CPU) ? XRT_SYS_G_CPU : XRT_SYS_G_SUMMARY;
        int64_t st0 = mono_ns();
        parse_stat(s, snap, dt[XRT_SYS_G_SUMMARY], have[XRT_SYS_G_SUMMARY], WANT(XRT_SYS_G_SUMMARY) != 0);
        snap->group[g].cost_ns += (uint64_t)(mono_ns() - st0);
    }
    if (WANT(XRT_SYS_G_POWER) || WANT(XRT_SYS_G_CPU) || WANT(XRT_SYS_G_DISKS)) {
        int g = WANT(XRT_SYS_G_POWER) ? XRT_SYS_G_POWER : WANT(XRT_SYS_G_CPU) ? XRT_SYS_G_CPU : XRT_SYS_G_DISKS;
        int64_t st0 = mono_ns();
        read_sensors(s, snap);
        snap->group[g].cost_ns += (uint64_t)(mono_ns() - st0);
    }
    if (WANT(XRT_SYS_G_CPU)) {
        BEGIN(XRT_SYS_G_CPU) {
            collect_cpu(s, snap);
            psi_read(s, 0, &snap->cpu.psi, dt[XRT_SYS_G_CPU], have[XRT_SYS_G_CPU]);
        }
        END(XRT_SYS_G_CPU);
    }
    if (WANT(XRT_SYS_G_MEMORY)) {
        BEGIN(XRT_SYS_G_MEMORY) collect_memory(s, snap, dt[XRT_SYS_G_MEMORY], have[XRT_SYS_G_MEMORY]);
        END(XRT_SYS_G_MEMORY);
    }
    if (WANT(XRT_SYS_G_DISKS)) {
        BEGIN(XRT_SYS_G_DISKS) collect_disks(s, snap, dt[XRT_SYS_G_DISKS], have[XRT_SYS_G_DISKS]);
        END(XRT_SYS_G_DISKS);
    }
    if (WANT(XRT_SYS_G_FILESYSTEMS)) {
        BEGIN(XRT_SYS_G_FILESYSTEMS) collect_filesystems(s, snap);
        END(XRT_SYS_G_FILESYSTEMS);
    }
    if (WANT(XRT_SYS_G_NETWORK)) {
        BEGIN(XRT_SYS_G_NETWORK) collect_network(s, snap, dt[XRT_SYS_G_NETWORK], have[XRT_SYS_G_NETWORK]);
        END(XRT_SYS_G_NETWORK);
    }
    if (WANT(XRT_SYS_G_PROCESSES) || (WANT(XRT_SYS_G_CONNECTIONS) && s->live)) {
        int g = WANT(XRT_SYS_G_PROCESSES) ? XRT_SYS_G_PROCESSES : XRT_SYS_G_CONNECTIONS;
        int64_t g_start = mono_ns();
        if ((uint64_t)g_start > deadline) {
            snap->group[g].st = XRT_SYS_UNAVAILABLE;
            snap->group[g].why = XRT_SYS_WHY_LIMIT;
            detail(&snap->group[g], 0, "sample budget exhausted before this group");
        } else
            collect_processes(s, snap, dt[XRT_SYS_G_PROCESSES], have[XRT_SYS_G_PROCESSES],
                              WANT(XRT_SYS_G_CONNECTIONS) && s->live, WANT(XRT_SYS_G_PROCESSES) != 0, deadline);
        if (g == XRT_SYS_G_PROCESSES) {
            int64_t XRT_SYS_G_PROCESSES_start = g_start;
            END(XRT_SYS_G_PROCESSES);
        } else snap->group[g].cost_ns += (uint64_t)(mono_ns() - g_start);
    }
    if (WANT(XRT_SYS_G_CONNECTIONS)) {
        BEGIN(XRT_SYS_G_CONNECTIONS) collect_connections(s, snap);
        END(XRT_SYS_G_CONNECTIONS);
    }
    if (WANT(XRT_SYS_G_POWER)) {
        BEGIN(XRT_SYS_G_POWER) collect_power(s, snap, dt[XRT_SYS_G_POWER]);
        END(XRT_SYS_G_POWER);
    }
    if (WANT(XRT_SYS_G_USERS)) {
        BEGIN(XRT_SYS_G_USERS) collect_users(s, snap);
        END(XRT_SYS_G_USERS);
    }
    if (WANT(XRT_SYS_G_SERVICES)) {
        BEGIN(XRT_SYS_G_SERVICES) collect_services(s, snap, deadline);
        if (s->lim.flags & XRT_SYS_REDACT) redact_services(&snap->services);
        END(XRT_SYS_G_SERVICES);
    }
    if (WANT(XRT_SYS_G_APPS)) {
        BEGIN(XRT_SYS_G_APPS) collect_apps(s, snap);
        END(XRT_SYS_G_APPS);
    }
    if (WANT(XRT_SYS_G_SYSINFO)) {
        BEGIN(XRT_SYS_G_SYSINFO) collect_info(s, snap);
        END(XRT_SYS_G_SYSINFO);
    }
    if (WANT(XRT_SYS_G_SUMMARY)) {
        BEGIN(XRT_SYS_G_SUMMARY) collect_summary(s, snap);
        END(XRT_SYS_G_SUMMARY);
    }
#undef BEGIN
#undef END
#undef WANT
    if (!(want & (1u << XRT_SYS_G_POWER))) snap->power.sensor_count = 0; /* read only to serve cpu/disks */
    /* self cost */
    int64_t t1 = mono_ns(), c1 = clock_ns(CLOCK_THREAD_CPUTIME_ID) + (int64_t)xrt_sys_nvml_cpu(s->nvml);
    struct xrt_sys_self *me = &snap->self;
    OK(me->wall_ms, (double)(t1 - t0) * 1e-6);
    OK(me->cpu_ms, (double)(c1 - c0) * 1e-6);
    if (s->self_mono_prev && t0 > s->self_mono_prev)
        OK(me->cpu_pct_of_core, 100.0 * (double)(c1 - c0) / (double)(t1 - s->self_mono_prev));
    else NA(me->cpu_pct_of_core, XRT_SYS_WHY_FIRST_SAMPLE);
    s->self_mono_prev = t1;
    OK(me->syscalls, s->syscalls);
    OK(me->files_opened, s->opened);
    OK(me->bytes_read, s->bytes);
    char b[128];
    int fd = open("/proc/self/statm", O_RDONLY | O_CLOEXEC);
    unsigned long long vm, res;
    if (fd >= 0) {
        ssize_t n = read(fd, b, sizeof b - 1);
        close(fd);
        if (n > 0) {
            b[n] = 0;
            if (sscanf(b, "%llu %llu", &vm, &res) == 2) OK(me->rss, res * (uint64_t)s->page);
        }
    }
    if (!me->rss.st) NA(me->rss, XRT_SYS_WHY_IO_ERROR);
    if (s->lim.flags & XRT_SYS_REDACT)
        for (uint32_t i = 0; i < snap->processes.count; ++i) redact_uid(&snap->processes.proc[i].uid);
    return XRT_OK;
}

/* ---- JSON ---- */
struct jb { char *p; size_t n, cap; int oom; int first[32]; int depth; };
static void jraw(struct jb *b, const char *s, size_t n)
{
    if (b->oom) return;
    if (b->n + n + 1 > b->cap) {
        size_t cap = b->cap ? b->cap : 65536;
        while (b->n + n + 1 > cap) cap *= 2;
        char *np = realloc(b->p, cap);
        if (!np) {
            b->oom = 1;
            return;
        }
        b->p = np;
        b->cap = cap;
    }
    memcpy(b->p + b->n, s, n);
    b->n += n;
    b->p[b->n] = 0;
}
static void jputs(struct jb *b, const char *s) { jraw(b, s, strlen(s)); }
static void jprintf(struct jb *b, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static void jprintf(struct jb *b, const char *fmt, ...)
{
    char t[128];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(t, sizeof t, fmt, ap);
    va_end(ap);
    if (n > 0) jraw(b, t, (size_t)n < sizeof t ? (size_t)n : sizeof t - 1);
}
static void jstr(struct jb *b, const char *s)
{
    jputs(b, "\"");
    for (const unsigned char *c = (const unsigned char *)s; *c; ++c) {
        if (*c == '"' || *c == '\\') {
            char e[2] = {'\\', (char)*c};
            jraw(b, e, 2);
        } else if (*c < 0x20 || *c == 0x7f) jprintf(b, "\\u%04x", *c);
        else if (*c >= 0x80) {
            /* pass valid UTF-8, replace other bytes */
            int len = (*c & 0xe0) == 0xc0 ? 2 : (*c & 0xf0) == 0xe0 ? 3 : (*c & 0xf8) == 0xf0 ? 4 : 0;
            int ok = len > 0;
            for (int i = 1; ok && i < len; ++i) ok = (c[i] & 0xc0) == 0x80;
            if (ok) {
                jraw(b, (const char *)c, (size_t)len);
                c += len - 1;
            } else jputs(b, "\\ufffd");
        } else jraw(b, (const char *)c, 1);
    }
    jputs(b, "\"");
}
static void jsep(struct jb *b)
{
    if (!b->first[b->depth]) jputs(b, ",");
    b->first[b->depth] = 0;
}
static void jkey(struct jb *b, const char *k)
{
    jsep(b);
    jstr(b, k);
    jputs(b, ":");
}
static void jopen(struct jb *b, const char *k, char c)
{
    if (k) jkey(b, k);
    else jsep(b);
    char t[2] = {c, 0};
    jputs(b, t);
    if (b->depth < 31) b->depth++;
    b->first[b->depth] = 1;
}
static void jclose(struct jb *b, char c)
{
    char t[2] = {c, 0};
    jputs(b, t);
    if (b->depth > 0) b->depth--;
}
static void jstate(struct jb *b, uint8_t st, uint8_t why)
{
    jprintf(b, "\"state\":\"%s\",\"why\":", st == XRT_SYS_STALE ? "stale" : "unavailable");
    jstr(b, xrt_sys_reason_text(st == XRT_SYS_UNSET && !why ? XRT_SYS_WHY_NOT_COLLECTED : (enum xrt_sys_reason)why));
}
static void jnum(struct jb *b, double v)
{
    if ((v < 0 ? -v : v) < 9e15 && v == (double)(int64_t)v) jprintf(b, "%lld", (long long)v);
    else jprintf(b, "%.9g", v);
}
static void jf(struct jb *b, const char *k, const struct xrt_sys_f64 *f)
{
    jkey(b, k);
    if (f->st == XRT_SYS_OK && (f->v == f->v && f->v - f->v == 0)) jnum(b, f->v);
    else if (f->st == XRT_SYS_STALE && (f->v == f->v && f->v - f->v == 0)) {
        jputs(b, "{\"v\":");
        jnum(b, f->v);
        jputs(b, ",");
        jstate(b, f->st, f->why);
        jputs(b, "}");
    } else {
        jputs(b, "{");
        jstate(b, f->st == XRT_SYS_OK ? XRT_SYS_UNAVAILABLE : f->st, f->st == XRT_SYS_OK ? XRT_SYS_WHY_PARSE_ERROR : f->why);
        jputs(b, "}");
    }
}
static void ju(struct jb *b, const char *k, const struct xrt_sys_u64 *f)
{
    jkey(b, k);
    if (f->st == XRT_SYS_OK) jprintf(b, "%llu", (unsigned long long)f->v);
    else if (f->st == XRT_SYS_STALE) {
        jprintf(b, "{\"v\":%llu,", (unsigned long long)f->v);
        jstate(b, f->st, f->why);
        jputs(b, "}");
    } else {
        jputs(b, "{");
        jstate(b, f->st, f->why);
        jputs(b, "}");
    }
}
static void jnm(struct jb *b, const char *k, const struct xrt_sys_name *f)
{
    jkey(b, k);
    if (f->st == XRT_SYS_OK) jstr(b, f->s);
    else {
        jputs(b, "{");
        jstate(b, f->st == XRT_SYS_STALE ? XRT_SYS_UNAVAILABLE : f->st, f->why);
        jputs(b, "}");
    }
}
static void js(struct jb *b, const char *k, const char *v)
{
    jkey(b, k);
    jstr(b, v);
}
static void ji(struct jb *b, const char *k, long long v)
{
    jkey(b, k);
    jprintf(b, "%lld", v);
}
static void jpsi(struct jb *b, const char *k, const struct xrt_sys_psi *p)
{
    jopen(b, k, '{');
    jf(b, "some_avg10", &p->some_avg10);
    jf(b, "some_avg60", &p->some_avg60);
    jf(b, "some_avg300", &p->some_avg300);
    jf(b, "full_avg10", &p->full_avg10);
    jf(b, "full_avg60", &p->full_avg60);
    jf(b, "full_avg300", &p->full_avg300);
    jf(b, "some_pct", &p->some_pct);
    jf(b, "full_pct", &p->full_pct);
    jclose(b, '}');
}
static void jtimes(struct jb *b, const char *k, const struct xrt_sys_cpu_times *t)
{
    jopen(b, k, '{');
    jf(b, "user", &t->user);
    jf(b, "nice", &t->nice);
    jf(b, "system", &t->system);
    jf(b, "idle", &t->idle);
    jf(b, "iowait", &t->iowait);
    jf(b, "irq", &t->irq);
    jf(b, "softirq", &t->softirq);
    jf(b, "steal", &t->steal);
    jf(b, "guest", &t->guest);
    jf(b, "busy", &t->busy);
    jclose(b, '}');
}
static const char *kind_name(uint8_t k)
{
    static const char *const names[] = {"?", "temp_c", "fan_rpm", "voltage_v", "current_a", "power_w", "energy_j", "freq_mhz", "humidity_pct", "pwm_pct"};
    return k < COUNT_OF(names) ? names[k] : "?";
}
struct sort_key { double key; uint32_t idx; };
static int sort_desc(const void *a, const void *b)
{
    const struct sort_key *x = a, *y = b;
    if (x->key != y->key) return x->key > y->key ? -1 : 1;
    return x->idx < y->idx ? -1 : x->idx > y->idx;
}
static double proc_key(const struct xrt_sys_proc *p, uint32_t sort)
{
    const double none = -1e300;
    switch (sort) {
    case XRT_SYS_SORT_CPU: return ISOK(p->cpu_pct) ? p->cpu_pct.v : none;
    case XRT_SYS_SORT_MEMORY: return ISOK(p->rss) ? (double)p->rss.v : none;
    case XRT_SYS_SORT_IO:
        return ISOK(p->io_read_bps) && ISOK(p->io_write_bps) ? p->io_read_bps.v + p->io_write_bps.v : none;
    case XRT_SYS_SORT_FDS: return p->fds.st == XRT_SYS_OK || p->fds.st == XRT_SYS_STALE ? (double)p->fds.v : none;
    case XRT_SYS_SORT_THREADS: return ISOK(p->threads) ? (double)p->threads.v : none;
    case XRT_SYS_SORT_START: return (double)p->start_ticks;
    default: return -(double)p->pid;
    }
}
static void jproc(struct jb *b, const struct xrt_sys_proc *p)
{
    jopen(b, NULL, '{');
    ji(b, "pid", p->pid);
    jkey(b, "start_ticks");
    jprintf(b, "%llu", (unsigned long long)p->start_ticks);
    ju(b, "ppid", &p->ppid);
    jf(b, "start_s", &p->start_s);
    js(b, "comm", p->comm);
    jnm(b, "cmdline", &p->cmdline);
    char st[2] = {p->state ? p->state : '?', 0};
    js(b, "state", st);
    ju(b, "uid", &p->uid);
    jnm(b, "user", &p->user);
    ju(b, "threads", &p->threads);
    ju(b, "rss", &p->rss);
    ju(b, "pss", &p->pss);
    ju(b, "vsize", &p->vsize);
    jf(b, "cpu_pct", &p->cpu_pct);
    ju(b, "cpu_time_ns", &p->cpu_time_ns);
    jf(b, "io_read_bps", &p->io_read_bps);
    jf(b, "io_write_bps", &p->io_write_bps);
    ju(b, "io_read_bytes", &p->io_read_bytes);
    ju(b, "io_write_bytes", &p->io_write_bytes);
    jf(b, "net_bps", &p->net_bps);
    ju(b, "fds", &p->fds);
    ju(b, "nice", &p->nice);
    ju(b, "kernel_thread", &p->kernel_thread);
    jnm(b, "cgroup", &p->cgroup);
    jclose(b, '}');
}
static void jconn(struct jb *b, const struct xrt_sys_conn *c)
{
    jopen(b, NULL, '{');
    js(b, "proto", c->proto == XRT_SYS_TCP ? "tcp" : c->proto == XRT_SYS_UDP ? "udp" : "unix");
    if (c->family) ji(b, "family", c->family);
    js(b, "state", c->state);
    jnm(b, "local", &c->local);
    jnm(b, "remote", &c->remote);
    jkey(b, "inode");
    jprintf(b, "%llu", (unsigned long long)c->inode);
    ju(b, "uid", &c->uid);
    ju(b, "pid", &c->pid);
    if (c->comm[0]) js(b, "comm", c->comm);
    ju(b, "rx_queue", &c->rx_queue);
    ju(b, "tx_queue", &c->tx_queue);
    jclose(b, '}');
}

char *xrt_sys_json(const struct xrt_sys_snapshot *snap, const struct xrt_sys_json_opts *o)
{
    struct xrt_sys_json_opts def = {.groups = XRT_SYS_ALL_GROUPS};
    if (!o) o = &def;
    uint32_t want = o->groups & snap->groups;
    uint32_t limit = o->limit;
    struct jb b = {0};
    b.first[0] = 1;
    jopen(&b, NULL, '{');
    ji(&b, "abi", snap->abi);
    jkey(&b, "sequence");
    jprintf(&b, "%llu", (unsigned long long)snap->sequence);
    jkey(&b, "redacted");
    jputs(&b, snap->redacted ? "true" : "false");
    jkey(&b, "realtime_ns");
    jprintf(&b, "%lld", (long long)snap->realtime_ns);
    jf(&b, "interval_s", &snap->interval_s);
    jopen(&b, "groups", '{');
    for (int g = 0; g < XRT_SYS_G_COUNT; ++g) {
        if (!(o->groups & (1u << g))) continue;
        const struct xrt_sys_group *gr = &snap->group[g];
        jopen(&b, xrt_sys_group_name((enum xrt_sys_group_id)g), '{');
        js(&b, "state", xrt_sys_state_text((enum xrt_sys_state)gr->st));
        if (gr->why) js(&b, "why", xrt_sys_reason_text((enum xrt_sys_reason)gr->why));
        if (gr->detail[0]) js(&b, "detail", gr->detail);
        ji(&b, "cost_us", (long long)(gr->cost_ns / 1000));
        if (gr->interval_ns) {
            jkey(&b, "interval_s");
            jnum(&b, (double)gr->interval_ns * 1e-9);
        }
        jclose(&b, '}');
    }
    jclose(&b, '}');
#define W(g) (want & (1u << (g)))
    if (W(XRT_SYS_G_SUMMARY)) {
        const struct xrt_sys_summary *m = &snap->summary;
        jopen(&b, "summary", '{');
        jf(&b, "uptime_s", &m->uptime_s);
        jf(&b, "load1", &m->load1);
        jf(&b, "load5", &m->load5);
        jf(&b, "load15", &m->load15);
        ju(&b, "boot_time_s", &m->boot_time_s);
        ju(&b, "processes", &m->processes);
        ju(&b, "threads", &m->threads);
        ju(&b, "running", &m->running);
        ju(&b, "blocked", &m->blocked);
        jf(&b, "context_switches_ps", &m->context_switches_ps);
        jf(&b, "interrupts_ps", &m->interrupts_ps);
        jf(&b, "forks_ps", &m->forks_ps);
        jf(&b, "cpu_busy_pct", &m->cpu_busy_pct);
        jf(&b, "memory_used_pct", &m->memory_used_pct);
        jclose(&b, '}');
    }
    if (W(XRT_SYS_G_CPU)) {
        const struct xrt_sys_cpus *c = &snap->cpu;
        jopen(&b, "cpu", '{');
        jnm(&b, "model", &c->model);
        jnm(&b, "freq_driver", &c->freq_driver);
        jnm(&b, "governor", &c->governor);
        jnm(&b, "epp", &c->epp);
        ju(&b, "logical", &c->logical);
        ju(&b, "online", &c->online);
        ju(&b, "cores", &c->cores);
        ju(&b, "packages", &c->packages);
        ju(&b, "l3_groups", &c->l3_groups);
        jtimes(&b, "total", &c->total);
        jf(&b, "package_temp_c", &c->package_temp_c);
        jpsi(&b, "psi", &c->psi);
        jopen(&b, "temps", '[');
        for (uint32_t i = 0; i < c->temp_count; ++i) {
            jopen(&b, NULL, '{');
            js(&b, "chip", c->temps[i].chip);
            js(&b, "label", c->temps[i].label);
            jf(&b, "value", &c->temps[i].value);
            jclose(&b, '}');
        }
        jclose(&b, ']');
        jopen(&b, "cpus", '[');
        for (uint32_t i = 0; i < c->count; ++i) {
            const struct xrt_sys_cpu *u = &c->cpu[i];
            jopen(&b, NULL, '{');
            ji(&b, "id", u->id);
            ju(&b, "online", &u->online);
            jtimes(&b, "times", &u->t);
            jf(&b, "freq_mhz", &u->freq_mhz);
            jf(&b, "freq_min_mhz", &u->freq_min_mhz);
            jf(&b, "freq_max_mhz", &u->freq_max_mhz);
            ju(&b, "package_id", &u->package_id);
            ju(&b, "die_id", &u->die_id);
            ju(&b, "core_id", &u->core_id);
            ju(&b, "l3_id", &u->l3_id);
            ju(&b, "smt_index", &u->smt_index);
            jf(&b, "temp_c", &u->temp_c);
            jclose(&b, '}');
        }
        jclose(&b, ']');
        jclose(&b, '}');
    }
    if (W(XRT_SYS_G_MEMORY)) {
        const struct xrt_sys_memory *m = &snap->memory;
        jopen(&b, "memory", '{');
        const struct { const char *k; const struct xrt_sys_u64 *f; } u[] = {
            {"total", &m->total}, {"free", &m->free}, {"available", &m->available}, {"used", &m->used},
            {"cached", &m->cached}, {"buffers", &m->buffers}, {"shmem", &m->shmem},
            {"slab_reclaimable", &m->slab_reclaimable}, {"slab_unreclaimable", &m->slab_unreclaimable},
            {"dirty", &m->dirty}, {"writeback", &m->writeback}, {"anon", &m->anon}, {"mapped", &m->mapped},
            {"page_tables", &m->page_tables}, {"commit_limit", &m->commit_limit}, {"committed", &m->committed},
            {"swap_total", &m->swap_total}, {"swap_free", &m->swap_free}, {"swap_used", &m->swap_used},
            {"swap_cached", &m->swap_cached}, {"zswap_pool", &m->zswap_pool}, {"zswap_stored", &m->zswap_stored},
            {"zswap_enabled", &m->zswap_enabled}};
        for (size_t i = 0; i < COUNT_OF(u); ++i) ju(&b, u[i].k, u[i].f);
        jf(&b, "page_faults_ps", &m->page_faults_ps);
        jf(&b, "major_faults_ps", &m->major_faults_ps);
        jf(&b, "swap_in_ps", &m->swap_in_ps);
        jf(&b, "swap_out_ps", &m->swap_out_ps);
        jpsi(&b, "psi", &m->psi);
        jclose(&b, '}');
    }
    if (W(XRT_SYS_G_DISKS)) {
        jopen(&b, "disks", '{');
        jpsi(&b, "psi", &snap->disks.psi);
        jopen(&b, "devices", '[');
        for (uint32_t i = 0; i < snap->disks.count; ++i) {
            const struct xrt_sys_disk *d = &snap->disks.disk[i];
            jopen(&b, NULL, '{');
            js(&b, "name", d->name);
            jnm(&b, "model", &d->model);
            ju(&b, "size_bytes", &d->size_bytes);
            ju(&b, "rotational", &d->rotational);
            ju(&b, "removable", &d->removable);
            ju(&b, "read_bytes", &d->read_bytes);
            ju(&b, "write_bytes", &d->write_bytes);
            jf(&b, "read_bps", &d->read_bps);
            jf(&b, "write_bps", &d->write_bps);
            jf(&b, "read_iops", &d->read_iops);
            jf(&b, "write_iops", &d->write_iops);
            jf(&b, "busy_pct", &d->busy_pct);
            jf(&b, "queue_depth", &d->queue_depth);
            jf(&b, "avg_latency_ms", &d->avg_latency_ms);
            ju(&b, "in_flight", &d->in_flight);
            jf(&b, "temp_c", &d->temp_c);
            jclose(&b, '}');
        }
        jclose(&b, ']');
        jclose(&b, '}');
    }
    if (W(XRT_SYS_G_FILESYSTEMS)) {
        const struct xrt_sys_filesystems *f = &snap->filesystems;
        jopen(&b, "filesystems", '{');
        ji(&b, "skipped_pseudo", f->skipped_pseudo);
        ji(&b, "skipped_duplicate", f->skipped_duplicate);
        jopen(&b, "mounts", '[');
        for (uint32_t i = 0; i < f->count; ++i) {
            const struct xrt_sys_filesystem *m = &f->fs[i];
            jopen(&b, NULL, '{');
            jnm(&b, "mount", &m->mount);
            jnm(&b, "source", &m->source);
            js(&b, "fstype", m->fstype);
            ju(&b, "total", &m->total);
            ju(&b, "free", &m->free);
            ju(&b, "avail", &m->avail);
            ju(&b, "used", &m->used);
            jf(&b, "used_pct", &m->used_pct);
            ju(&b, "inodes_total", &m->inodes_total);
            ju(&b, "inodes_free", &m->inodes_free);
            ju(&b, "read_only", &m->read_only);
            jclose(&b, '}');
        }
        jclose(&b, ']');
        jclose(&b, '}');
    }
    if (W(XRT_SYS_G_NETWORK)) {
        const struct xrt_sys_network *n = &snap->network;
        jopen(&b, "network", '{');
        jf(&b, "rx_bps", &n->rx_bps);
        jf(&b, "tx_bps", &n->tx_bps);
        jopen(&b, "interfaces", '[');
        for (uint32_t i = 0; i < n->count; ++i) {
            const struct xrt_sys_iface *f = &n->iface[i];
            jopen(&b, NULL, '{');
            js(&b, "name", f->name);
            jnm(&b, "operstate", &f->operstate);
            ju(&b, "carrier", &f->carrier);
            ju(&b, "speed_mbps", &f->speed_mbps);
            ju(&b, "mtu", &f->mtu);
            ju(&b, "loopback", &f->loopback);
            ju(&b, "physical", &f->physical);
            jnm(&b, "kind", &f->kind);
            jnm(&b, "mac", &f->mac);
            ju(&b, "rx_bytes", &f->rx_bytes);
            ju(&b, "tx_bytes", &f->tx_bytes);
            jf(&b, "rx_bps", &f->rx_bps);
            jf(&b, "tx_bps", &f->tx_bps);
            jf(&b, "rx_pps", &f->rx_pps);
            jf(&b, "tx_pps", &f->tx_pps);
            jf(&b, "rx_errors_ps", &f->rx_errors_ps);
            jf(&b, "tx_errors_ps", &f->tx_errors_ps);
            jf(&b, "rx_drops_ps", &f->rx_drops_ps);
            jf(&b, "tx_drops_ps", &f->tx_drops_ps);
            jopen(&b, "addresses", '[');
            for (uint32_t k = 0; k < f->addr_count; ++k) {
                jopen(&b, NULL, '{');
                ji(&b, "family", f->addr_family[k]);
                jnm(&b, "addr", &f->addr[k]);
                jclose(&b, '}');
            }
            jclose(&b, ']');
            jclose(&b, '}');
        }
        jclose(&b, ']');
        jclose(&b, '}');
    }
    if (W(XRT_SYS_G_CONNECTIONS)) {
        const struct xrt_sys_connections *c = &snap->connections;
        jopen(&b, "connections", '{');
        ju(&b, "tcp", &c->tcp);
        ju(&b, "udp", &c->udp);
        ju(&b, "unix", &c->unix_sockets);
        ju(&b, "listening", &c->listening);
        ju(&b, "established", &c->established);
        ju(&b, "owners_unresolved", &c->owners_unresolved);
        ji(&b, "count", c->count);
        ji(&b, "truncated", c->truncated);
        jopen(&b, "rows", '[');
        uint32_t shown = 0;
        for (uint32_t i = 0; i < c->count; ++i) {
            const struct xrt_sys_conn *x = &c->conn[i];
            if (o->pid > 0 && !(ISOK(x->pid) && x->pid.v == (uint64_t)o->pid)) continue;
            if (limit && shown >= limit) break;
            jconn(&b, x);
            shown++;
        }
        jclose(&b, ']');
        ji(&b, "shown", shown);
        jclose(&b, '}');
    }
    if (W(XRT_SYS_G_POWER)) {
        const struct xrt_sys_power *p = &snap->power;
        jopen(&b, "power", '{');
        jf(&b, "cpu_package_w", &p->cpu_package_w);
        jf(&b, "ac_online", &p->ac_online);
        jf(&b, "battery_pct", &p->battery_pct);
        jopen(&b, "gpus", '[');
        for (uint32_t i = 0; i < p->gpu_count; ++i) {
            const struct xrt_sys_gpu *g = &p->gpu[i];
            jopen(&b, NULL, '{');
            js(&b, "card", g->card);
            js(&b, "driver", g->driver);
            jnm(&b, "name", &g->name);
            jf(&b, "busy_pct", &g->busy_pct);
            jf(&b, "power_w", &g->power_w);
            jf(&b, "temp_c", &g->temp_c);
            ju(&b, "vram_used", &g->vram_used);
            ju(&b, "vram_total", &g->vram_total);
            jf(&b, "graphics_mhz", &g->graphics_mhz);
            jf(&b, "memory_mhz", &g->memory_mhz);
            jclose(&b, '}');
        }
        jclose(&b, ']');
        jopen(&b, "sensors", '[');
        for (uint32_t i = 0; i < p->sensor_count && (!limit || i < limit); ++i) {
            const struct xrt_sys_sensor *x = &p->sensor[i];
            jopen(&b, NULL, '{');
            js(&b, "chip", x->chip);
            js(&b, "label", x->label);
            js(&b, "kind", kind_name(x->kind));
            jf(&b, "value", &x->value);
            jf(&b, "max", &x->max);
            jf(&b, "crit", &x->crit);
            jclose(&b, '}');
        }
        jclose(&b, ']');
        jclose(&b, '}');
    }
    if (W(XRT_SYS_G_USERS)) {
        jopen(&b, "users", '[');
        for (uint32_t i = 0; i < snap->users.count; ++i) {
            const struct xrt_sys_user *u = &snap->users.user[i];
            jopen(&b, NULL, '{');
            jnm(&b, "user", &u->user);
            jnm(&b, "host", &u->host);
            js(&b, "line", u->line);
            ju(&b, "pid", &u->pid);
            ju(&b, "login_time_s", &u->login_time_s);
            jclose(&b, '}');
        }
        jclose(&b, ']');
    }
    if (W(XRT_SYS_G_SERVICES)) {
        jopen(&b, "services", '{');
        jnm(&b, "manager", &snap->services.manager);
        ji(&b, "count", snap->services.count);
        ji(&b, "scanned", snap->services.scanned);
        ji(&b, "unreadable", snap->services.unreadable);
        ji(&b, "truncated", snap->services.truncated);
        ji(&b, "visibility_limited", snap->services.visibility_limited);
        jopen(&b, "rows", '[');
        for (uint32_t i = 0; i < snap->services.count; ++i) {
            const struct xrt_sys_service *v = &snap->services.service[i];
            jopen(&b, NULL, '{');
            js(&b, "name", v->name);
            jnm(&b, "state", &v->state);
            ju(&b, "pid", &v->pid);
            ju(&b, "start_ticks", &v->start_ticks);
            ju(&b, "uid", &v->uid);
            ju(&b, "loginuid", &v->loginuid);
            jnm(&b, "user", &v->user);
            jf(&b, "uptime_s", &v->uptime_s);
            jf(&b, "cpu_pct", &v->cpu_pct);
            ju(&b, "rss", &v->rss);
            if (ISOK(v->cgroup)) js(&b, "cgroup", v->cgroup.s);
            else {
                struct xrt_sys_name missing = {.st = v->cgroup.st, .why = v->cgroup.why};
                jnm(&b, "cgroup", &missing);
            }
            jclose(&b, '}');
        }
        jclose(&b, ']');
        jclose(&b, '}');
    }
    if (W(XRT_SYS_G_APPS)) {
        const struct xrt_sys_apps *a = &snap->apps;
        jopen(&b, "apps", '{');
        jnm(&b, "manager", &a->manager);
        ju(&b, "count", &a->count);
        ju(&b, "total_size", &a->total_size);
        jopen(&b, "largest", '[');
        uint32_t lim = limit ? limit : 20;
        for (uint32_t i = 0; i < a->list_count && i < lim; ++i) {
            jopen(&b, NULL, '{');
            js(&b, "name", a->list[i].name);
            js(&b, "version", a->list[i].version);
            ju(&b, "size", &a->list[i].size);
            jclose(&b, '}');
        }
        jclose(&b, ']');
        jclose(&b, '}');
    }
    if (W(XRT_SYS_G_PROCESSES)) {
        const struct xrt_sys_processes *ps = &snap->processes;
        jopen(&b, "processes", '{');
        ji(&b, "count", ps->count);
        ji(&b, "truncated", ps->truncated);
        js(&b, "identity", "pid+start_ticks");
        jopen(&b, "rows", '[');
        struct sort_key *keys = ps->count ? malloc(ps->count * sizeof *keys) : NULL;
        uint32_t nk = 0;
        for (uint32_t i = 0; keys && i < ps->count; ++i) {
            if (o->pid > 0 && ps->proc[i].pid != o->pid) continue;
            keys[nk].key = proc_key(&ps->proc[i], o->sort);
            keys[nk].idx = i;
            nk++;
        }
        if (nk) qsort(keys, nk, sizeof *keys, sort_desc);
        uint32_t shown = 0;
        for (uint32_t i = 0; i < nk && (!limit || shown < limit); ++i, ++shown) jproc(&b, &ps->proc[keys[i].idx]);
        if (ps->count && !keys) b.oom = 1;
        free(keys);
        jclose(&b, ']');
        ji(&b, "shown", shown);
        jclose(&b, '}');
    }
    if (W(XRT_SYS_G_SYSINFO)) {
        const struct xrt_sys_info *in = &snap->info;
        jopen(&b, "sysinfo", '{');
        jnm(&b, "hostname", &in->hostname);
        jnm(&b, "kernel", &in->kernel);
        jnm(&b, "os", &in->os);
        jnm(&b, "arch", &in->arch);
        jnm(&b, "cpu_model", &in->cpu_model);
        jnm(&b, "init", &in->init);
        jnm(&b, "package_manager", &in->package_manager);
        ju(&b, "logical_cpus", &in->logical_cpus);
        ju(&b, "physical_cores", &in->physical_cores);
        ju(&b, "memory_total", &in->memory_total);
        jopen(&b, "gpus", '[');
        for (uint32_t i = 0; i < in->gpu_count; ++i) {
            jsep(&b);
            if (in->gpu[i].st == XRT_SYS_OK) jstr(&b, in->gpu[i].s);
            else jputs(&b, "null");
        }
        jclose(&b, ']');
        jclose(&b, '}');
    }
#undef W
    {
        const struct xrt_sys_self *m = &snap->self;
        jopen(&b, "self", '{');
        jf(&b, "wall_ms", &m->wall_ms);
        jf(&b, "cpu_ms", &m->cpu_ms);
        jf(&b, "cpu_pct_of_core", &m->cpu_pct_of_core);
        ju(&b, "syscalls_estimate", &m->syscalls);
        ju(&b, "files_opened", &m->files_opened);
        ju(&b, "bytes_read", &m->bytes_read);
        ju(&b, "rss", &m->rss);
        jclose(&b, '}');
    }
    jclose(&b, '}');
    if (b.oom) {
        free(b.p);
        return NULL;
    }
    return b.p;
}
