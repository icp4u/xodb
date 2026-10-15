/* Owned-fixture oracle: hold a real native register read until released. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/ptrace.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

long ptrace(enum __ptrace_request request, ...)
{
    va_list ap;
    va_start(ap, request);
    pid_t pid = va_arg(ap, pid_t);
    void *addr = va_arg(ap, void *);
    void *data = va_arg(ap, void *);
    va_end(ap);
    long (*next)(enum __ptrace_request, ...) = dlsym(RTLD_NEXT, "ptrace");
    if (!next) { errno = ENOSYS; return -1; }
    const char *dir = getenv("XODB_TEST_PTRACE_DIR");
    if (dir && request == PTRACE_GETREGSET) {
        char arm[4096], held[4096], temporary[4096], release[4096];
        if (snprintf(arm, sizeof arm, "%s/arm", dir) >= (int)sizeof arm ||
            snprintf(held, sizeof held, "%s/held.json", dir) >= (int)sizeof held ||
            snprintf(temporary, sizeof temporary, "%s/held.new", dir) >= (int)sizeof temporary ||
            snprintf(release, sizeof release, "%s/release", dir) >= (int)sizeof release) {
            errno = ENAMETOOLONG; return -1;
        }
        if (access(arm, F_OK) == 0 && access(held, F_OK) != 0) {
            int fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0644);
            if (fd >= 0) {
                dprintf(fd, "{\"pid\":%d,\"tid\":%ld,\"tracee\":%d,\"request\":%d}\n", getpid(), syscall(SYS_gettid), pid, request);
                close(fd);
                if (rename(temporary, held)) { errno = EIO; return -1; }
                struct timespec start, now, pause = {0, 1000000};
                clock_gettime(CLOCK_MONOTONIC, &start);
                while (access(release, F_OK) != 0) {
                    clock_gettime(CLOCK_MONOTONIC, &now);
                    if (now.tv_sec - start.tv_sec >= 30) { errno = ETIMEDOUT; return -1; }
                    nanosleep(&pause, NULL);
                }
            }
        }
    }
    return next(request, pid, addr, data);
}
