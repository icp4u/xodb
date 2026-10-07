#define _GNU_SOURCE
#include "bundle.h"
#include "../import/sha256.h"
#include "../import/jvm_budget.h"
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int cancelled(const struct xlf_cancel *c) { return c && xlf_cancel_requested(c); }
static int digest(const void *bytes, size_t size, const struct xlf_cancel *c, char out[65]) {
    struct jvm_budget b = {.cancel = c};
    return sha256_hex_cancellable(bytes, size, out, &b);
}
struct read_context { size_t limit; const struct xlf_cancel *cancel; struct xfb_input *out; };
static enum xlf_status read_sink(void *opaque, int fd, uint64_t size, struct xlf_error *error) {
    struct read_context *ctx = opaque;
    if (size > ctx->limit) return error->status = XLF_E_LIMIT;
    if (cancelled(ctx->cancel)) return error->status = XLF_E_CANCELLED;
    ctx->out->bytes = malloc(size ? (size_t)size : 1);
    if (!ctx->out->bytes) return error->status = XLF_E_MEMORY;
    ctx->out->size = (size_t)size;
    size_t at = 0;
    while (at < size) {
        if (cancelled(ctx->cancel)) return error->status = XLF_E_CANCELLED;
        size_t n = (size_t)size - at;
        if (n > 65536) n = 65536;
        ssize_t got = pread(fd, ctx->out->bytes + at, n, (off_t)at);
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0) return error->status = XLF_E_IO;
        at += (size_t)got;
    }
    uint8_t extra;
    ssize_t tail;
    do { tail = pread(fd, &extra, 1, (off_t)size); } while (tail < 0 && errno == EINTR);
    if (tail != 0) return error->status = XLF_E_IO;
    if (digest(ctx->out->bytes, ctx->out->size, ctx->cancel, ctx->out->sha256)) return error->status = XLF_E_CANCELLED;
    return XLF_OK;
}
enum xfb_status xfb_read(const char *path, size_t limit, const struct xlf_cancel *cancel, struct xfb_input *out) {
    memset(out, 0, sizeof *out);
    if (!path || !limit || limit > XFB_MAX_BYTES) return XFB_LIMIT;
    if (cancelled(cancel)) return XFB_CANCELLED;
    struct xlf_error error = {0};
    struct read_context ctx = {limit, cancel, out};
    enum xlf_status status = xlf_read_stable(path, read_sink, &ctx, &out->stability, &error);
    if (status == XLF_OK) return XFB_OK;
    xfb_input_free(out);
    if (status == XLF_E_LIMIT) return XFB_LIMIT;
    if (status == XLF_E_MEMORY) return XFB_MEMORY;
    if (status == XLF_E_CANCELLED) return XFB_CANCELLED;
    return XFB_IO;
}
void xfb_input_free(struct xfb_input *input) { free(input->bytes); memset(input, 0, sizeof *input); }
static void put(uint8_t *p, uint64_t n, unsigned bytes) {
    for (unsigned i = 0; i < bytes; ++i) p[i] = (uint8_t)(n >> (i * 8));
}
static uint64_t get(const uint8_t *p, unsigned bytes) {
    uint64_t n = 0;
    for (unsigned i = 0; i < bytes; ++i) n |= (uint64_t)p[i] << (i * 8);
    return n;
}
static enum xfb_status source_limits(const struct xfb_source *s, size_t *input) {
    if (s->kind < XFB_LOGICAL || s->kind > XFB_PERFMAP || s->stability > XLF_STABILITY_UNVERIFIED) return XFB_FORMAT;
    if (!s->metadata_size) return XFB_FORMAT;
    if (s->metadata_size > XFB_MAX_METADATA || s->size > XFB_MAX_INPUT - *input) return XFB_LIMIT;
    if (!s->metadata || (s->size && !s->bytes)) return XFB_FORMAT;
    *input += s->size;
    return XFB_OK;
}
enum xfb_status xfb_encode(const struct xfb_view *view, const struct xlf_cancel *cancel, uint8_t **out, size_t *size) {
    *out = NULL; *size = 0;
    if (cancelled(cancel)) return XFB_CANCELLED;
    if (!view || !view->count || view->count > XFB_MAX_SOURCES) return XFB_LIMIT;
    size_t input = 0, total = XFB_HEADER_BYTES;
    for (size_t i = 0; i < view->count; ++i) {
        enum xfb_status status = source_limits(&view->sources[i], &input);
        if (status != XFB_OK) return status;
        total += XFB_HEADER_BYTES + view->sources[i].metadata_size + view->sources[i].size;
    }
    uint8_t *bytes = calloc(1, total);
    if (!bytes) return XFB_MEMORY;
    memcpy(bytes, "XODBFRAM", 8); put(bytes + 8, 1, 4); put(bytes + 12, view->count, 4);
    put(bytes + 16, total - XFB_HEADER_BYTES, 8);
    size_t at = XFB_HEADER_BYTES;
    for (size_t i = 0; i < view->count; ++i) {
        const struct xfb_source *s = &view->sources[i];
        put(bytes + at, s->kind, 4); put(bytes + at + 4, s->stability, 4);
        put(bytes + at + 8, s->metadata_size, 4); put(bytes + at + 16, s->size, 8);
        char sha[65];
        if (digest(s->bytes, s->size, cancel, sha)) { free(bytes); return XFB_CANCELLED; }
        memcpy(bytes + at + 24, sha, 64); at += XFB_HEADER_BYTES;
        memcpy(bytes + at, s->metadata, s->metadata_size); at += s->metadata_size;
        for (size_t copied = 0; copied < s->size;) {
            if (cancelled(cancel)) { free(bytes); return XFB_CANCELLED; }
            size_t n = s->size - copied; if (n > 65536) n = 65536;
            memcpy(bytes + at + copied, s->bytes + copied, n); copied += n;
        }
        at += s->size;
    }
    char sha[65];
    if (digest(bytes + XFB_HEADER_BYTES, total - XFB_HEADER_BYTES, cancel, sha)) { free(bytes); return XFB_CANCELLED; }
    memcpy(bytes + 24, sha, 64); *out = bytes; *size = total;
    return XFB_OK;
}
enum xfb_status xfb_decode(const uint8_t *bytes, size_t size, const struct xlf_cancel *cancel, struct xfb_view *view) {
    memset(view, 0, sizeof *view);
    if (cancelled(cancel)) return XFB_CANCELLED;
    if (size > XFB_MAX_BYTES) return XFB_LIMIT;
    if (!bytes || size < XFB_HEADER_BYTES || memcmp(bytes, "XODBFRAM", 8)) return XFB_FORMAT;
    if (get(bytes + 8, 4) != 1) return XFB_VERSION;
    size_t count = (size_t)get(bytes + 12, 4);
    if (!count || count > XFB_MAX_SOURCES) return XFB_LIMIT;
    if (get(bytes + 16, 8) != size - XFB_HEADER_BYTES) return XFB_FORMAT;
    char sha[65];
    if (digest(bytes + XFB_HEADER_BYTES, size - XFB_HEADER_BYTES, cancel, sha)) return XFB_CANCELLED;
    if (memcmp(sha, bytes + 24, 64)) return XFB_CHECKSUM;
    struct xfb_view result = {0};
    size_t at = XFB_HEADER_BYTES;
    for (size_t i = 0; i < count; ++i) {
        if (size - at < XFB_HEADER_BYTES) return XFB_FORMAT;
        struct xfb_source *s = &result.sources[i];
        s->kind = (uint32_t)get(bytes + at, 4); s->stability = (uint32_t)get(bytes + at + 4, 4);
        uint64_t length = get(bytes + at + 16, 8);
        if (length > XFB_MAX_INPUT) return XFB_LIMIT;
        s->size = (size_t)length; s->metadata_size = (size_t)get(bytes + at + 8, 4);
        if (get(bytes + at + 12, 4)) return XFB_FORMAT;
        memcpy(s->sha256, bytes + at + 24, 64); s->sha256[64] = 0;
        at += XFB_HEADER_BYTES;
        if (s->metadata_size > size - at) return XFB_FORMAT;
        s->metadata = bytes + at; at += s->metadata_size;
        if (s->size > size - at) return XFB_FORMAT;
        s->bytes = bytes + at; at += s->size;
        enum xfb_status status = source_limits(s, &result.input_bytes);
        if (status != XFB_OK) return status;
        if (digest(s->bytes, s->size, cancel, sha)) return XFB_CANCELLED;
        if (memcmp(sha, s->sha256, 64)) return XFB_CHECKSUM;
    }
    if (at != size) return XFB_FORMAT;
    result.count = count; *view = result;
    return XFB_OK;
}
const char *xfb_status_name(enum xfb_status status) {
    switch (status) {
    case XFB_OK: return "ok";
    case XFB_MEMORY: return "FrameMemoryLimit";
    case XFB_LIMIT: return "FrameInputLimit";
    case XFB_FORMAT: return "FrameBundleInvalid";
    case XFB_VERSION: return "FrameBundleVersion";
    case XFB_CHECKSUM: return "FrameBundleChecksum";
    case XFB_CANCELLED: return "FrameCancelled";
    case XFB_IO: return "FrameInputUnavailable";
    }
    return "FrameBundleInvalid";
}
