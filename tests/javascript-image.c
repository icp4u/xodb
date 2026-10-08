#define _GNU_SOURCE 1
#include "../src/language/javascript_image.h"
#include <assert.h>
#include <fcntl.h>
#include <gelf.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

struct source { struct xbo_source base; int changed, cancel; };
static enum xbo_status identity(void *context, struct xbo_identity *out) {
    struct source *s = context;
    return s->changed ? XBO_CHANGED : s->base.identity(s->base.context, out);
}
static enum xbo_status read_file(void *context, uint64_t address, void *out, size_t n) {
    struct source *s = context;
    return s->base.read(s->base.context, address, out, n);
}
static int cancelled(void *context) { return ((struct source *)context)->cancel; }
struct target {
    int fd; Elf *elf;
    struct source *source;
    uint64_t bias, pointer, constant, note;
    const char *mode;
};
static uint64_t symbol(Elf *elf, const char *name) {
    Elf_Scn *section = NULL;
    while ((section = elf_nextscn(elf, section))) {
        GElf_Shdr h; assert(gelf_getshdr(section, &h));
        if (h.sh_type != SHT_SYMTAB && h.sh_type != SHT_DYNSYM) continue;
        Elf_Data *data = elf_getdata(section, NULL); assert(data);
        for (size_t i = 0; i < h.sh_size / h.sh_entsize; ++i) {
            GElf_Sym s; assert(gelf_getsym(data, (int)i, &s));
            const char *text = elf_strptr(elf, h.sh_link, s.st_name); assert(text);
            if (!strcmp(text, name) && s.st_shndx != SHN_UNDEF) return s.st_value;
        }
    }
    return 0;
}
static int bytes(struct target *t, uint64_t address, void *out, size_t n) {
    size_t count; assert(!elf_getphdrnum(t->elf, &count));
    for (size_t i = 0; i < count; ++i) {
        GElf_Phdr p; assert(gelf_getphdr(t->elf, (int)i, &p));
        if (p.p_type != PT_LOAD || address < p.p_vaddr || address - p.p_vaddr > p.p_memsz ||
            n > p.p_memsz - (address - p.p_vaddr)) continue;
        uint64_t offset = address - p.p_vaddr;
        size_t size = offset >= p.p_filesz ? 0 : p.p_filesz - offset < n ? (size_t)(p.p_filesz - offset) : n;
        memset(out, 0, n);
        return !size || pread(t->fd, out, size, (off_t)(p.p_offset + offset)) == (ssize_t)size ? 0 : -1;
    }
    return -1;
}
static uint64_t word(const unsigned char *p) {
    uint64_t value = 0;
    for (size_t i = 0; i < 8; ++i) value |= (uint64_t)p[i] << (i * 8);
    return value;
}
static int memory(void *context, uint64_t address, void *out, size_t n) {
    struct target *t = context;
    if (!strcmp(t->mode, "memory") || address < t->bias) return -1;
    if (!strcmp(t->mode, "slow")) { struct timespec delay = {.tv_nsec = 100000000}; nanosleep(&delay, NULL); }
    address -= t->bias;
    if (bytes(t, address, out, n)) return -1;
    unsigned char *p = out;
    if (address == t->pointer && n == 8) {
        uint64_t value = word(p);
        value = !strcmp(t->mode, "pointer") ? UINT64_C(0x600000000000) : value + t->bias;
        for (size_t i = 0; i < 8; ++i) p[i] = (unsigned char)(value >> (i * 8));
    }
    if (!strcmp(t->mode, "constant") && address <= t->constant && t->constant - address < n)
        p[t->constant - address] ^= 1;
    if (!strcmp(t->mode, "note") && address == t->note) p[0] ^= 1;
    if (!strcmp(t->mode, "version") && address != t->pointer) {
        unsigned char pointer[8]; assert(!bytes(t, t->pointer, pointer, 8));
        if (address == word(pointer)) p[0] ^= 1;
    }
    if (!strcmp(t->mode, "change")) t->source->changed = 1;
    return 0;
}
int main(int argc, char **argv) {
    assert(argc == 5); /* file mode expected-status expected-reason */
    int fd = open(argv[1], O_RDONLY | O_CLOEXEC | O_NONBLOCK); assert(fd >= 0);
    struct xbo_local local = {fd};
    struct source source = {.base = xbo_local_source(&local)};
    struct xbo_source reader = {&source, identity, read_file};
    struct xbo_object *object; assert(xbo_create(&reader, &object) == XBO_OK);
    struct xbo_budget budget = {.bytes_left = 1048576, .reads_left = 65536};
    assert(xbo_prepare(object, &budget) == XBO_OK);
    struct xjs_image *image;
    assert(xjs_image_create(object, &image) == XBO_OK);
    struct xjs_layout layout, empty = {0};
    const char *reason;
    struct xjs_reader target_reader = {0};
    struct xjs_image_verifier *verifier;
    assert(xjs_image_verifier_create(image, 0, &verifier) == XBO_AGAIN && !verifier);
    source.cancel = 1;
    budget = (struct xbo_budget){.bytes_left = 1048576, .reads_left = 64, .context = &source, .cancelled = cancelled};
    assert(xjs_image_step(image, &budget, 128) == XBO_CANCELLED);
    source.cancel = 0;
    budget.deadline_ns = 1;
    assert(xjs_image_step(image, &budget, 128) == XBO_AGAIN);
    uint64_t slices = 0, charged = 0;
    enum xbo_status status;
    do {
        budget = (struct xbo_budget){.bytes_left = slices < 80 ? 17 : 262144,
            .reads_left = slices < 80 ? 1 : 64, .deadline_ns = xbo_now_ns() + UINT64_C(15000000)};
        status = xjs_image_step(image, &budget, slices < 80 ? 1 : 4096);
        charged += budget.bytes_read;
        assert(++slices < 1000000);
        if (status == XBO_AGAIN) {
            assert(xjs_image_verifier_create(image, 0, &verifier) == XBO_AGAIN && !verifier);
        }
    } while (status == XBO_AGAIN);
    struct xjs_image_progress progress; xjs_image_progress(image, &progress);
    if (status == XBO_OK) {
        assert(progress.complete);
        assert(elf_version(EV_CURRENT) != EV_NONE);
        Elf *elf = elf_begin(fd, ELF_C_READ, NULL); assert(elf);
        uint32_t note; assert(xbo_find_section(object, ".note.gnu.build-id", &note) == XBO_OK);
        struct target t = {.fd = fd, .elf = elf, .source = &source,
            .bias = UINT64_C(0x100000000), .mode = argv[2],
            .pointer = symbol(elf, "_ZN2v88internal7Version15version_string_E"),
            .constant = symbol(elf, "v8dbg_SystemPointerSize"), .note = xbo_section(object, note)->address};
        target_reader = (struct xjs_reader){.context = &t, .read = memory};
        assert(xjs_image_verifier_create(image, t.bias, &verifier) == XBO_OK);
        assert(xjs_image_verifier_result(verifier, &layout, &reason) == XBO_AGAIN);
        assert(!memcmp(&layout, &empty, sizeof layout));
        for (unsigned attempt = 0;; ++attempt) {
            assert(attempt < 100);
            budget = (struct xbo_budget){.bytes_left = 7, .reads_left = 1,
                .deadline_ns = xbo_now_ns() + UINT64_C(15000000), .context = &source, .cancelled = cancelled};
            if (!strcmp(argv[2], "cancel")) source.cancel = 1;
            if (!strcmp(argv[2], "deadline")) budget.deadline_ns = 1;
            if (!strcmp(argv[2], "budget")) budget.bytes_left = 0;
            size_t reads = target_reader.reads;
            status = xjs_image_verifier_step(verifier, &target_reader, &budget, 1);
            assert(target_reader.reads - reads <= 1);
            enum xbo_status published = xjs_image_verifier_result(verifier, &layout, &reason);
            if (status == XBO_CANCELLED) {
                assert(published == XBO_AGAIN); reason = "JavaScriptMetadataCancelled"; break;
            }
            if (status == XBO_AGAIN) {
                assert(published == XBO_AGAIN && !memcmp(&layout, &empty, sizeof layout));
                if (!strcmp(argv[2], "deadline") || (!strcmp(argv[2], "budget") && target_reader.reads == reads)) break;
                continue;
            }
            assert(published == status);
            break;
        }
        if (status == XBO_OK) {
            assert(layout.version[0] == 14 && layout.version[1] == 6 && layout.version[2] == 202 && layout.version[3] == 34);
            assert(!strcmp(layout.version_string, "14.6.202.34-node.28"));
            for (size_t i = 0; i < XJS_FIELD_COUNT; ++i) {
                uint64_t address = symbol(elf, xjs_field_names[i]);
                assert(layout.present[i] == !!address);
                if (address) {
                    unsigned char raw[8] = {0}; assert(!bytes(&t, address, raw, 4));
                    assert((uint32_t)layout.fields[i] == (uint32_t)word(raw));
                }
            }
            assert(!layout.dwarf_fields && !layout.dwarf_frame_config);
            assert(target_reader.reads < 32);
            printf("version=%s constants=%zu loaded-reads=%zu loaded-bytes=%zu\n",
                layout.version_string, progress.constants, target_reader.reads, target_reader.bytes);
        } else assert(!memcmp(&layout, &empty, sizeof layout));
        xjs_image_verifier_destroy(verifier);
        elf_end(elf);
    } else reason = xjs_image_error(image);
    if (strcmp(xbo_status_name(status), argv[3]) || strcmp(reason ? reason : "-", argv[4]))
        fprintf(stderr, "wanted %s/%s got %s/%s\n", argv[3], argv[4], xbo_status_name(status), reason ? reason : "-");
    assert(!strcmp(xbo_status_name(status), argv[3]) && !strcmp(reason ? reason : "-", argv[4]));
    printf("%s reason=%s slices=%" PRIu64 " source-bytes=%" PRIu64 "\n",
        xbo_status_name(status), reason ? reason : "-", slices, charged);
    if (status == XBO_OK) {
        source.changed = 1;
        budget = (struct xbo_budget){.bytes_left = 1048576, .reads_left = 64};
        assert(xjs_image_step(image, &budget, 4096) == XBO_CHANGED);
        source.changed = 0;
        assert(xjs_image_step(image, &budget, 4096) == XBO_CHANGED);
        assert(xjs_image_verifier_create(image, 0, &verifier) == XBO_CHANGED && !verifier);
    }
    xjs_image_destroy(image); xbo_destroy(object); close(fd);
    return 0;
}
