#define _GNU_SOURCE 1
#define _FILE_OFFSET_BITS 64
#include "xrt_files.h"
#include "target_internal.h"
#include "wire_target.h"
#include <stdlib.h>

struct xrt_file_view {
    const struct xrt_target *target;
    struct xrt_file_identity identity;
    uint64_t remote_id;
    int fd, background;
    enum xrt_file_source source;
    enum xrt_status failure;
    unsigned char bytes[XRT_FILE_VIEW_MAX_READ];
};
static enum xrt_status remember(struct xrt_file_view *v, enum xrt_status status)
{
    if (status == XRT_FILE_CHANGED || status == XRT_PROTOCOL_ERROR ||
        status == XRT_TRANSPORT_FAILED || status == XRT_INVALID_ARGUMENT)
        v->failure = status == XRT_INVALID_ARGUMENT ? XRT_FILE_CHANGED : status;
    return v->failure != XRT_OK ? v->failure : status;
}
enum xrt_status xrt_target_file_view_open(const struct xrt_target *t,
        const struct xrt_file_request *request, struct xrt_file_view **out)
{
    if (!t || !request || !out || request->kind != XRT_FILE_MAPPED)
        return XRT_INVALID_ARGUMENT;
    struct xrt_file_view *v = calloc(1, sizeof(*v));
    if (!v) return XRT_OUT_OF_MEMORY;
    v->fd = -1;
    enum xrt_status status;
    if (!t->connection) {
        status = xrt_target_file_resolved(t, request, &v->fd, &v->identity, &v->source);
    } else {
        struct xrt_file_request copy = *request;
        struct xrt_codec wire = xrt_codec(v->bytes, sizeof(v->bytes), false);
        xrt_wire_file_request(&wire, &copy, NULL, 0);
        if (!wire.ok) { free(v); return XRT_INVALID_ARGUMENT; }
        unsigned char meta[128]; size_t size = 0;
        status = xrt_remote_call(t, &(struct xrt_call){.op = XRT_RPC_FILE_OPEN,
            .args = {XRT_RPC_FILE_SYMBOLS}, .data = v->bytes, .size = wire.at,
            .value = &v->remote_id, .out = meta, .capacity = sizeof(meta), .length = &size});
        if (status == XRT_OK) {
            struct xrt_codec in = xrt_codec(meta, size, true);
            bool regular = false;
            xrt_codec_bool(&in, &regular);
            xrt_wire_file_identity(&in, &v->identity);
            if (!in.ok || in.at != in.size || !regular || !v->remote_id ||
                v->remote_id > UINT32_MAX || v->identity.size <= 0 ||
                v->identity.mtime_ns < 0 || v->identity.mtime_ns >= 1000000000 ||
                v->identity.ctime_ns < 0 || v->identity.ctime_ns >= 1000000000)
                status = xrt_remote_fail(t, XRT_PROTOCOL_ERROR);
            else {
                v->target = t;
                v->source = XRT_FILE_SOURCE_REMOTE;
                __atomic_add_fetch(&((struct xrt_target *)t)->remote_files, 1, __ATOMIC_SEQ_CST);
            }
        }
    }
    if (status != XRT_OK) {
        if (v->fd >= 0) close(v->fd);
        free(v);
        return status;
    }
    *out = v;
    return XRT_OK;
}
const struct xrt_file_identity *xrt_file_view_identity(const struct xrt_file_view *v)
{
    return v ? &v->identity : NULL;
}
int xrt_file_view_remote(const struct xrt_file_view *v)
{
    return v && v->target != NULL;
}
enum xrt_file_source xrt_file_view_source(const struct xrt_file_view *v)
{
    return v ? v->source : XRT_FILE_SOURCE_UNKNOWN;
}
void xrt_file_view_background(struct xrt_file_view *v)
{
    if (v) v->background = 1;
}
static enum xrt_status file_read_call(struct xrt_file_view *v, const struct xrt_call *call)
{
    return v->background ? xrt_remote_background_file(v->target, call) :
        xrt_remote_call(v->target, call);
}
enum xrt_status xrt_file_view_validate(struct xrt_file_view *v)
{
    if (!v) return XRT_INVALID_ARGUMENT;
    if (v->failure != XRT_OK) return v->failure;
    if (!v->target) return remember(v, xrt_file_unchanged(v->fd, &v->identity));
    size_t size = 0;
    enum xrt_status status = file_read_call(v, &(struct xrt_call){
        .op = XRT_RPC_FILE_READ, .args = {v->remote_id, 0, 0}, .length = &size});
    return remember(v, status);
}
enum xrt_status xrt_file_view_read(struct xrt_file_view *v, uint64_t offset,
                                 void *out, size_t size)
{
    if (!v || (size && !out) || size > XRT_FILE_VIEW_MAX_READ ||
        offset > (uint64_t)v->identity.size || size > (uint64_t)v->identity.size - offset)
        return XRT_INVALID_ARGUMENT;
    if (v->failure != XRT_OK) return v->failure;
    enum xrt_status status;
    if (v->target) {
        size_t got = 0;
        status = file_read_call(v, &(struct xrt_call){.op = XRT_RPC_FILE_READ,
            .args = {v->remote_id, offset, size}, .out = v->bytes, .capacity = size, .length = &got});
        if (status == XRT_OK && got != size) status = XRT_FILE_CHANGED;
    } else {
        status = xrt_file_view_validate(v);
        if (status != XRT_OK) return status;
        ssize_t got;
        do { got = pread(v->fd, v->bytes, size, (off_t)offset); } while (got < 0 && errno == EINTR);
        status = got < 0 ? XRT_FILE_UNAVAILABLE : (size_t)got != size ? XRT_FILE_CHANGED : XRT_OK;
        if (status == XRT_OK) status = xrt_file_view_validate(v);
    }
    status = remember(v, status);
    if (status == XRT_OK && size) memcpy(out, v->bytes, size);
    return status;
}
enum xrt_status xrt_file_view_close(struct xrt_file_view *v)
{
    if (!v) return XRT_OK;
    enum xrt_status status = XRT_OK;
    if (v->target) {
        status = xrt_remote_call(v->target, &(struct xrt_call){
            .op = XRT_RPC_FILE_CLOSE, .args = {v->remote_id}});
        __atomic_sub_fetch(&((struct xrt_target *)v->target)->remote_files, 1, __ATOMIC_SEQ_CST);
    } else if (close(v->fd)) status = XRT_FILE_UNAVAILABLE;
    free(v);
    return status;
}
