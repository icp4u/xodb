#define _GNU_SOURCE 1
/* System observer parsing on a synthetic /proc + /sys tree. All values are
 * invented; nothing is captured from a real host. */
#include "xrt_sysstat.h"
#include <assert.h>
#include <errno.h>
#include <dirent.h>
#include <sys/resource.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <utmp.h>

static char root[256];

static void mkdirs(const char *rel)
{
    char p[512];
    snprintf(p, sizeof p, "%s/%s", root, rel);
    for (char *q = p + strlen(root) + 1; *q; ++q)
        if (*q == '/') {
            *q = 0;
            mkdir(p, 0755);
            *q = '/';
        }
    mkdir(p, 0755);
}
static void put(const char *rel, const char *fmt, ...)
{
    char p[512];
    snprintf(p, sizeof p, "%s/%s", root, rel);
    char *slash = strrchr(p, '/');
    *slash = 0;
    mkdirs(p + strlen(root) + 1);
    *slash = '/';
    FILE *f = fopen(p, "w");
    assert(f);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fclose(f);
}
static void link_to(const char *target, const char *rel)
{
    char p[512];
    snprintf(p, sizeof p, "%s/%s", root, rel);
    unlink(p);
    assert(symlink(target, p) == 0);
}
static int own_fds(void) {
    DIR *dir = opendir("/proc/self/fd"); assert(dir);
    int count = 0; struct dirent *entry;
    while ((entry = readdir(dir))) if (entry->d_name[0] != '.') count++;
    closedir(dir); return count;
}
static double mag(double x) { return x < 0 ? -x : x; }
static int near(double a, double b) { return mag(a - b) <= 1e-6 * (mag(b) > 1 ? mag(b) : 1); }

static void counters(unsigned step)
{
    /* cpu0 and cpu2 online, cpu1 offline (absent from /proc/stat) */
    put("proc/stat",
        "cpu  %u 0 %u %u 0 0 0 0 0 0\n"
        "cpu0 %u 0 %u %u 0 0 0 0 0 0\n"
        "cpu2 %u 0 %u %u 0 0 0 0 0 0\n"
        "intr %u 1 2 3\nctxt %u\nbtime 1000\nprocesses %u\nprocs_running 3\nprocs_blocked 1\n",
        200 + 60 * step, 100 + 20 * step, 1000 + 120 * step, 100 + 30 * step, 50 + 10 * step, 500 + 60 * step,
        100 + 30 * step, 50 + 10 * step, 500 + 60 * step, 5000 + 100 * step, 9000 + 400 * step, 700 + 2 * step);
    /* sda: reads sectors; nvme: counter reset on step 1 (device reset) */
    put("proc/diskstats",
        "   8       0 sda %u 0 %u 40 %u 0 %u 60 0 %u %u\n"
        "   8       1 sda1 1 0 8 0 1 0 8 0 0 0 0\n"
        " 259       0 nvme0n1 %u 0 %u 0 0 0 0 0 0 0 0\n"
        "   7       0 loop0 0 0 0 0 0 0 0 0 0 0 0\n",
        10 + 100 * step, 80 + 2048 * step, 5 + 50 * step, 40 + 1024 * step, 100 + 250 * step, 200 + 500 * step,
        step ? 1u : 1000u, step ? 8u : 80000u);
    put("proc/net/dev",
        "Inter-|   Receive                                                |  Transmit\n"
        " face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed\n"
        "    lo: %u %u 0 0 0 0 0 0 %u %u 0 0 0 0 0 0\n"
        "  eth0: %u %u 1 0 0 0 0 0 %u %u 0 2 0 0 0 0\n",
        1000 + 500 * step, 10 + 5 * step, 1000 + 500 * step, 10 + 5 * step, 4000 + 8000 * step, 40 + 80 * step,
        3000 + 1000 * step, 30 + 10 * step);
    put("proc/vmstat", "pgfault %u\npgmajfault 3\npswpin 0\npswpout %u\n", 100 + 1000 * step, 7 + 4 * step);
    put("proc/pressure/cpu", "some avg10=1.50 avg60=0.75 avg300=0.25 total=%u\n", 1000 + 25000 * step);
    put("proc/pressure/memory",
        "some avg10=0.00 avg60=0.00 avg300=0.00 total=0\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n");
    put("proc/100/stat",
        "100 (we(ird) n) S 1 100 100 0 -1 4194304 10 0 0 0 %u %u 0 0 20 0 2 0 %u 104857600 256 18446744073709551615\n",
        100 + 50 * step, 20 + 10 * step, 4242u);
    put("proc/100/io", "rchar: 1\nwchar: 2\nsyscr: 3\nsyscw: 4\nread_bytes: %u\nwrite_bytes: %u\ncancelled_write_bytes: 0\n",
        4096 + 8192 * step, 0 + 65536 * step);
    put("sys/class/powercap/intel-rapl:0/energy_uj", "%u\n", 1000000 + 5000000 * step);
}

int main(void)
{
    const char *tmp = getenv("TMPDIR");
    snprintf(root, sizeof root, "%s/xodb-sysstat-XXXXXX", tmp && *tmp ? tmp : "/tmp");
    assert(mkdtemp(root));
    chmod(root, 0755);
    counters(0);
    put("proc/uptime", "12345.67 9999.00\n");
    put("proc/loadavg", "0.50 0.40 0.30 2/345 6789\n");
    put("proc/meminfo",
        "MemTotal:       16000000 kB\nMemFree:         2000000 kB\nMemAvailable:    8000000 kB\nBuffers:          100000 kB\n"
        "Cached:          4000000 kB\nSwapCached:            0 kB\nSwapTotal:       1000000 kB\nSwapFree:         750000 kB\n"
        "Dirty:              123 kB\nWriteback:            0 kB\n");
    put("proc/cpuinfo", "processor\t: 0\nvendor_id\t: SyntheticVendor\nmodel name\t: Synthetic CPU 9000\n\n");
    put("proc/sys/kernel/osrelease", "6.1.0-synthetic\n");
    put("proc/sys/kernel/arch", "x86_64\n");
    put("proc/sys/kernel/hostname", "fixture-host\n");
    put("proc/1/comm", "init\n");
    put("proc/1/stat", "1 (init) S 0 1 1 0 -1 4194560 0 0 0 0 5 5 0 0 20 0 1 0 1 1000 10 0\n");
    put("proc/self/mountinfo",
        "21 1 259:2 / / rw,relatime shared:1 - ext4 /dev/nvme0n1p2 rw\n"
        "22 21 0:20 / /proc rw - proc proc rw\n"
        "23 21 0:21 / /tmp rw - tmpfs tmpfs rw\n"
        "24 21 8:1 / /mnt/my\\040disk rw - xfs /dev/sda1 rw\n"
        "25 21 8:1 /sub /srv rw - xfs /dev/sda1 rw\n"
        "26 21 0:50 / /net rw - nfs4 server:/export rw\n");
    for (int c = 0; c < 3; c += 2) {
        char p[128];
        snprintf(p, sizeof p, "sys/devices/system/cpu/cpu%d/topology/physical_package_id", c);
        put(p, "0\n");
        snprintf(p, sizeof p, "sys/devices/system/cpu/cpu%d/topology/die_id", c);
        put(p, "0\n");
        snprintf(p, sizeof p, "sys/devices/system/cpu/cpu%d/topology/core_id", c);
        put(p, "%d\n", c / 2);
        snprintf(p, sizeof p, "sys/devices/system/cpu/cpu%d/topology/thread_siblings_list", c);
        put(p, "%d\n", c);
        snprintf(p, sizeof p, "sys/devices/system/cpu/cpu%d/cache/index3/id", c);
        put(p, "%d\n", c / 2);
        snprintf(p, sizeof p, "sys/devices/system/cpu/cpu%d/cpufreq/scaling_cur_freq", c);
        put(p, "%d\n", 3000000 + c * 1000);
        snprintf(p, sizeof p, "sys/devices/system/cpu/cpu%d/cpufreq/cpuinfo_max_freq", c);
        put(p, "5000000\n");
    }
    put("sys/devices/system/cpu/cpu0/cpufreq/scaling_driver", "acpi-cpufreq\n");
    put("sys/devices/system/cpu/cpu0/cpufreq/scaling_governor", "schedutil\n");
    mkdirs("sys/block/sda/device");
    put("sys/block/sda/size", "2000\n");
    put("sys/block/sda/queue/rotational", "1\n");
    put("sys/block/sda/device/model", "SYNTH DISK  \n");
    mkdirs("sys/block/nvme0n1");
    put("sys/block/nvme0n1/size", "4000\n");
    mkdirs("sys/block/loop0");
    put("sys/block/loop0/size", "0\n");
    put("sys/class/net/lo/operstate", "unknown\n");
    put("sys/class/net/lo/flags", "0x9\n");
    put("sys/class/net/lo/mtu", "65536\n");
    put("sys/class/net/eth0/operstate", "up\n");
    put("sys/class/net/eth0/carrier", "1\n");
    put("sys/class/net/eth0/speed", "-1\n");
    put("sys/class/net/eth0/flags", "0x1003\n");
    put("sys/class/net/eth0/mtu", "1500\n");
    put("sys/class/net/eth0/address", "02:00:00:00:00:01\n");
    mkdirs("sys/class/net/eth0/device");
    /* hwmon: CPU chip with labels, an nvme chip mapped by device link, a GPU with both power files */
    put("sys/class/hwmon/hwmon0/name", "k10temp\n");
    put("sys/class/hwmon/hwmon0/temp1_input", "61250\n");
    put("sys/class/hwmon/hwmon0/temp1_label", "Tctl\n");
    put("sys/class/hwmon/hwmon0/temp3_input", "55000\n");
    put("sys/class/hwmon/hwmon0/temp3_label", "Tccd1\n");
    put("sys/class/hwmon/hwmon1/name", "nvme\n");
    put("sys/class/hwmon/hwmon1/temp1_input", "40850\n");
    put("sys/class/hwmon/hwmon1/temp1_label", "Composite\n");
    put("sys/class/hwmon/hwmon1/temp1_crit", "84850\n");
    link_to("../../nvme0", "sys/class/hwmon/hwmon1/device");
    put("sys/class/hwmon/hwmon2/name", "amdgpu\n");
    put("sys/class/hwmon/hwmon2/power1_average", "12500000\n");
    put("sys/class/hwmon/hwmon2/power1_input", "99000000\n");
    put("sys/class/hwmon/hwmon2/temp1_input", "45000\n");
    put("sys/class/hwmon/hwmon2/fan1_input", "1200\n");
    link_to("../../../devices/pci/0000:03:00.0", "sys/class/hwmon/hwmon2/device");
    put("sys/devices/pci/0000:03:00.0/uevent", "DRIVER=amdgpu\nPCI_ID=1002:ABCD\n");
    put("sys/devices/pci/0000:03:00.0/gpu_busy_percent", "37\n");
    put("sys/devices/pci/0000:03:00.0/mem_info_vram_used", "1048576\n");
    put("sys/devices/pci/0000:03:00.0/mem_info_vram_total", "8388608\n");
    mkdirs("sys/class/drm/card0");
    link_to("../../../devices/pci/0000:03:00.0", "sys/class/drm/card0/device");
    mkdirs("sys/class/drm/card0-DP-1");
    put("sys/class/power_supply/AC/type", "Mains\n");
    put("sys/class/power_supply/AC/online", "1\n");
    put("etc/os-release", "NAME=Synth\nPRETTY_NAME=\"Synthetic Linux 1\"\n");
    put("var/lib/pacman/local/ALPM_DB_VERSION", "9\n");
    put("var/lib/pacman/local/alpha-1.0-1/desc", "%%NAME%%\nalpha\n\n%%VERSION%%\n1.0-1\n\n%%SIZE%%\n1000\n");
    put("var/lib/pacman/local/beta-2.0-1/desc", "%%NAME%%\nbeta\n\n%%VERSION%%\n2.0-1\n\n%%SIZE%%\n5000\n");
    put("var/lib/pacman/local/gamma-3-1/desc", "%%NAME%%\ngamma\n\n%%VERSION%%\n3-1\n");
    put("etc/passwd", "root:x:0:0::/root:/bin/sh\ntester:x:%u:%u::/nonexistent:/bin/sh\n", (unsigned)getuid(), (unsigned)getgid());
    put("proc/100/cmdline", "%s", "");
    {
        char p[512];
        snprintf(p, sizeof p, "%s/proc/100/cmdline", root);
        FILE *f = fopen(p, "w");
        fwrite("/bin/worker\0--flag\0value\0", 1, 25, f);
        fclose(f);
    }
    put("proc/100/cgroup", "0::/synthetic.slice/worker\n");
    put("proc/100/loginuid", "4294967295\n");
    put("proc/100/status", "Name:\tworker\nUid:\t%u %u %u %u\n", (unsigned)getuid(), (unsigned)getuid(), (unsigned)getuid(), (unsigned)getuid());
    mkdirs("proc/100/fd");
    link_to("/dev/null", "proc/100/fd/0");
    link_to("socket:[777]", "proc/100/fd/1");
    link_to("pipe:[778]", "proc/100/fd/2");
    put("proc/101/stat", "101 (gone) Z 1 101 101 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 5000 0 0 0\n");
    put("proc/101/io", "denied\n");
    mkdirs("proc/101/fd");
    char deny[512];
    snprintf(deny, sizeof deny, "%s/proc/101/io", root);
    chmod(deny, 0);
    snprintf(deny, sizeof deny, "%s/proc/101/fd", root);
    chmod(deny, 0);
    put("proc/202/stat", "202 (kworker/0:1) I 2 0 0 0 -1 2129984 0 0 0 0 0 0 0 0 20 0 1 0 50 0 0 0\n");
    {
        struct utmp u[2];
        memset(u, 0, sizeof u);
        u[0].ut_type = USER_PROCESS;
        strcpy(u[0].ut_user, "tester");
        strcpy(u[0].ut_line, "pts/1");
        strcpy(u[0].ut_host, "remote.example");
        u[0].ut_pid = 4321;
        u[0].ut_tv.tv_sec = 1700000000;
        u[1].ut_type = DEAD_PROCESS;
        char p[512];
        snprintf(p, sizeof p, "%s/run", root);
        mkdir(p, 0755);
        snprintf(p, sizeof p, "%s/run/utmp", root);
        FILE *f = fopen(p, "wb");
        fwrite(u, sizeof u[0], 2, f);
        fclose(f);
    }

    struct xrt_sys_limits lim;
    xrt_sys_limits_default(&lim);
    lim.root = root;
    lim.sensor_timing_disabled = 1; /* scheduler preemption cannot change parser/field oracles */
    struct xrt_sys *s = xrt_sys_open(&lim);
    assert(s);
    struct xrt_sys_snapshot a = {0}, b = {0};
    assert(xrt_sys_sample(s, &a) == XRT_OK);
    assert(a.abi == XRT_SYS_ABI && a.sequence == 1);
    assert(a.interval_s.st == XRT_SYS_UNAVAILABLE && a.interval_s.why == XRT_SYS_WHY_FIRST_SAMPLE);
    /* first sample: rates are first-sample, never zero */
    assert(a.cpu.total.user.st == XRT_SYS_UNAVAILABLE && a.cpu.total.user.why == XRT_SYS_WHY_FIRST_SAMPLE);
    assert(a.disks.count == 2); /* sda and nvme0n1; partition and empty loop skipped */
    assert(a.disks.disk[0].read_bps.why == XRT_SYS_WHY_FIRST_SAMPLE);
    assert(a.network.iface[1].rx_bps.why == XRT_SYS_WHY_FIRST_SAMPLE);
    assert(a.processes.count == 4);
    assert(a.processes.proc[1].cpu_pct.why == XRT_SYS_WHY_FIRST_SAMPLE);
    assert(a.power.cpu_package_w.why == XRT_SYS_WHY_FIRST_SAMPLE);

    struct timespec pause = {0, 50 * 1000 * 1000};
    nanosleep(&pause, NULL);
    counters(1);
    assert(xrt_sys_sample(s, &b) == XRT_OK);
    double dt = b.interval_s.v;
    assert(b.interval_s.st == XRT_SYS_OK && dt > 0.04 && dt < 5);

    /* summary */
    assert(b.summary.uptime_s.st == XRT_SYS_OK && near(b.summary.uptime_s.v, 12345.67));
    assert(near(b.summary.load5.v, 0.40) && b.summary.threads.v == 345);
    assert(b.summary.running.v == 3 && b.summary.blocked.v == 1 && b.summary.boot_time_s.v == 1000);
    assert(near(b.summary.context_switches_ps.v, 400 / dt));
    assert(near(b.summary.forks_ps.v, 2 / dt));
    assert(b.summary.processes.st == XRT_SYS_OK && b.summary.processes.v == 4);
    assert(near(b.summary.memory_used_pct.v, 50.0));
    /* cpu: aggregate deltas user 60, system 20, idle 120 of 200 */
    assert(b.cpu.total.user.st == XRT_SYS_OK && near(b.cpu.total.user.v, 30.0));
    assert(near(b.cpu.total.system.v, 10.0) && near(b.cpu.total.idle.v, 60.0) && near(b.cpu.total.busy.v, 40.0));
    assert(b.cpu.count == 3 && b.cpu.online.v == 2 && b.cpu.logical.v == 3);
    assert(b.cpu.cpu[1].online.st == XRT_SYS_OK && b.cpu.cpu[1].online.v == 0);
    assert(b.cpu.cpu[1].t.busy.why == XRT_SYS_WHY_NOT_PRESENT);
    assert(near(b.cpu.cpu[0].t.user.v, 30.0) && near(b.cpu.cpu[2].t.busy.v, 40.0));
    assert(near(b.cpu.cpu[2].freq_mhz.v, 3002.0) && near(b.cpu.cpu[2].freq_max_mhz.v, 5000.0));
    assert(b.cpu.cpu[0].freq_min_mhz.why == XRT_SYS_WHY_NOT_PRESENT);
    assert(b.cpu.cpu[2].core_id.v == 1 && b.cpu.cpu[2].l3_id.v == 1 && b.cpu.cpu[2].smt_index.v == 0);
    assert(b.cpu.cores.v == 2 && b.cpu.packages.v == 1 && b.cpu.l3_groups.v == 2);
    assert(!strcmp(b.cpu.model.s, "Synthetic CPU 9000") && !strcmp(b.cpu.freq_driver.s, "acpi-cpufreq"));
    assert(b.cpu.epp.why == XRT_SYS_WHY_NOT_PRESENT);
    assert(near(b.cpu.package_temp_c.v, 61.25) && b.cpu.temp_count == 2);
    assert(b.cpu.cpu[0].temp_c.why == XRT_SYS_WHY_NOT_PRESENT);
    assert(near(b.cpu.psi.some_avg10.v, 1.5) && near(b.cpu.psi.some_pct.v, 25000e-4 / dt));
    assert(b.cpu.psi.full_avg10.why == XRT_SYS_WHY_NOT_PRESENT); /* no "full" line */
    /* memory */
    assert(b.memory.total.v == 16000000ull * 1024 && b.memory.used.v == 8000000ull * 1024);
    assert(b.memory.swap_used.v == 250000ull * 1024 && b.memory.dirty.v == 123 * 1024);
    assert(b.memory.zswap_pool.st == XRT_SYS_UNAVAILABLE && b.memory.zswap_pool.why == XRT_SYS_WHY_NOT_PRESENT);
    assert(b.memory.zswap_enabled.why == XRT_SYS_WHY_NOT_PRESENT);
    assert(near(b.memory.page_faults_ps.v, 1000 / dt) && near(b.memory.swap_out_ps.v, 4 / dt));
    assert(b.memory.psi.full_avg10.st == XRT_SYS_OK && b.memory.psi.full_pct.st == XRT_SYS_OK && b.memory.psi.full_pct.v == 0);
    /* disks */
    const struct xrt_sys_disk *sda = &b.disks.disk[0], *nv = &b.disks.disk[1];
    assert(!strcmp(sda->name, "sda") && sda->size_bytes.v == 2000 * 512 && sda->rotational.v == 1);
    assert(!strcmp(sda->model.s, "SYNTH DISK"));
    assert(near(sda->read_bps.v, 2048 * 512 / dt) && near(sda->write_bps.v, 1024 * 512 / dt));
    assert(near(sda->read_iops.v, 100 / dt) && near(sda->busy_pct.v, 250 * 0.1 / dt > 100 ? 100 : 250 * 0.1 / dt));
    assert(near(sda->queue_depth.v, 500e-3 / dt) && near(sda->avg_latency_ms.v, 0.0));
    assert(sda->temp_c.why == XRT_SYS_WHY_NOT_PRESENT && sda->removable.why == XRT_SYS_WHY_NOT_PRESENT);
    assert(!strcmp(nv->name, "nvme0n1") && nv->read_bps.why == XRT_SYS_WHY_COUNTER_RESET);
    assert(nv->temp_c.st == XRT_SYS_OK && near(nv->temp_c.v, 40.85));
    assert(nv->avg_latency_ms.st == XRT_SYS_UNAVAILABLE);
    assert(b.disks.psi.some_avg10.why == XRT_SYS_WHY_NOT_PRESENT); /* no io pressure file */
    /* filesystems: pseudo and duplicate skipped, escape decoded, network fs not probed */
    assert(b.filesystems.count == 3 && b.filesystems.skipped_pseudo == 2 && b.filesystems.skipped_duplicate == 1);
    assert(!strcmp(b.filesystems.fs[1].mount.s, "/mnt/my disk"));
    assert(b.filesystems.fs[0].total.why == XRT_SYS_WHY_NOT_SUPPORTED); /* statvfs needs the live system */
    assert(b.filesystems.fs[2].total.why == XRT_SYS_WHY_NOT_SUPPORTED);
    /* network */
    assert(b.network.count == 2);
    const struct xrt_sys_iface *lo = &b.network.iface[0], *eth = &b.network.iface[1];
    assert(lo->loopback.v == 1 && eth->loopback.v == 0 && eth->physical.v == 1 && lo->physical.v == 0);
    assert(eth->speed_mbps.why == XRT_SYS_WHY_NOT_PRESENT && eth->mtu.v == 1500 && !strcmp(eth->operstate.s, "up"));
    assert(lo->carrier.why == XRT_SYS_WHY_NOT_PRESENT);
    assert(near(eth->rx_bps.v, 8000 / dt) && near(eth->tx_pps.v, 10 / dt) && eth->rx_errors_ps.v == 0);
    assert(near(b.network.rx_bps.v, 8000 / dt)); /* loopback excluded */
    assert(!strcmp(eth->mac.s, "02:00:00:00:00:01"));
    assert(!strcmp(eth->kind.s, "physical") && !strcmp(lo->kind.s, "loopback"));
    /* processes: identity, odd comm, rates, denial cache, kernel thread */
    const struct xrt_sys_proc *p = &b.processes.proc[1], *z = &b.processes.proc[2], *k = &b.processes.proc[3];
    assert(p->pid == 100 && p->start_ticks == 4242 && !strcmp(p->comm, "we(ird) n"));
    assert(p->ppid.v == 1 && p->threads.v == 2 && p->rss.v == 256ull * (uint64_t)sysconf(_SC_PAGESIZE));
    assert(near(p->cpu_pct.v, 60 * 1e7 / dt * 1e-7)); /* 60 ticks at 100 Hz */
    assert(!strcmp(p->cmdline.s, "/bin/worker --flag value") && !strcmp(p->cgroup.s, "/synthetic.slice/worker"));
    assert(p->uid.v == getuid() && !strcmp(p->user.s, "tester"));
    assert(near(p->io_read_bps.v, 8192 / dt) && near(p->io_write_bps.v, 65536 / dt));
    assert(p->fds.st == XRT_SYS_OK && p->fds.v == 3 && p->net_bps.why == XRT_SYS_WHY_NOT_SUPPORTED);
    assert(p->pss.why == XRT_SYS_WHY_NOT_COLLECTED && p->kernel_thread.v == 0);
    assert(z->pid == 101 && z->state == 'Z' && z->cmdline.st == XRT_SYS_UNAVAILABLE);
    if (geteuid() != 0) {
        assert(z->io_read_bytes.why == XRT_SYS_WHY_NEEDS_PRIVILEGE && z->io_read_bps.why == XRT_SYS_WHY_NEEDS_PRIVILEGE);
        assert(z->fds.why == XRT_SYS_WHY_NEEDS_PRIVILEGE);
    }
    assert(k->pid == 202 && k->kernel_thread.v == 1 && k->state == 'I');
    /* power */
    assert(b.power.sensor_count == 6);
    int found_avg = 0;
    for (uint32_t i = 0; i < b.power.sensor_count; ++i)
        if (b.power.sensor[i].kind == XRT_SYS_POWER_W) found_avg += near(b.power.sensor[i].value.v, 12.5);
    assert(found_avg == 1); /* power1_average wins over power1_input */
    assert(b.power.gpu_count == 1 && !strcmp(b.power.gpu[0].driver, "amdgpu") && !strcmp(b.power.gpu[0].name.s, "1002:abcd"));
    assert(near(b.power.gpu[0].busy_pct.v, 37) && near(b.power.gpu[0].power_w.v, 12.5) && near(b.power.gpu[0].temp_c.v, 45));
    assert(b.power.gpu[0].vram_total.v == 8388608);
    assert(b.power.cpu_package_w.st == XRT_SYS_OK && b.power.cpu_package_w.v > 0);
    assert(near(b.power.ac_online.v, 1) && b.power.battery_pct.why == XRT_SYS_WHY_NOT_PRESENT);
    /* users: only USER_PROCESS records */
    assert(b.users.count == 1 && !strcmp(b.users.user[0].user.s, "tester") && b.users.user[0].pid.v == 4321);
    assert(!strcmp(b.users.user[0].host.s, "remote.example") && !strcmp(b.users.user[0].line, "pts/1"));
    /* Services are proc-derived; PID 100 has an unset audit login UID. */
    assert(!strcmp(b.services.manager.s, "init: init") && b.services.count == 1);
    assert(b.services.service[0].pid.v == 100 && b.services.service[0].start_ticks.v == 4242);
    assert(!strcmp(b.services.service[0].state.s, "S"));
    /* apps */
    assert(b.apps.count.v == 3 && b.apps.total_size.v == 6000 && b.apps.list_count == 3);
    assert(!strcmp(b.apps.list[0].name, "beta") && b.apps.list[2].size.why == XRT_SYS_WHY_NOT_PRESENT);
    /* sysinfo */
    assert(!strcmp(b.info.kernel.s, "6.1.0-synthetic") && !strcmp(b.info.os.s, "Synthetic Linux 1"));
    assert(b.info.hostname.why == XRT_SYS_WHY_REDACTED && !strcmp(b.info.init.s, "init"));
    assert(!strcmp(b.info.package_manager.s, "pacman") && b.info.gpu_count == 1);
    assert(b.info.memory_total.v == 16000000ull * 1024 && b.info.physical_cores.v == 2);
    /* connections need the live system */
    assert(b.group[XRT_SYS_G_CONNECTIONS].st == XRT_SYS_UNAVAILABLE && b.connections.tcp.why == XRT_SYS_WHY_NOT_SUPPORTED);
    /* self cost is always measured */
    assert(b.self.wall_ms.st == XRT_SYS_OK && b.self.syscalls.v > 0 && b.self.files_opened.v > 0);

    /* JSON: shape, states, filters */
    struct xrt_sys_json_opts o = {.groups = XRT_SYS_ALL_GROUPS, .sort = XRT_SYS_SORT_CPU, .limit = 0};
    char *j = xrt_sys_json(&b, &o);
    assert(j);
    long depth = 0;
    int in_str = 0;
    for (const char *c = j; *c; ++c) {
        if (in_str) {
            if (*c == '\\') ++c;
            else if (*c == '"') in_str = 0;
            continue;
        }
        if (*c == '"') in_str = 1;
        else if (*c == '{' || *c == '[') ++depth;
        else if (*c == '}' || *c == ']') assert(--depth >= 0);
    }
    assert(depth == 0 && !in_str);
    assert(strstr(j, "\"comm\":\"we(ird) n\""));
    assert(strstr(j, "\"read_bps\":{\"state\":\"unavailable\",\"why\":\"counter reset\"}"));
    assert(strstr(j, "\"net_bps\":{\"state\":\"unavailable\",\"why\":\"not supported\"}"));
    assert(!strstr(j, ":nan") && !strstr(j, ":inf") && !strstr(j, ":-inf"));
    free(j);
    o.pid = 202;
    o.groups = 1u << XRT_SYS_G_PROCESSES;
    j = xrt_sys_json(&b, &o);
    assert(j && strstr(j, "\"shown\":1") && strstr(j, "kworker") && !strstr(j, "\"cpu\":"));
    free(j);

    /* copy is deep and independent */
    struct xrt_sys_snapshot c = {0};
    assert(xrt_sys_snapshot_copy(&c, &b) == XRT_OK);
    assert(c.processes.proc != b.processes.proc && c.processes.count == 4 && c.processes.proc[1].pid == 100);
    xrt_sys_snapshot_free(&b);
    assert(c.apps.list && !strcmp(c.apps.list[0].name, "beta"));

    /* redaction and group masks */
    xrt_sys_configure(s, (1u << XRT_SYS_G_PROCESSES) | (1u << XRT_SYS_G_NETWORK) | (1u << XRT_SYS_G_USERS) |
                             (1u << XRT_SYS_G_FILESYSTEMS), XRT_SYS_REDACT);
    assert(xrt_sys_sample(s, &b) == XRT_OK);
    assert(b.redacted == 1 && b.processes.proc[1].cmdline.why == XRT_SYS_WHY_REDACTED);
    if (getuid() != 0) assert(b.processes.proc[1].uid.why == XRT_SYS_WHY_REDACTED && b.processes.proc[1].uid.v == 0);
    assert(b.processes.proc[1].user.why == XRT_SYS_WHY_REDACTED && b.users.user[0].host.why == XRT_SYS_WHY_REDACTED);
    assert(b.network.iface[1].mac.why == XRT_SYS_WHY_REDACTED && !strcmp(b.network.iface[0].mac.s, ""));
    assert(!strcmp(b.filesystems.fs[0].mount.s, "/") && b.filesystems.fs[1].mount.why == XRT_SYS_WHY_REDACTED);
    assert(b.filesystems.fs[2].mount.why == XRT_SYS_WHY_REDACTED && b.filesystems.fs[2].source.why == XRT_SYS_WHY_REDACTED);
    assert(b.group[XRT_SYS_G_CPU].st == XRT_SYS_UNAVAILABLE && b.group[XRT_SYS_G_CPU].why == XRT_SYS_WHY_NOT_COLLECTED);
    assert(b.cpu.total.user.st == XRT_SYS_UNSET);
    j = xrt_sys_json(&b, NULL);
    assert(j && !strstr(j, "tester") && !strstr(j, "worker --flag") && !strstr(j, "remote.example") && !strstr(j, "02:00:00"));
    assert(!strstr(j, "\"cpu\":{\"model\""));
    free(j);
    /* a group re-enabled after a skip computes its rates over its own interval */
    nanosleep(&pause, NULL);
    counters(2);
    xrt_sys_configure(s, XRT_SYS_ALL_GROUPS, 0);
    assert(xrt_sys_sample(s, &b) == XRT_OK);
    double cpu_dt = (double)b.group[XRT_SYS_G_CPU].interval_ns * 1e-9;
    assert(b.group[XRT_SYS_G_CPU].interval_ns > b.group[XRT_SYS_G_PROCESSES].interval_ns);
    assert(b.group[XRT_SYS_G_SUMMARY].interval_ns == b.group[XRT_SYS_G_CPU].interval_ns);
    assert(near(b.cpu.total.user.v, 30.0) && near(b.summary.context_switches_ps.v, 400 / cpu_dt));
    assert(near(b.processes.proc[1].cpu_pct.v, 60 / ((double)b.group[XRT_SYS_G_PROCESSES].interval_ns * 1e-9)));
    /* no tick elapsed: rates say so instead of reporting zero */
    assert(xrt_sys_sample(s, &b) == XRT_OK);
    assert(b.cpu.total.user.why == XRT_SYS_WHY_TOO_SOON && b.cpu.total.busy.st == XRT_SYS_UNAVAILABLE);

    /* Light mode never turns omitted IO/fd work into a measured zero or denial.
     * Returning to full detail needs a new IO baseline. */
    xrt_sys_configure(s, 1u << XRT_SYS_G_PROCESSES, XRT_SYS_LIGHT_PROCESSES);
    assert(xrt_sys_sample(s, &b) == XRT_OK);
    assert(b.processes.proc[1].fds.why == XRT_SYS_WHY_NOT_COLLECTED);
    assert(b.processes.proc[1].io_read_bytes.why == XRT_SYS_WHY_NOT_COLLECTED);
    assert(b.processes.proc[1].io_read_bps.why == XRT_SYS_WHY_NOT_COLLECTED);
    xrt_sys_configure(s, 1u << XRT_SYS_G_PROCESSES, 0);
    assert(xrt_sys_sample(s, &b) == XRT_OK);
    assert(b.processes.proc[1].fds.st == XRT_SYS_OK && b.processes.proc[1].fds.v == 3);
    assert(b.processes.proc[1].io_read_bytes.st == XRT_SYS_OK);
    assert(b.processes.proc[1].io_read_bps.why == XRT_SYS_WHY_FIRST_SAMPLE);
    /* Reply redaction works on a copy; the shared original is unchanged. */
    struct xrt_sys_snapshot hidden = {0};
    assert(xrt_sys_snapshot_copy(&hidden, &c) == XRT_OK);
    xrt_sys_snapshot_redact(&hidden);
    assert(hidden.info.kernel.why == XRT_SYS_WHY_REDACTED && hidden.info.os.why == XRT_SYS_WHY_REDACTED);
    assert(hidden.processes.proc[1].cmdline.why == XRT_SYS_WHY_REDACTED);
    assert(c.processes.proc[1].cmdline.st == XRT_SYS_OK && c.info.kernel.st == XRT_SYS_OK);
    xrt_sys_snapshot_free(&hidden);

    /* A vanished classification and a known virtual-only set are not physical-link zeroes. */
    char net_original[512], net_saved[512], net_device[512];
    snprintf(net_original, sizeof net_original, "%s/sys/class/net/eth0", root);
    snprintf(net_saved, sizeof net_saved, "%s/sys/class/net/saved", root);
    snprintf(net_device, sizeof net_device, "%s/sys/class/net/eth0/device", root);
    assert(rename(net_original, net_saved) == 0);
    xrt_sys_configure(s, 1u << XRT_SYS_G_NETWORK, 0);
    assert(xrt_sys_sample(s, &b) == XRT_OK && b.network.rx_bps.st == XRT_SYS_UNAVAILABLE);
    assert(rename(net_saved, net_original) == 0);
    assert(rmdir(net_device) == 0);
    assert(xrt_sys_sample(s, &b) == XRT_OK && b.network.rx_bps.st == XRT_SYS_UNAVAILABLE);
    assert(b.network.rx_bps.why == XRT_SYS_WHY_NOT_PRESENT);
    assert(mkdir(net_device, 0755) == 0);

    /* Metadata refresh counts process samples, even between other groups. */
    put("proc/100/cmdline", "updated-a"); put("proc/101/cmdline", "updated-b");
    int refreshed_a = 0, refreshed_b = 0;
    for (int step = 0; step < 16; ++step) {
        xrt_sys_configure(s, 1u << XRT_SYS_G_PROCESSES, XRT_SYS_LIGHT_PROCESSES);
        assert(xrt_sys_sample(s, &b) == XRT_OK);
        for (uint32_t k = 0; k < b.processes.count; ++k) {
            const struct xrt_sys_proc *p = &b.processes.proc[k];
            if (p->pid == 100 && !strcmp(p->cmdline.s, "updated-a")) refreshed_a = 1;
            if (p->pid == 101 && !strcmp(p->cmdline.s, "updated-b")) refreshed_b = 1;
        }
        xrt_sys_configure(s, 1u << XRT_SYS_G_MEMORY, 0);
        assert(xrt_sys_sample(s, &b) == XRT_OK);
    }
    assert(refreshed_a && refreshed_b);

    /* tiny capacity truncates explicitly */
    struct xrt_sys_limits small = lim;
    small.max_processes = 1;
    small.groups = 1u << XRT_SYS_G_PROCESSES;
    struct xrt_sys *t = xrt_sys_open(&small);
    struct xrt_sys_snapshot d = {0};
    assert(xrt_sys_sample(t, &d) == XRT_OK && d.processes.count == 1 && d.processes.truncated == 3);
    xrt_sys_snapshot_free(&d);
    xrt_sys_close(t);

    /* reason and group text are total */
    for (int r = 0; r < XRT_SYS_WHY_COUNT; ++r) assert(strcmp(xrt_sys_reason_text((enum xrt_sys_reason)r), "unknown"));
    for (int g = 0; g < XRT_SYS_G_COUNT; ++g) assert(strcmp(xrt_sys_group_name((enum xrt_sys_group_id)g), "unknown"));

    xrt_sys_snapshot_free(&b);
    xrt_sys_snapshot_free(&c);
    xrt_sys_snapshot_free(&a);
    xrt_sys_close(s);
    snprintf(deny, sizeof deny, "%s/proc/101/fd", root);
    chmod(deny, 0755);
    char cmd[600];
    snprintf(cmd, sizeof cmd, "rm -rf '%s'", root);
    assert(system(cmd) == 0);
    /* N1/N2: an empty root has no primary sources; groups and counts say so */
    {
        char empty[300];
        snprintf(empty, sizeof empty, "%s/xodb-sysstat-empty-XXXXXX", tmp && *tmp ? tmp : "/tmp");
        assert(mkdtemp(empty));
        struct xrt_sys_limits el = lim;
        el.root = empty;
        struct xrt_sys *e = xrt_sys_open(&el);
        struct xrt_sys_snapshot es = {0};
        assert(xrt_sys_sample(e, &es) == XRT_OK);
        static const int primary[] = {XRT_SYS_G_CPU, XRT_SYS_G_MEMORY, XRT_SYS_G_DISKS, XRT_SYS_G_FILESYSTEMS,
                                      XRT_SYS_G_NETWORK, XRT_SYS_G_PROCESSES};
        for (size_t i = 0; i < sizeof primary / sizeof primary[0]; ++i)
            assert(es.group[primary[i]].st == XRT_SYS_UNAVAILABLE && es.group[primary[i]].why == XRT_SYS_WHY_NOT_PRESENT);
        assert(es.cpu.logical.st == XRT_SYS_UNAVAILABLE && es.memory.total.st == XRT_SYS_UNAVAILABLE);
        xrt_sys_snapshot_free(&es);
        xrt_sys_close(e);
        rmdir(empty);
    }

    /* Live, owned processes only. R1: a non-dumpable process's /proc inodes are
     * root-owned; its uid must still be the real one. R2: sockets past the fd
     * counting cap keep their owner. */
    {
        int sv[2], cv[2];
        assert(socketpair(AF_UNIX, SOCK_STREAM, 0, cv) == 0);
        struct stat cst;
        assert(fstat(cv[0], &cst) == 0);
        int ready[2];
        assert(pipe(ready) == 0);
        pid_t child = fork();
        assert(child >= 0);
        if (child == 0) {
            prctl(PR_SET_DUMPABLE, 0, 0, 0, 0);
            close(ready[0]);
            assert(write(ready[1], "x", 1) == 1);
            for (;;) sleep(60);
        }
        close(ready[1]);
        char x;
        assert(read(ready[0], &x, 1) == 1);
        close(ready[0]);
        close(cv[0]);
        close(cv[1]);
        int fds[24];
        for (int i = 0; i < 24; i += 2) assert(socketpair(AF_UNIX, SOCK_STREAM, 0, fds + i) == 0);
        sv[0] = fds[0];
        sv[1] = fds[1];
        struct xrt_sys_limits ll;
        xrt_sys_limits_default(&ll);
        ll.groups = (1u << XRT_SYS_G_PROCESSES) | (1u << XRT_SYS_G_CONNECTIONS);
        ll.max_fds_counted = 8;
        const int fd_before = own_fds();
        struct xrt_sys *live = xrt_sys_open(&ll);
        struct xrt_sys_snapshot ls = {0};
        assert(xrt_sys_sample(live, &ls) == XRT_OK);
        char sp[64];
        snprintf(sp, sizeof sp, "/proc/%d/stat", (int)child);
        struct stat pst;
        assert(stat(sp, &pst) == 0);
        int exercised = pst.st_uid == 0 && getuid() != 0; /* inode really is root-owned */
        const struct xrt_sys_proc *cp = NULL, *me = NULL;
        for (uint32_t i = 0; i < ls.processes.count; ++i) {
            if (ls.processes.proc[i].pid == child) cp = &ls.processes.proc[i];
            if (ls.processes.proc[i].pid == getpid()) me = &ls.processes.proc[i];
        }
        assert(cp && me);
        assert(cp->uid.st == XRT_SYS_OK && cp->uid.v == geteuid());
        if (exercised) assert(cp->fds.why == XRT_SYS_WHY_NEEDS_PRIVILEGE);
        assert(me->fds.st == XRT_SYS_STALE && me->fds.why == XRT_SYS_WHY_LIMIT && me->fds.v == 8);
        int resolved = 0, child_socket = 0;
        for (int i = 0; i < 24; ++i) {
            struct stat fst;
            assert(fstat(fds[i], &fst) == 0);
            for (uint32_t k = 0; k < ls.connections.count; ++k) {
                const struct xrt_sys_conn *c = &ls.connections.conn[k];
                if (c->inode != fst.st_ino) continue;
                assert(c->pid.st == XRT_SYS_OK && c->pid.v == (uint64_t)getpid());
                resolved++;
            }
        }
        for (uint32_t k = 0; k < ls.connections.count; ++k)
            if (ls.connections.conn[k].inode == cst.st_ino) {
                child_socket = 1;
                if (exercised) assert(ls.connections.conn[k].pid.why == XRT_SYS_WHY_NEEDS_PRIVILEGE);
            }
        assert(resolved == 24 && child_socket);
        printf("runtime sysstat live: non-dumpable uid %s, %d sockets past an 8-fd cap resolved\n",
               exercised ? "checked against a root-owned inode" : "checked (inode not root-owned here)", resolved);
        /* A cached denial remains a denial, including the socket owner. */
        for (int step = 0; step < 3; ++step) {
            assert(xrt_sys_sample(live, &ls) == XRT_OK);
            int found = 0;
            for (uint32_t k = 0; k < ls.connections.count; ++k)
                if (ls.connections.conn[k].inode == cst.st_ino) {
                    found = 1;
                    if (exercised) assert(ls.connections.conn[k].pid.why == XRT_SYS_WHY_NEEDS_PRIVILEGE);
                }
            assert(found);
        }
        assert(own_fds() <= fd_before + 2048);
        kill(child, SIGKILL);
        waitpid(child, NULL, 0);
        assert(xrt_sys_sample(live, &ls) == XRT_OK);
        for (uint32_t k = 0; k < ls.processes.count; ++k) assert(ls.processes.proc[k].pid != child);
        xrt_sys_snapshot_free(&ls);
        xrt_sys_close(live);
        assert(own_fds() == fd_before);
        for (int i = 0; i < 24; ++i) close(fds[i]);
        (void)sv;
    }
    pid_t limited = fork(); assert(limited >= 0);
    if (!limited) {
        struct rlimit bound; assert(getrlimit(RLIMIT_NOFILE, &bound) == 0);
        if (bound.rlim_cur > 128) bound.rlim_cur = 128;
        assert(setrlimit(RLIMIT_NOFILE, &bound) == 0);
        const int before = own_fds();
        struct xrt_sys_limits ll; xrt_sys_limits_default(&ll);
        ll.groups = 1u << XRT_SYS_G_PROCESSES; ll.flags = XRT_SYS_LIGHT_PROCESSES;
        struct xrt_sys *live = xrt_sys_open(&ll); assert(live);
        struct xrt_sys_snapshot ls = {0};
        for (int step = 0; step < 2; ++step) assert(xrt_sys_sample(live, &ls) == XRT_OK && ls.processes.count > 0);
        assert(own_fds() <= before + (int)(bound.rlim_cur / 8));
        xrt_sys_snapshot_free(&ls); xrt_sys_close(live);
        assert(own_fds() == before); _exit(0);
    }
    int status; assert(waitpid(limited, &status, 0) == limited && WIFEXITED(status) && WEXITSTATUS(status) == 0);
    puts("runtime sysstat: ok");
    return 0;
}
