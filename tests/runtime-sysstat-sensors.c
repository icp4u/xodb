#define _GNU_SOURCE 1
/* Deterministic wall-time injection around actual owned sensor reads. The
 * collector is built unchanged; GNU ld wrappers exist only in this test. */
#include "xrt_sysstat.h"
#include <assert.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static int64_t fake_ns = INT64_C(1000000000), delay_ns;
static unsigned sensor_reads;
static char sensor_path[512];
int __real_clock_gettime(clockid_t, struct timespec *);
ssize_t __real_read(int, void *, size_t);
int __wrap_clock_gettime(clockid_t id, struct timespec *out)
{
    if (id != CLOCK_MONOTONIC) return __real_clock_gettime(id, out);
    *out = (struct timespec){fake_ns / 1000000000, fake_ns % 1000000000};
    return 0;
}
ssize_t __wrap_read(int fd, void *data, size_t size)
{
    char proc[64], path[512];
    snprintf(proc, sizeof proc, "/proc/self/fd/%d", fd);
    ssize_t n = readlink(proc, path, sizeof path - 1);
    if (n >= 0) {
        path[n] = 0;
        if (!strcmp(path, sensor_path)) {
            sensor_reads++;
            fake_ns += delay_ns;
        }
    }
    return __real_read(fd, data, size);
}
static void write_text(const char *path, const char *text)
{
    FILE *f = fopen(path, "w"); assert(f);
    assert(fputs(text, f) >= 0); assert(!fclose(f));
}
static void sample(struct xrt_sys *s, struct xrt_sys_snapshot *snapshot, int slow, int stale)
{
    fake_ns += 100000000;
    delay_ns = slow ? 2000000 : 0;
    const unsigned before = sensor_reads;
    assert(xrt_sys_sample(s, snapshot) == XRT_OK);
    assert(snapshot->power.sensor_count == 1);
    const struct xrt_sys_f64 *value = &snapshot->power.sensor[0].value;
    assert(value->st == (stale ? XRT_SYS_STALE : XRT_SYS_OK));
    assert(value->why == (stale ? XRT_SYS_WHY_SLOW_SOURCE : XRT_SYS_WHY_NONE));
    assert(value->v == 42.0);
    assert(sensor_reads == before + (stale ? 0u : 1u));
}
int main(void)
{
    const char *tmp = getenv("TMPDIR");
    char root[256], path[512];
    snprintf(root, sizeof root, "%s/xodb-sensor-XXXXXX", tmp && *tmp ? tmp : "/tmp");
    assert(mkdtemp(root)); assert(chmod(root, 0755) == 0);
    const char *dirs[] = {"sys", "sys/class", "sys/class/hwmon", "sys/class/hwmon/hwmon0"};
    for (unsigned i = 0; i < sizeof dirs / sizeof dirs[0]; i++) {
        snprintf(path, sizeof path, "%s/%s", root, dirs[i]); assert(mkdir(path, 0755) == 0);
    }
    snprintf(path, sizeof path, "%s/sys/class/hwmon/hwmon0/name", root); write_text(path, "synthetic\n");
    snprintf(sensor_path, sizeof sensor_path, "%s/sys/class/hwmon/hwmon0/temp1_input", root); write_text(sensor_path, "42000\n");
    struct xrt_sys_limits lim; xrt_sys_limits_default(&lim);
    lim.root = root; lim.groups = 1u << XRT_SYS_G_POWER;
    assert(lim.sensor_timing_disabled == 0);
    struct xrt_sys *s = xrt_sys_open(&lim); assert(s);
    struct xrt_sys_snapshot snapshot = {0};
    sample(s, &snapshot, 1, 0);
    sample(s, &snapshot, 0, 0);
    puts("PASS one injected slow read does not make the next sensor stale");
    for (unsigned i = 0; i < 4; i++) { sample(s, &snapshot, 1, 0); sample(s, &snapshot, 0, 0); }
    puts("PASS fast reads reset intermittent-delay streaks");
    sample(s, &snapshot, 1, 0); sample(s, &snapshot, 1, 0); sample(s, &snapshot, 1, 0);
    sample(s, &snapshot, 0, 1);
    puts("PASS three consecutive slow reads throttle with the cached stale reason");
    fake_ns += INT64_C(5000000000);
    sample(s, &snapshot, 0, 0); sample(s, &snapshot, 0, 0);
    puts("PASS a fast scheduled refresh recovers immediately");
    sample(s, &snapshot, 1, 0); sample(s, &snapshot, 1, 0);
    write_text(sensor_path, "invalid\n"); delay_ns = 2000000; fake_ns += 100000000;
    assert(xrt_sys_sample(s, &snapshot) == XRT_OK);
    assert(snapshot.power.sensor[0].value.st == XRT_SYS_UNAVAILABLE);
    write_text(sensor_path, "42000\n"); sample(s, &snapshot, 1, 0); sample(s, &snapshot, 0, 0);
    puts("PASS read failures reset the streak without retaining a fabricated value");
    xrt_sys_snapshot_free(&snapshot); xrt_sys_close(s);
    lim.sensor_timing_disabled = 1; s = xrt_sys_open(&lim); assert(s);
    for (unsigned i = 0; i < 8; i++) sample(s, &snapshot, 1, 0);
    puts("PASS fixture timing opt-out stays deterministic under repeated injected delays");
    xrt_sys_snapshot_free(&snapshot); xrt_sys_close(s);
    assert(unlink(sensor_path) == 0); assert(unlink(path) == 0);
    for (unsigned i = sizeof dirs / sizeof dirs[0]; i; i--) {
        snprintf(path, sizeof path, "%s/%s", root, dirs[i - 1]); assert(rmdir(path) == 0);
    }
    assert(rmdir(root) == 0);
}
