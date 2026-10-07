/* Owned descriptor workloads with known activity for lsof-top tests.
 * Each mode prints "ready PID [PID...]" once set up, then runs until killed.
 *   churn DIR RATE        open/close RATE files per second, eight held at a time
 *   leak RATE MAX         open RATE fds per second (pipes, /dev/null, eventfd) up to MAX
 *   deleted DIR BYTES     hold an unlinked file of BYTES written bytes
 *   write DIR RATE        append RATE bytes per second to a file
 *   read DIR RATE BYTES   read a BYTES sparse file at RATE bytes per second
 *   pair RATE             a child reads RATE bytes/s from a pipe and a socketpair each
 *   idle N                N children each holding a pipe and /dev/null
 *   title [PADDING [TEXT]] rewrite its process title (argv area) like sshd, then wait
 *   rotate DIR            rename DIR/log to log.1 and reopen DIR/log onto the
 *                         same fd number every second, appending 1000 bytes in between */
#define _GNU_SOURCE 1
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/eventfd.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static char block[65536];
/* Forked children are reaped on SIGTERM, so a stopped fixture leaves nothing behind. */
static pid_t *kids;
static int nkids;
static void reap(int sig)
{
    (void)sig;
    for (int i = 0; i < nkids; i++)
        if (kids[i] > 0)
            kill(kids[i], SIGKILL);
    for (int i = 0; i < nkids; i++)
        if (kids[i] > 0)
            waitpid(kids[i], NULL, 0);
    _exit(0);
}
static void own(pid_t *list, int n)
{
    kids = list;
    nkids = n;
    signal(SIGTERM, reap);
}

static uint64_t now(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000000u + (uint64_t)t.tv_nsec;
}
static void tick(uint64_t at)
{
    struct timespec t = { .tv_sec = (time_t)(at / 1000000000u), .tv_nsec = (long)(at % 1000000000u) };
    while (clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &t, NULL) == EINTR)
        ;
}
static void die(const char *what)
{
    perror(what);
    exit(1);
}
static void ready(const pid_t *extra, int n)
{
    printf("ready %d", (int)getpid());
    for (int i = 0; i < n; i++)
        printf(" %d", (int)extra[i]);
    printf("\n");
    fflush(stdout);
}
/* Calls step(k) as often as RATE units per second say, for ever. */
static void paced(double rate, void (*step)(uint64_t), uint64_t unit)
{
    const uint64_t start = now();
    uint64_t done = 0;
    for (uint64_t at = start;; ) {
        at += 10000000u;
        tick(at);
        const uint64_t due = (uint64_t)(rate * (double)(now() - start) / 1e9) / unit;
        for (; done < due; done++)
            step(done);
    }
}

static const char *dir;
static int window[8];
static void churn(uint64_t k)
{
    char path[4096];
    snprintf(path, sizeof(path), "%s/churn-%u", dir, (unsigned)(k % 16));
    const int slot = (int)(k % 8);
    if (window[slot] >= 0)
        close(window[slot]);
    window[slot] = open(path, O_RDONLY | O_CREAT | O_CLOEXEC, 0644);
    if (window[slot] < 0)
        die("open");
}
static int leak_max, leaked;
static void leak(uint64_t k)
{
    if (leaked >= leak_max)
        return;
    int p[2];
    switch (k % 3) {
    case 0:
        if (pipe(p))
            die("pipe");
        leaked += 2;
        break;
    case 1:
        if (open("/dev/null", O_RDONLY) < 0)
            die("open");
        leaked++;
        break;
    default:
        if (eventfd(0, 0) < 0)
            die("eventfd");
        leaked++;
        break;
    }
}
static int io_fd, pipe_fd, sock_fd;
static void put(uint64_t k)
{
    (void)k;
    if (write(io_fd, block, 4096) != 4096)
        die("write");
}
static void get(uint64_t k)
{
    (void)k;
    if (read(io_fd, block, 4096) != 4096)
        die("read");
}
static void send_pair(uint64_t k)
{
    (void)k;
    if (write(pipe_fd, block, 4096) != 4096 || write(sock_fd, block, 4096) != 4096)
        die("write pair");
}

int main(int argc, char **argv)
{
    if (argc < 2)
        return 2;
    setvbuf(stdout, NULL, _IOLBF, 0);
    prctl(PR_SET_PDEATHSIG, SIGKILL);
    const char *mode = argv[1];
    if (!strcmp(mode, "churn") && argc == 4) {
        dir = argv[2];
        for (int i = 0; i < 8; i++)
            window[i] = -1;
        ready(NULL, 0);
        paced(atof(argv[3]), churn, 1);
    } else if (!strcmp(mode, "leak") && argc == 4) {
        leak_max = atoi(argv[3]);
        ready(NULL, 0);
        paced(atof(argv[2]), leak, 1);
    } else if (!strcmp(mode, "deleted") && argc == 4) {
        char path[4096];
        snprintf(path, sizeof(path), "%s/held", argv[2]);
        const int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0644);
        if (fd < 0)
            die("open");
        memset(block, 'x', sizeof(block));
        for (long long left = atoll(argv[3]); left > 0;) {
            const size_t n = left < (long long)sizeof(block) ? (size_t)left : sizeof(block);
            if (write(fd, block, n) != (ssize_t)n)
                die("write");
            left -= (long long)n;
        }
        if (unlink(path))
            die("unlink");
        ready(NULL, 0);
        for (;;)
            pause();
    } else if (!strcmp(mode, "write") && argc == 4) {
        char path[4096];
        snprintf(path, sizeof(path), "%s/written", argv[2]);
        io_fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (io_fd < 0)
            die("open");
        ready(NULL, 0);
        paced(atof(argv[3]), put, 4096);
    } else if (!strcmp(mode, "read") && argc == 5) {
        char path[4096];
        snprintf(path, sizeof(path), "%s/source", argv[2]);
        const int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd < 0 || ftruncate(fd, atoll(argv[4])))
            die("create");
        close(fd);
        io_fd = open(path, O_RDONLY);
        if (io_fd < 0)
            die("open");
        ready(NULL, 0);
        paced(atof(argv[3]), get, 4096);
    } else if (!strcmp(mode, "pair") && argc == 3) {
        int p[2], s[2];
        if (pipe(p) || socketpair(AF_UNIX, SOCK_STREAM, 0, s))
            die("pair");
        const pid_t child = fork();
        if (child < 0)
            die("fork");
        if (child == 0) {
            prctl(PR_SET_PDEATHSIG, SIGKILL);
            close(p[1]);
            close(s[0]);
            for (;;) {
                if (read(p[0], block, sizeof(block)) <= 0 || read(s[1], block, sizeof(block)) <= 0)
                    _exit(0);
            }
        }
        static pid_t only;
        only = child;
        own(&only, 1);
        close(p[0]);
        close(s[1]);
        pipe_fd = p[1];
        sock_fd = s[0];
        ready(&child, 1);
        paced(atof(argv[2]), send_pair, 4096);
    } else if (!strcmp(mode, "title")) {
        char title[256] = "fxtitle: private words";
        if (argc >= 4) { /* title PADDING TEXT: TEXT is also the command name */
            snprintf(title, sizeof(title), "%s", argv[3]);
            prctl(PR_SET_NAME, title);
        }
        char *start = argv[0], *end = argv[argc - 1] + strlen(argv[argc - 1]);
        const size_t n = strlen(title);
        memset(start, 0, (size_t)(end - start));
        memcpy(start, title, (size_t)(end - start) < n ? (size_t)(end - start) : n);
        ready(NULL, 0);
        for (;;)
            pause();
    } else if (!strcmp(mode, "rotate") && argc == 3) {
        char log[4096], old[4096];
        snprintf(log, sizeof(log), "%s/log", argv[2]);
        snprintf(old, sizeof(old), "%s/log.1", argv[2]);
        int fd = open(log, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd < 0)
            die("open");
        ready(NULL, 0);
        for (;;) {
            for (int i = 0; i < 10; i++) {
                if (write(fd, block, 100) != 100)
                    die("write");
                tick(now() + 100000000u);
            }
            close(fd);
            if (rename(log, old))
                die("rename");
            fd = open(log, O_WRONLY | O_CREAT | O_APPEND, 0644);
            if (fd < 0)
                die("reopen");
        }
    } else if (!strcmp(mode, "idle") && argc == 3) {
        const int n = atoi(argv[2]);
        pid_t *children = calloc((size_t)n, sizeof(*children));
        if (!children)
            die("calloc");
        own(children, n);
        for (int i = 0; i < n; i++) {
            children[i] = fork();
            if (children[i] < 0)
                die("fork");
            if (children[i] == 0) {
                prctl(PR_SET_PDEATHSIG, SIGKILL);
                int p[2];
                if (pipe(p) || open("/dev/null", O_RDONLY) < 0)
                    _exit(1);
                for (;;)
                    pause();
            }
        }
        printf("ready %d (%d children)\n", (int)getpid(), n);
        fflush(stdout);
        for (;;)
            pause();
    }
    return 2;
}
