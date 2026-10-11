#define _GNU_SOURCE 1
#include "gdb_link.h"
#include <assert.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <poll.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>

/* This executable alone replaces libc's resolver with an owned held call.
 * No network, NSS configuration, or absolute performance threshold is used. */
static int entered[2], release_dns[2], completed[2];
int getaddrinfo(const char *host, const char *service,
                const struct addrinfo *hints, struct addrinfo **out)
{
    assert(!strcmp(service, "1234") && hints->ai_socktype == SOCK_STREAM);
    *out = NULL;
    if (!strcmp(host, "held.invalid")) {
        assert(write(entered[1], "!", 1) == 1);
        char byte;
        assert(read(release_dns[0], &byte, 1) == 1);
    } else assert(!strcmp(host, "fresh.invalid"));
    return EAI_NONAME;
}
struct caller { struct xrt_cancel *cancel; enum xrt_status status; };
static void *connect_thread(void *opaque)
{
    struct caller *caller = opaque;
    struct xrt_gdb_link *link = calloc(1, sizeof(*link)); assert(link);
    caller->status = xrt_gdb_connect(link, "held.invalid:1234", caller->cancel);
    assert(link->failed && link->fd == -1);
    free(link);
    assert(write(completed[1], "!", 1) == 1);
    return NULL;
}
static void bytes(int fd, size_t count)
{
    while (count--) {
        struct pollfd p = {.fd = fd, .events = POLLIN};
        assert(poll(&p, 1, 10000) == 1);
        char byte; assert(read(fd, &byte, 1) == 1);
    }
}
static unsigned threads(void)
{
    DIR *dir = opendir("/proc/self/task"); assert(dir);
    unsigned count = 0;
    struct dirent *entry;
    while ((entry = readdir(dir))) if (entry->d_name[0] != '.') ++count;
    closedir(dir); return count;
}
static void cancelled_result(enum xrt_status status) { assert(status == XRT_REMOTE_CANCELLED); }
int main(void)
{
    alarm(30);
    assert(!pipe2(entered, O_CLOEXEC) && !pipe2(release_dns, O_CLOEXEC) && !pipe2(completed, O_CLOEXEC));
    struct caller callers[4]; pthread_t callers_thread[4];
    for (unsigned i = 0; i < 4; ++i) {
        callers[i] = (struct caller){.cancel = xrt_cancel_create()};
        assert(callers[i].cancel && !pthread_create(&callers_thread[i], NULL, connect_thread, &callers[i]));
    }
    bytes(entered[0], 4); /* All four actual libc calls are held. */
    for (unsigned i = 0; i < 4; ++i) xrt_cancel_request(callers[i].cancel);
    bytes(completed[0], 4); /* Must finish before any DNS reply is released. */
    for (unsigned i = 0; i < 4; ++i) {
        assert(!pthread_join(callers_thread[i], NULL));
        cancelled_result(callers[i].status);
        xrt_cancel_release(callers[i].cancel);
    }
    struct xrt_gdb_link *link = calloc(1, sizeof(*link)); assert(link);
    assert(xrt_gdb_connect(link, "fresh.invalid:1234", NULL) == XRT_TRANSPORT_FAILED);
    assert(strstr(link->reason, "capacity exhausted"));
    assert(write(release_dns[1], "!!!!", 4) == 4);
    /* This test owns every worker; verify they release all independent jobs. */
    while (threads() != 1) sched_yield();
    assert(xrt_gdb_connect(link, "fresh.invalid:1234", NULL) == XRT_TRANSPORT_FAILED);
    assert(strstr(link->reason, "host resolution failed"));
    while (threads() != 1) sched_yield();
    free(link);
    struct rlimit core = {0}; assert(!setrlimit(RLIMIT_CORE, &core));
    pid_t wrong = fork(); assert(wrong >= 0);
    if (!wrong) { cancelled_result(XRT_OK); _exit(0); }
    int status; assert(waitpid(wrong, &status, 0) == wrong);
    assert(WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT);
    close(entered[0]); close(entered[1]); close(release_dns[0]); close(release_dns[1]); close(completed[0]); close(completed[1]);
    return 0;
}
