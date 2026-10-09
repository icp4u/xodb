/* Unprivileged descriptor activity from /proc; see xrt_fdscan.h. */
#define _GNU_SOURCE 1
#define _FILE_OFFSET_BITS 64
#include "xrt_fdscan.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

#define TOTALS 120
#define METRICS 5
#define LINK_MAX 4096
#define CMDLINE_MAX 512
#define PF_KTHREAD 0x00200000u
#define DENTS 32768
/* The kernel's getdents64 record; libc names for it differ. */
struct dent {
    uint64_t ino;
    int64_t off;
    unsigned short reclen;
    unsigned char type;
    char name[];
};

struct snap {
    struct xrt_fd_process *procs;
    uint32_t nprocs;
    struct xrt_fd *fds;
    uint32_t nfds;
    char *strings;
    uint32_t nstrings;
    struct xrt_fd_unseen *unseen;
    uint32_t nunseen;
    uint32_t procs_cap, fds_cap, strings_cap, unseen_cap;
    struct xrt_fd_snapshot view;
};
struct key {
    uint64_t device, inode;
    uint32_t fd, proc;
};
struct xrt_fdscan {
    struct xrt_fdscan_options o;
    int expected_dir;
    int32_t *pids;
    int proc;
    int32_t self, detail;
    int32_t interest[XRT_FD_INTEREST_MAX];
    uint32_t ninterest;
    int all_interest;
    struct snap s[2];
    int cur;
    uint64_t epoch, sequence;
    int32_t resume;  /* budgeted scans continue from this pid */
    uint32_t window; /* processes per budgeted scan; 0: all */
    int32_t *numbers;
    uint32_t numbers_cap;
    char *dents;
    struct key *keys;
    struct xrt_fd_file *files;
    uint32_t nfiles, keys_cap, files_cap;
    int allocation_failed;
    uint64_t files_sequence;
    float totals[METRICS][TOTALS];
    uint32_t ntotals;
};

/* Limits bound demand, not up-front address-space reservations. Failed growth
 * keeps the old allocation valid; poll never publishes a half-built sample. */
static void *reserve(struct xrt_fdscan *s, void *old, uint32_t *capacity,
                     uint32_t need, uint32_t limit, size_t width)
{
    if (need<=*capacity) return old;
    if (need>limit) return NULL;
    uint32_t next=*capacity ? *capacity : 64;
    if (next>limit) next=limit;
    while (next<need) next=next>limit/2 ? limit : next*2;
    if (next>SIZE_MAX/width) {s->allocation_failed=1;return NULL;}
    void *p=realloc(old,(size_t)next*width);
    if (!p) {s->allocation_failed=1;return NULL;}
    *capacity=next;return p;
}
static int grow_snap(struct xrt_fdscan *s, struct snap *c, uint32_t processes,
                     uint32_t fds, uint32_t unseen_count, uint32_t strings)
{
#define GROW(member, cap, need, limit) do { \
    if ((need)>c->cap) { \
        void *p=reserve(s,c->member,&c->cap,(need),(limit),sizeof *c->member); \
        if (!p) return 0; \
        c->member=p; \
    } \
} while (0)
    GROW(procs,procs_cap,processes,s->o.max_processes);
    GROW(fds,fds_cap,fds,s->o.max_fds);
    GROW(unseen,unseen_cap,unseen_count,s->o.max_processes);
    GROW(strings,strings_cap,strings,s->o.max_strings);
#undef GROW
    return 1;
}

static uint64_t clock_ns(clockid_t id)
{
    struct timespec t;
    clock_gettime(id, &t);
    return (uint64_t)t.tv_sec * 1000000000u + (uint64_t)t.tv_nsec;
}
static int by_pid(const void *a, const void *b)
{
    const int32_t x = *(const int32_t *)a, y = *(const int32_t *)b;
    return (x > y) - (x < y);
}
static float per_second(uint64_t value, uint64_t ns)
{
    return ns ? (float)((double)value * 1e9 / (double)ns) : 0;
}
const char *xrt_fd_kind_name(enum xrt_fd_kind kind)
{
    switch (kind) {
    case XRT_FD_REGULAR: return "file";
    case XRT_FD_DIRECTORY: return "dir";
    case XRT_FD_SOCKET: return "socket";
    case XRT_FD_PIPE: return "pipe";
    case XRT_FD_ANON: return "anon";
    case XRT_FD_MEMFD: return "memfd";
    case XRT_FD_DEVICE: return "device";
    case XRT_FD_OTHER: return "other";
    case XRT_FD_KINDS: break;
    }
    return "?";
}

enum xrt_status xrt_fdscan_create(const struct xrt_fdscan_options *options, struct xrt_fdscan **out)
{
    if (!out)
        return XRT_INVALID_ARGUMENT;
    *out = NULL;
    struct xrt_fdscan *s = calloc(1, sizeof(*s));
    if (!s)
        return XRT_OUT_OF_MEMORY;
    s->expected_dir = -1;
    if (options)
        s->o = *options;
    if (!s->o.max_processes)
        s->o.max_processes = 16384;
    if (!s->o.max_fds)
        s->o.max_fds = 262144;
    if (!s->o.max_strings)
        s->o.max_strings = 16u << 20;
    if (s->o.max_processes > (1u << 24) || s->o.max_fds > (1u << 26) || s->o.max_strings < 16 ||
        s->o.pid_count > s->o.max_processes || (s->o.pid_count && !s->o.pids) || (s->o.expected_start && s->o.pid_count != 1)) {
        free(s);
        return XRT_INVALID_ARGUMENT;
    }
    s->proc = -1;
    s->self = getpid();
    if (s->o.pid_count) {
        s->pids = malloc(s->o.pid_count * sizeof(*s->pids));
        if (!s->pids)
            goto oom;
        memcpy(s->pids, s->o.pids, s->o.pid_count * sizeof(*s->pids));
        qsort(s->pids, s->o.pid_count, sizeof(*s->pids), by_pid);
    }
    s->o.pids = NULL;
    for (int i = 0; i < 2; i++) {
        if (!grow_snap(s,&s->s[i],0,0,0,1)) goto oom;
        s->s[i].strings[0] = 0;
        s->s[i].nstrings = 1;
    }
    s->dents = malloc(DENTS);
    if (!s->dents)
        goto oom;
    s->proc = open(s->o.proc ? s->o.proc : "/proc", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    s->o.proc = NULL;
    if (s->proc < 0) {
        const int e = errno;
        xrt_fdscan_destroy(s);
        return e == EACCES ? XRT_PERMISSION_DENIED : XRT_FILE_UNAVAILABLE;
    }
    if (s->o.expected_start) {
        char name[32];
        snprintf(name, sizeof(name), "%d", s->pids[0]);
        s->expected_dir = openat(s->proc, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
        if (s->expected_dir < 0) { xrt_fdscan_destroy(s); return XRT_PROCESS_GONE; }
    }
    s->epoch = clock_ns(CLOCK_MONOTONIC);
    *out = s;
    return XRT_OK;
oom:
    xrt_fdscan_destroy(s);
    return XRT_OUT_OF_MEMORY;
}

void xrt_fdscan_destroy(struct xrt_fdscan *s)
{
    if (!s)
        return;
    if (s->proc >= 0)
        close(s->proc);
    if (s->expected_dir >= 0)
        close(s->expected_dir);
    for (int i = 0; i < 2; i++) {
        free(s->s[i].procs);
        free(s->s[i].unseen);
        free(s->s[i].fds);
        free(s->s[i].strings);
    }
    free(s->pids);
    free(s->numbers);
    free(s->dents);
    free(s->keys);
    free(s->files);
    free(s);
}

void xrt_fdscan_budget(struct xrt_fdscan *s, uint32_t ms)
{
    if (!s)
        return;
    s->o.budget_ms = ms;
    if (!ms) {
        s->window = 0;
        s->resume = 0;
    }
}

void xrt_fdscan_cgroups(struct xrt_fdscan *s, int enabled)
{
    if (s) s->o.cgroups=enabled!=0;
}

void xrt_fdscan_detail(struct xrt_fdscan *s, int32_t pid)
{
    if (s)
        s->detail = pid;
}

enum xrt_status xrt_fdscan_interest(struct xrt_fdscan *s, const int32_t *pids,
                                    uint32_t count, int all)
{
    if (!s || count > XRT_FD_INTEREST_MAX || (count && !pids)) return XRT_INVALID_ARGUMENT;
    for (uint32_t i = 0; i < count; ++i) if (pids[i] <= 0) return XRT_INVALID_ARGUMENT;
    if (count) memcpy(s->interest, pids, count * sizeof(*pids));
    s->ninterest = count;
    s->all_interest = all != 0;
    return XRT_OK;
}
static int interested(const struct xrt_fdscan *s, int32_t pid)
{
    if (s->all_interest || s->detail == pid) return 1;
    for (uint32_t i = 0; i < s->ninterest; ++i) if (s->interest[i] == pid) return 1;
    return 0;
}

/* Returns the string offset, or 0 (the empty string) when the arena is full. */
static uint32_t put(struct xrt_fdscan *s, struct snap *c, const char *text, size_t n)
{
    if (n >= s->o.max_strings - c->nstrings)
        return 0;
    if (!grow_snap(s,c,0,0,0,c->nstrings+(uint32_t)n+1)) return 0;
    const uint32_t at = c->nstrings;
    memcpy(c->strings + at, text, n);
    c->strings[at + n] = 0;
    c->nstrings += (uint32_t)n + 1;
    return at;
}

/* Small /proc files: NUL-terminated bytes read, or -errno. One read: procfs
 * returns these records whole, and anything longer than cap is cut. */
static ssize_t slurp(int dir, const char *name, char *buffer, size_t cap)
{
    const int fd = openat(dir, name, O_RDONLY | O_CLOEXEC | O_NOCTTY);
    if (fd < 0)
        return -errno;
    ssize_t got;
    do
        got = read(fd, buffer, cap - 1);
    while (got < 0 && errno == EINTR);
    const int e = errno;
    close(fd);
    if (got < 0)
        return -e;
    buffer[got] = 0;
    return got;
}

static uint64_t field(const char *text, const char *name)
{
    const size_t n = strlen(name);
    for (const char *line = text; line && *line; line = strchr(line, '\n'), line = line ? line + 1 : NULL)
        if (!strncmp(line, name, n))
            return strtoull(line + n, NULL, 10);
    return 0;
}

static int starts(const char *text, size_t n, const char *prefix)
{
    const size_t p = strlen(prefix);
    return n >= p && !memcmp(text, prefix, p);
}

static void take_stat(struct xrt_fd *f, const struct stat *st)
{
    f->flags |= XRT_FD_STAT;
    f->mode = st->st_mode;
    f->device = st->st_dev;
    f->inode = st->st_ino;
    f->size = st->st_size;
    f->disk = (int64_t)st->st_blocks * 512;
}

/* Deleted means no links left; without a stat, the kernel's link suffix. */
static void deleted(struct xrt_fd *f, const char *link, size_t n, const struct stat *st, int have)
{
    f->flags &= (uint8_t)~XRT_FD_DELETED;
    if (f->kind == XRT_FD_REGULAR || f->kind == XRT_FD_DIRECTORY || (f->kind == XRT_FD_OTHER && n && link[0] == '/')) {
        if (have ? st->st_nlink == 0 : n > 10 && !memcmp(link + n - 10, " (deleted)", 10))
            f->flags |= XRT_FD_DELETED;
    }
}

static void classify(const char *link, size_t n, const struct stat *st, int have, struct xrt_fd *f)
{
    if (have)
        take_stat(f, st);
    if (starts(link, n, "socket:["))
        f->kind = XRT_FD_SOCKET;
    else if (starts(link, n, "pipe:["))
        f->kind = XRT_FD_PIPE;
    else if (starts(link, n, "anon_inode:"))
        f->kind = XRT_FD_ANON;
    else if (starts(link, n, "/memfd:"))
        f->kind = XRT_FD_MEMFD;
    else if (n && link[0] == '/' && have) {
        switch (st->st_mode & S_IFMT) {
        case S_IFREG: f->kind = XRT_FD_REGULAR; break;
        case S_IFDIR: f->kind = XRT_FD_DIRECTORY; break;
        case S_IFCHR:
        case S_IFBLK: f->kind = XRT_FD_DEVICE; break;
        case S_IFIFO: f->kind = XRT_FD_PIPE; break;
        case S_IFSOCK: f->kind = XRT_FD_SOCKET; break;
        default: f->kind = XRT_FD_OTHER; break;
        }
    } else
        f->kind = XRT_FD_OTHER;
    deleted(f, link, n, st, have);
}

static int fdinfo(int proc, int32_t pid, int32_t fd, struct xrt_fd *f)
{
    char name[48], text[512];
    if (pid) snprintf(name, sizeof(name), "%d/fdinfo/%d", pid, fd);
    else snprintf(name, sizeof(name), "fdinfo/%d", fd);
    if (slurp(proc, name, text, sizeof(text)) < 0)
        return 0;
    const char *flags = strstr(text, "flags:");
    if (strncmp(text, "pos:", 4) || !flags)
        return 0;
    f->pos = strtoull(text + 4, NULL, 10);
    f->open_flags = (uint32_t)strtoul(flags + 6, NULL, 8);
    f->flags |= XRT_FD_INFO;
    return 1;
}

static int seekable(const struct xrt_fd *f)
{
    return f->kind == XRT_FD_REGULAR || f->kind == XRT_FD_MEMFD ||
           (f->kind == XRT_FD_DEVICE && S_ISBLK(f->mode));
}

static void append_history(struct xrt_fd_process *p, uint32_t ms)
{
    struct xrt_fd_history *h = &p->history;
    if (h->samples == XRT_FD_HISTORY) {
        memmove(h->ms, h->ms + 1, sizeof(h->ms) - sizeof(h->ms[0]));
        memmove(h->fds, h->fds + 1, sizeof(h->fds) - sizeof(h->fds[0]));
        memmove(h->churn, h->churn + 1, sizeof(h->churn) - sizeof(h->churn[0]));
        memmove(h->io, h->io + 1, sizeof(h->io) - sizeof(h->io[0]));
        memmove(h->kinds, h->kinds + 1, sizeof(h->kinds) - sizeof(h->kinds[0]));
        h->samples--;
    }
    const uint32_t i = h->samples++;
    h->ms[i] = ms;
    h->fds[i] = p->count;
    h->churn[i] = p->opened + p->closed;
    h->io[i] = p->read_rate + p->write_rate;
    for (int k = 0; k < XRT_FD_KINDS; k++)
        h->kinds[i][k] = (uint16_t)(p->kinds[k] > 65535 ? 65535 : p->kinds[k]);
}

uint32_t xrt_fd_growth(const struct xrt_fd_process *p)
{
    return p->growth;
}

/* Growth over the history window, so a process that warmed up once and then
 * stayed flat drops out after XRT_FD_HISTORY samples. */
static void growth(struct xrt_fd_process *p)
{
    const struct xrt_fd_history *h = &p->history;
    uint32_t low = 0;
    for (uint32_t i = 1; i < h->samples; i++)
        if (h->fds[i] < h->fds[low])
            low = i;
    p->growth = h->samples && p->count > h->fds[low] ? p->count - h->fds[low] : 0;
    for (int k = 0; k < XRT_FD_KINDS; k++)
        p->grew[k] = h->samples && p->kinds[k] > h->kinds[low][k] ? p->kinds[k] - h->kinds[low][k] : 0;
}

/* Rising steadily: no drop over the last ten samples, at least four more fds
 * across them, and at least eight above the window's low point. */
static int leaking(const struct xrt_fd_process *p)
{
    const struct xrt_fd_history *h = &p->history;
    if (h->samples < 6 || p->growth < 8)
        return 0;
    const uint32_t k = h->samples < 10 ? h->samples : 10, from = h->samples - k;
    for (uint32_t i = from + 1; i < h->samples; i++)
        if (h->fds[i] < h->fds[i - 1])
            return 0;
    return h->fds[h->samples - 1] >= h->fds[from] + 4;
}

static int unseen(struct xrt_fdscan *s, struct snap *c, int32_t pid, uint32_t uid, uint64_t start, int kernel, int stale)
{
    if (c->nunseen == s->o.max_processes) {
        c->view.dropped_processes++;
        return 0;
    }
    if (!grow_snap(s,c,0,0,c->nunseen+1,0)) return 0;
    struct xrt_fd_unseen *u = &c->unseen[c->nunseen++];
    memset(u, 0, sizeof(*u));
    u->pid = pid;
    u->uid = uid;
    u->start = start;
    u->kernel = (uint8_t)kernel;
    u->stale = (uint8_t)stale;
    return 1;
}

/* Only the unified hierarchy has a single exact grouping key. Do not guess
 * a service from command names or silently equate different v1 hierarchies. */
static void read_cgroup(struct xrt_fdscan *s,struct snap *c,struct xrt_fd_process *p,int proc)
{
    char data[4096];ssize_t n=slurp(proc,"cgroup",data,sizeof data);
    p->cgroup_status=XRT_FD_CGROUP_UNAVAILABLE;
    if (n<0) {
        p->cgroup_error=(int32_t)-n;
        if (n==-EACCES || n==-EPERM) p->cgroup_status=XRT_FD_CGROUP_DENIED;
        return;
    }
    if (n==(ssize_t)sizeof data-1) {p->cgroup_status=XRT_FD_CGROUP_TRUNCATED;return;}
    if (n<5 || memchr(data,0,(size_t)n)) {p->cgroup_status=XRT_FD_CGROUP_MALFORMED;return;}
    const char *path=NULL;size_t length=0;
    for (const char *at=data;at<data+n;) {
        const char *end=memchr(at,'\n',(size_t)(data+n-at));
        if (!end) {p->cgroup_status=XRT_FD_CGROUP_MALFORMED;return;}
        if (end-at>=4 && !memcmp(at,"0::/",4)) {
            if (path) {p->cgroup_status=XRT_FD_CGROUP_MALFORMED;return;}
            path=at+3;length=(size_t)(end-path);
        }
        at=end+1;
    }
    if (!path) {p->cgroup_status=XRT_FD_CGROUP_UNSUPPORTED;return;}
    p->cgroup=put(s,c,path,length);p->cgroup_length=p->cgroup ? (uint32_t)length : 0;
    p->cgroup_status=p->cgroup ? XRT_FD_CGROUP_CURRENT : XRT_FD_CGROUP_TRUNCATED;
}

enum outcome { SCANNED, UNSEEN, GONE, FULL };
static int carry(struct xrt_fdscan *, struct snap *, const struct snap *, const struct xrt_fd_process *);

static enum outcome scan_process(struct xrt_fdscan *s, struct snap *c, const struct snap *prev,
                         const struct xrt_fd_process *old, const struct xrt_fd_unseen *was_unseen,
                         int32_t pid, uint64_t now, int proc)
{
    char name[48], text[1024];
    snprintf(name, sizeof(name), "stat");
    const ssize_t n = slurp(proc, name, text, sizeof(text));
    char *close_paren = n > 0 ? strrchr(text, ')') : NULL;
    char *open_paren = n > 0 ? strchr(text, '(') : NULL;
    unsigned long long fields[20] = {0};
    if (!close_paren || !open_paren || open_paren > close_paren || close_paren[1] != ' ')
        return GONE;
    {
        char *at = close_paren + 3; /* past ") S" */
        for (int i = 1; i < 20 && at; i++) {
            while (*at == ' ')
                at++;
            fields[i] = strtoull(at, &at, 10);
        }
    }
    const uint64_t start = fields[19];
    if (s->o.expected_start && start != s->o.expected_start) return GONE;
    if (fields[6] & PF_KTHREAD) {
        unseen(s, c, pid, 0, start, 1, 0);
        return UNSEEN;
    }
    if (old && old->start != start)
        old = NULL;
    if (was_unseen && was_unseen->start != start)
        was_unseen = NULL;
    /* Owner and permissions rarely change within one identity: recheck them,
     * and retry denied fd tables, every eighth scan. */
    const int recheck = (!old && !was_unseen) || s->sequence % 8 == 0;
    if (was_unseen && !recheck) {
        unseen(s, c, pid, was_unseen->uid, start, 0, 0);
        return UNSEEN;
    }
    struct stat st;
    uint32_t uid = old ? old->uid : was_unseen ? was_unseen->uid : 0;
    snprintf(name, sizeof(name), ".");
    if (recheck) {
        if (fstatat(proc, name, &st, 0))
            return GONE;
        uid = st.st_uid;
    }
    snprintf(name, sizeof(name), "fd");
    const int fd_dir = openat(proc, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd_dir < 0) {
        if (errno != EACCES && errno != EPERM)
            return GONE;
        unseen(s, c, pid, uid, start, 0, 0);
        return UNSEEN;
    }
    if (c->nprocs == s->o.max_processes) {
        close(fd_dir);
        return FULL;
    }
    if (!grow_snap(s,c,c->nprocs+1,0,0,0)) {close(fd_dir);return FULL;}
    const uint32_t strings_before = c->nstrings;
    struct xrt_fd_process *p = &c->procs[c->nprocs];
    memset(p, 0, offsetof(struct xrt_fd_process, history));
    p->pid = pid;
    p->ppid = (int32_t)fields[1];
    p->uid = uid;
    p->start = start;
    {
        size_t len = (size_t)(close_paren - open_paren - 1);
        if (len > sizeof(p->comm) - 1)
            len = sizeof(p->comm) - 1;
        memcpy(p->comm, open_paren + 1, len);
        p->comm[len] = 0;
    }
    if (s->o.cgroups) read_cgroup(s,c,p,proc);
    if (old) {
        p->history = old->history;
        p->lifetime_low = old->lifetime_low;
    } else {
        p->history.samples = 0;
        p->flags |= XRT_FDP_NEW;
    }
    if (old && !strcmp(old->comm, p->comm) && old->cmdline_length) {
        p->cmdline = put(s, c, prev->strings + old->cmdline, old->cmdline_length);
        p->cmdline_length = p->cmdline ? old->cmdline_length : 0;
    } else {
        char line[CMDLINE_MAX];
        snprintf(name, sizeof(name), "cmdline");
        const ssize_t got = slurp(proc, name, line, sizeof(line));
        if (got > 0) {
            p->cmdline = put(s, c, line, (size_t)got);
            p->cmdline_length = p->cmdline ? (uint32_t)got : 0;
        }
    }
    snprintf(name, sizeof(name), "io");
    if (slurp(proc, name, text, sizeof(text)) > 0) {
        p->rchar = field(text, "rchar:");
        p->wchar = field(text, "wchar:");
        p->read_bytes = field(text, "read_bytes:");
        p->write_bytes = field(text, "write_bytes:");
        if (old && !(old->flags & XRT_FDP_NO_IO)) {
            p->d_rchar = p->rchar >= old->rchar ? p->rchar - old->rchar : 0;
            p->d_wchar = p->wchar >= old->wchar ? p->wchar - old->wchar : 0;
        }
    } else
        p->flags |= XRT_FDP_NO_IO;
    p->sampled_ns = now;
    p->interval_ns = old && now > old->sampled_ns ? now - old->sampled_ns : 0;
    p->first = c->nfds;
    uint32_t count = 0, unlisted = 0;
    for (;;) {
        const long got = syscall(SYS_getdents64, fd_dir, s->dents, DENTS);
        if (got <= 0)
            break;
        for (long at = 0; at < got;) {
            const struct dent *e = (const struct dent *)(const void *)(s->dents + at); /* records are 8-byte aligned */
            at += e->reclen;
            if (e->name[0] < '0' || e->name[0] > '9')
                continue;
            if (count == s->numbers_cap) {
                /* Never hold more numbers than the fd limit could keep. */
                int32_t *grown=reserve(s,s->numbers,&s->numbers_cap,count+1,s->o.max_fds,sizeof *grown);
                if (!grown) {
                    unlisted++;
                    continue;
                }
                s->numbers = grown;
            }
            s->numbers[count++] = (int32_t)strtol(e->name, NULL, 10);
        }
    }
    if (unlisted) {
        p->flags |= XRT_FDP_TRUNCATED;
        c->view.dropped_fds += unlisted;
    }
    if (count > 1) /* numbers is NULL until a process has fds */
        qsort(s->numbers, count, sizeof(*s->numbers), by_pid);
    const struct xrt_fd *before = old ? prev->fds + old->first : NULL;
    const uint32_t before_count = old ? old->count : 0;
    const int whole = s->detail == pid;
    const int foreground = interested(s, pid);
    const int full = !s->o.adaptive || !old || foreground ||
                     s->sequence + 1 - old->full_sequence >= 8;
    p->full_sequence = full ? s->sequence + 1 : old->full_sequence;
    /* The count and process IO are only a hint. A close/reopen or rename can
     * leave both unchanged, so retaining anything marks the whole row stale. */
    if (!full && !unlisted && !(old->flags & (XRT_FDP_TRUNCATED | XRT_FDP_NO_IO)) &&
        !(p->flags & XRT_FDP_NO_IO) && count == old->count &&
        p->rchar == old->rchar && p->wchar == old->wchar &&
        p->read_bytes == old->read_bytes && p->write_bytes == old->write_bytes) {
        close(fd_dir);
        c->nstrings = strings_before;
        if (!carry(s, c, prev, old)) return FULL;
        c->procs[c->nprocs - 1].flags |= XRT_FDP_QUIET;
        ++c->view.stale;
        return SCANNED;
    }
    uint32_t j = 0, matched = 0;
    for (uint32_t i = 0; i < count; i++) {
        if (c->nfds == s->o.max_fds) {
            p->flags |= XRT_FDP_TRUNCATED;
            c->view.dropped_fds += count - i;
            break;
        }
        if (!grow_snap(s,c,0,c->nfds+1,0,0)) {close(fd_dir);return FULL;}
        char link[LINK_MAX];
        snprintf(name, sizeof(name), "%d", s->numbers[i]);
        struct xrt_fd *f = &c->fds[c->nfds];
        while (j < before_count && before[j].fd < s->numbers[i]) j++;
        const struct xrt_fd *was = j < before_count && before[j].fd == s->numbers[i] ? &before[j] : NULL;
        /* Cached absolute path targets use stat for identity and size. Their
         * path text is retained with a stale label until a full refresh.
         * Pipes/sockets use their inode-bearing link text instead. */
        int have = 0, cached_link = 0;
        if (!full && was && (was->flags & XRT_FD_STAT) &&
            !(was->flags & XRT_FD_LINK_CUT) && was->link_length && prev->strings[was->link] == '/') {
            have = fstatat(fd_dir, name, &st, 0) == 0;
            if (have && was->device == (uint64_t)st.st_dev && was->inode == (uint64_t)st.st_ino)
                cached_link = 1;
        }
        ssize_t len;
        if (cached_link) {
            len = was->link_length;
            memcpy(link, prev->strings + was->link, (size_t)len);
        } else {
            len = readlinkat(fd_dir, name, link, sizeof(link) - 1);
            if (len < 0 && errno == ENOENT) continue;
        }
        const size_t length = len < 0 ? 0 : (size_t)len;
        link[length] = 0;
        const int path = length && link[0] == '/';
        const int text = was && !(was->flags & XRT_FD_LINK_CUT) && was->link_length == length &&
                         !memcmp(prev->strings + was->link, link, length);
        const int needs = path && (!text || was->kind == XRT_FD_REGULAR || was->kind == XRT_FD_MEMFD || was->kind == XRT_FD_DIRECTORY || (full && s->o.adaptive));
        if (!have && needs) have = fstatat(fd_dir, name, &st, 0) == 0;
        int same = text;
        if (was && have && (was->flags & XRT_FD_STAT) && was->link_length && prev->strings[was->link] == '/')
            same = was->device == (uint64_t)st.st_dev && was->inode == (uint64_t)st.st_ino;
        if (!same && !path) have = fstatat(fd_dir, name, &st, 0) == 0;
        if (same) {
            *f = *was;
            f->flags &= (uint8_t)~(XRT_FD_OPENED | XRT_FD_LINK_CUT | XRT_FD_LINK_STALE | XRT_FD_STAT_STALE);
            if (cached_link) f->flags |= XRT_FD_LINK_STALE;
            if (!have) f->flags |= XRT_FD_STAT_STALE;
            f->advance = 0;
            f->rate = 0;
            if (have) {
                take_stat(f, &st);
                deleted(f, link, length, &st, have);
            }
            matched++;
        } else {
            memset(f, 0, sizeof(*f));
            f->fd = s->numbers[i];
            f->generation = (uint32_t)s->sequence + 1;
            if (old)
                f->flags |= XRT_FD_OPENED;
            classify(link, length, &st, have, f);
        }
        f->link_length = (uint16_t)length;
        f->link = length ? put(s, c, link, length) : 0;
        if (length && !f->link) {
            f->flags |= XRT_FD_LINK_CUT;
            f->link_length = 0;
            c->view.cut_strings++;
        }
        const int read_info = !same || whole || (seekable(f) && full);
        const uint64_t last = f->pos, last_at = same ? was->info_sampled_ns : 0;
        const int had = same && (was->flags & XRT_FD_INFO);
        f->flags |= XRT_FD_INFO_STALE;
        if (!same) f->info_interval_ns = 0;
        if (read_info && fdinfo(proc, 0, f->fd, f)) {
            f->flags &= (uint8_t)~XRT_FD_INFO_STALE;
            f->info_sampled_ns = now;
            f->info_interval_ns = had && now > last_at ? now - last_at : 0;
            if (had && f->pos > last) {
                f->advance = f->pos - last;
                f->rate = per_second(f->advance, f->info_interval_ns);
            }
        } else if (had) f->rate = was->rate;
        if (seekable(f) && (f->flags & XRT_FD_INFO_STALE)) p->flags |= XRT_FDP_OFFSETS_STALE;
        p->kinds[f->kind]++;
        p->advance += f->advance;
        if (!(f->flags & XRT_FD_INFO_STALE)) p->advance_rate += f->rate;
        c->nfds++;
    }
    close(fd_dir);
    p->count = c->nfds - p->first;
    if (old && !((p->flags | old->flags) & XRT_FDP_TRUNCATED)) {
        p->opened = p->count - matched;
        p->closed = before_count - matched;
        p->d_count = (int32_t)p->count - (int32_t)before_count;
    }
    p->read_rate = per_second(p->d_rchar, p->interval_ns);
    p->write_rate = per_second(p->d_wchar, p->interval_ns);
    /* Each fd may have a different previous offset sample. Sum its measured
     * rate, never divide a multi-scan offset delta by one process interval. */
    p->churn_rate = per_second((uint64_t)p->opened + p->closed, p->interval_ns);
    if (!old || p->count < p->lifetime_low)
        p->lifetime_low = p->count;
    append_history(p, (uint32_t)((now - s->epoch) / 1000000u));
    growth(p);
    if (leaking(p))
        p->flags |= XRT_FDP_LEAKING;
    c->nprocs++;
    return SCANNED;
}

static enum outcome scan(struct xrt_fdscan *s, struct snap *c, const struct snap *prev,
                         const struct xrt_fd_process *old, const struct xrt_fd_unseen *was,
                         int32_t pid, uint64_t now)
{
    if (s->expected_dir>=0) return scan_process(s,c,prev,old,was,pid,now,s->expected_dir);
    char name[32];snprintf(name,sizeof name,"%d",pid);
    int proc=openat(s->proc,name,O_RDONLY|O_DIRECTORY|O_CLOEXEC);
    if (proc<0) {
        if (errno==EACCES || errno==EPERM) {
            unseen(s,c,pid,was ? was->uid : 0,was ? was->start : 0,0,0);return UNSEEN;
        }
        return GONE;
    }
    enum outcome result=scan_process(s,c,prev,old,was,pid,now,proc);
    close(proc);return result;
}

/* Carry a process over unscanned when the time budget runs out: its last
 * rates stand, its counts are zero. */
static int carry(struct xrt_fdscan *s, struct snap *c, const struct snap *prev, const struct xrt_fd_process *old)
{
    if (c->nprocs == s->o.max_processes || old->count > s->o.max_fds - c->nfds)
        return 0;
    if (!grow_snap(s,c,c->nprocs+1,c->nfds+old->count,0,0)) return 0;
    struct xrt_fd_process *p = &c->procs[c->nprocs++];
    *p = *old;
    p->flags = (p->flags & ~(uint32_t)(XRT_FDP_NEW | XRT_FDP_QUIET)) | XRT_FDP_STALE | XRT_FDP_OFFSETS_STALE;
    p->d_rchar = p->d_wchar = p->advance = 0;
    p->opened = p->closed = 0;
    p->d_count = 0;
    p->interval_ns = 0;
    p->cgroup=old->cgroup_length ? put(s,c,prev->strings+old->cgroup,old->cgroup_length) : 0;
    p->cgroup_length=p->cgroup ? old->cgroup_length : 0;
    if (old->cgroup_length) p->cgroup_status=p->cgroup ? XRT_FD_CGROUP_STALE : XRT_FD_CGROUP_TRUNCATED;
    p->cmdline = old->cmdline_length ? put(s, c, prev->strings + old->cmdline, old->cmdline_length) : 0;
    if (!p->cmdline)
        p->cmdline_length = 0;
    p->first = c->nfds;
    for (uint32_t i = 0; i < old->count; i++) {
        struct xrt_fd *f = &c->fds[c->nfds++];
        *f = prev->fds[old->first + i];
        f->advance = 0;
        f->flags &= (uint8_t)~XRT_FD_OPENED;
        f->flags |= XRT_FD_INFO_STALE | XRT_FD_LINK_STALE | XRT_FD_STAT_STALE;
        if (f->link_length) {
            f->link = put(s, c, prev->strings + f->link, f->link_length);
            if (!f->link) {
                f->link_length = 0;
                f->flags |= XRT_FD_LINK_CUT;
                c->view.cut_strings++;
            }
        }
    }
    return 1;
}

static void record(struct xrt_fdscan *s, int metric, float value)
{
    s->totals[metric][s->ntotals] = value;
}

enum xrt_status xrt_fdscan_poll(struct xrt_fdscan *s, struct xrt_fd_snapshot *out)
{
    if (!s || !out)
        return XRT_INVALID_ARGUMENT;
    const uint64_t started = clock_ns(CLOCK_MONOTONIC), cpu = clock_ns(CLOCK_THREAD_CPUTIME_ID);
    const uint64_t deadline = s->o.budget_ms ? started + (uint64_t)s->o.budget_ms * 1000000u : UINT64_MAX;
    const struct snap *prev = &s->s[s->cur];
    struct snap *c = &s->s[!s->cur];
    const int first = s->sequence == 0;
    s->allocation_failed=0;
    c->nprocs = c->nfds = c->nunseen = 0;
    c->nstrings = 1;
    memset(&c->view, 0, sizeof(c->view));
    uint32_t pj = 0, uj = 0;
    DIR *listing = NULL;
    if (!s->pids) {
        const int again = openat(s->proc, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
        listing = again >= 0 ? fdopendir(again) : NULL;
        if (!listing) {
            if (again >= 0)
                close(again);
            return XRT_FILE_UNAVAILABLE;
        }
    }
    int32_t *pids = NULL;
    uint32_t npids = 0, cap = 0;
    if (listing) {
        for (struct dirent *e; (e = readdir(listing));) {
            if (e->d_name[0] < '1' || e->d_name[0] > '9')
                continue;
            /* Bound the pid listing as well as the visible/unseen arrays. */
            const uint32_t list_limit = s->o.max_processes * 2;
            if (npids == list_limit) {
                if (c->view.dropped_processes != UINT32_MAX)
                    c->view.dropped_processes++;
                continue;
            }
            if (npids == cap) {
                cap = cap ? cap * 2 : 1024;
                if (cap > list_limit) cap = list_limit;
                int32_t *grown = realloc(pids, cap * sizeof(*pids));
                if (!grown) {
                    free(pids);
                    closedir(listing);
                    return XRT_OUT_OF_MEMORY;
                }
                pids = grown;
            }
            pids[npids++] = (int32_t)strtol(e->d_name, NULL, 10);
        }
        closedir(listing);
        if (npids > 1)
            qsort(pids, npids, sizeof(*pids), by_pid);
    }
    const int32_t *list = listing ? pids : s->pids;
    const uint32_t total = listing ? npids : s->o.pid_count;
    /* Under a time budget each scan covers the next window of the pid list,
     * sized from the previous scan's pace, so every process is reached in
     * turn. Output stays in pid order; the others are carried over, stale,
     * and those never sampled yet are counted as unscanned. */
    uint32_t from = 0;
    while (from < total && list[from] < s->resume)
        from++;
    if (from == total)
        from = 0;
    const uint32_t to = s->window && s->window < total - from ? from + s->window : total;
    uint32_t next = to;
    int late = 0;
    for (uint32_t i = 0; i < total; i++) {
        const int32_t pid = list[i];
        if (i && list[i - 1] == pid)
            continue;
        if (pid == s->self && !s->o.include_self)
            continue;
        while (pj < prev->nprocs && prev->procs[pj].pid < pid)
            pj++;
        while (uj < prev->nunseen && prev->unseen[uj].pid < pid)
            uj++;
        const struct xrt_fd_process *old = !first && pj < prev->nprocs && prev->procs[pj].pid == pid ? &prev->procs[pj] : NULL;
        const struct xrt_fd_unseen *was = !first && uj < prev->nunseen && prev->unseen[uj].pid == pid ? &prev->unseen[uj] : NULL;
        if (i > from && i < to && !late && clock_ns(CLOCK_MONOTONIC) > deadline) {
            late = 1;
            next = i;
        }
        if (i < from || i >= to || late) {
            if (old) {
                if (carry(s, c, prev, old))
                    c->view.stale++;
                else
                    c->view.dropped_processes++;
            } else if (was)
                unseen(s, c, was->pid, was->uid, was->start, was->kernel, 1);
            else
                c->view.unscanned++;
            continue;
        }
        switch (scan(s, c, prev, old, was, pid, clock_ns(CLOCK_MONOTONIC))) {
        case SCANNED: break;
        case UNSEEN: break;
        case GONE: c->view.gone++; break;
        case FULL: c->view.dropped_processes++; break;
        }
    }
    if (s->o.budget_ms) {
        if (late)
            s->window = next > from ? next - from : 1;
        else if (s->window)
            s->window = s->window + s->window / 8 + 1 >= total ? 0 : s->window + s->window / 8 + 1;
        s->resume = next < total ? list[next] : 0;
    }
    free(pids);
    if (s->allocation_failed) return XRT_OUT_OF_MEMORY;
    const uint64_t ended = clock_ns(CLOCK_MONOTONIC);
    struct xrt_fd_snapshot *v = &c->view;
    v->source = XRT_FD_SOURCE_POLL;
    v->sequence = ++s->sequence;
    v->taken_ns = started;
    v->interval_ns = first ? 0 : started - prev->view.taken_ns;
    v->scan_ns = ended - started;
    v->scan_cpu_ns = clock_ns(CLOCK_THREAD_CPUTIME_ID) - cpu;
    v->processes = c->procs;
    v->process_count = c->nprocs;
    v->fds = c->fds;
    v->fd_count = c->nfds;
    v->strings = c->strings;
    v->strings_length = c->nstrings;
    v->unseen = c->unseen;
    v->unseen_count = c->nunseen;
    for (uint32_t k = 0; k < c->nunseen; k++) {
        if (c->unseen[k].kernel)
            v->kernel_threads++;
        else
            v->hidden++;
    }
    for (uint32_t k = 0; k < c->nprocs; k++) {
        const struct xrt_fd_process *p = &c->procs[k];
        for (int kind = 0; kind < XRT_FD_KINDS; kind++)
            v->kinds[kind] += p->kinds[kind];
        v->opened += p->opened;
        v->closed += p->closed;
        v->read_rate += p->read_rate;
        v->write_rate += p->write_rate;
        v->advance_rate += p->advance_rate;
        v->churn_rate += p->churn_rate;
    }
    if (!first) {
        if (s->ntotals == TOTALS) {
            for (int m = 0; m < METRICS; m++)
                memmove(s->totals[m], s->totals[m] + 1, sizeof(s->totals[m]) - sizeof(float));
            s->ntotals--;
        }
        record(s, XRT_FD_METRIC_FDS, (float)v->fd_count);
        record(s, XRT_FD_METRIC_CHURN, v->churn_rate);
        record(s, XRT_FD_METRIC_IO, v->read_rate + v->write_rate);
        record(s, XRT_FD_METRIC_READ, v->read_rate);
        record(s, XRT_FD_METRIC_WRITE, v->write_rate);
        s->ntotals++;
    }
    s->cur = !s->cur;
    *out = *v;
    return XRT_OK;
}

uint32_t xrt_fdscan_totals(const struct xrt_fdscan *s, enum xrt_fd_metric metric, float *out, uint32_t n)
{
    if (!s || (unsigned)metric >= METRICS || !out)
        return 0;
    const uint32_t k = n < s->ntotals ? n : s->ntotals;
    memcpy(out, s->totals[metric] + (s->ntotals - k), k * sizeof(float));
    return k;
}

static int by_key(const void *a, const void *b)
{
    const struct key *x = a, *y = b;
    if (x->device != y->device)
        return x->device < y->device ? -1 : 1;
    if (x->inode != y->inode)
        return x->inode < y->inode ? -1 : 1;
    if (x->proc != y->proc)
        return x->proc < y->proc ? -1 : 1;
    return (x->fd > y->fd) - (x->fd < y->fd);
}
static int by_rate(const void *a, const void *b)
{
    const struct xrt_fd_file *x = a, *y = b;
    if (x->rate != y->rate)
        return x->rate > y->rate ? -1 : 1;
    if (x->fds != y->fds)
        return x->fds > y->fds ? -1 : 1;
    return (x->sample > y->sample) - (x->sample < y->sample);
}

enum xrt_status xrt_fdscan_files(struct xrt_fdscan *s, const struct xrt_fd_file **out, uint32_t *count)
{
    if (!s || !out || !count || !s->sequence)
        return XRT_INVALID_ARGUMENT;
    const struct snap *c = &s->s[s->cur];
    if (s->files_sequence != s->sequence) {
        if (c->nfds>s->keys_cap) {
            void *p=reserve(s,s->keys,&s->keys_cap,c->nfds,s->o.max_fds,sizeof *s->keys);
            if (!p) return XRT_OUT_OF_MEMORY;
            s->keys=p;
        }
        if (c->nfds>s->files_cap) {
            void *p=reserve(s,s->files,&s->files_cap,c->nfds,s->o.max_fds,sizeof *s->files);
            if (!p) return XRT_OUT_OF_MEMORY;
            s->files=p;
        }
        uint32_t n = 0;
        for (uint32_t p = 0; p < c->nprocs; p++)
            for (uint32_t i = 0; i < c->procs[p].count; i++) {
                const uint32_t at = c->procs[p].first + i;
                const struct xrt_fd *f = &c->fds[at];
                if (!(f->flags & XRT_FD_STAT))
                    continue;
                struct key *k = &s->keys[n++];
                k->fd = at;
                k->proc = p;
                k->device = f->kind == XRT_FD_ANON ? UINT64_MAX : f->device;
                k->inode = f->kind == XRT_FD_ANON ? at : f->inode;
            }
        if (n > 1)
            qsort(s->keys, n, sizeof(*s->keys), by_key);
        uint32_t files = 0;
        for (uint32_t i = 0; i < n;) {
            const struct key *k = &s->keys[i];
            const struct xrt_fd *f = &c->fds[k->fd];
            struct xrt_fd_file *file = &s->files[files++];
            memset(file, 0, sizeof(*file));
            file->device = f->device;
            file->inode = f->inode;
            file->size = f->size;
            file->disk = f->disk;
            file->kind = f->kind;
            file->sample = k->fd;
            file->holder_set = 14695981039346656037ull;
            uint32_t j = i;
            for (; j < n && s->keys[j].device == k->device && s->keys[j].inode == k->inode; j++) {
                const struct xrt_fd *g = &c->fds[s->keys[j].fd];
                if (j == i || s->keys[j].proc != s->keys[j - 1].proc) {
                    file->holders++;
                    file->holder_set = (file->holder_set ^ (uint32_t)c->procs[s->keys[j].proc].pid) * 1099511628211ull;
                }
                file->fds++;
                file->flags |= g->flags & (XRT_FD_DELETED | XRT_FD_INFO_STALE | XRT_FD_LINK_STALE | XRT_FD_STAT_STALE);
                file->rate += g->rate;
                if ((g->flags & XRT_FD_INFO) && (g->open_flags & O_ACCMODE) == O_RDONLY)
                    file->read_rate += g->rate;
                if ((g->flags & XRT_FD_INFO) && (g->open_flags & O_ACCMODE) == O_WRONLY)
                    file->write_rate += g->rate;
                if (g->size > file->size)
                    file->size = g->size, file->disk = g->disk;
            }
            i = j;
        }
        if (files > 1)
            qsort(s->files, files, sizeof(*s->files), by_rate);
        s->nfiles = files;
        s->files_sequence = s->sequence;
    }
    *out = s->files;
    *count = s->nfiles;
    return XRT_OK;
}

/* One allocation: the snapshot header, then each array, 8-byte aligned. */
struct xrt_fd_snapshot *xrt_fd_snapshot_copy(const struct xrt_fd_snapshot *v)
{
    if (!v)
        return NULL;
    const size_t head = (sizeof(*v) + 7) & ~(size_t)7;
    const size_t procs = (size_t)v->process_count * sizeof(*v->processes);
    const size_t fds = (size_t)v->fd_count * sizeof(*v->fds);
    const size_t unseen_size = (size_t)v->unseen_count * sizeof(*v->unseen);
    const size_t strings = ((size_t)v->strings_length + 7) & ~(size_t)7;
    char *block = malloc(head + procs + fds + unseen_size + strings);
    if (!block)
        return NULL;
    struct xrt_fd_snapshot *copy = (struct xrt_fd_snapshot *)(void *)block;
    *copy = *v;
    char *at = block + head;
    if (procs)
        memcpy(at, v->processes, procs);
    copy->processes = (const struct xrt_fd_process *)(void *)at;
    at += procs;
    if (fds)
        memcpy(at, v->fds, fds);
    copy->fds = (const struct xrt_fd *)(void *)at;
    at += fds;
    if (unseen_size)
        memcpy(at, v->unseen, unseen_size);
    copy->unseen = (const struct xrt_fd_unseen *)(void *)at;
    at += unseen_size;
    if (v->strings_length)
        memcpy(at, v->strings, v->strings_length);
    copy->strings = at;
    return copy;
}

void xrt_fd_snapshot_free(struct xrt_fd_snapshot *copy)
{
    free(copy);
}
