#define _POSIX_C_SOURCE 200809L
#include "../src/debug/source_paths.h"
#include <assert.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
static void normalization(void)
{
    char path[XDW_SOURCE_PATH_MAX];
    const char *inputs[]={"/a/build/../src/./unit.c", "//a///src/unit.c", "/a/b/../../c", "/a/..", "/.../..hidden"};
    const char *wanted[]={"/a/src/unit.c", "/a/src/unit.c", "/c", "/", "/.../..hidden"};
    for(unsigned n=0;n<sizeof inputs/sizeof *inputs;++n) {
        assert(xdw_source_normalize(inputs[n],path)==XBO_OK && !strcmp(path,wanted[n]));
        assert(xdw_source_normalize(path,path)==XBO_OK && !strcmp(path,wanted[n]));
    }
    assert(xdw_source_normalize("/../a",path)==XBO_MALFORMED);
    assert(xdw_source_normalize("/a/../../b",path)==XBO_MALFORMED);
    assert(xdw_source_normalize("relative.c",path)==XBO_MALFORMED);
    assert(xdw_source_normalize(NULL,path)==XBO_MALFORMED);
    memset(path,'a',sizeof path);path[0]='/';
    assert(xdw_source_normalize(path,path)==XBO_LIMIT);
}
int main(int argc, char **argv)
{
    assert(argc == 4);
    normalization();
    int fd = open(argv[1], O_RDONLY | O_CLOEXEC | O_NONBLOCK); assert(fd >= 0);
    struct xbo_local local = {fd}; struct xbo_source source = xbo_local_source(&local);
    struct xbo_object *object = NULL; assert(xbo_create(&source, &object) == XBO_OK);
    struct xbo_budget budget = {.bytes_left=64*1024*1024, .reads_left=65536,
        .deadline_ns=xbo_now_ns()+UINT64_C(2000000000)};
    enum xbo_status s = xbo_prepare(object, &budget);
    if (s == XBO_OK) s = xdw_source_path(object, argv[2], &budget);
    printf("%s: %s (%llu bytes, %llu reads)\n", argv[2], xbo_status_name(s),
        (unsigned long long)budget.bytes_read, (unsigned long long)budget.reads);
    int ok = !strcmp(argv[3], xbo_status_name(s));
    xbo_destroy(object); close(fd); return ok ? 0 : 1;
}
