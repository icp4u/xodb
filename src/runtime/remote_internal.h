#ifndef XODB_RUNTIME_REMOTE_INTERNAL_H
#define XODB_RUNTIME_REMOTE_INTERNAL_H
#include "xrt_remote.h"
#include "rpc.h"
#include "xrt_files.h"
struct xrt_call {
    uint16_t op;
    uint64_t args[3];
    const void *data;
    size_t size;
    uint64_t *value;
    void *out;
    size_t capacity, *length;
};
enum xrt_status xrt_remote_call(const struct xrt_target *, const struct xrt_call *);
enum xrt_status xrt_remote_background_file(const struct xrt_target *, const struct xrt_call *);
enum xrt_status xrt_remote_health(const struct xrt_target *);
enum xrt_status xrt_remote_fail(const struct xrt_target *, enum xrt_status);
enum xrt_status xrt_remote_destroy(struct xrt_target *);
enum xrt_status xrt_remote_file(const struct xrt_target *, const struct xrt_file_request *, int *,
                                struct xrt_file_identity *);
enum xrt_status xrt_remote_launch(struct xrt_target *, const char *const[]);
enum xrt_status xrt_remote_registers(const struct xrt_target *, int32_t, struct xrt_registers *);
enum xrt_status xrt_remote_extended(const struct xrt_target *, int32_t, struct xrt_xstate *);
enum xrt_status xrt_remote_adopt(struct xrt_target *, int32_t, struct xrt_target *,
                                 struct xrt_birth *);
enum xrt_status xrt_remote_capacity(const struct xrt_target *, uint8_t *);
const struct xrt_target *xrt_remote_root(const struct xrt_target *);
/* Refresh related snapshots after shared-address-space and family operations. */
enum xrt_status xrt_remote_sync_family(struct xrt_target *);
#endif
