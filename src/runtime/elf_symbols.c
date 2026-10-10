#define _GNU_SOURCE 1
#define _FILE_OFFSET_BITS 64
#include "elf_symbols.h"
#include <elf.h>
#include <errno.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

struct image {
    xrt_elf_read read;
    void *context;
    int fd;
    uint64_t size, copied;
    bool wide, little;
};
static uint64_t number(const struct image *im, const unsigned char *p, unsigned n)
{
    uint64_t v = 0;
    for (unsigned i = 0; i < n; ++i)
        v = (v << 8) | p[im->little ? n - i - 1 : i];
    return v;
}
static uint64_t word(const struct image *im, const unsigned char *p, unsigned at64, unsigned at32)
{
    return number(im, p + (im->wide ? at64 : at32), im->wide ? 8 : 4);
}
static enum xrt_status store(int fd, uint64_t at, const void *bytes, size_t n)
{
    const unsigned char *p = bytes;
    while (n) {
        ssize_t got = pwrite(fd, p, n, (off_t)at);
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0) return XRT_FILE_UNAVAILABLE;
        p += got; at += (uint64_t)got; n -= (size_t)got;
    }
    return XRT_OK;
}
#define TRY(e) do { enum xrt_status s_ = (e); if (s_ != XRT_OK) return s_; } while (0)
static enum xrt_status copy(struct image *im, uint64_t at, uint64_t n, unsigned char *out)
{
    if (at > im->size || n > im->size - at) return XRT_INVALID_ARGUMENT;
    if (n > UINT64_C(64) * 1024 * 1024 - im->copied) return XRT_FILE_LIMIT;
    im->copied += n;
    unsigned char scratch[65536];
    while (n) {
        size_t count = n < sizeof(scratch) ? (size_t)n : sizeof(scratch);
        unsigned char *dst = out ? out : scratch;
        TRY(im->read(im->context, at, dst, count));
        TRY(store(im->fd, at, dst, count));
        at += count; n -= count;
        if (out) out += count;
    }
    return XRT_OK;
}
static enum xrt_status tables(struct image *im, unsigned char *header)
{
    const unsigned phsize = im->wide ? 56 : 32, shsize = im->wide ? 64 : 40;
    uint64_t phoff = word(im, header, 32, 28), shoff = word(im, header, 40, 32);
    uint64_t phnum = number(im, header + (im->wide ? 56 : 44), 2);
    uint64_t shnum = number(im, header + (im->wide ? 60 : 48), 2);
    uint64_t names_index = number(im, header + (im->wide ? 62 : 50), 2);
    if (shoff) {
        if (number(im, header + (im->wide ? 58 : 46), 2) != shsize)
            return XRT_INVALID_ARGUMENT;
        unsigned char zero[64];
        TRY(copy(im, shoff, shsize, zero));
        if (!shnum) shnum = word(im, zero, 32, 20);
        if (phnum == PN_XNUM) phnum = number(im, zero + (im->wide ? 44 : 28), 4);
        if (names_index == SHN_XINDEX) names_index = number(im, zero + (im->wide ? 40 : 24), 4);
    } else {
        if (phnum == PN_XNUM) return XRT_INVALID_ARGUMENT;
        shnum = 0;
    }
    /* Bounds on metadata, independently of file size or transfer policy. */
    if (phnum > 4096 || shnum > 65536) return XRT_FILE_LIMIT;
    if (phnum && number(im, header + (im->wide ? 54 : 42), 2) != phsize)
        return XRT_INVALID_ARGUMENT;
    if (phnum) {
        unsigned char *programs = malloc((size_t)phnum * phsize);
        if (!programs) return XRT_OUT_OF_MEMORY;
        enum xrt_status status = copy(im, phoff, phnum * phsize, programs);
        for (uint64_t i = 0; status == XRT_OK && i < phnum; ++i) {
            const unsigned char *p = programs + i * phsize;
            uint64_t type = number(im, p, 4);
            if (type == PT_NOTE || type == PT_DYNAMIC)
                status = copy(im, word(im, p, 8, 4), word(im, p, 32, 16), NULL);
        }
        free(programs);
        if (status != XRT_OK) return status;
    }
    if (!shnum) return XRT_OK;
    size_t n = (size_t)shnum * shsize;
    unsigned char *sections = malloc(n);
    unsigned char *names = NULL;
    uint64_t names_size = 0;
    bool *selected = calloc((size_t)shnum, sizeof(*selected));
    if (!sections || !selected) { free(sections); free(selected); return XRT_OUT_OF_MEMORY; }
    enum xrt_status result = copy(im, shoff, n, sections);
    if (result != XRT_OK) goto done;
    if (names_index) {
        if (names_index >= shnum) { result = XRT_INVALID_ARGUMENT; goto done; }
        const unsigned char *s = sections + names_index * shsize;
        if (number(im, s + 4, 4) != SHT_STRTAB) { result = XRT_INVALID_ARGUMENT; goto done; }
        names_size = word(im, s, 32, 20);
        uint64_t names_offset = word(im, s, 24, 16);
        if (names_offset > im->size || names_size > im->size - names_offset) { result = XRT_INVALID_ARGUMENT; goto done; }
        if (names_size > UINT64_C(64) * 1024 * 1024 - im->copied) { result = XRT_FILE_LIMIT; goto done; }
        if (names_size) {
            names = malloc((size_t)names_size);
            if (!names) { result = XRT_OUT_OF_MEMORY; goto done; }
            result = copy(im, names_offset, names_size, names);
            if (result != XRT_OK) goto done;
        }
    }
    for (uint64_t i = 1; i < shnum; ++i) {
        const unsigned char *s = sections + i * shsize;
        uint64_t type = number(im, s + 4, 4);
        if (type == SHT_NOTE) { selected[i] = true; continue; }
        uint64_t name = number(im, s, 4);
        if (type == SHT_PROGBITS && name < names_size &&
            sizeof(".gnu_debuglink") <= names_size - name &&
            !memcmp(names + name, ".gnu_debuglink", sizeof(".gnu_debuglink"))) {
            selected[i] = true; continue;
        }
        if (type != SHT_SYMTAB && type != SHT_DYNSYM && type != SHT_SYMTAB_SHNDX) continue;
        uint64_t link = number(im, s + (im->wide ? 40 : 24), 4);
        if (link >= shnum) { result = XRT_INVALID_ARGUMENT; goto done; }
        uint64_t linked_type = number(im, sections + link * shsize + 4, 4);
        if ((type == SHT_SYMTAB_SHNDX && linked_type != SHT_SYMTAB && linked_type != SHT_DYNSYM) ||
            (type != SHT_SYMTAB_SHNDX && linked_type != SHT_STRTAB)) {
            result = XRT_INVALID_ARGUMENT; goto done;
        }
        selected[i] = true;
        selected[link] = true;
    }
    for (uint64_t i = 1; i < shnum; ++i) {
        if (!selected[i] || i == names_index) continue;
        const unsigned char *s = sections + i * shsize;
        result = copy(im, word(im, s, 24, 16), word(im, s, 32, 20), NULL);
        if (result != XRT_OK) goto done;
    }
done:
    free(sections); free(selected); free(names);
    return result;
}
enum xrt_status xrt_elf_symbols(xrt_elf_read read, void *context, int fd, uint64_t size)
{
    struct image im = {.read = read, .context = context, .fd = fd, .size = size};
    unsigned char header[64];
    if (size < 16) return XRT_FILE_UNAVAILABLE;
    TRY(read(context, 0, header, 16));
    if (!memcmp(header, "PK\3\4", 4)) return XRT_UNSUPPORTED_MODE;
    if (memcmp(header, ELFMAG, SELFMAG)) return XRT_FILE_UNAVAILABLE;
    if ((header[EI_CLASS] != ELFCLASS32 && header[EI_CLASS] != ELFCLASS64) ||
        (header[EI_DATA] != ELFDATA2LSB && header[EI_DATA] != ELFDATA2MSB) ||
        header[EI_VERSION] != EV_CURRENT) return XRT_INVALID_ARGUMENT;
    im.wide = header[EI_CLASS] == ELFCLASS64;
    im.little = header[EI_DATA] == ELFDATA2LSB;
    size_t hsize = im.wide ? 64 : 52;
    TRY(copy(&im, 0, hsize, header));
    uint64_t type = number(&im, header + 16, 2);
    if ((type != ET_EXEC && type != ET_DYN) || number(&im, header + 20, 4) != EV_CURRENT ||
        number(&im, header + (im.wide ? 52 : 40), 2) != hsize) return XRT_INVALID_ARGUMENT;
    TRY(tables(&im, header));
    /* Names and .gnu_debuglink allow verified companion discovery. DWARF,
     * unwind and code contents remain absent; this is only a symbol view. */
    return store(fd, 0, header, hsize);
}
