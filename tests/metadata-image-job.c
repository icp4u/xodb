#define _GNU_SOURCE 1
#include "../src/debug/metadata_job.h"
#include "../src/runtime/xrt_loader.h"
#include "../src/runtime/xrt_remote.h"
#include "../src/runtime/remote_internal.h"
#include <assert.h>
#include <fcntl.h>
#include <gelf.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <time.h>
#include <unistd.h>

static void ok(enum xrt_status status) {
    if (status != XRT_OK) fprintf(stderr, "runtime status=%u\n", status);
    assert(status == XRT_OK);
}
static uint64_t main_symbol(Elf *elf) {
    Elf_Scn *section = NULL;
    while ((section = elf_nextscn(elf, section))) {
        GElf_Shdr h; assert(gelf_getshdr(section, &h));
        if (h.sh_type != SHT_SYMTAB && h.sh_type != SHT_DYNSYM) continue;
        Elf_Data *data = elf_getdata(section, NULL); assert(data);
        for (size_t i = 0; i < h.sh_size / h.sh_entsize; ++i) {
            GElf_Sym symbol; assert(gelf_getsym(data, (int)i, &symbol));
            const char *name = elf_strptr(elf, h.sh_link, symbol.st_name); assert(name);
            if (!strcmp(name, "main") && symbol.st_shndx != SHN_UNDEF) return symbol.st_value;
        }
    }
    return 0;
}
static uint64_t phdr_address(Elf *elf) {
    GElf_Ehdr header; assert(gelf_getehdr(elf, &header));
    size_t count; assert(!elf_getphdrnum(elf, &count));
    for (size_t i = 0; i < count; ++i) {
        GElf_Phdr p; assert(gelf_getphdr(elf, (int)i, &p));
        if (p.p_type == PT_LOAD && header.e_phoff >= p.p_offset &&
            header.e_phoff - p.p_offset < p.p_filesz)
            return p.p_vaddr + header.e_phoff - p.p_offset;
    }
    assert(0); return 0;
}
static struct xrt_mapping mapping(struct xrt_target *target, uint64_t phdr,
                                  const char *path, const struct stat *stat) {
    int fd; const struct xrt_file_request request = {.kind = XRT_FILE_MAPS};
    ok(xrt_target_file(target, &request, &fd));
    FILE *file = fdopen(fd, "r"); assert(file);
    char *line = NULL; size_t capacity = 0;
    struct xrt_mapping out = {0};
    while (getline(&line, &capacity, file) >= 0) {
        uint64_t low, high, offset, maj, min, inode; char permissions[5];
        if (sscanf(line, "%" SCNx64 "-%" SCNx64 " %4s %" SCNx64 " %" SCNx64 ":%" SCNx64 " %" SCNu64,
            &low, &high, permissions, &offset, &maj, &min, &inode) != 7) continue;
        if (phdr < low || phdr >= high) continue;
        assert(maj == major(stat->st_dev) && min == minor(stat->st_dev) && inode == stat->st_ino);
        out = (struct xrt_mapping){low, high, offset, maj, min, inode, path}; break;
    }
    free(line); fclose(file); assert(out.end); return out;
}
static int read_target(void *target, uint64_t address, void *out, size_t n) {
    size_t got = 0;
    return xrt_target_read(target, address, out, n, &got) == XRT_OK && got == n ? 0 : -1;
}
int main(int argc, char **argv) {
    assert(argc == 6); /* image agent cache field-mask mode */
    setvbuf(stdout, NULL, _IONBF, 0);
    int fd = open(argv[1], O_RDONLY | O_CLOEXEC | O_NONBLOCK); assert(fd >= 0);
    struct stat st; assert(!fstat(fd, &st));
    assert(elf_version(EV_CURRENT) != EV_NONE);
    Elf *elf = elf_begin(fd, ELF_C_READ, NULL); assert(elf);
    struct xrt_target *target;
    int remote = strcmp(argv[2], "-") != 0;
    if (remote) { const char *command[] = {argv[2], "--stdio", NULL}; ok(xrt_target_remote(command, &target)); }
    else target = xrt_target_create();
    assert(target);
    const char *command[] = {argv[1], "-e", "for (;;) {}", NULL};
    ok(xrt_target_launch(target, command));
    struct xrt_loader loader;
    ok(xrt_target_loader(target, &loader, NULL));
    uint64_t expected_bias = loader.main_phdr - phdr_address(elf);
    uint64_t main = main_symbol(elf); assert(main);
    elf_end(elf);
    uint64_t breakpoint;
    ok(xrt_target_breakpoint_set(target, expected_bias + main, false, &breakpoint));
    ok(xrt_target_continue(target)); ok(xrt_target_wait_stopped(target));
    struct xrt_target_view target_view; xrt_target_view(target, &target_view);
    assert(target_view.state == XRT_STOPPED && target_view.thread_count);
    assert(target_view.threads[0].reason == XRT_STOP_BREAKPOINT);
    uint64_t generation = target_view.generation, epoch = target_view.image_epoch;
    struct xrt_file_request request = {.kind = XRT_FILE_MAPPED,
        .mapping = mapping(target, loader.main_phdr, argv[1], &st)};
    struct xrt_file_view *view;
    ok(xrt_target_file_view_open(target, &request, &view));
    int managed = !strcmp(argv[3], "@");
    int cache_fd = strcmp(argv[3], "-") && !managed ? open(argv[3], O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0600) : -1;
    if (strcmp(argv[3], "-") && !managed) assert(cache_fd >= 0);
    struct xmd_job *job;
    assert((managed ? xmd_start_javascript_cached(view, &job) :
        xmd_start_javascript(view, cache_fd, UINT64_C(8) * 1024 * 1024 * 1024, &job)) == XBO_OK);
    if (cache_fd >= 0) close(cache_fd);
    uint64_t start = xbo_now_ns(), max_poll = 0, max_rpc = 0, polls = 0, rpcs = 0;
    struct xmd_snapshot snapshot;
    for (;;) {
        uint64_t before = xbo_now_ns(); xmd_poll(job, &snapshot);
        uint64_t elapsed = xbo_now_ns() - before; if (elapsed > max_poll) max_poll = elapsed; ++polls;
        if (snapshot.state == XMD_READY || snapshot.state == XMD_FAILED || snapshot.state == XMD_CANCELLED) break;
        assert(!snapshot.profile.fields);
        if (remote && rpcs < 20) {
            before = xbo_now_ns(); ok(xrt_remote_call(target, &(struct xrt_call){.op = XRT_RPC_VIEW}));
            elapsed = xbo_now_ns() - before; if (elapsed > max_rpc) max_rpc = elapsed; ++rpcs;
        }
        struct timespec pause = {.tv_nsec = 1000000}; nanosleep(&pause, NULL);
        assert(xbo_now_ns() - start < UINT64_C(900000000000));
    }
    while (xmd_join(job) == XBO_AGAIN) { struct timespec pause = {.tv_nsec = 1000000}; nanosleep(&pause, NULL); }
    if (snapshot.state != XMD_READY) fprintf(stderr, "job failed: %s status=%u runtime=%u\n",
        snapshot.reason ? snapshot.reason : "no reason", snapshot.status, snapshot.runtime_status);
    assert(snapshot.state == XMD_READY && snapshot.profile.fields == strtoull(argv[4], NULL, 16));
    if (managed && !remote) assert(snapshot.cache_bytes == 0);
    uint64_t bias;
    assert(xmd_mapping_bias(job, request.mapping.start, request.mapping.end, request.mapping.offset, 4096, 0, &bias) == XBO_OK);
    assert(bias == expected_bias);
    assert(xmd_mapping_bias(job, request.mapping.start, request.mapping.end, request.mapping.offset + 1, 4096, 0, &bias) == XBO_MALFORMED && !bias);
    assert(xmd_mapping_bias(job, request.mapping.start, request.mapping.end, request.mapping.offset, 3, 0, &bias) == XBO_MALFORMED && !bias);
    uint64_t verify_calls = 0, max_verify = 0, verify_reads = 0, verify_bytes = 0;
    int restarted = 0;
    struct xjs_layout result, empty = {0}; const char *reason;
    for (;;) {
        struct xjs_reader reader = {.context = target, .read = read_target};
        uint64_t before = xbo_now_ns();
        enum xbo_status status = xmd_verify_javascript(job, expected_bias, generation, &reader, &result, &reason);
        uint64_t elapsed = xbo_now_ns() - before; if (elapsed > max_verify) max_verify = elapsed;
        ++verify_calls; verify_reads += reader.reads; verify_bytes += reader.bytes;
        assert(reader.reads <= 1 && verify_calls < 100);
        if (status == XBO_AGAIN) {
            assert(!memcmp(&result, &empty, sizeof result));
            if (!strcmp(argv[5], "restart") && !restarted && verify_reads == 2) { ++generation; restarted = 1; }
            continue;
        }
        if (status != XBO_OK) fprintf(stderr, "verify failed: %s status=%u\n", reason ? reason : "no reason", status);
        assert(status == XBO_OK && !reason);
        break;
    }
    if (!strcmp(argv[5], "restart")) assert(restarted);
    assert(!strcmp(result.version_string, "14.6.202.34-node.28") && result.dwarf_fields == snapshot.profile.fields);
    xrt_target_view(target, &target_view);
    assert(target_view.state == XRT_STOPPED && target_view.image_epoch == epoch);
    assert(target_view.generation + (unsigned)restarted == generation);
    assert(max_poll < UINT64_C(100000000) && max_rpc < UINT64_C(500000000));
    assert(max_verify < UINT64_C(500000000));
    printf("fields=%" PRIx64 " polls=%" PRIu64 " max_poll_ms=%.3f rpcs=%" PRIu64 " max_rpc_ms=%.3f"
        " verify_calls=%" PRIu64 " max_verify_ms=%.3f loaded_reads=%" PRIu64 " loaded_bytes=%" PRIu64
        " source_bytes=%" PRIu64 " cache_bytes=%" PRIu64 " index_units=%" PRIu64 " seconds=%.3f\n", result.dwarf_fields,
        polls, max_poll / 1e6, rpcs, max_rpc / 1e6, verify_calls, max_verify / 1e6, verify_reads, verify_bytes,
        snapshot.source_bytes, snapshot.cache_bytes, snapshot.index.units, (xbo_now_ns() - start) / 1e9);
    xmd_cancel(job);
    xmd_poll(job, &snapshot);
    assert(snapshot.state == XMD_CANCELLED && snapshot.status == XBO_CANCELLED);
    assert(!snapshot.profile.fields && !strcmp(snapshot.reason, "DebugMetadataCancelled"));
    struct xjs_reader reader = {.context = target, .read = read_target};
    assert(xmd_verify_javascript(job, expected_bias, generation, &reader, &result, &reason) == XBO_CANCELLED);
    assert(!memcmp(&result, &empty, sizeof result));
    xmd_destroy(job); ok(xrt_target_destroy(target)); close(fd);
    return 0;
}
