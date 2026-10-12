/* Owned synthetic embedder for runtime identity checks.
 * usage: hostile LANG MODE REAL DECOY [PARKED_THREADS]
 * Loads a private copy of the runtime library (REAL), optionally a decoy
 * image, applies one hostile mutation, then runs the interpreter and blocks
 * on stdin so a debugger can attach. Only files passed on the command line
 * are altered; they must be private copies. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <link.h>
#include <pthread.h>
#include <semaphore.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>
#define DIE(...) do { fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); exit(2); } while (0)
/* An owned parked thread supplies a forged return PC in the twin; the
 * real interpreter's blocking read truncates its own unwind. No twin
 * instruction runs. The original frame record is restored before return. */
static sem_t forge_ready;
static long forged_tid;
static void *forge_target;
static int blind;
ssize_t read(int fd, void *buf, size_t n) {
    if (!blind || fd != 0) return syscall(SYS_read, fd, buf, n);
    void **fp = __builtin_frame_address(0);
    void *ra = fp[1], *up = fp[0];
    if (blind == 2) fp[1] = (char *)forge_target + 8;
    else { fp[1] = 0; fp[0] = 0; }
    static const char message[] = "{\"blinded\":1}\n";
    if (syscall(SYS_write, 1, message, sizeof message - 1) != sizeof message - 1) _exit(2);
    ssize_t result = syscall(SYS_read, fd, buf, n);
    fp[0] = up; fp[1] = ra;
    return result;
}
__attribute__((noinline)) static void forged_park(void) {
    void **fp = __builtin_frame_address(0);
    fp[1] = (char *)forge_target + 8;
    forged_tid = syscall(SYS_gettid);
    if (sem_post(&forge_ready)) DIE("forge ready");
    for (;;) pause();
}
static void *forge_fakera(void *arg) { (void)arg; forged_park(); return NULL; }
static void put16(unsigned char *p, unsigned v) { p[0] = v; p[1] = v >> 8; }
static void put32(unsigned char *p, unsigned v) { for (int i = 0; i < 4; ++i) p[i] = v >> (8 * i); }
static void put64(unsigned char *p, uint64_t v) { for (int i = 0; i < 8; ++i) p[i] = v >> (8 * i); }
/* Smallest structurally valid PE32+ x64 header set: 64+24+112+40 = 240 bytes. */
static size_t pe_header(unsigned char *b, uint64_t file_size) {
    memset(b, 0, 240);
    b[0] = 'M'; b[1] = 'Z'; put32(b + 60, 64);
    unsigned char *coff = b + 64; memcpy(coff, "PE\0\0", 4);
    put16(coff + 4, 0x8664); put16(coff + 6, 1); put16(coff + 20, 112); put16(coff + 22, 0x2022);
    unsigned char *opt = coff + 24; put16(opt, 0x20b);
    put32(opt + 16, 0x1000);                 /* entry rva */
    put64(opt + 24, 0x180000000ull);         /* preferred base */
    put32(opt + 32, 0x1000); put32(opt + 36, 0x200);
    put32(opt + 56, 0x3000);                 /* image size */
    put32(opt + 60, 0x400);                  /* headers size */
    put32(opt + 108, 0);                     /* no directories */
    unsigned char *sec = opt + 112; memcpy(sec, ".text", 5);
    put32(sec + 8, 0x200); put32(sec + 12, 0x1000); put32(sec + 16, 0x200); put32(sec + 20, 0x400);
    put32(sec + 36, 0x60000020);
    if (file_size < 0x600) DIE("runtime too small");
    return 240;
}
static void overwrite(const char *path, const unsigned char *bytes, size_t n) {
    int fd = open(path, O_WRONLY); if (fd < 0) DIE("open %s", path);
    if (pwrite(fd, bytes, n, 0) != (ssize_t)n) DIE("pwrite");
    close(fd);
}
static void copy_file(const char *from, const char *to) {
    int in = open(from, O_RDONLY), out = open(to, O_WRONLY | O_CREAT | O_EXCL, 0755);
    if (in < 0 || out < 0) DIE("copy %s -> %s", from, to);
    char buf[65536]; ssize_t n;
    while ((n = read(in, buf, sizeof buf)) > 0) if (write(out, buf, n) != n) DIE("write");
    close(in); close(out);
}
struct map { unsigned long start, end; char perms[5]; };
/* Every mapping of `path` in this process. */
static size_t mappings(const char *needle, struct map *out, size_t cap) {
    FILE *f = fopen("/proc/self/maps", "r"); if (!f) DIE("maps");
    char line[8192]; size_t n = 0;
    while (fgets(line, sizeof line, f)) {
        if (!strstr(line, needle)) continue;
        if (n == cap) DIE("too many maps");
        if (sscanf(line, "%lx-%lx %4s", &out[n].start, &out[n].end, out[n].perms) != 3) DIE("parse");
        ++n;
    }
    fclose(f); return n;
}
/* Keep process memory independent of later file writes. */
static void cow_first_page(const char *needle) {
    struct map m[64]; size_t n = mappings(needle, m, 64); if (!n) DIE("no mapping of %s", needle);
    if (mprotect((void *)m[0].start, 4096, PROT_READ | PROT_WRITE)) DIE("mprotect");
    volatile unsigned char *p = (void *)m[0].start; for (int i = 0; i < 4096; ++i) p[i] = p[i];
    mprotect((void *)m[0].start, 4096, PROT_READ);
}
/* Move every mapping of the runtime file into anonymous memory at the same
 * addresses: the running runtime then has no file mapping at all. */
static void to_anonymous(const char *needle, size_t first) {
    struct map m[64]; size_t n = mappings(needle, m, 64); if (!n) DIE("no mapping of %s", needle);
    for (size_t i = first; i < n; ++i) {
        size_t len = m[i].end - m[i].start;
        void *save = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (save == MAP_FAILED) DIE("save");
        if (!strchr(m[i].perms, 'r')) mprotect((void *)m[i].start, len, PROT_READ);
        memcpy(save, (void *)m[i].start, len);
        if (mmap((void *)m[i].start, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0) == MAP_FAILED) DIE("fixed");
        memcpy((void *)m[i].start, save, len);
        int prot = (m[i].perms[0] == 'r' ? PROT_READ : 0) | (m[i].perms[1] == 'w' ? PROT_WRITE : 0) | (m[i].perms[2] == 'x' ? PROT_EXEC : 0);
        if (mprotect((void *)m[i].start, len, prot)) DIE("restore prot");
        munmap(save, len);
    }
}
static void emit_ranges(const char *name, const struct map *maps, size_t count) {
    printf("\"%s\":[", name);
    for (size_t i = 0; i < count; ++i)
        printf("%s[\"0x%lx\",\"0x%lx\",\"%s\"]", i ? "," : "", maps[i].start, maps[i].end, maps[i].perms);
    putchar(']');
}
static char **fixture_argv, **fixture_envp;
__attribute__((noinline)) static void dormant_checkpoint(void) {
    puts("{\"ready\":1}"); fflush(stdout);
    char line[32]; if (!fgets(line, sizeof line, stdin)) DIE("dormant input");
    if (line[0] == 'e') { execve("/proc/self/exe", fixture_argv, fixture_envp); DIE("exec fixture"); }
}
struct _typeobject;
typedef struct _object { intptr_t ob_refcnt; struct _typeobject *ob_type; } PyObject;
typedef struct SV { void *sv_any; uint32_t sv_refcnt, sv_flags; union { intptr_t iv; double nv; char *pv; void *rv; } sv_u; } SV;
PyObject *fixture_python_value;
SV *fixture_perl_value;
static int execute(void *rt, const char *lang, const char *mode, char **envp) {
    if (!strcmp(lang, "perl")) {
        void (*sys_init3)(int *, char ***, char ***) = dlsym(rt, "Perl_sys_init3");
        void *(*alloc)(void) = dlsym(rt, "perl_alloc");
        void (*construct)(void *) = dlsym(rt, "perl_construct");
        int (*parse)(void *, void *, int, char **, char **) = dlsym(rt, "perl_parse");
        int (*run)(void *) = dlsym(rt, "perl_run");
        if (!sys_init3 || !alloc || !construct || !parse || !run) DIE("perl api");
        char *args[] = {"hostile-perl", "-e",
            "$|=1; print qq({\"ready\":1}\\n); sub definer_checkpoint { my $held = 42; my $line = <STDIN>; return $held; } definer_checkpoint();", NULL};
        if (!strcmp(mode, "idle")) args[2] = "$main::held = 42;";
        int count = 3; char **vector = args;
        sys_init3(&count, &vector, &envp);
        void *perl = alloc(); construct(perl);
        if (parse(perl, NULL, count, vector, NULL)) DIE("perl_parse");
        if (run(perl)) DIE("perl_run");
        if (!strcmp(mode, "idle")) {
            SV *(*get_sv)(void *, const char *, int) = dlsym(rt, "Perl_get_sv");
            if (!get_sv || !(fixture_perl_value = get_sv(perl, "main::held", 0))) DIE("perl global value");
        }
        if (!strcmp(mode, "idle") || !strcmp(mode, "transition")) dormant_checkpoint();
        return 0;
    }
    void (*init)(void) = dlsym(rt, "Py_Initialize");
    int (*simple)(const char *) = dlsym(rt, "PyRun_SimpleString");
    if (!init || !simple) DIE("python api");
    init();
    if (!strcmp(mode, "idle")) {
        if (simple("held = {'answer': 42}\n")) DIE("python setup");
        void *(*main_module)(const char *) = dlsym(rt, "PyImport_AddModule");
        void *(*dictionary)(void *) = dlsym(rt, "PyModule_GetDict");
        PyObject *(*get_item)(void *, const char *) = dlsym(rt, "PyDict_GetItemString");
        if (!main_module || !dictionary || !get_item || !(fixture_python_value = get_item(dictionary(main_module("__main__")), "held"))) DIE("python global value");
        dormant_checkpoint();
        return 0;
    }
    int result = simple("import sys\nprint('{\"ready\":1}', flush=True)\ndef definer_checkpoint():\n    held = 42\n    sys.stdin.readline()\n    return held\ndefiner_checkpoint()\n");
    if (!strcmp(mode, "transition")) dormant_checkpoint();
    return result;
}
struct task { void *rt; const char *lang; char **envp; };
static void *other_runtime(void *arg) {
    struct task *task = arg;
    execute(task->rt, task->lang, "none", task->envp);
    return NULL;
}
static void *parked(void *arg) {
    (void)arg;
    pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
    pthread_cond_t condition = PTHREAD_COND_INITIALIZER;
    pthread_mutex_lock(&mutex);
    for (;;) pthread_cond_wait(&condition, &mutex);
    return NULL;
}
int main(int argc, char **argv, char **envp) {
    fixture_argv = argv; fixture_envp = envp;
    if (argc < 5) DIE("usage: hostile perl|python MODE REAL DECOY");
    const char *lang = argv[1], *mode = argv[2], *real = argv[3], *decoy = argv[4];
    const char *needle = real; /* full private path: must not match the twin */
    void *rt;
    struct stat st; if (stat(real, &st)) DIE("stat real");
    if (!strcmp(mode, "memfd")) {
        int fd = memfd_create("runtime", 0); if (fd < 0) DIE("memfd");
        int in = open(real, O_RDONLY); char buf[65536]; ssize_t n;
        while ((n = read(in, buf, sizeof buf)) > 0) if (write(fd, buf, n) != n) DIE("memfd write");
        close(in);
        char path[64]; snprintf(path, sizeof path, "/proc/self/fd/%d", fd);
        rt = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
        if (unlink(real)) DIE("unlink real");   /* the only copy is the memfd */
    } else rt = dlopen(real, RTLD_NOW | RTLD_GLOBAL);
    if (!rt) DIE("dlopen real: %s", dlerror());
    void *second = NULL;
    if (strcmp(decoy, "-")) {
        second = !strcmp(mode, "both") ? dlmopen(LM_ID_NEWLM, decoy, RTLD_NOW | RTLD_LOCAL) : dlopen(decoy, RTLD_NOW | RTLD_LOCAL);
        if (!second) DIE("dlopen decoy: %s", dlerror());
    }
    struct map real_maps[64], twin_maps[64];
    size_t real_count = mappings(needle, real_maps, 64);
    size_t twin_count = strcmp(decoy, "-") ? mappings(decoy, twin_maps, 64) : 0;
    unsigned char bytes[240];
    if (!strcmp(mode, "mz")) { cow_first_page(needle); overwrite(real, (const unsigned char *)"MZ", 2); }
    else if (!strcmp(mode, "pehdr")) { cow_first_page(needle); overwrite(real, bytes, pe_header(bytes, (uint64_t)st.st_size)); }
    else if (!strcmp(mode, "other")) { cow_first_page(needle); overwrite(real, (const unsigned char *)"XXXX", 4); }
    else if (!strcmp(mode, "macho")) { cow_first_page(needle); overwrite(real, (const unsigned char *)"\xcf\xfa\xed\xfe", 4); }
    else if (!strcmp(mode, "deleted")) { if (unlink(real)) DIE("unlink"); }
    else if (!strcmp(mode, "replaced")) {   /* new inode at the old path */
        if (unlink(real)) DIE("unlink");
        if (!strcmp(decoy, "-")) DIE("replaced needs a decoy");
        copy_file(decoy, real);
    } else if (!strcmp(mode, "anon")) to_anonymous(needle, 0);
    else if (!strcmp(mode, "unreadable")) { if (chmod(real, 0)) DIE("chmod"); }
    else if (!strcmp(mode, "hdronly-unreadable")) {  /* only the non-executable header mapping stays file-backed */
        to_anonymous(needle, 1); if (chmod(real, 0)) DIE("chmod");
    }
    else if (!strcmp(mode, "anonextra")) {   /* an executable mapping with no file */
        unsigned char *p = mmap(NULL, 8192, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        memcpy(p, "\x7f" "ELF\xc3", 5); mprotect(p, 8192, PROT_READ | PROT_EXEC);
    } else if (!strcmp(mode, "memfdextra")) { /* a harmless executable memfd beside the real runtime */
        int fd = memfd_create("jit", 0); if (ftruncate(fd, 8192)) DIE("truncate");
        if (mmap(NULL, 8192, PROT_READ | PROT_EXEC, MAP_SHARED, fd, 0) == MAP_FAILED) DIE("memfd map");
    } else if (!strcmp(mode, "deletedextra")) { /* deleted executable scratch mapping beside the real runtime */
        char path[] = "/tmp/xodb-jit-XXXXXX";
        int fd = mkstemp(path); if (fd < 0 || ftruncate(fd, 8192)) DIE("deleted truncate");
        if (mmap(NULL, 8192, PROT_READ | PROT_EXEC, MAP_SHARED, fd, 0) == MAP_FAILED) DIE("deleted map");
        if (unlink(path)) DIE("deleted unlink");
    } else if (strcmp(mode, "none") && strcmp(mode, "idle") && strcmp(mode, "both") && strcmp(mode, "threads") && strcmp(mode, "transition") && strcmp(mode, "memfd") && strcmp(mode, "forged") && strcmp(mode, "leafra")) DIE("unknown mode %s", mode);
    if (!strcmp(mode, "forged")) {
        if (!second || sem_init(&forge_ready, 0, 0)) DIE("forge setup");
        forge_target = dlsym(second, !strcmp(lang, "perl") ? "Perl_runops_standard" : "_PyEval_EvalFrameDefault");
        pthread_t thread;
        if (!forge_target || pthread_create(&thread, NULL, forge_fakera, NULL)) DIE("forge thread");
        if (sem_wait(&forge_ready)) DIE("forge wait");
        blind = 1;
    }
    if (!strcmp(mode, "leafra")) {
        if (!second) DIE("leaf return setup");
        forge_target = dlsym(second, !strcmp(lang, "perl") ? "Perl_runops_standard" : "_PyEval_EvalFrameDefault");
        if (!forge_target) DIE("leaf return target");
        // The real interpreter is running on this very thread. Only its
        // blocking read's saved return address points into the passive twin.
        blind = 2;
    }
    printf("{\"forged_tid\":%ld,", forged_tid); emit_ranges("real", real_maps, real_count); putchar(','); emit_ranges("twin", twin_maps, twin_count); puts("}"); fflush(stdout);
    struct task task = {second, lang, envp};
    if (!strcmp(mode, "both")) {
        pthread_t thread;
        if (!second || pthread_create(&thread, NULL, other_runtime, &task)) DIE("second runtime thread");
    }
    /* Optional fifth argument: parked native threads beside any mode. */
    int parked_threads = argc > 5 ? atoi(argv[5]) : !strcmp(mode, "threads") ? 32 : 0;
    for (int i = 0; i < parked_threads; ++i) {
        pthread_t thread;
        if (pthread_create(&thread, NULL, parked, NULL)) DIE("parked thread");
    }
    return execute(rt, lang, mode, envp);
}
