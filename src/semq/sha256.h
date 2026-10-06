#ifndef XODB_XSQ_SHA256_H
#define XODB_XSQ_SHA256_H
#include <stddef.h>

#include <stdint.h>

/* FIPS 180-4 SHA-256 of a buffer as 64 lowercase hex digits plus NUL. */
void xsq_sha256_hex(const void *data, size_t size, char out[65]);

/* Incremental form (lets the loader poll cancellation between chunks). */
struct xsq_sha256 { uint32_t h[8]; unsigned char buf[64]; size_t fill; uint64_t total; };
void xsq_sha256_init(struct xsq_sha256 *s);
void xsq_sha256_update(struct xsq_sha256 *s, const void *data, size_t size);
void xsq_sha256_final(struct xsq_sha256 *s, char out[65]);
#endif
