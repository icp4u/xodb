/* Owned memory only. Commands permit polling at stable lifecycle phases.
 * No global THP, compaction, swap or dirty-bit settings are changed. */
#define _GNU_SOURCE 1
#include <errno.h>
#include <inttypes.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/wait.h>
#include <unistd.h>
#ifndef MADV_COLLAPSE
#define MADV_COLLAPSE 25
#endif
static void emit(const char *phase, void *base, size_t bytes, int rc, int error, pid_t child)
{
    printf("{\"phase\":\"%s\",\"start\":\"0x%" PRIxPTR "\",\"end\":\"0x%" PRIxPTR
        "\",\"bytes\":%zu,\"rc\":%d,\"errno\":%d,\"child\":%ld}\n",
        phase, (uintptr_t)base, (uintptr_t)base + bytes, bytes, rc, error, (long)child);
    fflush(stdout);
}
int main(int argc, char **argv)
{
    const size_t huge = 2u << 20, page = (size_t)sysconf(_SC_PAGESIZE);
    size_t bytes = (size_t)1 << 30;
    if (argc > 1) {
        char *end; unsigned long n = strtoul(argv[1], &end, 10);
        if (*end || n < 4 || n > 1024 || n % 2) return 2;
        bytes = (size_t)n << 20;
    }
    (void)prctl(PR_SET_PDEATHSIG, SIGTERM);
    unsigned char *raw = mmap(NULL, bytes + huge, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (raw == MAP_FAILED) return 3;
    unsigned char *base = (void *)(((uintptr_t)raw + huge - 1) & ~(uintptr_t)(huge - 1));
    size_t front = (size_t)(base - raw), back = huge - front;
    if ((front && munmap(raw, front)) || (back && munmap(base + bytes, back))) return 4;
    int rc = madvise(base, bytes, MADV_HUGEPAGE), error = rc ? errno : 0;
    for (size_t i = 0; i < bytes; i += page) base[i] = 1;
    emit("ready", base, bytes, rc, error, 0);
    char command[64]; pid_t child = 0; int child_control = -1;
    const size_t stress = bytes < (64u << 20) ? bytes : (64u << 20);
    while (fgets(command, sizeof(command), stdin)) {
        rc = 0; error = 0;
        if (!strcmp(command, "quit\n")) break;
        if (!strcmp(command, "deny\n")) rc = prctl(PR_SET_DUMPABLE, 0);
        else if (!strcmp(command, "allow\n")) rc = prctl(PR_SET_DUMPABLE, 1);
        else if (!strcmp(command, "split\n")) rc = mprotect(base + page, page, PROT_READ);
        else if (!strcmp(command, "restore\n")) rc = mprotect(base, bytes, PROT_READ | PROT_WRITE);
        else if (!strcmp(command, "fork\n") && !child) {
            int control[2], ready[2];
            if (pipe(control) || pipe(ready)) return 5;
            child = fork();
            if (child < 0) return 6;
            if (!child) {
                close(control[1]); close(ready[0]);
                (void)prctl(PR_SET_PDEATHSIG, SIGTERM);
                base[0] = 2; /* Deliberate COW without touching the protected page. */
                char byte = 'r';
                if (write(ready[1], &byte, 1) != 1) _exit(7);
                close(ready[1]);
                while (read(control[0], &byte, 1) < 0 && errno == EINTR) {}
                close(control[0]); _exit(0);
            }
            close(control[0]); close(ready[1]); child_control = control[1];
            char byte;
            ssize_t n;
            do { n = read(ready[0], &byte, 1); } while (n < 0 && errno == EINTR);
            close(ready[0]); if (n != 1) return 8;
        } else if (!strcmp(command, "reap\n") && child) {
            close(child_control); child_control = -1;
            while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {}
            child = 0;
        } else if (!strcmp(command, "fragment\n")) {
            rc = mprotect(base, bytes, PROT_READ | PROT_WRITE);
            if (!rc) rc = madvise(base, stress, MADV_NOHUGEPAGE);
            if (!rc) for (size_t i = 0; i < stress; i += 2 * page)
                if ((rc = madvise(base + i, page, MADV_DONTNEED))) break;
        } else if (!strcmp(command, "compact\n")) {
            rc = madvise(base, stress, MADV_HUGEPAGE);
            if (!rc) {
                for (size_t i = 0; i < stress; i += page) base[i] = 3;
                rc = madvise(base, stress, MADV_COLLAPSE);
            }
        } else if (strcmp(command, "snapshot\n")) { rc = -1; errno = EINVAL; }
        error = rc ? errno : 0;
        command[strcspn(command, "\n")] = 0;
        emit(command, base, bytes, rc, error, child);
    }
    if (child) { close(child_control); while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {} }
    munmap(base, bytes);
    return 0;
}
