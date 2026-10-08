#define _GNU_SOURCE 1
#include "../src/binary/symbol_query.h"
#include <assert.h>
#include <fcntl.h>
#include <gelf.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

struct source { struct xbo_source base; int changed, cancel; };
static enum xbo_status identity(void *context, struct xbo_identity *out) {
    struct source *s = context;
    return s->changed ? XBO_CHANGED : s->base.identity(s->base.context, out);
}
static enum xbo_status read_bytes(void *context, uint64_t at, void *out, size_t n) {
    struct source *s = context;
    return s->base.read(s->base.context, at, out, n);
}
static int cancelled(void *context) { return ((struct source *)context)->cancel; }
static void oracle(int fd, const char *name, struct xbs_symbol *out) {
    assert(elf_version(EV_CURRENT) != EV_NONE);
    Elf *elf = elf_begin(fd, ELF_C_READ, NULL); assert(elf);
    memset(out, 0, sizeof *out);
    Elf_Scn *section = NULL;
    while ((section = elf_nextscn(elf, section))) {
        GElf_Shdr header; assert(gelf_getshdr(section, &header));
        if (header.sh_type != SHT_SYMTAB && header.sh_type != SHT_DYNSYM) continue;
        Elf_Data *data = elf_getdata(section, NULL); assert(data);
        for (size_t i = 0; i < header.sh_size / header.sh_entsize; ++i) {
            GElf_Sym sym; assert(gelf_getsym(data, (int)i, &sym));
            const char *str = elf_strptr(elf, header.sh_link, sym.st_name); assert(str);
            if (strcmp(str, name) || sym.st_shndx == SHN_UNDEF || sym.st_shndx >= SHN_LORESERVE) continue;
            GElf_Shdr defined; assert(gelf_getshdr(elf_getscn(elf, sym.st_shndx), &defined));
            if (!(defined.sh_flags & SHF_ALLOC)) continue;
            struct xbs_symbol result = {.address = sym.st_value, .size = sym.st_size,
                .section = sym.st_shndx, .type = GELF_ST_TYPE(sym.st_info),
                .binding = GELF_ST_BIND(sym.st_info), .present = 1};
            if (out->present) assert(out->address == result.address && out->size == result.size &&
                out->type == result.type && out->section == result.section);
            *out = result;
        }
    }
    elf_end(elf);
}
static void unpublished(struct xbs_query *q, size_t count, enum xbo_status status) {
    for (size_t i = 0; i < count; ++i) {
        struct xbs_symbol result, empty = {0}; memset(&result, 0xff, sizeof result);
        assert(xbs_result(q, i, &result) == status);
        assert(!memcmp(&result, &empty, sizeof result));
    }
}
int main(int argc, char **argv) {
    assert(argc >= 6); /* file status reason mode names... */
    int fd = open(argv[1], O_RDONLY | O_NONBLOCK | O_CLOEXEC); assert(fd >= 0);
    struct xbo_local local = {fd};
    struct source s = {.base = xbo_local_source(&local)};
    struct xbo_source source = {&s, identity, read_bytes};
    struct xbo_object *object; assert(xbo_create(&source, &object) == XBO_OK);
    size_t count = (size_t)argc - 5;
    struct xbs_query *query = (void *)1;
    assert(xbs_create(object, (const char *const *)argv + 5, count, &query) == XBO_MALFORMED && !query);
    struct xbo_budget budget = {.bytes_left = 1048576, .reads_left = 65536};
    assert(xbo_prepare(object, &budget) == XBO_OK);
    assert(xbs_create(object, (const char *const *)argv + 5, 0, &query) == XBO_MALFORMED && !query);
    assert(xbs_create(object, (const char *const *)argv + 5, XBS_NAMES + 1, &query) == XBO_LIMIT && !query);
    char long_name[XBS_NAME_BYTES + 1]; memset(long_name, 'x', sizeof long_name - 1); long_name[XBS_NAME_BYTES] = 0;
    const char *invalid[] = {long_name};
    assert(xbs_create(object, invalid, 1, &query) == XBO_LIMIT && !query);
    invalid[0] = "";
    assert(xbs_create(object, invalid, 1, &query) == XBO_LIMIT && !query);
    invalid[0] = NULL;
    assert(xbs_create(object, invalid, 1, &query) == XBO_MALFORMED && !query);
    char **names = calloc(count, sizeof *names); assert(names);
    for (size_t i = 0; i < count; ++i) { names[i] = strdup(argv[5 + i]); assert(names[i]); }
    assert(xbs_create(object, (const char *const *)names, count, &query) == XBO_OK);
    for (size_t i = 0; i < count; ++i) { memset(names[i], '!', strlen(names[i])); free(names[i]); }
    free(names);
    unpublished(query, count, XBO_AGAIN);
    s.cancel = 1;
    budget = (struct xbo_budget){.bytes_left = 1048576, .reads_left = 64, .context = &s, .cancelled = cancelled};
    assert(xbs_step(query, &budget, 1024) == XBO_CANCELLED);
    s.cancel = 0; budget.deadline_ns = 1;
    assert(xbs_step(query, &budget, 1024) == XBO_AGAIN);
    uint64_t slices = 0, bytes = 0, start = xbo_now_ns();
    int cancelled_midway = 0, change = !strcmp(argv[4], "change"), tiny = !strcmp(argv[4], "tiny");
    enum xbo_status status;
    struct xbs_progress progress;
    do {
        budget = (struct xbo_budget){.bytes_left = tiny || slices < 64 ? 17 : 262144,
            .reads_left = tiny || slices < 64 ? 1 : 64, .deadline_ns = xbo_now_ns() + UINT64_C(15000000)};
        status = xbs_step(query, &budget, slices < 64 ? 1 : 128);
        bytes += budget.bytes_read; assert(++slices < 2000000);
        assert(budget.bytes_read <= (tiny || slices <= 64 ? 17 : 262144));
        xbs_progress(query, &progress);
        if (status == XBO_AGAIN) {
            unpublished(query, count, XBO_AGAIN);
            if (!cancelled_midway && progress.symbols) {
                s.cancel = 1;
                budget = (struct xbo_budget){.bytes_left = 1048576, .reads_left = 64, .context = &s, .cancelled = cancelled};
                assert(xbs_step(query, &budget, 1024) == XBO_CANCELLED);
                unpublished(query, count, XBO_AGAIN);
                s.cancel = 0; cancelled_midway = 1;
                if (change) s.changed = 1;
            }
        }
    } while (status == XBO_AGAIN);
    const char *reason = xbs_error(query) ? xbs_error(query) : "-";
    if (strcmp(xbo_status_name(status), argv[2]) || strcmp(reason, argv[3]))
        fprintf(stderr, "wanted %s/%s; got %s/%s\n", argv[2], argv[3], xbo_status_name(status), reason);
    assert(!strcmp(xbo_status_name(status), argv[2]) && !strcmp(reason, argv[3]));
    assert(progress.memory_bytes < 1280 * 1024);
    if (status == XBO_OK) {
        assert(progress.complete);
        for (size_t i = 0; i < count; ++i) {
            struct xbs_symbol got, expected; oracle(fd, argv[5 + i], &expected);
            assert(xbs_result(query, i, &got) == (expected.present ? XBO_OK : XBO_NOT_FOUND));
            assert(got.present == expected.present && got.address == expected.address && got.size == expected.size &&
                got.section == expected.section && got.type == expected.type && got.binding == expected.binding);
            printf("symbol %s present=%u address=%" PRIu64 " size=%" PRIu64 " section=%u type=%u\n",
                argv[5 + i], got.present, got.address, got.size, got.section, got.type);
        }
        s.changed = 1;
        budget = (struct xbo_budget){.bytes_left = 1048576, .reads_left = 64};
        assert(xbs_step(query, &budget, 1024) == XBO_CHANGED);
        unpublished(query, count, XBO_CHANGED);
        s.changed = 0;
        assert(xbs_step(query, &budget, 1024) == XBO_CHANGED);
    } else {
        unpublished(query, count, status);
        s.changed = 0;
        assert(xbs_step(query, &budget, 1024) == status);
    }
    printf("%s reason=%s symbols=%" PRIu64 " sections=%" PRIu64 " memory=%" PRIu64
           " slices=%" PRIu64 " bytes=%" PRIu64 " seconds=%.6f\n", xbo_status_name(status), reason,
           progress.symbols, progress.sections, progress.memory_bytes, slices, bytes, (xbo_now_ns() - start) / 1e9);
    xbs_destroy(query); xbo_destroy(object); close(fd);
    return 0;
}
