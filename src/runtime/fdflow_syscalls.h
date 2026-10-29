#ifndef XODB_RUNTIME_FDFLOW_SYSCALLS_H
#define XODB_RUNTIME_FDFLOW_SYSCALLS_H
#include "xrt_arch_syscalls.h"
/* Native syscall numbers for the architecture this binary is compiled for.
 * <sys/syscall.h> is the source. A name that header does not define is
 * omitted (the generic table has no open, pipe, dup2, fork, vfork, creat).
 * Raw tracepoints also fire for a compat ABI and carry no ABI tag, so those
 * numbers stay unlisted and unproved:
 *   x86-64: int 0x80 and x32 (their numbers alias native fstat/lseek/munmap)
 *   aarch64: 32-bit compat
 *   ppc64le: 32-bit compat
 *   riscv64, loongarch64, m68k: no second userspace ABI is listed
 * A missing name is not a reason to guess a number.
 */
/* The counter is also built into the macOS seam, which has no Linux capture
 * to feed it; there every list is empty. */
#ifdef __linux__
#include <sys/syscall.h>
#endif
#ifdef SYS_exit_group
#define XRT_FDFLOW_NR_EXIT SYS_exit
#define XRT_FDFLOW_NR_EXIT_GROUP SYS_exit_group
#else
#define XRT_FDFLOW_NR_EXIT (-1)
#define XRT_FDFLOW_NR_EXIT_GROUP (-1)
#endif

#ifdef SYS_read
#define XRT_FDFLOW_HAVE_read(X) X(read, SYS_read, XRT_FDFLOW_READ)
#else
#define XRT_FDFLOW_HAVE_read(X)
#endif
#ifdef SYS_write
#define XRT_FDFLOW_HAVE_write(X) X(write, SYS_write, XRT_FDFLOW_WRITE)
#else
#define XRT_FDFLOW_HAVE_write(X)
#endif
#ifdef SYS_pread64
#define XRT_FDFLOW_HAVE_pread64(X) X(pread64, SYS_pread64, XRT_FDFLOW_READ)
#elif defined(SYS_pread)
#define XRT_FDFLOW_HAVE_pread64(X) X(pread, SYS_pread, XRT_FDFLOW_READ)
#else
#define XRT_FDFLOW_HAVE_pread64(X)
#endif
#ifdef SYS_pwrite64
#define XRT_FDFLOW_HAVE_pwrite64(X) X(pwrite64, SYS_pwrite64, XRT_FDFLOW_WRITE)
#elif defined(SYS_pwrite)
#define XRT_FDFLOW_HAVE_pwrite64(X) X(pwrite, SYS_pwrite, XRT_FDFLOW_WRITE)
#else
#define XRT_FDFLOW_HAVE_pwrite64(X)
#endif
#ifdef SYS_readv
#define XRT_FDFLOW_HAVE_readv(X) X(readv, SYS_readv, XRT_FDFLOW_READ)
#else
#define XRT_FDFLOW_HAVE_readv(X)
#endif
#ifdef SYS_writev
#define XRT_FDFLOW_HAVE_writev(X) X(writev, SYS_writev, XRT_FDFLOW_WRITE)
#else
#define XRT_FDFLOW_HAVE_writev(X)
#endif
#ifdef SYS_preadv
#define XRT_FDFLOW_HAVE_preadv(X) X(preadv, SYS_preadv, XRT_FDFLOW_READ)
#else
#define XRT_FDFLOW_HAVE_preadv(X)
#endif
#ifdef SYS_pwritev
#define XRT_FDFLOW_HAVE_pwritev(X) X(pwritev, SYS_pwritev, XRT_FDFLOW_WRITE)
#else
#define XRT_FDFLOW_HAVE_pwritev(X)
#endif
#ifdef SYS_preadv2
#define XRT_FDFLOW_HAVE_preadv2(X) X(preadv2, SYS_preadv2, XRT_FDFLOW_READ)
#else
#define XRT_FDFLOW_HAVE_preadv2(X)
#endif
#ifdef SYS_pwritev2
#define XRT_FDFLOW_HAVE_pwritev2(X) X(pwritev2, SYS_pwritev2, XRT_FDFLOW_WRITE)
#else
#define XRT_FDFLOW_HAVE_pwritev2(X)
#endif
#ifdef SYS_sendto
#define XRT_FDFLOW_HAVE_sendto(X) X(sendto, SYS_sendto, XRT_FDFLOW_WRITE)
#else
#define XRT_FDFLOW_HAVE_sendto(X)
#endif
#ifdef SYS_recvfrom
#define XRT_FDFLOW_HAVE_recvfrom(X) X(recvfrom, SYS_recvfrom, XRT_FDFLOW_READ)
#else
#define XRT_FDFLOW_HAVE_recvfrom(X)
#endif
#ifdef SYS_sendmsg
#define XRT_FDFLOW_HAVE_sendmsg(X) X(sendmsg, SYS_sendmsg, XRT_FDFLOW_WRITE)
#else
#define XRT_FDFLOW_HAVE_sendmsg(X)
#endif
#ifdef SYS_recvmsg
#define XRT_FDFLOW_HAVE_recvmsg(X) X(recvmsg, SYS_recvmsg, XRT_FDFLOW_READ)
#else
#define XRT_FDFLOW_HAVE_recvmsg(X)
#endif

/* X(name, number, operation). operation is XRT_FDFLOW_READ or XRT_FDFLOW_WRITE.
 * Those tokens expand when the list is used, so xrt_fdflow.h must be included
 * before expanding this list in a context that reads the operation. */
#define XRT_FDFLOW_EACH_IO(X)                                                                      \
  XRT_FDFLOW_HAVE_read(X)                                                                          \
  XRT_FDFLOW_HAVE_write(X)                                                                         \
  XRT_FDFLOW_HAVE_pread64(X)                                                                       \
  XRT_FDFLOW_HAVE_pwrite64(X)                                                                      \
  XRT_FDFLOW_HAVE_readv(X)                                                                         \
  XRT_FDFLOW_HAVE_writev(X)                                                                        \
  XRT_FDFLOW_HAVE_preadv(X)                                                                        \
  XRT_FDFLOW_HAVE_pwritev(X)                                                                       \
  XRT_FDFLOW_HAVE_preadv2(X)                                                                       \
  XRT_FDFLOW_HAVE_pwritev2(X)                                                                      \
  XRT_FDFLOW_HAVE_sendto(X)                                                                        \
  XRT_FDFLOW_HAVE_recvfrom(X)                                                                      \
  XRT_FDFLOW_HAVE_sendmsg(X)                                                                       \
  XRT_FDFLOW_HAVE_recvmsg(X)

#define XRT_FDFLOW_IO_PLUS(name, num, op) +1
#define XRT_FDFLOW_IO_COUNT (0 XRT_FDFLOW_EACH_IO(XRT_FDFLOW_IO_PLUS))

#ifdef SYS_open
#define XRT_FDFLOW_MUT_open(X) X(open, SYS_open, 0)
#else
#define XRT_FDFLOW_MUT_open(X)
#endif
#ifdef SYS_close
#define XRT_FDFLOW_MUT_close(X) X(close, SYS_close, 0)
#else
#define XRT_FDFLOW_MUT_close(X)
#endif
#ifdef SYS_pipe
#define XRT_FDFLOW_MUT_pipe(X) X(pipe, SYS_pipe, 0)
#else
#define XRT_FDFLOW_MUT_pipe(X)
#endif
#ifdef SYS_dup
#define XRT_FDFLOW_MUT_dup(X) X(dup, SYS_dup, 0)
#else
#define XRT_FDFLOW_MUT_dup(X)
#endif
#ifdef SYS_dup2
#define XRT_FDFLOW_MUT_dup2(X) X(dup2, SYS_dup2, 0)
#else
#define XRT_FDFLOW_MUT_dup2(X)
#endif
#ifdef SYS_socket
#define XRT_FDFLOW_MUT_socket(X) X(socket, SYS_socket, 0)
#else
#define XRT_FDFLOW_MUT_socket(X)
#endif
#ifdef SYS_accept
#define XRT_FDFLOW_MUT_accept(X) X(accept, SYS_accept, 0)
#else
#define XRT_FDFLOW_MUT_accept(X)
#endif
#ifdef SYS_recvmsg
#define XRT_FDFLOW_MUT_recvmsg(X) X(recvmsg, SYS_recvmsg, 0)
#else
#define XRT_FDFLOW_MUT_recvmsg(X)
#endif
#ifdef SYS_socketpair
#define XRT_FDFLOW_MUT_socketpair(X) X(socketpair, SYS_socketpair, 0)
#else
#define XRT_FDFLOW_MUT_socketpair(X)
#endif
#ifdef SYS_clone
#define XRT_FDFLOW_MUT_clone(X) X(clone, SYS_clone, 0)
#else
#define XRT_FDFLOW_MUT_clone(X)
#endif
#ifdef SYS_fork
#define XRT_FDFLOW_MUT_fork(X) X(fork, SYS_fork, 0)
#else
#define XRT_FDFLOW_MUT_fork(X)
#endif
#ifdef SYS_vfork
#define XRT_FDFLOW_MUT_vfork(X) X(vfork, SYS_vfork, 0)
#else
#define XRT_FDFLOW_MUT_vfork(X)
#endif
#ifdef SYS_execve
#define XRT_FDFLOW_MUT_execve(X) X(execve, SYS_execve, 0)
#else
#define XRT_FDFLOW_MUT_execve(X)
#endif
#ifdef SYS_fcntl
#define XRT_FDFLOW_MUT_fcntl(X) X(fcntl, SYS_fcntl, 0)
#else
#define XRT_FDFLOW_MUT_fcntl(X)
#endif
#ifdef SYS_creat
#define XRT_FDFLOW_MUT_creat(X) X(creat, SYS_creat, 0)
#else
#define XRT_FDFLOW_MUT_creat(X)
#endif
#ifdef SYS_openat
#define XRT_FDFLOW_MUT_openat(X) X(openat, SYS_openat, 0)
#else
#define XRT_FDFLOW_MUT_openat(X)
#endif
#ifdef SYS_accept4
#define XRT_FDFLOW_MUT_accept4(X) X(accept4, SYS_accept4, 0)
#else
#define XRT_FDFLOW_MUT_accept4(X)
#endif
#ifdef SYS_dup3
#define XRT_FDFLOW_MUT_dup3(X) X(dup3, SYS_dup3, 0)
#else
#define XRT_FDFLOW_MUT_dup3(X)
#endif
#ifdef SYS_pipe2
#define XRT_FDFLOW_MUT_pipe2(X) X(pipe2, SYS_pipe2, 0)
#else
#define XRT_FDFLOW_MUT_pipe2(X)
#endif
#ifdef SYS_recvmmsg
#define XRT_FDFLOW_MUT_recvmmsg(X) X(recvmmsg, SYS_recvmmsg, 0)
#else
#define XRT_FDFLOW_MUT_recvmmsg(X)
#endif
#ifdef SYS_execveat
#define XRT_FDFLOW_MUT_execveat(X) X(execveat, SYS_execveat, 0)
#else
#define XRT_FDFLOW_MUT_execveat(X)
#endif
#ifdef SYS_io_uring_setup
#define XRT_FDFLOW_MUT_io_uring_setup(X) X(io_uring_setup, SYS_io_uring_setup, 1)
#else
#define XRT_FDFLOW_MUT_io_uring_setup(X)
#endif
#ifdef SYS_io_uring_enter
#define XRT_FDFLOW_MUT_io_uring_enter(X) X(io_uring_enter, SYS_io_uring_enter, 1)
#else
#define XRT_FDFLOW_MUT_io_uring_enter(X)
#endif
#ifdef SYS_io_uring_register
#define XRT_FDFLOW_MUT_io_uring_register(X) X(io_uring_register, SYS_io_uring_register, 1)
#else
#define XRT_FDFLOW_MUT_io_uring_register(X)
#endif
#ifdef SYS_clone3
#define XRT_FDFLOW_MUT_clone3(X) X(clone3, SYS_clone3, 0)
#else
#define XRT_FDFLOW_MUT_clone3(X)
#endif
#ifdef SYS_close_range
#define XRT_FDFLOW_MUT_close_range(X) X(close_range, SYS_close_range, 0)
#else
#define XRT_FDFLOW_MUT_close_range(X)
#endif
#ifdef SYS_openat2
#define XRT_FDFLOW_MUT_openat2(X) X(openat2, SYS_openat2, 0)
#else
#define XRT_FDFLOW_MUT_openat2(X)
#endif
#ifdef SYS_pidfd_getfd
#define XRT_FDFLOW_MUT_pidfd_getfd(X) X(pidfd_getfd, SYS_pidfd_getfd, 0)
#else
#define XRT_FDFLOW_MUT_pidfd_getfd(X)
#endif
#ifdef SYS_fcntl64
#define XRT_FDFLOW_MUT_fcntl64(X) X(fcntl64, SYS_fcntl64, 0)
#else
#define XRT_FDFLOW_MUT_fcntl64(X)
#endif
#ifdef SYS_recvmmsg_time64
#define XRT_FDFLOW_MUT_recvmmsg_time64(X) X(recvmmsg_time64, SYS_recvmmsg_time64, 0)
#else
#define XRT_FDFLOW_MUT_recvmmsg_time64(X)
#endif
/* socketcall multiplexes socket, accept and recvmsg on ppc64 and m68k. Its
 * IO (send/recv through it) is not counted; its fd changes withdraw joins. */
#ifdef SYS_socketcall
#define XRT_FDFLOW_MUT_socketcall(X) X(socketcall, SYS_socketcall, 0)
#else
#define XRT_FDFLOW_MUT_socketcall(X)
#endif

/* X(name, number, asynchronous). asynchronous is 1 for io_uring calls. */
#define XRT_FDFLOW_EACH_MUTATION(X)                                                                \
  XRT_FDFLOW_MUT_open(X)                                                                           \
  XRT_FDFLOW_MUT_close(X)                                                                          \
  XRT_FDFLOW_MUT_pipe(X)                                                                           \
  XRT_FDFLOW_MUT_dup(X)                                                                            \
  XRT_FDFLOW_MUT_dup2(X)                                                                           \
  XRT_FDFLOW_MUT_socket(X)                                                                         \
  XRT_FDFLOW_MUT_accept(X)                                                                         \
  XRT_FDFLOW_MUT_recvmsg(X)                                                                        \
  XRT_FDFLOW_MUT_socketpair(X)                                                                     \
  XRT_FDFLOW_MUT_clone(X)                                                                          \
  XRT_FDFLOW_MUT_fork(X)                                                                           \
  XRT_FDFLOW_MUT_vfork(X)                                                                          \
  XRT_FDFLOW_MUT_execve(X)                                                                         \
  XRT_FDFLOW_MUT_fcntl(X)                                                                          \
  XRT_FDFLOW_MUT_creat(X)                                                                          \
  XRT_FDFLOW_MUT_openat(X)                                                                         \
  XRT_FDFLOW_MUT_accept4(X)                                                                        \
  XRT_FDFLOW_MUT_dup3(X)                                                                           \
  XRT_FDFLOW_MUT_pipe2(X)                                                                          \
  XRT_FDFLOW_MUT_recvmmsg(X)                                                                       \
  XRT_FDFLOW_MUT_execveat(X)                                                                       \
  XRT_FDFLOW_MUT_io_uring_setup(X)                                                                 \
  XRT_FDFLOW_MUT_io_uring_enter(X)                                                                 \
  XRT_FDFLOW_MUT_io_uring_register(X)                                                              \
  XRT_FDFLOW_MUT_clone3(X)                                                                         \
  XRT_FDFLOW_MUT_close_range(X)                                                                    \
  XRT_FDFLOW_MUT_openat2(X)                                                                        \
  XRT_FDFLOW_MUT_pidfd_getfd(X)                                                                    \
  XRT_FDFLOW_MUT_fcntl64(X)                                                                        \
  XRT_FDFLOW_MUT_recvmmsg_time64(X)                                                                \
  XRT_FDFLOW_MUT_socketcall(X)

#if defined(__x86_64__) && !defined(__ILP32__)
/* The count and churn tests spell SYS_*. These asserts keep the host macros
 * equal to the x86-64 row in xrt_arch_syscalls.h. */
_Static_assert(SYS_read == XRT_X86_64_NR_read && SYS_write == XRT_X86_64_NR_write, "x86 read/write");
_Static_assert(SYS_pread64 == XRT_X86_64_NR_pread64 && SYS_pwrite64 == XRT_X86_64_NR_pwrite64, "x86 pread/pwrite");
_Static_assert(SYS_readv == XRT_X86_64_NR_readv && SYS_writev == XRT_X86_64_NR_writev, "x86 readv/writev");
_Static_assert(SYS_preadv == XRT_X86_64_NR_preadv && SYS_pwritev == XRT_X86_64_NR_pwritev, "x86 preadv/pwritev");
_Static_assert(SYS_preadv2 == XRT_X86_64_NR_preadv2 && SYS_pwritev2 == XRT_X86_64_NR_pwritev2, "x86 preadv2/pwritev2");
_Static_assert(SYS_sendto == XRT_X86_64_NR_sendto && SYS_recvfrom == XRT_X86_64_NR_recvfrom, "x86 sendto/recvfrom");
_Static_assert(SYS_sendmsg == XRT_X86_64_NR_sendmsg && SYS_recvmsg == XRT_X86_64_NR_recvmsg, "x86 sendmsg/recvmsg");
_Static_assert(SYS_open == XRT_X86_64_NR_open && SYS_close == XRT_X86_64_NR_close && SYS_pipe == XRT_X86_64_NR_pipe, "x86 open/close/pipe");
_Static_assert(SYS_dup == XRT_X86_64_NR_dup && SYS_dup2 == XRT_X86_64_NR_dup2 && SYS_socket == XRT_X86_64_NR_socket, "x86 dup/socket");
_Static_assert(SYS_accept == XRT_X86_64_NR_accept && SYS_socketpair == XRT_X86_64_NR_socketpair, "x86 accept/socketpair");
_Static_assert(SYS_clone == XRT_X86_64_NR_clone && SYS_fork == XRT_X86_64_NR_fork && SYS_vfork == XRT_X86_64_NR_vfork, "x86 clone/fork");
_Static_assert(SYS_execve == XRT_X86_64_NR_execve && SYS_fcntl == XRT_X86_64_NR_fcntl && SYS_creat == XRT_X86_64_NR_creat, "x86 exec/fcntl/creat");
_Static_assert(SYS_openat == XRT_X86_64_NR_openat && SYS_accept4 == XRT_X86_64_NR_accept4, "x86 openat/accept4");
_Static_assert(SYS_dup3 == XRT_X86_64_NR_dup3 && SYS_pipe2 == XRT_X86_64_NR_pipe2 && SYS_recvmmsg == XRT_X86_64_NR_recvmmsg, "x86 dup3/pipe2");
_Static_assert(SYS_execveat == XRT_X86_64_NR_execveat, "x86 execveat");
_Static_assert(SYS_io_uring_setup == XRT_X86_64_NR_io_uring_setup && SYS_io_uring_enter == XRT_X86_64_NR_io_uring_enter && SYS_io_uring_register == XRT_X86_64_NR_io_uring_register,
               "x86 io_uring");
_Static_assert(SYS_clone3 == XRT_X86_64_NR_clone3 && SYS_close_range == XRT_X86_64_NR_close_range, "x86 clone3/close_range");
_Static_assert(SYS_openat2 == XRT_X86_64_NR_openat2 && SYS_pidfd_getfd == XRT_X86_64_NR_pidfd_getfd, "x86 openat2/pidfd_getfd");
_Static_assert(SYS_fstat == XRT_X86_64_NR_fstat && SYS_lseek == XRT_X86_64_NR_lseek && SYS_munmap == XRT_X86_64_NR_munmap, "x86 compat aliases");
_Static_assert(SYS_exit == XRT_X86_64_NR_exit && SYS_exit_group == XRT_X86_64_NR_exit_group, "x86 exit/exit_group");
#if defined(SYS_fcntl64) || defined(SYS_recvmmsg_time64) || defined(SYS_socketcall)
#error "x86-64 mutation set changed"
#endif
_Static_assert(SYS_uname == XRT_X86_64_NR_uname && SYS_getuid == XRT_X86_64_NR_getuid, "x86 harmless numbers");
_Static_assert(XRT_FDFLOW_IO_COUNT == 14, "x86 keeps 14 IO calls");
#elif defined(__linux__) &&                                                                      \
    (defined(__aarch64__) || defined(__loongarch__) ||                                           \
     (defined(__riscv) && __riscv_xlen == 64))
/* Every syscall used by fdflow must agree with the generated native
 * asm-generic row. Missing deprecated calls expand to no assertion. */
#define XRT_FDFLOW_GENERIC_CHECK(name, number, unused)                                           \
    _Static_assert((number) == XRT_GENERIC_NR_##name, "asm-generic " #name);
XRT_FDFLOW_EACH_IO(XRT_FDFLOW_GENERIC_CHECK)
XRT_FDFLOW_EACH_MUTATION(XRT_FDFLOW_GENERIC_CHECK)
#undef XRT_FDFLOW_GENERIC_CHECK
_Static_assert(SYS_exit == XRT_GENERIC_NR_exit && SYS_exit_group == XRT_GENERIC_NR_exit_group,
               "asm-generic exit/exit_group");
_Static_assert(XRT_FDFLOW_IO_COUNT == 14, "asm-generic keeps 14 IO calls");
#endif
#endif
