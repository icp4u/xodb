/* Owned memory for the memory defrag views. Maps N MiB (default 1024) of
 * private anonymous memory, touches it with 4 KiB pages under
 * MADV_NOHUGEPAGE, then marks it MADV_HUGEPAGE so it is THP-eligible with no
 * huge pages yet. "collapse" MADV_COLLAPSEs the next quarter, "split"
 * mprotects one page of the first quarter (a PMD split), "quit" exits.
 * Each command answers one JSON line. No system settings are changed. */
#define _GNU_SOURCE 1
#include <errno.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <signal.h>
#include <unistd.h>
#ifndef MADV_COLLAPSE
#define MADV_COLLAPSE 25
#endif
static void emit(const char *phase, unsigned char *base, size_t bytes, int rc, int error)
{
    printf("{\"phase\":\"%s\",\"pid\":%ld,\"start\":\"0x%" PRIxPTR "\",\"bytes\":%zu,\"rc\":%d,\"errno\":%d}\n",
        phase, (long)getpid(), (uintptr_t)base, bytes, rc, error);
    fflush(stdout);
}
int main(int argc, char **argv)
{
    const size_t huge = 2u << 20, page = (size_t)sysconf(_SC_PAGESIZE);
    size_t mib = argc > 1 ? strtoul(argv[1], NULL, 10) : 1024;
    if (mib < 8 || mib > 4096 || mib % 8) return 2;
    const size_t bytes = mib << 20, quarter = bytes / 4;
    (void)prctl(PR_SET_PDEATHSIG, SIGTERM);
    unsigned char *raw = mmap(NULL, bytes + huge, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (raw == MAP_FAILED) return 3;
    unsigned char *base = (void *)(((uintptr_t)raw + huge - 1) & ~(uintptr_t)(huge - 1));
    size_t front = (size_t)(base - raw), back = huge - front;
    if ((front && munmap(raw, front)) || (back && munmap(base + bytes, back))) return 4;
    if (madvise(base, bytes, MADV_NOHUGEPAGE)) return 5;
    for (size_t i = 0; i < bytes; i += page) base[i] = 1;
    int rc = madvise(base, bytes, MADV_HUGEPAGE);
    emit("ready", base, bytes, rc, rc ? errno : 0);
    char command[64];
    size_t done = 0;
    while (fgets(command, sizeof(command), stdin)) {
        rc = 0;
        command[strcspn(command, "\n")] = 0;
        if (!strcmp(command, "quit")) break;
        if (!strcmp(command, "collapse") && done < bytes) {
            rc = madvise(base + done, quarter, MADV_COLLAPSE);
            done += quarter;
        } else if (!strcmp(command, "split")) {
            rc = mprotect(base + page, page, PROT_READ);
        } else if (strcmp(command, "snapshot")) {
            rc = -1;
            errno = EINVAL;
        }
        emit(command, base, bytes, rc, rc ? errno : 0);
    }
    munmap(base, bytes);
    return 0;
}
