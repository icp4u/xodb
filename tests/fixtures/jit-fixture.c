// Owned JIT fixture (x86-64 Linux): installs real executable code, emits a
// jitdump and a perf map, moves code, reuses the old address for new code and
// records frame-pointer observations from inside the generated code together
// with ground truth. Usage: jit-fixture OUTDIR
// The jitdump file is mapped PROT_EXEC as perf's jitdump convention requires so
// that "perf record" + "perf inject -j" can independently consume it.
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

#if !defined(__x86_64__)
#error "jit-fixture generates x86-64 code"
#endif

struct jit_header {
    uint32_t magic, version, total_size, elf_mach, pad1, pid;
    uint64_t timestamp, flags;
};
struct jit_prefix {
    uint32_t id, total_size;
    uint64_t timestamp;
};
struct jit_load {
    struct jit_prefix p;
    uint32_t pid, tid;
    uint64_t vma, code_addr, code_size, code_index;
};
struct jit_move {
    struct jit_prefix p;
    uint32_t pid, tid;
    uint64_t vma, old_code_addr, new_code_addr, code_size, code_index;
};
struct jit_debug {
    struct jit_prefix p;
    uint64_t code_addr, nr_entry;
};
struct jit_debug_entry {
    uint64_t addr;
    uint32_t line, discrim;
};

#define MAX_OBS 8
#define MAX_FRAMES 8
struct observation {
    uint64_t time;
    int frames;
    uint64_t pc[MAX_FRAMES];
};

static int dump_fd, map_fd;
static FILE *truth;
static uint32_t pid;
static struct observation obs[MAX_OBS];
static int obs_count;
static const char *outdir;
static void **main_frame;

static uint64_t now(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000000u + (uint64_t)t.tv_nsec;
}

static void die(const char *what)
{
    fprintf(stderr, "jit-fixture: %s: %s\n", what, strerror(errno));
    exit(2);
}

static void put(int fd, const void *p, size_t n)
{
    const char *c = p;
    while (n) {
        ssize_t w = write(fd, c, n);
        if (w < 0 && errno == EINTR)
            continue;
        if (w <= 0)
            die("write");
        c += w;
        n -= (size_t)w;
    }
}

/* Called from generated code; walks the frame-pointer chain from the
 * generated frame. Return addresses are observed raw PCs. */
__attribute__((noinline)) void fixture_observe(void)
{
    struct observation *o = &obs[obs_count < MAX_OBS ? obs_count++ : MAX_OBS - 1];
    o->time = now();
    void **frame = __builtin_frame_address(0);
    o->frames = 0;
    while (frame && frame <= main_frame && o->frames < MAX_FRAMES) {
        o->pc[o->frames++] = (uint64_t)(uintptr_t)frame[1];
        void **next = frame[0];
        if (next <= frame)
            break;
        frame = next;
    }
}

/* push rbp; mov rbp,rsp; movabs rax,observe; call rax; mov eax,tag; [nop*pad]; pop rbp; ret */
static size_t emit(uint8_t *code, uint32_t tag, size_t pad, size_t *call_end)
{
    size_t n = 0;
    code[n++] = 0x55;
    code[n++] = 0x48, code[n++] = 0x89, code[n++] = 0xe5;
    code[n++] = 0x48, code[n++] = 0xb8;
    uint64_t target = (uint64_t)(uintptr_t)fixture_observe;
    memcpy(code + n, &target, 8);
    n += 8;
    code[n++] = 0xff, code[n++] = 0xd0;
    *call_end = n;
    code[n++] = 0xb8;
    memcpy(code + n, &tag, 4);
    n += 4;
    for (size_t i = 0; i < pad; ++i)
        code[n++] = 0x90;
    code[n++] = 0x5d;
    code[n++] = 0xc3;
    return n;
}

static void protect(void *page, int prot)
{
    if (mprotect(page, 4096, prot))
        die("mprotect");
}

static void hex(FILE *f, const uint8_t *p, size_t n)
{
    for (size_t i = 0; i < n; ++i)
        fprintf(f, "%02x", p[i]);
}

static void record_debug(uint64_t addr, size_t call_end, const char *file)
{
    /* Two entries: function entry (line 1) and the call site (line 2). The
     * second repeats the file name with the "\xff\0" convention. Padded to 8. */
    size_t n = strlen(file) + 1, body = 2 * sizeof(struct jit_debug_entry) + n + 2;
    size_t total = sizeof(struct jit_debug) + body, padded = (total + 7) & ~(size_t)7;
    struct jit_debug d = {{2, (uint32_t)padded, now()}, addr, 2};
    struct jit_debug_entry e1 = {addr, 1, 0}, e2 = {addr + call_end - 2, 2, 0};
    static const uint8_t repeat[2] = {0xff, 0}, zero[8];
    put(dump_fd, &d, sizeof d);
    put(dump_fd, &e1, sizeof e1);
    put(dump_fd, file, n);
    put(dump_fd, &e2, sizeof e2);
    put(dump_fd, repeat, 2);
    put(dump_fd, zero, padded - total);
    fprintf(truth, "debug code_addr=0x%llx entries=2 file=%s line1=0x%llx line2=0x%llx\n", (unsigned long long)addr,
            file, (unsigned long long)addr, (unsigned long long)(addr + call_end - 2));
}

static void record_load(uint8_t *code, size_t size, uint64_t index, const char *name)
{
    size_t n = strlen(name) + 1;
    uint64_t addr = (uint64_t)(uintptr_t)code, t = now();
    struct jit_load r = {{0, (uint32_t)(sizeof r + n + size), t}, pid, (uint32_t)syscall(SYS_gettid), addr, addr,
                         size, index};
    put(dump_fd, &r, sizeof r);
    put(dump_fd, name, n);
    put(dump_fd, code, size);
    dprintf(map_fd, "%llx %zx %s\n", (unsigned long long)addr, size, name);
    fprintf(truth, "load index=%llu addr=0x%llx size=0x%zx time=%llu code=", (unsigned long long)index,
            (unsigned long long)addr, size, (unsigned long long)t);
    hex(truth, code, size);
    fprintf(truth, " name=%s\n", name);
}

static void record_move(uint8_t *from, uint8_t *to, size_t size, uint64_t index, const char *name)
{
    uint64_t t = now();
    struct jit_move r = {{1, sizeof r, t}, pid, (uint32_t)syscall(SYS_gettid), (uint64_t)(uintptr_t)to,
                         (uint64_t)(uintptr_t)from, (uint64_t)(uintptr_t)to, size, index};
    put(dump_fd, &r, sizeof r);
    /* A perf map cannot express a move; producers append another line. */
    dprintf(map_fd, "%llx %zx %s\n", (unsigned long long)(uintptr_t)to, size, name);
    fprintf(truth, "move index=%llu from=0x%llx to=0x%llx size=0x%zx time=%llu\n", (unsigned long long)index,
            (unsigned long long)(uintptr_t)from, (unsigned long long)(uintptr_t)to, size, (unsigned long long)t);
}

/* Toy language logical stack reported by the "runtime" alongside each call:
 * independent of native frames; no bridge observation is recorded. */
__attribute__((noinline)) static uint32_t run(uint8_t *code, uint64_t index, const char *logical)
{
    uint32_t (*fn)(void) = (uint32_t (*)(void))(uintptr_t)code;
    int before = obs_count;
    uint32_t tag = fn();
    if (obs_count != before + 1) {
        fprintf(stderr, "jit-fixture: observation missing\n");
        exit(2);
    }
    struct observation *o = &obs[before];
    fprintf(truth, "obs id=%d time=%llu tag=%u expect_index=%llu expect_start=0x%llx logical=%s frames=", before + 1,
            (unsigned long long)o->time, tag, (unsigned long long)index, (unsigned long long)(uintptr_t)code,
            logical);
    for (int i = 0; i < o->frames; ++i)
        fprintf(truth, "%s0x%llx", i ? "," : "", (unsigned long long)o->pc[i]);
    fprintf(truth, "\n");
    return tag;
}

static void identity(void)
{
    char buf[1024], path[64];
    FILE *f = fopen("/proc/self/stat", "re");
    if (!f || !fgets(buf, sizeof buf, f))
        die("stat");
    fclose(f);
    char *p = strrchr(buf, ')');
    unsigned long long ticks = 0;
    /* fields after comm: state(3) ... starttime(22) */
    if (!p || sscanf(p + 2, "%*c %*d %*d %*d %*d %*d %*u %*u %*u %*u %*u %*u %*u %*d %*d %*d %*d %*d %*d %llu",
                     &ticks) != 1)
        die("starttime");
    char boot[64] = {0};
    f = fopen("/proc/sys/kernel/random/boot_id", "re");
    if (!f || !fgets(boot, sizeof boot, f))
        die("boot_id");
    fclose(f);
    boot[strcspn(boot, "\n")] = 0;
    char ns[128] = {0};
    snprintf(path, sizeof path, "/proc/self/ns/time");
    ssize_t n = readlink(path, ns, sizeof ns - 1);
    if (n < 0)
        snprintf(ns, sizeof ns, "unavailable");
    fprintf(truth, "pid %u\nstart_ticks %llu\nboot_id %s\ntime_ns %s\nclock CLOCK_MONOTONIC\narch x86_64\n", pid, ticks,
            boot, ns);
}

static void copy_maps(void)
{
    char path[4096];
    snprintf(path, sizeof path, "%s/maps-%u.txt", outdir, pid);
    int in = open("/proc/self/maps", O_RDONLY | O_CLOEXEC), out = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (in < 0 || out < 0)
        die("maps");
    char buf[65536];
    ssize_t n;
    while ((n = read(in, buf, sizeof buf)) > 0)
        put(out, buf, (size_t)n);
    close(in);
    close(out);
}

int main(int argc, char **argv)
{
    if (argc != 2) {
        fprintf(stderr, "usage: jit-fixture OUTDIR\n");
        return 2;
    }
    umask(022);
    main_frame = __builtin_frame_address(0);
    outdir = argv[1];
    pid = (uint32_t)getpid();
    char path[4096];
    snprintf(path, sizeof path, "%s/truth-%u.txt", outdir, pid);
    truth = fopen(path, "we");
    if (!truth)
        die("truth");
    identity();
    snprintf(path, sizeof path, "%s/jit-%u.dump", outdir, pid);
    dump_fd = open(path, O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (dump_fd < 0)
        die("jitdump");
    fprintf(truth, "jitdump %s\n", path);
    snprintf(path, sizeof path, "%s/perf-%u.map", outdir, pid);
    map_fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND | O_CLOEXEC, 0644);
    if (map_fd < 0)
        die("perf map");
    fprintf(truth, "perfmap %s\n", path);

    struct jit_header h = {0x4A695444u, 1, sizeof h, 62 /* EM_X86_64 */, 0, pid, now(), 0};
    put(dump_fd, &h, sizeof h);
    fprintf(truth, "header_time %llu\n", (unsigned long long)h.timestamp);
    void *marker = mmap(NULL, 4096, PROT_READ | PROT_EXEC, MAP_PRIVATE, dump_fd, 0);
    if (marker == MAP_FAILED)
        die("mmap jitdump marker");

    uint8_t *region = mmap(NULL, 4 * 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (region == MAP_FAILED)
        die("mmap code");
    uint8_t *a1 = region, *a2 = region + 2 * 4096, staging[64];
    size_t call_end;
    const char *alpha = "jit alpha \xce\xbb (toy:compute)", *beta = "jit beta (toy:reuse)";

    /* 1. Load alpha at A1. */
    size_t alpha_size = emit(staging, 0xa1, 9, &call_end);
    memcpy(a1, staging, alpha_size);
    protect(a1, PROT_READ | PROT_EXEC);
    record_debug((uint64_t)(uintptr_t)a1, call_end, "fixture-alpha.toy");
    record_load(a1, alpha_size, 1, alpha);
    run(a1, 1, "main@main.toy:3>compute@main.toy:7");

    /* 2. Move alpha to A2; destroy the old copy. */
    protect(a2, PROT_READ | PROT_WRITE);
    memcpy(a2, a1, alpha_size);
    protect(a2, PROT_READ | PROT_EXEC);
    record_move(a1, a2, alpha_size, 1, alpha);
    protect(a1, PROT_READ | PROT_WRITE);
    memset(a1, 0xcc, 4096);
    run(a2, 1, "main@main.toy:3>compute@main.toy:7");

    /* 3. Reuse A1 for different code with a new code index. */
    size_t beta_size = emit(staging, 0xb2, 0, &call_end);
    memcpy(a1, staging, beta_size);
    protect(a1, PROT_READ | PROT_EXEC);
    record_load(a1, beta_size, 2, beta);
    run(a1, 2, "main@main.toy:4>reuse@main.toy:12");
    run(a2, 1, "main@main.toy:5>compute@main.toy:7");

    struct jit_prefix close_record = {3, sizeof close_record, now()};
    put(dump_fd, &close_record, sizeof close_record);
    fprintf(truth, "close time=%llu\n", (unsigned long long)close_record.timestamp);
    copy_maps();
    fprintf(truth, "maps %s/maps-%u.txt\n", outdir, pid);
    fprintf(truth, "fixture_observe 0x%llx\nrun 0x%llx\n", (unsigned long long)(uintptr_t)fixture_observe,
            (unsigned long long)(uintptr_t)run);
    fprintf(truth, "coverage_end %llu\n", (unsigned long long)now());
    munmap(marker, 4096);
    munmap(region, 4 * 4096);
    close(dump_fd);
    close(map_fd);
    if (fclose(truth))
        die("truth close");
    printf("%u\n", pid);
    return 0;
}
