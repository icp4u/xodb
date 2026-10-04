#ifndef XODB_ALLOCATION_BROKER_H
#define XODB_ALLOCATION_BROKER_H
#include <stdint.h>
typedef int (*xodb_allocation_cancel)(void *);

/* Private same-host protocol. No network listener, target control or memory
 * reader. Each response transfers one disabled, task-scoped perf descriptor. */
struct xodb_allocation_open {
    uint32_t magic;
    int32_t pid;
    int32_t tid;
    uint32_t flags; /* bit 0: return probe; bit 1: group leader */
    uint64_t offset;
};
struct xodb_allocation_reply { uint32_t magic; int32_t error; };
#define XODB_ALLOCATION_MAGIC 0x58414c31u

/* The explicit helper option invokes sudo noninteractively. It never changes
 * sudo policy or installs capabilities. All diagnostics use stderr. */
int xodb_allocation_broker_start(const char *helper, int *socket_fd, int *child_pid);
int xodb_allocation_broker_open(int socket_fd, int pid, int tid, int file_fd,
                               int group_fd, uint64_t offset, int return_probe,
                               int leader, xodb_allocation_cancel cancelled, void *context);
void xodb_allocation_broker_close(int socket_fd, int child_pid);
#endif
