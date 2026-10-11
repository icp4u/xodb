#define _GNU_SOURCE
#include "allocation_broker.h"
#include "../runtime/xrt_uprobes.h"
#include "../runtime/mapped_file.h"
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/syscall.h>
#include <sys/sysmacros.h>
#include <linux/perf_event.h>
#include <elf.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static int send_packet(int socket, const void *data, size_t size, const int *fds, size_t count) {
    struct iovec io = { .iov_base = (void *)data, .iov_len = size };
    union { struct cmsghdr align; char bytes[CMSG_SPACE(2 * sizeof(int))]; } control = {0};
    struct msghdr msg = { .msg_iov = &io, .msg_iovlen = 1 };
    if (count) {
        if (count > 2) { errno = EINVAL; return -1; }
        msg.msg_control = control.bytes;
        msg.msg_controllen = CMSG_SPACE(count * sizeof(int));
        struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg);
        cmsg->cmsg_level = SOL_SOCKET; cmsg->cmsg_type = SCM_RIGHTS;
        cmsg->cmsg_len = CMSG_LEN(count * sizeof(int));
        memcpy(CMSG_DATA(cmsg), fds, count * sizeof(int));
    }
    ssize_t n;
    do n = sendmsg(socket, &msg, MSG_NOSIGNAL); while (n < 0 && errno == EINTR);
    if (n < 0) return -1;
    if ((size_t)n != size) { errno = EPROTO; return -1; }
    return 0;
}
static int receive_packet(int socket, void *data, size_t size, int fds[2], size_t *count) {
    struct iovec io = { .iov_base = data, .iov_len = size };
    union { struct cmsghdr align; char bytes[CMSG_SPACE(2 * sizeof(int))]; } control = {0};
    struct msghdr msg = { .msg_iov = &io, .msg_iovlen = 1, .msg_control = control.bytes, .msg_controllen = sizeof control.bytes };
    ssize_t n;
    *count = 0;
    do n = recvmsg(socket, &msg, MSG_CMSG_CLOEXEC); while (n < 0 && errno == EINTR);
    if (n < 0) return -1;
    int bad = !!(msg.msg_flags & (MSG_TRUNC | MSG_CTRUNC));
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wsign-compare" /* musl CMSG_NXTHDR */
    for (struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg); cmsg; cmsg = CMSG_NXTHDR(&msg, cmsg)) {
#pragma GCC diagnostic pop
        if (cmsg->cmsg_level != SOL_SOCKET || cmsg->cmsg_type != SCM_RIGHTS || cmsg->cmsg_len < CMSG_LEN(0)) { bad = 1; continue; }
        size_t bytes = cmsg->cmsg_len - CMSG_LEN(0);
        if (bytes % sizeof(int)) bad = 1;
        for (size_t i = 0; i < bytes / sizeof(int); ++i) {
            int fd;
            memcpy(&fd, (char *)CMSG_DATA(cmsg) + i * sizeof(int), sizeof fd);
            if (*count < 2) fds[(*count)++] = fd;
            else { close(fd); bad = 1; }
        }
    }
    if ((size_t)n != size || bad) {
        for (size_t i = 0; i < *count; ++i) close(fds[i]);
        *count = 0; errno = n == 0 ? EPIPE : EPROTO; return -1;
    }
    return 0;
}

#ifndef XODB_ALLOCATION_HELPER
extern char **environ;
int xodb_allocation_broker_start(const char *helper, int *socket_fd, int *child_pid) {
    if (!helper || !*helper || !socket_fd || !child_pid) { errno = EINVAL; return -1; }
    int pair[2];
    if (socketpair(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0, pair)) return -1;
    for (unsigned i = 0; i < 2; ++i) {
        if (pair[i] >= 3) continue;
        int fd = fcntl(pair[i], F_DUPFD_CLOEXEC, 3);
        if (fd < 0) { int saved = errno; close(pair[0]); close(pair[1]); errno = saved; return -1; }
        close(pair[i]); pair[i] = fd;
    }
    posix_spawn_file_actions_t actions;
    int error = posix_spawn_file_actions_init(&actions);
    if (error) goto done;
    error = posix_spawn_file_actions_adddup2(&actions, pair[1], STDIN_FILENO);
    if (!error) error = posix_spawn_file_actions_adddup2(&actions, STDERR_FILENO, STDOUT_FILENO);
    if (!error) error = posix_spawn_file_actions_addclose(&actions, pair[0]);
    if (!error && pair[1] != STDIN_FILENO) error = posix_spawn_file_actions_addclose(&actions, pair[1]);
    pid_t child = -1;
    char *const args[] = { "sudo", "-n", "--", (char *)helper, "--stdio", NULL };
    if (!error) error = posix_spawnp(&child, "sudo", &actions, NULL, args, environ);
    posix_spawn_file_actions_destroy(&actions);
    if (!error) { close(pair[1]); *socket_fd = pair[0]; *child_pid = child; return 0; }
done:
    close(pair[0]); close(pair[1]); errno = error; return -1;
}
static int broker_open(int socket_fd, int pid, int tid, int file_fd,
                               int group_fd, uint64_t offset, int return_probe,
                               int leader, int callstacks, int functions, xodb_allocation_cancel cancelled, void *context) {
    if (cancelled && cancelled(context)) { errno = ECANCELED; return -1; }
    const struct xodb_allocation_open request = {
        .magic = XODB_ALLOCATION_MAGIC, .pid = pid, .tid = tid,
        .flags = (return_probe ? 1u : 0u) | (leader ? 2u : 0u) | (callstacks ? 4u : 0u) | (functions ? 8u : 0u), .offset = offset,
    };
    int fds[2] = { file_fd, group_fd };
    if (send_packet(socket_fd, &request, sizeof request, fds, group_fd < 0 ? 1 : 2)) return -1;
    for (unsigned i = 0; i < 50; ++i) {
        if (cancelled && cancelled(context)) { errno = ECANCELED; return -1; }
        struct pollfd p = { .fd = socket_fd, .events = POLLIN };
        int rc = poll(&p, 1, 100);
        if (rc < 0 && errno == EINTR) continue;
        if (rc < 0) return -1;
        if (!rc) continue;
        struct xodb_allocation_reply reply;
        size_t count = 0;
        if (receive_packet(socket_fd, &reply, sizeof reply, fds, &count)) return -1;
        if (reply.magic != XODB_ALLOCATION_MAGIC || reply.error < 0 || count != (reply.error ? 0u : 1u)) {
            for (size_t j = 0; j < count; ++j) close(fds[j]);
            errno = EPROTO; return -1;
        }
        if (reply.error) { errno = reply.error; return -1; }
        return fds[0];
    }
    errno = ETIMEDOUT; return -1;
}
int xodb_allocation_broker_open(int socket_fd, int pid, int tid, int file_fd,
                               int group_fd, uint64_t offset, int return_probe,
                               int leader, int callstacks, xodb_allocation_cancel cancelled, void *context) {
    return broker_open(socket_fd, pid, tid, file_fd, group_fd, offset, return_probe,
                       leader, callstacks, 0, cancelled, context);
}
int xodb_function_broker_open(int socket_fd, int pid, int tid, int file_fd,
                             int group_fd, uint64_t offset, int return_probe,
                             int leader, int callstacks, xodb_allocation_cancel cancelled, void *context) {
    return broker_open(socket_fd, pid, tid, file_fd, group_fd, offset, return_probe,
                       leader, callstacks, 1, cancelled, context);
}
void xodb_allocation_broker_close(int socket_fd, int child_pid) {
    if (socket_fd >= 0) close(socket_fd);
    if (child_pid <= 0) return;
    for (unsigned i = 0; i < 20; ++i) {
        int status;
        pid_t result = waitpid(child_pid, &status, WNOHANG);
        if (result == child_pid || (result < 0 && errno == ECHILD)) return;
        struct timespec delay = { .tv_nsec = 10000000 };
        nanosleep(&delay, NULL);
    }
    kill(child_pid, SIGKILL);
    while (waitpid(child_pid, NULL, 0) < 0 && errno == EINTR) {}
}
#else
static int read_file(const char *path, char *buffer, size_t size) {
    int fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK);
    if (fd < 0) return -1;
    size_t used = 0;
    while (used + 1 < size) {
        ssize_t n = read(fd, buffer + used, size - used - 1);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) { int saved = errno; close(fd); errno = saved; return -1; }
        if (!n) { close(fd); buffer[used] = 0; return 0; }
        used += (size_t)n;
    }
    close(fd); errno = E2BIG; return -1;
}
static int held_task(int pid, int tid, struct ucred peer) {
    char path[80], buffer[16384];
    snprintf(path, sizeof path, "/proc/%d/task/%d/status", pid, tid);
    if (read_file(path, buffer, sizeof buffer)) return -1;
    bool uid = false, traced = false, group = false, stopped = false;
    char *save;
    for (char *line = strtok_r(buffer, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
        unsigned ids[4]; int n; char status;
        if (sscanf(line, "Uid: %u %u %u %u", &ids[0], &ids[1], &ids[2], &ids[3]) == 4)
            uid = ids[0] == peer.uid && ids[1] == peer.uid && ids[2] == peer.uid && ids[3] == peer.uid;
        if (sscanf(line, "TracerPid: %d", &n) == 1) traced = n == peer.pid;
        if (sscanf(line, "Tgid: %d", &n) == 1) group = n == pid;
        if (sscanf(line, "State: %c", &status) == 1) stopped = status == 't';
    }
    if (!uid || !traced || !group || !stopped) { errno = EPERM; return -1; }
    return 0;
}
static int executable_offset(int fd, uint64_t offset) {
    struct stat s; Elf64_Ehdr header;
    if (fstat(fd, &s)) return -1;
    if (!S_ISREG(s.st_mode) || s.st_size < (off_t)sizeof header || offset >= (uint64_t)s.st_size ||
        pread(fd, &header, sizeof header, 0) != sizeof header ||
        memcmp(header.e_ident, "\177ELF\2\1", 6) || header.e_machine != EM_X86_64 ||
        (header.e_type != ET_DYN && header.e_type != ET_EXEC) || header.e_phentsize != sizeof(Elf64_Phdr) ||
        !header.e_phnum || header.e_phnum > 4096 || header.e_phoff > (uint64_t)s.st_size ||
        header.e_phnum * sizeof(Elf64_Phdr) > (uint64_t)s.st_size - header.e_phoff) { errno = EINVAL; return -1; }
    for (unsigned i = 0; i < header.e_phnum; ++i) {
        Elf64_Phdr ph;
        if (pread(fd, &ph, sizeof ph, (off_t)(header.e_phoff + i * sizeof ph)) != sizeof ph) { errno = EIO; return -1; }
        if (ph.p_type == PT_LOAD && (ph.p_flags & PF_X) && ph.p_offset <= offset && offset - ph.p_offset < ph.p_filesz &&
            ph.p_offset <= (uint64_t)s.st_size && ph.p_filesz <= (uint64_t)s.st_size - ph.p_offset) return 0;
    }
    errno = EINVAL; return -1;
}
static int mapped_offset(int pid, int fd, uint64_t offset) {
    struct stat s;
    if (fstat(fd, &s)) return -1;
    char path[80]; snprintf(path, sizeof path, "/proc/%d/maps", pid);
    FILE *f = fopen(path, "re");
    if (!f) return -1;
    /* fscan line storage and count are bounded independently of map paths. */
    char line[8192]; bool found = false;
    for (unsigned i = 0; i < 65536 && fgets(line, sizeof line, f); ++i) {
        unsigned long long start, end, from, inode; unsigned ma, mi; char perms[5];
        if (sscanf(line, "%llx-%llx %4s %llx %x:%x %llu", &start, &end, perms, &from, &ma, &mi, &inode) != 7) continue;
        if (end > start && perms[2] == 'x' && inode == s.st_ino && offset >= from && offset - from < end - start &&
            xodb_mapped_file_matches(fd, pid, start, end, ma, mi, inode, 1)) { found = true; break; }
    }
    fclose(f);
    if (!found) { errno = EPERM; return -1; }
    return 0;
}
static int open_probe(struct xodb_allocation_open request, int fds[2], size_t count, struct ucred peer, unsigned pmu, uint64_t retmask) {
    const bool leader = !!(request.flags & 2);
    const bool stacks = (request.flags & 4) && !(request.flags & 1);
    if (request.magic != XODB_ALLOCATION_MAGIC || request.pid <= 0 || request.tid <= 0 || request.flags > 15 ||
        count != (leader ? 1u : 2u)) { errno = EINVAL; return -1; }
    if (held_task(request.pid, request.tid, peer) || executable_offset(fds[0], request.offset) || mapped_offset(request.pid, fds[0], request.offset)) return -1;
    char path[64]; snprintf(path, sizeof path, "/proc/self/fd/%d", fds[0]);
    struct perf_event_attr attr = {
        .type = pmu, .size = 112, .config = request.flags & 1 ? retmask : 0,
        .config1 = (uint64_t)(uintptr_t)path, .config2 = request.offset,
        .sample_period = 1, .sample_type = PERF_SAMPLE_TID | PERF_SAMPLE_TIME | PERF_SAMPLE_ID | PERF_SAMPLE_REGS_USER | (stacks ? PERF_SAMPLE_CALLCHAIN | PERF_SAMPLE_STACK_USER : 0),
        .sample_max_stack = stacks ? 32 : 0, .sample_stack_user = stacks ? 8 : 0,
        .sample_regs_user = request.flags & 8 ? XRT_FUNCTION_REGISTER_MASK : XRT_ALLOCATION_REGISTER_MASK,
        .exclude_callchain_kernel = 1, .mmap = leader && (request.flags & 12), .mmap2 = leader && (request.flags & 12),
        .disabled = 1, .exclude_kernel = 1, .exclude_hv = 1, .sample_id_all = 1,
        .use_clockid = 1, .clockid = CLOCK_MONOTONIC,
        .comm = leader, .task = leader, .comm_exec = leader,
    };
    return (int)syscall(SYS_perf_event_open, &attr, request.tid, -1, leader ? -1 : fds[1], PERF_FLAG_FD_CLOEXEC);
}
int main(int argc, char **argv) {
    if (argc != 2 || strcmp(argv[1], "--stdio")) { fprintf(stderr, "xodb-allocation-helper: private --stdio helper; see docs/ALLOCATIONS.md\n"); return 2; }
#if !defined(__x86_64__)
    fprintf(stderr, "xodb-allocation-helper: x86-64 only\n"); return 2;
#endif
    struct ucred peer; socklen_t length = sizeof peer;
    int type; socklen_t type_length = sizeof type;
    if (getsockopt(0, SOL_SOCKET, SO_TYPE, &type, &type_length) || type != SOCK_SEQPACKET ||
        getsockopt(0, SOL_SOCKET, SO_PEERCRED, &peer, &length) || length != sizeof peer || peer.pid <= 0) {
        fprintf(stderr, "xodb-allocation-helper: expected inherited local seqpacket socket\n"); return 2;
    }
    /* Every privilege-bearing invocation expires, including an idle client. */
    signal(SIGALRM, SIG_DFL);
    sigset_t mask; sigemptyset(&mask); sigprocmask(SIG_SETMASK, &mask, NULL);
    alarm(30);
    char buffer[128], extra; unsigned pmu, bit;
    if (read_file("/sys/bus/event_source/devices/uprobe/type", buffer, sizeof buffer) || sscanf(buffer, "%u %c", &pmu, &extra) != 1 ||
        read_file("/sys/bus/event_source/devices/uprobe/format/retprobe", buffer, sizeof buffer) || sscanf(buffer, "config:%u %c", &bit, &extra) != 1 || bit > 63) {
        fprintf(stderr, "xodb-allocation-helper: uprobe PMU unavailable\n"); return 2;
    }
    for (unsigned i = 0; i < 1024; ++i) {
        struct xodb_allocation_open request; int fds[2]; size_t count = 0;
        if (receive_packet(0, &request, sizeof request, fds, &count)) return errno == EPIPE ? 0 : 2;
        int fd = open_probe(request, fds, count, peer, pmu, 1ull << bit);
        int saved = fd < 0 ? errno : 0;
        for (size_t j = 0; j < count; ++j) close(fds[j]);
        struct xodb_allocation_reply reply = { .magic = XODB_ALLOCATION_MAGIC, .error = saved };
        int result = send_packet(0, &reply, sizeof reply, &fd, fd < 0 ? 0 : 1);
        if (fd >= 0) close(fd);
        if (result || saved) return result ? 2 : 0;
    }
    return 0;
}
#endif
