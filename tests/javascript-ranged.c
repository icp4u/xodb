#define _GNU_SOURCE 1
#include "../src/language/javascript_ranged.h"
#include "../src/language/javascript.h"
#include "../src/debug/dwarf_index.h"
#include <assert.h>
#include <fcntl.h>
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
static enum xbo_status read_bytes(void *context, uint64_t offset, void *out, size_t size) {
    struct source *s = context;
    return s->base.read(s->base.context, offset, out, size);
}
static int cancelled(void *context) { return ((struct source *)context)->cancel; }
static int unit_order(const void *a, const void *b) {
    uint64_t x=*(const uint64_t *)a,y=*(const uint64_t *)b;
    return x<y?-1:x>y;
}
static void indexed(struct xbo_object *object, const char *path,
        enum xbo_status expected_status, struct xjs_dwarf_profile expected) {
    uint32_t section;
    if (xbo_find_section(object,".debug_info",&section)!=XBO_OK) return;
    int fd=open(path,O_RDWR|O_CREAT|O_EXCL|O_CLOEXEC,0600);assert(fd>=0);
    const char *names[64];size_t count=xjs_ranged_names(names,64);assert(count<=64);
    struct xdi_index *index;
    assert(xdi_open_names(object,fd,16*1024*1024,names,count,&index)==XBO_OK);
    uint64_t slices=0;
    for (;;) {
        struct xbo_budget budget={.bytes_left=slices<8?17:262144,.reads_left=slices<8?1:64};
        enum xbo_status status=xdi_build(index,&budget,slices<8?1:4096);
        assert(++slices<1000000);
        assert(status==XBO_OK||status==XBO_AGAIN);if(status==XBO_OK)break;
    }
    uint64_t units[16384];size_t unit_count=0;
    for(size_t n=0;n<count;++n) {
        struct xdi_query *query;assert(xdi_query(index,names[n],&query)==XBO_OK);
        for(;;) {
            struct xbo_budget budget={.bytes_left=128,.reads_left=2};struct xdn_hit hit;
            enum xbo_status status=xdi_next(query,&budget,3,&hit);
            if(status==XBO_AGAIN)continue;
            if(status==XBO_NOT_FOUND)break;
            assert(status==XBO_OK);size_t k=0;while(k<unit_count&&units[k]!=hit.unit)++k;
            if(k==unit_count){assert(unit_count<16384);units[unit_count++]=hit.unit;}
        }
        xdi_query_destroy(query);
    }
    qsort(units,unit_count,sizeof *units,unit_order);
    struct xjs_ranged *scan;assert(xjs_ranged_create_units(object,units,unit_count,&scan)==XBO_OK);
    for(;;) {
        struct xbo_budget budget={.bytes_left=97,.reads_left=3};
        enum xbo_status status=xjs_ranged_step(scan,&budget,7);
        if(status==XBO_AGAIN)continue;
        assert(status==expected_status);break;
    }
    struct xjs_dwarf_profile actual;
    assert(xjs_ranged_result(scan,&actual)==expected_status);
    assert(actual.fields==expected.fields&&actual.frame_config==expected.frame_config);
    assert((!actual.error&&!expected.error)||(actual.error&&expected.error&&!strcmp(actual.error,expected.error)));
    struct xjs_ranged_progress progress;xjs_ranged_progress(scan,&progress);
    if(expected_status==XBO_OK)assert(progress.complete&&progress.dwarf.units==unit_count);
    xjs_ranged_destroy(scan);xdi_destroy(index);close(fd);
}
int main(int argc, char **argv) {
    assert(argc == 5);
    int fd = open(argv[1], O_RDONLY | O_CLOEXEC | O_NONBLOCK); assert(fd >= 0);
    struct xbo_local local = {fd};
    struct source s = {.base = xbo_local_source(&local)};
    struct xbo_source source = {&s, identity, read_bytes};
    struct xbo_object *object;
    assert(xbo_create(&source, &object) == XBO_OK);
    struct xbo_budget budget = {.bytes_left = 1048576, .reads_left = 65536};
    assert(xbo_prepare(object, &budget) == XBO_OK);
    struct xjs_ranged *profile = NULL;
    enum xbo_status status = xjs_ranged_create(object, &profile);
    struct xjs_dwarf_profile result = {0};
    uint64_t slices = 0, bytes = 0, start = xbo_now_ns();
    int cancelled_midway = 0;
    if (status == XBO_OK) {
        s.cancel = 1;
        budget = (struct xbo_budget){.bytes_left = 1048576, .reads_left = 64,
            .context = &s, .cancelled = cancelled};
        assert(xjs_ranged_step(profile, &budget, 4096) == XBO_CANCELLED);
        s.cancel = 0;
        budget.deadline_ns = 1;
        assert(xjs_ranged_step(profile, &budget, 4096) == XBO_AGAIN);
        for (;;) {
            budget = (struct xbo_budget){.bytes_left = slices < 8 ? 17 : 262144,
                .reads_left = slices < 8 ? 1 : 64, .deadline_ns = xbo_now_ns() + UINT64_C(15000000)};
            status = xjs_ranged_step(profile, &budget, slices < 8 ? 1 : 4096);
            bytes += budget.bytes_read;
            assert(++slices < 2000000);
            enum xbo_status published = xjs_ranged_result(profile, &result);
            if (status == XBO_AGAIN || status == XBO_CANCELLED) {
                assert(published == XBO_AGAIN && !result.fields && !result.frame_config && result.error);
                struct xjs_ranged_progress at;
                xjs_ranged_progress(profile, &at);
                if (!cancelled_midway && at.dwarf.dies) {
                    s.cancel = 1;
                    budget = (struct xbo_budget){.bytes_left = 1048576, .reads_left = 64,
                        .context = &s, .cancelled = cancelled};
                    assert(xjs_ranged_step(profile, &budget, 4096) == XBO_CANCELLED);
                    s.cancel = 0; cancelled_midway = 1;
                    assert(xjs_ranged_result(profile, &result) == XBO_AGAIN && !result.fields);
                }
                continue;
            }
            assert(published == status);
            if (status != XBO_OK) assert(!result.fields && !result.frame_config && result.error);
            break;
        }
    }
    const char *reason = result.error ? result.error : xbo_status_name(status);
    if (!strcmp(argv[2], "ok")) {
        assert(status == XBO_OK && !result.error);
        if (!strcmp(argv[3], "oracle")) {
            Dwarf *dwarf = dwarf_begin(fd, DWARF_C_READ);
            struct xjs_dwarf_profile expected;
            xjs_dwarf_profile(dwarf, &expected);
            if (expected.error) fprintf(stderr, "oracle error: %s\n", expected.error);
            assert(!expected.error && result.fields == expected.fields && result.frame_config == expected.frame_config);
            if (dwarf) dwarf_end(dwarf);
        } else {
            assert(result.fields == strtoull(argv[3], NULL, 16));
        }
    } else {
        if (strcmp(reason, argv[2])) fprintf(stderr, "wanted %s; got %s\n", argv[2], reason);
        assert(!strcmp(reason, argv[2]));
    }
    struct xjs_ranged_progress progress;
    xjs_ranged_progress(profile, &progress);
    assert(progress.dwarf.memory_bytes < 2 * 1024 * 1024);
    printf("%s fields=%" PRIx64 " observations=%" PRIu64 " units=%" PRIu64 " dies=%" PRIu64
           " slices=%" PRIu64 " bytes=%" PRIu64 " seconds=%.6f\n", reason, result.fields,
           progress.observations, progress.dwarf.units, progress.dwarf.dies, slices, bytes,
           (xbo_now_ns() - start) / 1e9);
    if(status==XBO_OK || (result.error && (!strcmp(result.error,"JavaScriptDwarfLayoutMismatch") ||
        !strcmp(result.error,"JavaScriptDwarfConstantUnsupported")))) indexed(object,argv[4],status,result);
    if (status == XBO_OK) {
        s.changed = 1;
        budget = (struct xbo_budget){.bytes_left = 1048576, .reads_left = 64};
        assert(xjs_ranged_step(profile, &budget, 4096) == XBO_CHANGED);
        s.changed = 0;
        assert(xjs_ranged_step(profile, &budget, 4096) == XBO_CHANGED);
        assert(xjs_ranged_result(profile, &result) == XBO_CHANGED && !result.fields && !result.frame_config);
    }
    xjs_ranged_destroy(profile); xbo_destroy(object); close(fd);
    return 0;
}
