#define _POSIX_C_SOURCE 200809L
#include "../src/debug/macho_dwarf.h"
#include "check.h"
#include <elfutils/libdw.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

struct file { int fd; uint64_t bytes, calls; };
static enum xmo_status read_file(void *arg, uint64_t at, void *out, size_t n) {
    struct file *f=arg;
    if (n>XMO_MAX_READ_BYTES-f->bytes || ++f->calls>XMO_MAX_READS) return XMO_LIMIT;
    if (pread(f->fd,out,n,(off_t)at)!=(ssize_t)n) return XMO_IO;
    f->bytes+=n;return XMO_OK;
}
int main(int argc, char **argv) {
    CHECK(argc==5);
    struct file file={.fd=open(argv[1],O_RDONLY)};CHECK(file.fd>=0);
    struct stat st;CHECK(fstat(file.fd,&st)==0 && st.st_size>=0);
    struct xmo_source source={&file,(uint64_t)st.st_size,XMO_FILE,read_file};
    struct xmo_options options={.cputype=(uint32_t)strtoul(argv[2],NULL,0)};
    struct xmo_image *image=NULL;
    enum xmo_status status=xmo_load(&source,&options,&image);
    struct xmo_dwarf dwarf={0};
    if (status==XMO_OK) status=xmo_dwarf_build(image,strtoull(argv[4],NULL,0),&dwarf);
    printf("status\t%s\nbytes\t%zu\n",xmo_status_name(status),dwarf.size);
    if (status==XMO_OK) {
        CHECK(elf_version(EV_CURRENT)!=EV_NONE);
        Elf *elf=elf_memory((char *)dwarf.bytes,dwarf.size);CHECK(elf);
        Dwarf *debug=dwarf_begin_elf(elf,DWARF_C_READ,NULL);
        if (debug) {
            Dwarf_Off off=0,next;size_t head;Dwarf_Addr pc=strtoull(argv[3],NULL,0);
            while (dwarf_nextcu(debug,off,&next,&head,NULL,NULL,NULL)==0) {
                Dwarf_Die die;CHECK(dwarf_offdie(debug,off+head,&die));
                Dwarf_Line *row=dwarf_getsrc_die(&die,pc);
                if (row) {
                    int line=0,column=0;Dwarf_Addr address=0;
                    CHECK(dwarf_lineno(row,&line)==0 && dwarf_linecol(row,&column)==0 && dwarf_lineaddr(row,&address)==0);
                    printf("source\t%s\t%d\t%d\t%llx\n",dwarf_linesrc(row,NULL,NULL),line,column,(unsigned long long)address);
                }
                off=next;
            }
            CHECK(dwarf_end(debug)==0);
        }
        CHECK(elf_end(elf)==0);
    }
    printf("reads\t%llu\t%llu\n",(unsigned long long)file.calls,(unsigned long long)file.bytes);
    xmo_dwarf_free(&dwarf);xmo_destroy(image);CHECK(close(file.fd)==0);
    return 0;
}
