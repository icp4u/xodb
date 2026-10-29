#ifndef XODB_RUNTIME_FDEVENT_SYSCALLS_H
#define XODB_RUNTIME_FDEVENT_SYSCALLS_H
#include "xrt_arch_syscalls.h"

/* The per-thread counter decodes the ABI of the native collector. Linux
 * AArch64, LoongArch64 and RISC-V 64 share the generated asm-generic row.
 * Other builds retain the x86-64 row for portable decoder tests and the
 * macOS seam, where no Linux collector feeds it. Negative values stand for
 * legacy syscalls that asm-generic deliberately omits. */
#if defined(__linux__) &&                                                                       \
    (defined(__aarch64__) || defined(__loongarch__) ||                                         \
     (defined(__riscv) && __riscv_xlen == 64))
#define XRT_FDEVENT_NR_read XRT_GENERIC_NR_read
#define XRT_FDEVENT_NR_write XRT_GENERIC_NR_write
#define XRT_FDEVENT_NR_open (-1)
#define XRT_FDEVENT_NR_close XRT_GENERIC_NR_close
#define XRT_FDEVENT_NR_pread64 XRT_GENERIC_NR_pread64
#define XRT_FDEVENT_NR_pwrite64 XRT_GENERIC_NR_pwrite64
#define XRT_FDEVENT_NR_readv XRT_GENERIC_NR_readv
#define XRT_FDEVENT_NR_writev XRT_GENERIC_NR_writev
#define XRT_FDEVENT_NR_pipe (-2)
#define XRT_FDEVENT_NR_dup XRT_GENERIC_NR_dup
#define XRT_FDEVENT_NR_dup2 (-3)
#define XRT_FDEVENT_NR_sendfile XRT_GENERIC_NR_sendfile
#define XRT_FDEVENT_NR_socket XRT_GENERIC_NR_socket
#define XRT_FDEVENT_NR_accept XRT_GENERIC_NR_accept
#define XRT_FDEVENT_NR_sendto XRT_GENERIC_NR_sendto
#define XRT_FDEVENT_NR_recvfrom XRT_GENERIC_NR_recvfrom
#define XRT_FDEVENT_NR_sendmsg XRT_GENERIC_NR_sendmsg
#define XRT_FDEVENT_NR_recvmsg XRT_GENERIC_NR_recvmsg
#define XRT_FDEVENT_NR_socketpair XRT_GENERIC_NR_socketpair
#define XRT_FDEVENT_NR_fcntl XRT_GENERIC_NR_fcntl
#define XRT_FDEVENT_NR_creat (-4)
#define XRT_FDEVENT_NR_epoll_create (-5)
#define XRT_FDEVENT_NR_inotify_init (-6)
#define XRT_FDEVENT_NR_openat XRT_GENERIC_NR_openat
#define XRT_FDEVENT_NR_splice XRT_GENERIC_NR_splice
#define XRT_FDEVENT_NR_tee XRT_GENERIC_NR_tee
#define XRT_FDEVENT_NR_vmsplice XRT_GENERIC_NR_vmsplice
#define XRT_FDEVENT_NR_signalfd (-7)
#define XRT_FDEVENT_NR_timerfd_create XRT_GENERIC_NR_timerfd_create
#define XRT_FDEVENT_NR_eventfd (-8)
#define XRT_FDEVENT_NR_accept4 XRT_GENERIC_NR_accept4
#define XRT_FDEVENT_NR_signalfd4 XRT_GENERIC_NR_signalfd4
#define XRT_FDEVENT_NR_eventfd2 XRT_GENERIC_NR_eventfd2
#define XRT_FDEVENT_NR_epoll_create1 XRT_GENERIC_NR_epoll_create1
#define XRT_FDEVENT_NR_dup3 XRT_GENERIC_NR_dup3
#define XRT_FDEVENT_NR_pipe2 XRT_GENERIC_NR_pipe2
#define XRT_FDEVENT_NR_inotify_init1 XRT_GENERIC_NR_inotify_init1
#define XRT_FDEVENT_NR_preadv XRT_GENERIC_NR_preadv
#define XRT_FDEVENT_NR_pwritev XRT_GENERIC_NR_pwritev
#define XRT_FDEVENT_NR_recvmmsg XRT_GENERIC_NR_recvmmsg
#define XRT_FDEVENT_NR_sendmmsg XRT_GENERIC_NR_sendmmsg
#define XRT_FDEVENT_NR_memfd_create XRT_GENERIC_NR_memfd_create
#define XRT_FDEVENT_NR_userfaultfd XRT_GENERIC_NR_userfaultfd
#define XRT_FDEVENT_NR_copy_file_range XRT_GENERIC_NR_copy_file_range
#define XRT_FDEVENT_NR_preadv2 XRT_GENERIC_NR_preadv2
#define XRT_FDEVENT_NR_pwritev2 XRT_GENERIC_NR_pwritev2
#define XRT_FDEVENT_NR_io_uring_setup XRT_GENERIC_NR_io_uring_setup
#define XRT_FDEVENT_NR_io_uring_enter XRT_GENERIC_NR_io_uring_enter
#define XRT_FDEVENT_NR_pidfd_open XRT_GENERIC_NR_pidfd_open
#define XRT_FDEVENT_NR_close_range XRT_GENERIC_NR_close_range
#define XRT_FDEVENT_NR_openat2 XRT_GENERIC_NR_openat2
#else
#define XRT_FDEVENT_NR_read XRT_X86_64_NR_read
#define XRT_FDEVENT_NR_write XRT_X86_64_NR_write
#define XRT_FDEVENT_NR_open XRT_X86_64_NR_open
#define XRT_FDEVENT_NR_close XRT_X86_64_NR_close
#define XRT_FDEVENT_NR_pread64 XRT_X86_64_NR_pread64
#define XRT_FDEVENT_NR_pwrite64 XRT_X86_64_NR_pwrite64
#define XRT_FDEVENT_NR_readv XRT_X86_64_NR_readv
#define XRT_FDEVENT_NR_writev XRT_X86_64_NR_writev
#define XRT_FDEVENT_NR_pipe XRT_X86_64_NR_pipe
#define XRT_FDEVENT_NR_dup XRT_X86_64_NR_dup
#define XRT_FDEVENT_NR_dup2 XRT_X86_64_NR_dup2
#define XRT_FDEVENT_NR_sendfile XRT_X86_64_NR_sendfile
#define XRT_FDEVENT_NR_socket XRT_X86_64_NR_socket
#define XRT_FDEVENT_NR_accept XRT_X86_64_NR_accept
#define XRT_FDEVENT_NR_sendto XRT_X86_64_NR_sendto
#define XRT_FDEVENT_NR_recvfrom XRT_X86_64_NR_recvfrom
#define XRT_FDEVENT_NR_sendmsg XRT_X86_64_NR_sendmsg
#define XRT_FDEVENT_NR_recvmsg XRT_X86_64_NR_recvmsg
#define XRT_FDEVENT_NR_socketpair XRT_X86_64_NR_socketpair
#define XRT_FDEVENT_NR_fcntl XRT_X86_64_NR_fcntl
#define XRT_FDEVENT_NR_creat XRT_X86_64_NR_creat
#define XRT_FDEVENT_NR_epoll_create XRT_X86_64_NR_epoll_create
#define XRT_FDEVENT_NR_inotify_init XRT_X86_64_NR_inotify_init
#define XRT_FDEVENT_NR_openat XRT_X86_64_NR_openat
#define XRT_FDEVENT_NR_splice XRT_X86_64_NR_splice
#define XRT_FDEVENT_NR_tee XRT_X86_64_NR_tee
#define XRT_FDEVENT_NR_vmsplice XRT_X86_64_NR_vmsplice
#define XRT_FDEVENT_NR_signalfd XRT_X86_64_NR_signalfd
#define XRT_FDEVENT_NR_timerfd_create XRT_X86_64_NR_timerfd_create
#define XRT_FDEVENT_NR_eventfd XRT_X86_64_NR_eventfd
#define XRT_FDEVENT_NR_accept4 XRT_X86_64_NR_accept4
#define XRT_FDEVENT_NR_signalfd4 XRT_X86_64_NR_signalfd4
#define XRT_FDEVENT_NR_eventfd2 XRT_X86_64_NR_eventfd2
#define XRT_FDEVENT_NR_epoll_create1 XRT_X86_64_NR_epoll_create1
#define XRT_FDEVENT_NR_dup3 XRT_X86_64_NR_dup3
#define XRT_FDEVENT_NR_pipe2 XRT_X86_64_NR_pipe2
#define XRT_FDEVENT_NR_inotify_init1 XRT_X86_64_NR_inotify_init1
#define XRT_FDEVENT_NR_preadv XRT_X86_64_NR_preadv
#define XRT_FDEVENT_NR_pwritev XRT_X86_64_NR_pwritev
#define XRT_FDEVENT_NR_recvmmsg XRT_X86_64_NR_recvmmsg
#define XRT_FDEVENT_NR_sendmmsg XRT_X86_64_NR_sendmmsg
#define XRT_FDEVENT_NR_memfd_create XRT_X86_64_NR_memfd_create
#define XRT_FDEVENT_NR_userfaultfd XRT_X86_64_NR_userfaultfd
#define XRT_FDEVENT_NR_copy_file_range XRT_X86_64_NR_copy_file_range
#define XRT_FDEVENT_NR_preadv2 XRT_X86_64_NR_preadv2
#define XRT_FDEVENT_NR_pwritev2 XRT_X86_64_NR_pwritev2
#define XRT_FDEVENT_NR_io_uring_setup XRT_X86_64_NR_io_uring_setup
#define XRT_FDEVENT_NR_io_uring_enter XRT_X86_64_NR_io_uring_enter
#define XRT_FDEVENT_NR_pidfd_open XRT_X86_64_NR_pidfd_open
#define XRT_FDEVENT_NR_close_range XRT_X86_64_NR_close_range
#define XRT_FDEVENT_NR_openat2 XRT_X86_64_NR_openat2
#endif
#endif
