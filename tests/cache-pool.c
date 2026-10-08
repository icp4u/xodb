#define _GNU_SOURCE 1
#include "../src/binary/cache_pool.h"
#include "../src/binary/object_cache.h"
#include "../src/binary/cache_io.h"
#include <assert.h>
#include <fcntl.h>
#include <stdio.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

static struct xbo_identity identity(uint64_t n) {
    return (struct xbo_identity){.device=1, .inode=n, .size=65536, .mtime_sec=7, .ctime_sec=8};
}
static struct xcp_entry *acquire(int dir, unsigned n) {
    struct xbo_identity id=identity(n); struct xcp_entry *entry=NULL;
    unsigned char build[2]={1,(unsigned char)n};
    assert(xcp_acquire(dir,&id,build,sizeof build,&entry)==XBO_OK && entry);
    assert(xcp_range_limit(entry)+xcp_index_limit(entry)==XCP_SLOT_LIMIT);
    return entry;
}
static void concurrent(int dir) {
    /* Both children start together and retain successes until both report.
     * A bounded acquire may decline caching; it must return no entry, and any
     * simultaneous successes must own distinct slots. */
    for (unsigned round = 0; round < 8; ++round) {
        int start[2], result[2], release[2];
        assert(!pipe(start) && !pipe(result) && !pipe(release));
        pid_t children[2];
        for (unsigned n = 0; n < 2; ++n) {
            children[n] = fork(); assert(children[n] >= 0);
            if (!children[n]) {
                close(start[1]); close(result[0]); close(release[1]);
                char byte;
                assert(read(start[0], &byte, 1) == 1);
                struct xcp_entry *entry = NULL;
                struct xbo_identity id = identity(100 + round * 2 + n);
                unsigned char build[2] = {2, (unsigned char)n};
                enum xbo_status status = xcp_acquire(dir, &id, build, sizeof build, &entry);
                struct { enum xbo_status status; dev_t device; ino_t inode; } reply = { .status = status };
                assert((status == XBO_OK && entry) || (status == XBO_AGAIN && !entry));
                if (entry) {
                    struct stat st;
                    assert(!fstat(xcp_range_fd(entry), &st));
                    reply.device = st.st_dev; reply.inode = st.st_ino;
                }
                assert(write(result[1], &reply, sizeof reply) == sizeof reply);
                assert(read(release[0], &byte, 1) == 1);
                xcp_release(entry);
                _exit(0);
            }
        }
        close(start[0]); close(result[1]); close(release[0]);
        assert(write(start[1], "go", 2) == 2); close(start[1]);
        struct { enum xbo_status status; dev_t device; ino_t inode; } replies[2];
        for (unsigned n = 0; n < 2; ++n) {
            assert(read(result[0], &replies[n], sizeof replies[n]) == sizeof replies[n]);
            assert(replies[n].status == XBO_OK || replies[n].status == XBO_AGAIN);
        }
        if (replies[0].status == XBO_OK && replies[1].status == XBO_OK)
            assert(replies[0].device != replies[1].device || replies[0].inode != replies[1].inode);
        close(result[0]); assert(write(release[1], "go", 2) == 2); close(release[1]);
        for (unsigned n = 0; n < 2; ++n) {
            int status;
            assert(waitpid(children[n], &status, 0) == children[n] && WIFEXITED(status) && !WEXITSTATUS(status));
        }
    }
}
static void marker(struct xcp_entry *entry, char c) {
    assert(pwrite(xcp_range_fd(entry),&c,1,0)==1);
    assert(pwrite(xcp_index_fd(entry),&c,1,0)==1);
}
static void check(struct xcp_entry *entry, char c) {
    char found=0; struct stat st;
    assert(!fstat(xcp_range_fd(entry),&st));
    if(c) assert(pread(xcp_range_fd(entry),&found,1,0)==1 && found==c);
    else assert(!st.st_size);
    found=0; assert(!fstat(xcp_index_fd(entry),&st));
    if(c) assert(pread(xcp_index_fd(entry),&found,1,0)==1 && found==c);
    else assert(!st.st_size);
}
static enum xbo_status fixture_identity(void *context, struct xbo_identity *out) {
    *out = *(struct xbo_identity *)context; return XBO_OK;
}
static enum xbo_status fixture_read(void *context, uint64_t offset, void *data, size_t size) {
    (void)context; (void)offset; (void)data; (void)size;
    assert(!"creating empty range metadata must not read source bytes"); return XBO_IO;
}
static void legacy_headers(const char *path) {
    int dir = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC); assert(dir >= 0);
    struct xcp_entry *entries[2];
    for (unsigned n = 0; n < 2; ++n) {
        struct xbo_identity id = identity(n + 1); id.size = UINT64_C(3400000000);
        unsigned char build[2] = {1, (unsigned char)n};
        assert(xcp_acquire(dir, &id, build, sizeof build, &entries[n]) == XBO_OK);
        struct xbo_source source = {&id, fixture_identity, fixture_read};
        struct xbc_cache *cache = NULL;
        assert(xbc_create(&source, &id, build, sizeof build, xcp_range_fd(entries[n]),
                          xcp_range_limit(entries[n]), &cache) == XBO_OK);
        xbc_destroy(cache);
    }
    for (unsigned n = 0; n < 2; ++n) xcp_release(entries[n]);
    close(dir);
}
int main(int argc,char **argv) {
    if (argc == 3 && !strcmp(argv[1], "--legacy")) { legacy_headers(argv[2]); return 0; }
    assert(argc==2);
    if(!strcmp(argv[1],"--directory")) {
        int fd=xcp_directory();
        if(fd<0)return 2;
        close(fd);return 0;
    }
    int dir=open(argv[1],O_RDONLY|O_DIRECTORY|O_CLOEXEC); assert(dir>=0);
    assert(xc_checksum((const unsigned char *)"123456789",9)==UINT32_C(0xe3069283));
    concurrent(dir);
    struct xcp_entry *a=acquire(dir,1), *b=acquire(dir,2), *other=NULL;
    marker(a,'a'); marker(b,'b');
    struct xbo_identity id=identity(3); unsigned char build[2]={1,3};
    assert(xcp_acquire(dir,&id,build,2,&other)==XBO_AGAIN && !other);
    pid_t pid=fork(); assert(pid>=0);
    if(!pid) _exit(xcp_acquire(dir,&id,build,2,&other)==XBO_AGAIN?0:1);
    int status; assert(waitpid(pid,&status,0)==pid && WIFEXITED(status) && !WEXITSTATUS(status));
    xcp_release(a); a=acquire(dir,1); check(a,'a'); xcp_release(a);
    a=acquire(dir,3); check(a,0); marker(a,'c'); check(b,'b'); xcp_release(a); xcp_release(b);
    /* Oldest unused entry is replaced; a recently used matching entry survives. */
    a=acquire(dir,3); check(a,'c'); xcp_release(a);
    b=acquire(dir,4); check(b,0); marker(b,'d'); xcp_release(b);
    a=acquire(dir,3); check(a,'c');
    assert(ftruncate(xcp_index_fd(a),(off_t)xcp_index_limit(a)+1)==0); xcp_release(a);
    a=acquire(dir,3); check(a,0); marker(a,'e');
    assert(xcp_reset(a)==XBO_OK); check(a,0); xcp_release(a);
    id=identity(9); id.size=XCP_SLOT_LIMIT;
    assert(xcp_acquire(dir,&id,build,2,&other)==XBO_LIMIT && !other);
    assert(fchmod(dir,0755)==0);
    assert(xcp_acquire(dir,&id,build,0,&other)==XBO_MALFORMED && !other);
    id=identity(9); assert(xcp_acquire(dir,&id,build,2,&other)==XBO_IO && !other);
    assert(fchmod(dir,0700)==0);
    /* Crash/partial metadata is reclaimed only under the slot lease. */
    int fd=openat(dir,"0.lease",O_WRONLY); assert(fd>=0); assert(ftruncate(fd,3)==0); close(fd);
    a=acquire(dir,9); check(a,0); xcp_release(a);
    /* Symlinks, FIFOs, hardlinks and permissive files are never opened as data. */
    const char *names[]={"0.ranges","0.names","0.lease"};
    for(unsigned i=0;i<3;++i) {
        assert(!unlinkat(dir,names[i],0)); assert(!symlinkat("victim",dir,names[i]));
        id=identity(10+i); assert(xcp_acquire(dir,&id,build,2,&other)==XBO_IO && !other);
        assert(!unlinkat(dir,names[i],0)); assert(!mkfifoat(dir,names[i],0600));
        assert(xcp_acquire(dir,&id,build,2,&other)==XBO_IO && !other);
        assert(!unlinkat(dir,names[i],0));
        fd=openat(dir,names[i],O_RDWR|O_CREAT|O_EXCL,0600); assert(fd>=0); assert(!fchmod(fd,0644)); close(fd);
        assert(xcp_acquire(dir,&id,build,2,&other)==XBO_IO && !other);
        assert(!unlinkat(dir,names[i],0)); assert(!linkat(dir,"victim",dir,names[i],0));
        assert(xcp_acquire(dir,&id,build,2,&other)==XBO_IO && !other);
        assert(!unlinkat(dir,names[i],0));
    }
    fd=openat(dir,"victim",O_RDONLY); assert(fd>=0);
    char byte; assert(read(fd,&byte,1)==1 && byte=='v'); close(fd); close(dir);
    puts("cache pool: quota, leases, reuse, eviction, recovery and unsafe entries passed");
    return 0;
}
