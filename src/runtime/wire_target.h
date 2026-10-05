#ifndef XODB_RUNTIME_WIRE_TARGET_H
#define XODB_RUNTIME_WIRE_TARGET_H
#include "xrt_wire.h"
#include "xrt_target.h"
#include "xrt_files.h"
/* Decode only into a fresh, unpublished target. Publish it atomically after
 * validating the entire reply; never mutate a live target from partial bytes. */
void xrt_wire_target(struct xrt_codec *, struct xrt_target *);
void xrt_wire_registers(struct xrt_codec *, struct xrt_registers *);
void xrt_wire_signal(struct xrt_codec *, struct xrt_signal_info *);
void xrt_wire_xstate(struct xrt_codec *, struct xrt_xstate *);
void xrt_wire_file_request(struct xrt_codec *, struct xrt_file_request *, char *path,
                           size_t capacity);
void xrt_wire_file_identity(struct xrt_codec *, struct xrt_file_identity *);
void xrt_wire_birth(struct xrt_codec *, struct xrt_birth *);
#endif
