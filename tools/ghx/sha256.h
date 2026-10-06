/* Minimal SHA-256 (FIPS 180-4). C01 candidate, GPLv3 as xodb. */
#ifndef GHX_SHA256_H
#define GHX_SHA256_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
struct ghx_sha256 { uint32_t h[8]; uint64_t n; unsigned char buf[64]; size_t used; };
void ghx_sha256_init(struct ghx_sha256 *s);
void ghx_sha256_update(struct ghx_sha256 *s, const void *p, size_t len);
void ghx_sha256_final(struct ghx_sha256 *s, unsigned char out[32]);
/* hex digest of whole file; returns 0 or -1 (errno set) */
int ghx_sha256_file(const char *path, char hex[65]);
void ghx_sha256_hex(const void *p, size_t len, char hex[65]);
#ifdef __cplusplus
}
#endif
#endif
