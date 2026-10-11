#ifndef XODB_RUNTIME_HOST_COMPAT_H
#define XODB_RUNTIME_HOST_COMPAT_H
/* Host differences for the portable client code (GDB remote and agent wire
 * clients). Linux keeps its atomic flags and sealed memfds. Other hosts set
 * close-on-exec after creation and have no sealed anonymous file: callers
 * report the typed XRT_FILE_UNAVAILABLE. */
#include <errno.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/mman.h>
#endif

static inline int xrt_host_flags(int fd, int nonblock)
{
    if (fd < 0) return fd;
    int flags = fcntl(fd, F_GETFD);
    if (flags < 0 || fcntl(fd, F_SETFD, flags | FD_CLOEXEC) < 0) goto fail;
    if (nonblock) {
        flags = fcntl(fd, F_GETFL);
        if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) goto fail;
    }
    return fd;
fail:
    close(fd);
    return -1;
}
static inline int xrt_host_socket(int family, int type, int protocol, int nonblock)
{
#if defined(SOCK_CLOEXEC) && defined(SOCK_NONBLOCK)
    return socket(family, type | SOCK_CLOEXEC | (nonblock ? SOCK_NONBLOCK : 0), protocol);
#else
    return xrt_host_flags(socket(family, type, protocol), nonblock);
#endif
}
/* A close-on-exec, non-blocking pipe. */
static inline int xrt_host_pipe(int out[2])
{
#ifdef __linux__
    return pipe2(out, O_CLOEXEC | O_NONBLOCK);
#else
    if (pipe(out)) return -1;
    out[0] = xrt_host_flags(out[0], 1);
    out[1] = xrt_host_flags(out[1], 1);
    if (out[0] >= 0 && out[1] >= 0) return 0;
    if (out[0] >= 0) close(out[0]);
    if (out[1] >= 0) close(out[1]);
    return -1;
#endif
}
static inline int xrt_host_socketpair(int family, int type, int protocol, int out[2])
{
#ifdef SOCK_CLOEXEC
    return socketpair(family, type | SOCK_CLOEXEC, protocol, out);
#else
    if (socketpair(family, type, protocol, out)) return -1;
    out[0] = xrt_host_flags(out[0], 0);
    out[1] = xrt_host_flags(out[1], 0);
    if (out[0] >= 0 && out[1] >= 0) return 0;
    if (out[0] >= 0) close(out[0]);
    if (out[1] >= 0) close(out[1]);
    return -1;
#endif
}
static inline int xrt_host_sealed_file(const char *name)
{
#ifdef __linux__
    return memfd_create(name, MFD_CLOEXEC | MFD_ALLOW_SEALING);
#else
    (void)name;
    errno = ENOSYS;
    return -1;
#endif
}
static inline int xrt_host_seal(int fd)
{
#ifdef __linux__
    return fcntl(fd, F_ADD_SEALS, F_SEAL_SEAL | F_SEAL_SHRINK | F_SEAL_GROW | F_SEAL_WRITE);
#else
    (void)fd;
    errno = ENOSYS;
    return -1;
#endif
}
#endif
