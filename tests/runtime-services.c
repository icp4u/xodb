#define _GNU_SOURCE 1
/* Invented /proc trees: identical daemon rules across init layouts. */
#include "xrt_sysstat.h"
#include <assert.h>
#include <dirent.h>
#include <errno.h>
#include <ftw.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static char root[512];
static struct xrt_sys_snapshot snap;
static void put(const char *rel, const char *fmt, ...)
{
    char path[1024]; snprintf(path, sizeof path, "%s/%s", root, rel);
    for (char *p = path + strlen(root) + 1; *p; ++p) if (*p == '/') {
        *p = 0; assert(mkdir(path, 0755) == 0 || errno == EEXIST); *p = '/';
    }
    FILE *f = fopen(path, "w"); assert(f);
    va_list ap; va_start(ap, fmt); vfprintf(f, fmt, ap); va_end(ap); assert(fclose(f) == 0);
}
static void task(unsigned pid, unsigned ppid, unsigned sid, int tty, unsigned uid,
                 const char *cg, unsigned start, unsigned cpu, const char *name)
{
    char path[64];
    snprintf(path, sizeof path, "proc/%u/stat", pid);
    put(path, "%u (%s) S %u %u %u %d -1 0 0 0 0 0 %u 0 0 0 20 0 1 0 %u 40960 10 0\n",
        pid, name, ppid, sid, sid, tty, cpu, start);
    snprintf(path, sizeof path, "proc/%u/status", pid);
    put(path, "Name:\tdaemon\nUid:\t%u %u %u %u\n", uid, uid, uid, uid);
    snprintf(path, sizeof path, "proc/%u/cgroup", pid); put(path, "%s", cg);
    snprintf(path, sizeof path, "proc/%u/loginuid", pid); put(path, "%u\n", uid < 1000 ? UINT32_MAX : uid);
}
static void loginuid(unsigned pid, uint32_t uid)
{
    char path[64]; snprintf(path, sizeof path, "proc/%u/loginuid", pid); put(path, "%u\n", uid);
}
static int remove_one(const char *p, const struct stat *st, int type, struct FTW *f)
{
    (void)st; (void)type; (void)f; return remove(p);
}
static void sample(struct xrt_sys *s) { assert(xrt_sys_sample(s, &snap) == XRT_OK); }
static struct xrt_sys_service *row(unsigned pid)
{
    for (unsigned i = 0; i < snap.services.count; ++i) if (snap.services.service[i].pid.v == pid) return &snap.services.service[i];
    return NULL;
}
static struct xrt_sys *open_tree(unsigned max)
{
    struct xrt_sys_limits lim; xrt_sys_limits_default(&lim);
    lim.root = root; lim.groups = 1u << XRT_SYS_G_SERVICES; lim.budget_ns = 1000000000;
    lim.max_processes = max;
    struct xrt_sys *s = xrt_sys_open(&lim); assert(s); return s;
}
int main(void)
{
    umask(022);
    const char *tmp = getenv("TMPDIR");
    snprintf(root, sizeof root, "%s/xodb-services-XXXXXX", tmp && *tmp ? tmp : "/tmp");
    assert(mkdtemp(root)); assert(chmod(root, 0755) == 0);
    const char *inits[] = {"systemd", "openrc-init", "dinit"};
    const char *groups[] = {"0::/system.slice/daemon.service\n", "7:name=openrc:/sshd\n9:memory:/\n", "0::/\n"};
    const char *sessions[] = {"0::/user.slice/user-1000.slice/session-1.scope\n", "0::/1\n", "0::/\n"};
    for (unsigned layout = 0; layout < 3; ++layout) {
        put("proc/1/comm", "%s\n", inits[layout]);
        task(1, 0, 1, 0, 0, groups[layout], 1, 0, inits[layout]);
        put("proc/uptime", "1000.00 500.00\n");
        task(11, 1, 11, 0, 0, groups[layout], 100, 10, "daemon (odd)"); /* system uid */
        task(12, 1, 12, 0, 1200, groups[layout], 200, 20, "dedicated"); /* dedicated service account; not a login descendant */
        loginuid(12, UINT32_MAX);
        task(13, 1, 7, 0, 99, groups[layout], 300, 30, "orphan"); /* leader exited */
        task(14, 1, 14, 4, 0, groups[layout], 400, 40, "terminal");
        task(15, 9, 15, 0, 0, groups[layout], 500, 50, "supervised");
        task(16, 1, 1, 0, 0, groups[layout], 600, 60, "init-session");
        task(17, 1, 17, 0, 1200, "0::/user.slice/user-1200.slice/session-1.scope\n", 700, 70, "user");
        task(18, 1, 18, 0, 1200, "0::/a/user-1200.slice/b\n", 800, 80, "user-slice");
        task(19, 1, 19, 0, 1200, "0::/a/session-2.scope\n", 900, 90, "session");
        task(20, 1, 20, 0, 1200, "0::/user.slice-backup\n", 1000, 100, "not-user-slice");
        task(21, 1, 21, 0, 0, "0::/user.slice\n", 1100, 110, "system-uid"); /* system UID may qualify despite a user cgroup */
        loginuid(20, UINT32_MAX); /* component boundary test, dedicated daemon */
        loginuid(21, 1000); /* admin-started root daemon still qualifies */
        task(27, 1, 27, 0, 1000, sessions[layout], 1200, 0, "screen");
        task(28, 1, 28, 0, 1000, sessions[layout], 1300, 0, "dbus-session");
        task(29, 800, 800, 0, 1000, "0::/user.slice/user-1000.slice/user@1000.service/app.slice/app\n", 1400, 0, "user-app");
        struct xrt_sys *s = open_tree(8192); sample(s);
        assert(snap.services.count == 5 && snap.services.scanned == 14 && snap.services.unreadable == 0);
        char manager[64]; snprintf(manager, sizeof manager, "init: %s", inits[layout]);
        assert(!strcmp(snap.services.manager.s, manager));
        assert(row(11) && row(12) && row(13) && row(20) && row(21));
        assert(row(12)->loginuid.v == UINT32_MAX && !row(27) && !row(28) && !row(29));
        assert(!row(14) && !row(15) && !row(16) && !row(17) && !row(18) && !row(19));
        struct xrt_sys_service *v = row(11);
        assert(v->start_ticks.v == 100 && !strcmp(v->name, "daemon (odd)") && !strcmp(v->state.s, "S"));
        assert(v->uid.v == 0 && !strcmp(v->user.s, "uid:0") && v->rss.v == 10u * (unsigned long)sysconf(_SC_PAGESIZE));
        assert(v->uptime_s.st == XRT_SYS_OK && v->uptime_s.v == 1000.0 - 100.0 / (double)sysconf(_SC_CLK_TCK));
        assert(v->cpu_pct.why == XRT_SYS_WHY_FIRST_SAMPLE);
        usleep(20000); task(11, 1, 11, 0, 0, groups[layout], 100, 12, "daemon (odd)"); sample(s);
        assert(row(11)->cpu_pct.st == XRT_SYS_OK && row(11)->cpu_pct.v > 0);
        sample(s); assert(row(11)->cpu_pct.st == XRT_SYS_OK && row(11)->cpu_pct.v == 0);
        task(11, 1, 11, 0, 0, groups[layout], 100, 1, "daemon (odd)"); sample(s);
        assert(row(11)->cpu_pct.why == XRT_SYS_WHY_COUNTER_RESET);
        task(11, 1, 11, 0, 0, groups[layout], 999, 99, "replacement"); sample(s);
        assert(row(11)->start_ticks.v == 999 && row(11)->cpu_pct.why == XRT_SYS_WHY_FIRST_SAMPLE);
        struct xrt_sys_json_opts jo = {.groups = 1u << XRT_SYS_G_SERVICES};
        char *json = xrt_sys_json(&snap, &jo); assert(json);
        assert(strstr(json, "\"start_ticks\":999") && strstr(json, "\"user\":\"uid:0\"") && strstr(json, "\"uptime_s\":")); free(json);
        xrt_sys_configure(s, 1u << XRT_SYS_G_SERVICES, XRT_SYS_REDACT); sample(s);
        assert(snap.services.manager.why == XRT_SYS_WHY_REDACTED);
        assert(!strcmp(row(11)->name, "service") && row(11)->user.why == XRT_SYS_WHY_REDACTED && row(11)->cgroup.why == XRT_SYS_WHY_REDACTED);
        assert(row(11)->cgroup.s[0] == 0);
        assert(row(12)->uid.why == XRT_SYS_WHY_REDACTED && row(12)->uid.v == 0);
        assert(row(13)->uid.why == XRT_SYS_WHY_REDACTED && row(13)->uid.v == 0);
        assert(row(21)->loginuid.why == XRT_SYS_WHY_REDACTED && row(21)->loginuid.v == 0);
        json = xrt_sys_json(&snap, &jo); assert(json && !strstr(json, "replacement") && !strstr(json, "uid:0") && !strstr(json, "user.slice") && !strstr(json, "\"uid\":1200") && !strstr(json, "\"uid\":99") && !strstr(json, "\"loginuid\":1000")); free(json);
        xrt_sys_configure(s, 1u << XRT_SYS_G_SERVICES, 0);
        char path[1024]; snprintf(path, sizeof path, "%s/proc/12/loginuid", root); assert(unlink(path) == 0);
        sample(s); assert(!row(12) && snap.services.unreadable == 1); /* no cgroup-only fallback */
        put("proc/12/loginuid", "invalid\n"); sample(s); assert(!row(12) && snap.services.unreadable == 1);
        loginuid(12, UINT32_MAX); sample(s); assert(row(12));
        xrt_sys_close(s);
        printf("PASS %s: predicate, metadata, rates, reset, PID reuse, JSON, redaction\n", inits[layout]);
    }
    /* Unknown UID/login origin cannot be bypassed by a cgroup. A known system
     * UID can still qualify with unavailable cgroup metadata. */
    put("proc/11/status", "malformed\n");
    put("proc/12/cgroup", "malformed\n");
    put("proc/13/cgroup", "malformed\n");
    put("proc/20/stat", "bad stat\n");
    struct xrt_sys *s = open_tree(8192); sample(s);
    assert(!row(11));
    assert(!row(12) && row(13) && row(13)->cgroup.why == XRT_SYS_WHY_PARSE_ERROR);
    assert(snap.services.unreadable == 3 && strstr(snap.group[XRT_SYS_G_SERVICES].detail, "partial"));
    char path[1024]; snprintf(path, sizeof path, "%s/proc/11/status", root); assert(chmod(path, 0) == 0);
    sample(s);
    if (geteuid() != 0) assert(!row(11) && snap.services.unreadable >= 1);
    else puts("SKIP mode-bit denial: root bypasses discretionary permissions");
    assert(chmod(path, 0644) == 0);
    put("proc/11/status", "Name:	daemon\nUid:	0 0 0 0\n");
    /* No cgroup is silently shortened, and classification uses the whole path. */
    char longpath[1300]; memset(longpath, 'x', sizeof longpath); longpath[0] = '/'; longpath[sizeof longpath - 1] = 0;
    task(22, 1, 22, 0, 1200, "0::/\n", 10, 0, "long-path"); put("proc/22/cgroup", "0::%s\n", longpath); loginuid(22, UINT32_MAX);
    sample(s); assert(row(22) && row(22)->cgroup.why == XRT_SYS_WHY_LIMIT && !row(22)->cgroup.s[0]);
    put("proc/22/cgroup", "0::%s/user.slice\n", longpath); sample(s); assert(!row(22));
    put("proc/1/stat", "unreadable identity\n"); sample(s); assert(!row(13) && row(11));
    put("proc/uptime", "nan\n"); sample(s); assert(row(11)->uptime_s.why == XRT_SYS_WHY_PARSE_ERROR);
    /* A v1 user hierarchy wins even beside a non-user hierarchy. */
    task(23, 1, 23, 0, 1200, "2:cpu:/system.slice\n4:memory:/user.slice\n", 10, 0, "mixed-v1");
    task(24, 1, 24, 0, 1200, "2:cpu:/\n1:name=systemd:/system.slice/worker\n", 10, 0, "v1-display");
    task(25, 1, 25, 0, 0, "0::/\n", 10, 0, "kernel");
    put("proc/25/stat", "25 (kernel) I 1 25 25 0 -1 2097152 0 0 0 0 0 0 0 0 20 0 1 0 10 0 0\n");
    task(26, 1, 26, 0, 1200, "0::/session/worker\n", 10, 0, "session-component");
    loginuid(23, UINT32_MAX); loginuid(24, UINT32_MAX); loginuid(26, UINT32_MAX);
    sample(s); assert(!row(23) && row(24) && !strcmp(row(24)->cgroup.s, "/system.slice/worker") && !row(25) && !row(26));
    xrt_sys_close(s);
    s = open_tree(1); sample(s); assert(snap.services.truncated && snap.services.scanned == 1 && snap.group[XRT_SYS_G_SERVICES].why == XRT_SYS_WHY_LIMIT); xrt_sys_close(s);
    /* Row cap and kernel-thread exclusion are independent of init names. */
    task(1, 0, 1, 0, 0, "0::/\n", 1, 0, "init");
    for (unsigned pid = 100; pid < 620; ++pid) task(pid, 1, pid, 0, 0, "0::/\n", 1, 0, "service");
    s = open_tree(8192); sample(s); assert(snap.services.count == XRT_SYS_MAX_SERVICES && snap.services.truncated); xrt_sys_close(s);
    xrt_sys_snapshot_free(&snap); assert(nftw(root, remove_one, 32, FTW_DEPTH | FTW_PHYS) == 0);
    assert(mkdir(root, 0755) == 0);
    s = open_tree(8192); sample(s);
    assert(!snap.services.count && snap.group[XRT_SYS_G_SERVICES].st == XRT_SYS_UNAVAILABLE);
    xrt_sys_close(s);
    task(1, 0, 1, 0, 0, "0::/\n", 1, 0, "init");
    s = open_tree(8192); sample(s);
    assert(!snap.services.count && snap.group[XRT_SYS_G_SERVICES].st == XRT_SYS_OK);
    xrt_sys_close(s);
    put("proc/mounts", "proc /proc proc rw,hidepid=invisible 0 0\n");
    s = open_tree(8192); sample(s);
    assert(snap.services.visibility_limited && snap.group[XRT_SYS_G_SERVICES].why == XRT_SYS_WHY_NEEDS_PRIVILEGE);
    assert(strstr(snap.group[XRT_SYS_G_SERVICES].detail, "hidepid"));
    xrt_sys_close(s);
    snap.processes.proc = calloc(2, sizeof *snap.processes.proc); assert(snap.processes.proc);
    snap.processes.count = 2; snap.groups |= 1u << XRT_SYS_G_PROCESSES;
    snap.processes.proc[0].uid = (struct xrt_sys_u64){.v=0,.st=XRT_SYS_OK};
    snap.processes.proc[1].uid = (struct xrt_sys_u64){.v=1200,.st=XRT_SYS_OK};
    xrt_sys_snapshot_redact(&snap);
    assert(snap.processes.proc[0].uid.st == XRT_SYS_OK);
    assert(snap.processes.proc[1].uid.why == XRT_SYS_WHY_REDACTED && snap.processes.proc[1].uid.v == 0);
    struct xrt_sys_json_opts jo = {.groups=1u<<XRT_SYS_G_PROCESSES};
    char *json = xrt_sys_json(&snap, &jo); assert(json && !strstr(json, "\"uid\":1200")); free(json);
    xrt_sys_snapshot_free(&snap);
    assert(nftw(root, remove_one, 32, FTW_DEPTH | FTW_PHYS) == 0);
    puts("PASS partial/denied/malformed/long paths/init identity/uptime/scan and row bounds");
    return 0;
}
