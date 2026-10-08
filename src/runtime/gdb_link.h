#ifndef XODB_GDB_LINK_H
#define XODB_GDB_LINK_H
#include "gdb_packet.h"
#include "xrt.h"
#include <stdbool.h>

#define XRT_GDB_OPERATION_NS UINT64_C(10000000000)
#define XRT_GDB_OPEN_NS UINT64_C(30000000000)

struct xrt_gdb_link {
    int fd;
    bool noack, failed, awaiting_ack;
    unsigned retries;
    uint64_t operation_deadline_ns;
    size_t packet_size, received, sent;
    uint8_t rx[XRT_GDB_WIRE_MAX], tx[XRT_GDB_WIRE_MAX];
    char reason[128];
};
/* One owning thread serializes all link operations. Payload views are copied
 * into caller storage; the link retains only an outstanding command frame. */
enum xrt_status xrt_gdb_connect(struct xrt_gdb_link *, const char *endpoint);
void xrt_gdb_disconnect(struct xrt_gdb_link *);
enum xrt_status xrt_gdb_send(struct xrt_gdb_link *, const void *, size_t);
enum xrt_status xrt_gdb_receive(struct xrt_gdb_link *, void *, size_t, size_t *,
                                bool wait);
/* A missing stop is a timeout, not proof that the transport was lost. */
enum xrt_status xrt_gdb_receive_stop(struct xrt_gdb_link *, void *, size_t, size_t *, bool);
enum xrt_status xrt_gdb_exchange(struct xrt_gdb_link *, const void *, size_t,
                                 void *, size_t, size_t *);
enum xrt_status xrt_gdb_interrupt(struct xrt_gdb_link *);
#endif
