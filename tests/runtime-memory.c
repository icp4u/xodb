/* Standalone C-runtime checks: no Zig, debugger host or display required. */
#define _GNU_SOURCE 1
#include "xrt_memory.h"

#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/ptrace.h>
#include <sys/wait.h>
#include <unistd.h>

static pid_t child;

static void cleanup(void)
{
    if (child <= 0)
        return;
    kill(child, SIGKILL);
    int status;
    for (;;) {
        const pid_t result = waitpid(child, &status, 0);
        if (result < 0 && errno == EINTR)
            continue;
        if (result <= 0 || WIFEXITED(status) || WIFSIGNALED(status))
            break;
        ptrace(PTRACE_CONT, child, (void *)0, (void *)(uintptr_t)SIGKILL);
    }
    child = 0;
}

#define CHECK(expr)                                                                                \
    do {                                                                                           \
        if (!(expr)) {                                                                             \
            fprintf(stderr, "%s:%d: %s (errno=%d)\n", __FILE__, __LINE__, #expr, errno);           \
            exit(1);                                                                               \
        }                                                                                          \
    } while (0)

int main(void)
{
    unsigned char actual[128], expected[128], patch[32];
    size_t count = 999;
    CHECK(xrt_memory_read(0, 0, NULL, 0, &count) == XRT_OK && count == 0);
    CHECK(xrt_memory_patch(0, 0, NULL, 0, &count) == XRT_OK && count == 0);
    CHECK(xrt_memory_read(0, UINT64_MAX, actual, 2, &count) == XRT_INVALID_ADDRESS && count == 0);
    CHECK(xrt_memory_patch(0, UINTPTR_MAX - 1, patch, 2, &count) == XRT_INVALID_ADDRESS &&
          count == 0);
    CHECK(xrt_memory_read(0, 0, actual, 1, &count) == XRT_INVALID_ADDRESS && count == 0);
    CHECK(xrt_memory_patch(0, 1, NULL, 1, &count) == XRT_INVALID_ARGUMENT && count == 0);
    if (UINTPTR_MAX < UINT64_MAX)
        CHECK(xrt_memory_read(0, (uint64_t)UINTPTR_MAX + 1, actual, 1, &count) ==
                  XRT_INVALID_ADDRESS &&
              count == 0);

    const char *no_live = getenv("XODB_TEST_NO_LIVE");
    if (no_live && strcmp(no_live, "1") == 0) {
        puts("C runtime memory: bounds passed; live checks explicitly disabled");
        return 0;
    }

    const long page_size = sysconf(_SC_PAGESIZE);
    CHECK(page_size >= (long)sizeof(actual));
    const size_t page = (size_t)page_size;
    unsigned char *mapping =
        mmap(NULL, 3 * page, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    CHECK(mapping != MAP_FAILED);
    memset(mapping, 0xff, 3 * page);
    CHECK(munmap(mapping + page, page) == 0);
    CHECK(mprotect(mapping, page, PROT_READ | PROT_EXEC) == 0);
    CHECK(atexit(cleanup) == 0);
    const pid_t parent = getpid();
    child = fork();
    CHECK(child >= 0);
    if (child == 0) {
        if (prctl(PR_SET_PDEATHSIG, SIGKILL) < 0 || getppid() != parent)
            _exit(2);
        if (ptrace(PTRACE_TRACEME, 0, (void *)0, (void *)0) < 0)
            _exit(3);
        raise(SIGSTOP);
        _exit(0);
    }
    alarm(20);
    int status;
    CHECK(waitpid(child, &status, 0) == child && WIFSTOPPED(status));
    CHECK(ptrace(PTRACE_SETOPTIONS, child, (void *)0, (void *)(uintptr_t)PTRACE_O_EXITKILL) == 0);
    const uint64_t address = (uint64_t)(uintptr_t)mapping;

    /* Include PEEK == -1 data, every native word offset, and writes crossing
     * multiple words. Check both neighbors on a read-only executable page. */
    for (size_t i = 0; i < sizeof(patch); ++i)
        patch[i] = (unsigned char)(0x80 + i);
    for (size_t offset = 0; offset < 2 * sizeof(long); ++offset) {
        for (size_t size = 1; size <= 2 * sizeof(long) + 1; ++size) {
            memset(expected, 0xff, sizeof(expected));
            CHECK(xrt_memory_patch(child, address, expected, sizeof(expected), &count) == XRT_OK &&
                  count == sizeof(expected));
            memcpy(expected + offset, patch, size);
            CHECK(xrt_memory_patch(child, address + offset, patch, size, &count) == XRT_OK &&
                  count == size);
            CHECK(xrt_memory_read(child, address, actual, sizeof(actual), &count) == XRT_OK &&
                  count == sizeof(actual));
            CHECK(memcmp(actual, expected, sizeof(actual)) == 0);
        }
    }

    /* A hole after the first mapping must report a short read and an exact
     * changed prefix on a failed patch, without touching the third page. */
    CHECK(xrt_memory_read(child, address + page - 3, actual, 8, &count) == XRT_OK && count == 3);
    CHECK(xrt_memory_patch(child, address + page - 3, patch, 8, &count) == XRT_MEMORY_UNREADABLE &&
          count == 3);
    CHECK(xrt_memory_read(child, address + page - 3, actual, 3, &count) == XRT_OK && count == 3);
    CHECK(memcmp(actual, patch, 3) == 0);
    CHECK(xrt_memory_read(child, address + page, actual, 1, &count) == XRT_MEMORY_UNREADABLE &&
          count == 0);
    CHECK(xrt_memory_read(child, address + 2 * page, actual, sizeof(actual), &count) == XRT_OK &&
          count == sizeof(actual));
    memset(expected, 0xff, sizeof(expected));
    CHECK(memcmp(actual, expected, sizeof(actual)) == 0);

    cleanup();
    alarm(0);
    CHECK(munmap(mapping, page) == 0);
    CHECK(munmap(mapping + 2 * page, page) == 0);
    puts("C runtime memory passed: bounds, native word patches, neighbors, partial reads/writes");
    return 0;
}
