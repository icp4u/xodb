// Synthetic jitdump writer for tests and seeds. swap=1 writes the opposite
// of the host byte order. Not a producer: the owned fixture writes its own.
#ifndef XODB_JITMAP_BUILD_H
#define XODB_JITMAP_BUILD_H
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

struct jb {
    uint8_t *bytes;
    size_t len, cap;
    int swap;
    size_t debug_at; /* open debug record offset */
};

static inline void jb_init(struct jb *b, int swap)
{
    memset(b, 0, sizeof *b);
    b->swap = swap;
}

static inline void jb_free(struct jb *b)
{
    free(b->bytes);
    memset(b, 0, sizeof *b);
}

static inline void jb_put(struct jb *b, const void *p, size_t n)
{
    if (b->len + n > b->cap) {
        size_t cap = b->cap ? b->cap : 256;
        while (cap < b->len + n)
            cap *= 2;
        uint8_t *grown = realloc(b->bytes, cap);
        if (!grown)
            abort();
        b->bytes = grown;
        b->cap = cap;
    }
    memcpy(b->bytes + b->len, p, n);
    b->len += n;
}

static inline void jb_u32(struct jb *b, uint32_t v)
{
    if (b->swap)
        v = __builtin_bswap32(v);
    jb_put(b, &v, 4);
}

static inline void jb_u64(struct jb *b, uint64_t v)
{
    if (b->swap)
        v = __builtin_bswap64(v);
    jb_put(b, &v, 8);
}

static inline void jb_patch32(struct jb *b, size_t at, uint32_t v)
{
    if (b->swap)
        v = __builtin_bswap32(v);
    memcpy(b->bytes + at, &v, 4);
}

static inline void jb_patch64(struct jb *b, size_t at, uint64_t v)
{
    if (b->swap)
        v = __builtin_bswap64(v);
    memcpy(b->bytes + at, &v, 8);
}

static inline void jb_header(struct jb *b, uint32_t pid, uint64_t time, uint64_t flags)
{
    jb_u32(b, 0x4A695444u);
    jb_u32(b, 1);
    jb_u32(b, 40);
    jb_u32(b, 62); /* EM_X86_64 */
    jb_u32(b, 0);
    jb_u32(b, pid);
    jb_u64(b, time);
    jb_u64(b, flags);
}

static inline void jb_prefix(struct jb *b, uint32_t id, uint32_t size, uint64_t time)
{
    jb_u32(b, id);
    jb_u32(b, size);
    jb_u64(b, time);
}

static inline void jb_load(struct jb *b, uint64_t time, uint32_t pid, uint32_t tid, uint64_t addr, uint64_t size,
                    uint64_t index, const char *name, uint8_t fill)
{
    size_t n = strlen(name) + 1;
    uint64_t code = size <= 4096 ? size : 0; /* large ranges carry no bytes */
    jb_prefix(b, 0, (uint32_t)(56 + n + code), time);
    jb_u32(b, pid);
    jb_u32(b, tid);
    jb_u64(b, addr);
    jb_u64(b, addr);
    jb_u64(b, size);
    jb_u64(b, index);
    jb_put(b, name, n);
    for (uint64_t i = 0; i < code; ++i)
        jb_put(b, &fill, 1);
}

static inline void jb_load_unterminated(struct jb *b, uint64_t time, uint32_t pid, uint64_t addr)
{
    jb_prefix(b, 0, 56 + 4, time);
    jb_u32(b, pid);
    jb_u32(b, 1);
    jb_u64(b, addr);
    jb_u64(b, addr);
    jb_u64(b, 1);
    jb_u64(b, 99);
    jb_put(b, "abcd", 4);
}

static inline void jb_move(struct jb *b, uint64_t time, uint32_t pid, uint32_t tid, uint64_t from, uint64_t to,
                    uint64_t size, uint64_t index)
{
    jb_prefix(b, 1, 64, time);
    jb_u32(b, pid);
    jb_u32(b, tid);
    jb_u64(b, to);
    jb_u64(b, from);
    jb_u64(b, to);
    jb_u64(b, size);
    jb_u64(b, index);
}

/* Debug record: begin, add entries, size is patched by each entry; padded to 8. */
static inline void jb_debug_begin(struct jb *b, uint64_t time, uint64_t code_addr, uint64_t count)
{
    b->debug_at = b->len;
    jb_prefix(b, 2, 32, time);
    jb_u64(b, code_addr);
    jb_u64(b, count);
}

static inline void jb_debug_entry(struct jb *b, uint64_t addr, uint32_t line, uint32_t discrim, const char *file)
{
    jb_u64(b, addr);
    jb_u32(b, line);
    jb_u32(b, discrim);
    jb_put(b, file, strlen(file) + 1);
    jb_patch32(b, b->debug_at + 4, (uint32_t)(b->len - b->debug_at));
}

static inline void jb_unwind(struct jb *b, uint64_t time, uint64_t size, uint64_t hdr, uint64_t mapped)
{
    uint64_t padded = (size + 7) & ~7ull;
    jb_prefix(b, 4, (uint32_t)(40 + padded), time);
    jb_u64(b, size);
    jb_u64(b, hdr);
    jb_u64(b, mapped);
    for (uint64_t i = 0; i < padded; ++i) {
        uint8_t z = (uint8_t)i;
        jb_put(b, &z, 1);
    }
}

static inline void jb_close(struct jb *b, uint64_t time)
{
    jb_prefix(b, 3, 16, time);
}

/* Arbitrary id and declared size; body is zero-filled when size >= 16. */
static inline void jb_raw_record(struct jb *b, uint32_t id, uint32_t size, uint64_t time)
{
    jb_prefix(b, id, size, time);
    for (uint32_t i = 16; i < size; ++i) {
        uint8_t z = 0;
        jb_put(b, &z, 1);
    }
}
#endif
