#ifndef XODB_RUNTIME_XRT_ARCH_SYSCALLS_H
#define XODB_RUNTIME_XRT_ARCH_SYSCALLS_H
/* Linux syscall numbers by architecture. These are the ABI numbers a traced
 * task uses, not whatever <sys/syscall.h> means on the build host. The fd
 * event counter decodes the x86-64 row. A native fdflow build on x86-64
 * checks its host SYS_* macros against the same row.
 *
 * Only x86-64 is filled. Tests assert against this row, not their own literals. A missing architecture is not a guessed row.
 * Register rows and software-breakpoint bytes stay in arch.c. */

#define XRT_X86_64_NR_read 0
#define XRT_X86_64_NR_write 1
#define XRT_X86_64_NR_open 2
#define XRT_X86_64_NR_close 3
#define XRT_X86_64_NR_fstat 5
#define XRT_X86_64_NR_lseek 8
#define XRT_X86_64_NR_munmap 11
#define XRT_X86_64_NR_pread64 17
#define XRT_X86_64_NR_pwrite64 18
#define XRT_X86_64_NR_readv 19
#define XRT_X86_64_NR_writev 20
#define XRT_X86_64_NR_pipe 22
#define XRT_X86_64_NR_dup 32
#define XRT_X86_64_NR_dup2 33
#define XRT_X86_64_NR_getpid 39
#define XRT_X86_64_NR_sendfile 40
#define XRT_X86_64_NR_socket 41
#define XRT_X86_64_NR_accept 43
#define XRT_X86_64_NR_sendto 44
#define XRT_X86_64_NR_recvfrom 45
#define XRT_X86_64_NR_sendmsg 46
#define XRT_X86_64_NR_recvmsg 47
#define XRT_X86_64_NR_socketpair 53
#define XRT_X86_64_NR_clone 56
#define XRT_X86_64_NR_fork 57
#define XRT_X86_64_NR_vfork 58
#define XRT_X86_64_NR_execve 59
#define XRT_X86_64_NR_exit 60
#define XRT_X86_64_NR_uname 63
#define XRT_X86_64_NR_fcntl 72
#define XRT_X86_64_NR_creat 85
#define XRT_X86_64_NR_getuid 102
#define XRT_X86_64_NR_epoll_create 213
#define XRT_X86_64_NR_exit_group 231
#define XRT_X86_64_NR_inotify_init 253
#define XRT_X86_64_NR_openat 257
#define XRT_X86_64_NR_splice 275
#define XRT_X86_64_NR_tee 276
#define XRT_X86_64_NR_vmsplice 278
#define XRT_X86_64_NR_signalfd 282
#define XRT_X86_64_NR_timerfd_create 283
#define XRT_X86_64_NR_eventfd 284
#define XRT_X86_64_NR_accept4 288
#define XRT_X86_64_NR_signalfd4 289
#define XRT_X86_64_NR_eventfd2 290
#define XRT_X86_64_NR_epoll_create1 291
#define XRT_X86_64_NR_dup3 292
#define XRT_X86_64_NR_pipe2 293
#define XRT_X86_64_NR_inotify_init1 294
#define XRT_X86_64_NR_preadv 295
#define XRT_X86_64_NR_pwritev 296
#define XRT_X86_64_NR_recvmmsg 299
#define XRT_X86_64_NR_sendmmsg 307
#define XRT_X86_64_NR_memfd_create 319
#define XRT_X86_64_NR_execveat 322
#define XRT_X86_64_NR_userfaultfd 323
#define XRT_X86_64_NR_copy_file_range 326
#define XRT_X86_64_NR_preadv2 327
#define XRT_X86_64_NR_pwritev2 328
#define XRT_X86_64_NR_io_uring_setup 425
#define XRT_X86_64_NR_io_uring_enter 426
#define XRT_X86_64_NR_io_uring_register 427
#define XRT_X86_64_NR_pidfd_open 434
#define XRT_X86_64_NR_clone3 435
#define XRT_X86_64_NR_close_range 436
#define XRT_X86_64_NR_openat2 437
#define XRT_X86_64_NR_pidfd_getfd 438

#endif
