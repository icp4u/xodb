#define _POSIX_C_SOURCE 200809L
#include "../src/debug/macho_unwind.h"
#include "check.h"
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>
struct file { int fd; };
static enum xmo_status read_file(void *arg, uint64_t at, void *out, size_t n) {
    struct file *f=arg;
    return pread(f->fd,out,n,(off_t)at)==(ssize_t)n ? XMO_OK : XMO_IO;
}
int main(int argc, char **argv) {
    CHECK(argc==4);
    struct file file={open(argv[1],O_RDONLY)};CHECK(file.fd>=0);
    struct stat st;CHECK(fstat(file.fd,&st)==0 && st.st_size>=0);
    struct xmo_source source={&file,(uint64_t)st.st_size,XMO_FILE,read_file};
    struct xmo_image *image=NULL;CHECK(xmo_load(&source,NULL,&image)==XMO_OK);
    const struct xmo_section *section=xmo_find_section(image,"__TEXT","__unwind_info");
    CHECK(section && section->size<16*1024*1024);
    unsigned char *bytes=malloc((size_t)section->size);CHECK(bytes);
    for (uint64_t at=0;at<section->size;) {
        size_t n=section->size-at>XMO_MAX_CHUNK ? XMO_MAX_CHUNK : (size_t)(section->size-at);
        CHECK(xmo_read_section(image,section,at,bytes+at,n)==XMO_OK);at+=n;
    }
    struct xmu_table *table=NULL;
    enum xmo_status status=xmu_create(bytes,(size_t)section->size,strtoull(argv[3],NULL,0),&table);
    printf("table\t%s\n",xmo_status_name(status));
    if (status==XMO_OK) {
        struct xmu_row row={0};
        status=xmu_lookup(table,strtoull(argv[2],NULL,0),&row);
        printf("row\t%s\t%x\t%x\t%x\n",xmo_status_name(status),row.start,row.end,row.encoding);
    }
    printf("retained\t%zu\n",xmu_bytes(table));
    xmu_destroy(table);free(bytes);xmo_destroy(image);CHECK(close(file.fd)==0);return 0;
}
