#ifndef XODB_GDBREMOTE_INTERNAL_H
#define XODB_GDBREMOTE_INTERNAL_H
#include "remote_internal.h"
#include "xrt_gdbremote.h"
struct xrt_gdb;
enum xrt_status xrt_gdb_open(const char *, struct xrt_target *, struct xrt_gdb **);
enum xrt_status xrt_gdb_call(struct xrt_gdb *, struct xrt_target *, const struct xrt_call *);
enum xrt_status xrt_gdb_health(const struct xrt_gdb *);
void xrt_gdb_info(const struct xrt_gdb *, struct xrt_gdb_info *);
void xrt_gdb_free(struct xrt_gdb *);
void xrt_gdb_abandon(struct xrt_gdb *);
#endif
