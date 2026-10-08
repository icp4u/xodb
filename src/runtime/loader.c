#define _GNU_SOURCE 1
#include "xrt_loader.h"
#include "xrt_files.h"
#include "xrt_remote.h"
#include <elf.h>
#include <errno.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

struct reader {
    const struct xrt_target *target;
    struct xrt_loader *out;
    const volatile sig_atomic_t *cancel;
    uint64_t start;
    unsigned word;
    bool little;
};
static uint64_t now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000 + (uint64_t)ts.tv_nsec;
}
static uint64_t number(struct reader *r, const unsigned char *p, unsigned n)
{
    uint64_t value = 0;
    for (unsigned i = 0; i < n; ++i)
        value = (value << 8) | p[r->little ? n - i - 1 : i];
    return value;
}
static enum xrt_status read_bytes(struct reader *r, uint64_t address, void *out, size_t n)
{
    if (!address || n > UINT64_MAX - address)
        return XRT_INVALID_ADDRESS;
    if (r->cancel && *r->cancel) return XRT_DISCOVERY_CANCELLED;
    if (now() - r->start >= 2000000000) return XRT_DISCOVERY_PENDING;
    if (r->out->reads >= 128 || n > 128 * 1024 - r->out->bytes)
        return XRT_DISCOVERY_BUDGET;
    size_t got = 0;
    ++r->out->reads;
    enum xrt_status status = xrt_target_read(r->target, address, out, n, &got);
    r->out->bytes += got;
    return status != XRT_OK ? status : got == n ? XRT_OK : XRT_MEMORY_UNREADABLE;
}
#define TRY(expr) do { enum xrt_status s_ = (expr); if (s_ != XRT_OK) return s_; } while (0)
static enum xrt_status word_at(struct reader *r, uint64_t address, unsigned width, uint64_t *out)
{
    unsigned char bytes[8];
    TRY(read_bytes(r, address, bytes, width));
    *out = number(r, bytes, width);
    return XRT_OK;
}
struct dynamic {
    uint64_t debug, strings, symbols, hash, gnu_hash, string_size, symbol_size;
};
static enum xrt_status dynamic_at(struct reader *r, uint64_t address, uint64_t size,
                                  uint64_t bias, struct dynamic *out)
{
    unsigned char bytes[16384];
    const unsigned stride = r->word * 2;
    if (!address || size < stride || size > sizeof(bytes))
        return XRT_FILE_UNAVAILABLE;
    TRY(read_bytes(r, address, bytes, (size_t)size));
    for (size_t at = 0; at + stride <= size; at += stride) {
        uint64_t tag = number(r, bytes + at, r->word);
        uint64_t value = number(r, bytes + at + r->word, r->word);
        if (tag == DT_NULL)
            return XRT_OK;
        if (tag == DT_DEBUG) out->debug = value;
        if (tag == DT_SYMENT) out->symbol_size = value;
        if (tag == DT_STRSZ) out->string_size = value;
        /* A loader's own dynamic pointers can still be link-time values at
         * the exec stop; glibc relocates them before normal application stops. */
        if (value && value < bias) {
            if (value > UINT64_MAX - bias) return XRT_INVALID_ADDRESS;
            value += bias;
        }
        if (tag == DT_STRTAB) out->strings = value;
        if (tag == DT_SYMTAB) out->symbols = value;
        if (tag == DT_HASH) out->hash = value;
        if (tag == DT_GNU_HASH) out->gnu_hash = value;
    }
    return XRT_FILE_UNAVAILABLE;
}
static enum xrt_status program_headers(struct reader *r, uint64_t phdr, uint64_t count,
                                       uint64_t stride, uint64_t bias, bool known_bias,
                                       struct dynamic *out)
{
    unsigned char bytes[8192];
    if (!count || count > 128 || stride != (r->word == 8 ? 56 : 32) ||
        count > sizeof(bytes) / stride)
        return XRT_FILE_UNAVAILABLE;
    TRY(read_bytes(r, phdr, bytes, (size_t)(count * stride)));
    uint64_t dynamic = 0, size = 0;
    for (uint64_t i = 0; i < count; ++i) {
        const unsigned char *p = bytes + i * stride;
        uint64_t type = number(r, p, 4);
        uint64_t vaddr = number(r, p + (r->word == 8 ? 16 : 8), r->word);
        if (type == PT_PHDR && !known_bias) {
            if (phdr < vaddr) return XRT_INVALID_ADDRESS;
            bias = phdr - vaddr;
            known_bias = true;
        }
        if (type == PT_DYNAMIC) {
            dynamic = vaddr;
            size = number(r, p + (r->word == 8 ? 32 : 16), r->word);
        }
    }
    if (!known_bias || !dynamic || dynamic > UINT64_MAX - bias)
        return XRT_FILE_UNAVAILABLE;
    return dynamic_at(r, bias + dynamic, size, bias, out);
}
static enum xrt_status symbol(struct reader *r, const struct dynamic *d, uint64_t bias,
                               const char *name, uint64_t *address)
{
    unsigned char bytes[32];
    size_t length = strlen(name);
    if (length >= sizeof(bytes) || !d->symbols || !d->strings ||
        d->symbol_size != (r->word == 8 ? 24 : 16))
        return XRT_FILE_UNAVAILABLE;
    uint64_t index = 0, chains = 0, count = 0;
    uint32_t hash = 5381;
    if (d->gnu_hash) {
        for (const unsigned char *p = (const unsigned char *)name; *p; ++p)
            hash = hash * 33 + *p;
        TRY(read_bytes(r, d->gnu_hash, bytes, 16));
        uint64_t buckets = number(r, bytes, 4), first = number(r, bytes + 4, 4);
        uint64_t bloom = number(r, bytes + 8, 4);
        if (!buckets || buckets > 1048576 || bloom > 1048576 || first > 1048576 ||
            d->gnu_hash > UINT64_MAX - (16 + bloom * r->word + buckets * 4))
            return XRT_FILE_UNAVAILABLE;
        uint64_t table = d->gnu_hash + 16 + bloom * r->word;
        TRY(word_at(r, table + (hash % buckets) * 4, 4, &index));
        if (index < first || index > 1048576) return XRT_FILE_UNAVAILABLE;
        chains = table + buckets * 4;
        count = first;
    } else if (d->hash) {
        hash = 0;
        for (const unsigned char *p = (const unsigned char *)name; *p; ++p) {
            hash = (hash << 4) + *p;
            uint32_t high = hash & 0xf0000000;
            if (high) hash ^= high >> 24;
            hash &= ~high;
        }
        TRY(read_bytes(r, d->hash, bytes, 8));
        uint64_t buckets = number(r, bytes, 4);
        count = number(r, bytes + 4, 4);
        if (!buckets || buckets > 1048576 || count > 1048576 ||
            d->hash > UINT64_MAX - (8 + buckets * 4 + count * 4))
            return XRT_FILE_UNAVAILABLE;
        TRY(word_at(r, d->hash + 8 + (hash % buckets) * 4, 4, &index));
        chains = d->hash + 8 + buckets * 4;
    } else return XRT_FILE_UNAVAILABLE;
    for (unsigned steps = 0; steps < 64 && index; ++steps) {
        if (index > 1048576 || (!d->gnu_hash && index >= count) ||
            d->symbols > UINT64_MAX - index * d->symbol_size)
            return XRT_FILE_UNAVAILABLE;
        TRY(read_bytes(r, d->symbols + index * d->symbol_size, bytes, (size_t)d->symbol_size));
        uint64_t str = number(r, bytes, 4);
        uint64_t value = number(r, bytes + (r->word == 8 ? 8 : 4), r->word);
        uint64_t section = number(r, bytes + (r->word == 8 ? 6 : 14), 2);
        if (section && str < d->string_size && length < d->string_size - str &&
            d->strings <= UINT64_MAX - str && bias <= UINT64_MAX - value) {
            TRY(read_bytes(r, d->strings + str, bytes, length + 1));
            if (!memcmp(bytes, name, length + 1)) {
                *address = bias + value;
                return XRT_OK;
            }
        }
        uint64_t next = 0;
        uint64_t offset = (d->gnu_hash ? index - count : index) * 4;
        if (chains > UINT64_MAX - offset) return XRT_INVALID_ADDRESS;
        TRY(word_at(r, chains + offset, 4, &next));
        if (d->gnu_hash) {
            if (next & 1) break;
            ++index;
        } else index = next;
    }
    return XRT_FILE_UNAVAILABLE;
}
static enum xrt_status auxiliary(struct reader *r, struct xrt_auxv *out)
{
    unsigned char aux[4096];
    int fd = -1;
    struct xrt_file_request request = {.kind = XRT_FILE_AUXV};
    TRY(xrt_target_file(r->target, &request, &fd));
    ssize_t n;
    do { n = read(fd, aux, sizeof aux); } while (n < 0 && errno == EINTR);
    close(fd);
    if (n <= 0 || n == sizeof aux || (size_t)n % (r->word * 2)) return XRT_FILE_UNAVAILABLE;
    r->out->bytes += (uint64_t)n;
    unsigned seen = 0;
    for (size_t i = 0; i + r->word * 2 <= (size_t)n; i += r->word * 2) {
        uint64_t key = number(r, aux + i, r->word);
        uint64_t value = number(r, aux + i + r->word, r->word);
        if (key == AT_NULL) return XRT_OK;
        uint64_t *field = NULL; unsigned bit = 0;
        if (key == AT_PHDR) { field = &out->main_phdr; bit = 1; }
        if (key == AT_PHNUM) { field = &out->phnum; bit = 2; }
        if (key == AT_PHENT) { field = &out->phent; bit = 4; }
        if (key == AT_BASE) { field = &out->interpreter; bit = 8; }
        if (key == AT_PAGESZ) { field = &out->page_size; bit = 16; }
        if (key == AT_ENTRY) { field = &out->entry; bit = 32; }
        if (field) {
            if (seen & bit) return XRT_FILE_UNAVAILABLE;
            seen |= bit; *field = value;
        }
    }
    return XRT_FILE_UNAVAILABLE;
}
enum xrt_status xrt_target_auxv(const struct xrt_target *target, struct xrt_auxv *out)
{
    if (!target || !out) return XRT_INVALID_ARGUMENT;
    *out = (struct xrt_auxv){0};
    struct xrt_target_view view;
    xrt_target_view(target, &view);
    if (view.state != XRT_STOPPED) return XRT_NOT_STOPPED;
    const struct xrt_arch *arch = xrt_target_arch(target);
    if (!arch || (arch->address_bits != 32 && arch->address_bits != 64)) return XRT_UNSUPPORTED_ARCHITECTURE;
    struct xrt_loader stats = {0};
    struct reader r = {.target=target, .out=&stats, .word=arch->address_bits/8, .little=arch->little_endian};
    struct xrt_auxv values = {0};
    enum xrt_status status = auxiliary(&r, &values);
    if (status != XRT_OK) return status;
    if (!values.main_phdr || !values.page_size || values.page_size & (values.page_size-1)) return XRT_FILE_UNAVAILABLE;
    *out = values;
    return XRT_OK;
}
static enum xrt_status discover(struct reader *r)
{
    struct xrt_auxv aux = {0};
    TRY(auxiliary(r, &aux));
    r->out->main_phdr = aux.main_phdr;
    r->out->interpreter = aux.interpreter;
    uint64_t count = aux.phnum, stride = aux.phent;
    struct dynamic main = {0};
    enum xrt_status status = program_headers(r, r->out->main_phdr, count, stride, 0, false, &main);
    if (status == XRT_OK && main.debug) {
        r->out->debug_address = main.debug;
        if (main.debug > UINT64_MAX - (r->word == 8 ? 16 : 8)) return XRT_INVALID_ADDRESS;
        TRY(word_at(r, main.debug + (r->word == 8 ? 16 : 8), r->word, &r->out->break_address));
        if (r->out->break_address) return XRT_OK;
    }
    /* Before DT_DEBUG/r_brk is initialized, inspect only the interpreter's
     * dynamic exports. AT_BASE comes from the kernel, not a filename guess. */
    uint64_t base = r->out->interpreter;
    if (!base) return XRT_FILE_UNAVAILABLE;
    unsigned char header[64];
    TRY(read_bytes(r, base, header, sizeof(header)));
    if (memcmp(header, ELFMAG, SELFMAG) || header[EI_CLASS] != (r->word == 8 ? ELFCLASS64 : ELFCLASS32) ||
        header[EI_DATA] != (r->little ? ELFDATA2LSB : ELFDATA2MSB))
        return XRT_FILE_UNAVAILABLE;
    uint64_t offset = number(r, header + (r->word == 8 ? 32 : 28), r->word);
    stride = number(r, header + (r->word == 8 ? 54 : 42), 2);
    count = number(r, header + (r->word == 8 ? 56 : 44), 2);
    if (base > UINT64_MAX - offset) return XRT_INVALID_ADDRESS;
    struct dynamic loader = {0};
    TRY(program_headers(r, base + offset, count, stride, base, true, &loader));
    TRY(symbol(r, &loader, base, "_r_debug", &r->out->debug_address));
    TRY(symbol(r, &loader, base, "_dl_debug_state", &r->out->break_address));
    return XRT_OK;
}
enum xrt_status xrt_target_loader(const struct xrt_target *target, struct xrt_loader *out,
                                  const volatile sig_atomic_t *cancel)
{
    if (!target || !out) return XRT_INVALID_ARGUMENT;
    *out = (struct xrt_loader){0};
    struct xrt_target_view view;
    xrt_target_view(target, &view);
    if (view.state != XRT_STOPPED) return XRT_NOT_STOPPED;
    const struct xrt_arch *arch = xrt_target_arch(target);
    struct reader r = {.target = target, .out = out, .cancel = cancel, .start = now(),
                       .word = arch->address_bits / 8, .little = arch->little_endian};
    if (r.word != 4 && r.word != 8) return XRT_UNSUPPORTED_ARCHITECTURE;
    enum xrt_status status = discover(&r);
    out->elapsed_ns = now() - r.start;
    return status;
}
