#define _GNU_SOURCE 1
#include "../src/debug/cfi_image.h"
#include <assert.h>
#include <elf.h>
#include <elfutils/libdw.h>
#include <fcntl.h>
#include <gelf.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int cancelled(void *p) { return *(int *)p; }
static struct xbo_budget budget(uint64_t bytes) {
    return (struct xbo_budget){.bytes_left=bytes,.reads_left=2};
}
static void ops_equal(Dwarf_Op *a, size_t na, Dwarf_Op *b, size_t nb) {
    assert(na==nb);
    for (size_t i=0;i<na;++i) {
        assert(a[i].atom==b[i].atom);
        assert(a[i].number==b[i].number);
        assert(a[i].number2==b[i].number2);
    }
}
static unsigned compare(Dwarf_CFI *full, Dwarf_CFI *copy, uint64_t pc) {
    Dwarf_Frame *a=NULL,*b=NULL;
    int sa=dwarf_cfi_addrframe(full,pc,&a),sb=dwarf_cfi_addrframe(copy,pc,&b);
    assert((sa==0)==(sb==0));
    if (sa) return 0;
    Dwarf_Addr low[2],high[2];bool signal[2];
    int ra=dwarf_frame_info(a,&low[0],&high[0],&signal[0]);
    int rb=dwarf_frame_info(b,&low[1],&high[1],&signal[1]);
    assert(ra==rb && low[0]==low[1] && high[0]==high[1] && signal[0]==signal[1]);
    Dwarf_Op *oa=NULL,*ob=NULL;size_t na=0,nb=0;
    sa=dwarf_frame_cfa(a,&oa,&na);sb=dwarf_frame_cfa(b,&ob,&nb);
    assert((sa==0)==(sb==0));if(!sa)ops_equal(oa,na,ob,nb);
    for (unsigned i=0;i<32;++i) {
        Dwarf_Op ba[3],bb[3];oa=ob=NULL;na=nb=0;
        sa=dwarf_frame_register(a,i,ba,&oa,&na);sb=dwarf_frame_register(b,i,bb,&ob,&nb);
        assert((sa==0)==(sb==0));
        if (!sa) {
            if (!na && !nb) assert((oa==NULL)==(ob==NULL));
            ops_equal(oa,na,ob,nb);
        }
    }
    free(a);free(b);return 1;
}
int main(int argc,char **argv) {
    assert(argc>=3 && argc<=4);assert(elf_version(EV_CURRENT)!=EV_NONE);
    int mutation=argc==4 && !strcmp(argv[3],"mutate");
    int fd=open(argv[1],(mutation?O_RDWR:O_RDONLY)|O_CLOEXEC);assert(fd>=0);
    struct xbo_local local={fd};struct xbo_source source=xbo_local_source(&local);
    struct xbo_object *object=NULL;assert(xbo_create(&source,&object)==XBO_OK);
    enum xbo_status status;unsigned slices=0;
    do {struct xbo_budget b=budget(4096);status=xbo_prepare(object,&b);assert(++slices<1000000);}while(status==XBO_AGAIN);
    if (status!=XBO_OK) {
        assert(!strcmp(xbo_status_name(status),argv[2]));
        xbo_destroy(object);close(fd);printf("ELF refusal: %s\n",argv[2]);return 0;
    }
    struct xcf_image *image=NULL;status=xcf_create(object,&image);
    uint64_t quantum=argc==4 && !strcmp(argv[3],"large")?4096:17;
    if (status==XBO_OK) {
        int cancel=1;struct xbo_budget b=budget(4096);b.cancelled=cancelled;b.context=&cancel;
        assert(xcf_step(image,&b)==XBO_CANCELLED);
        unsigned char *bytes=NULL;size_t size=99;assert(xcf_result(image,&bytes,&size)==XBO_AGAIN && !bytes && !size);
        do {b=budget(quantum);status=xcf_step(image,&b);assert(++slices<2000000);}while(status==XBO_AGAIN);
    }
    if (strcmp(argv[2],"ok")) {
        assert(!strcmp(xbo_status_name(status),argv[2]));
        xcf_destroy(image);xbo_destroy(object);close(fd);printf("refusal: %s\n",argv[2]);return 0;
    }
    assert(status==XBO_OK);
    unsigned char *bytes;size_t size;assert(xcf_result(image,&bytes,&size)==XBO_OK && size<=XCF_MAX_BYTES);
    Elf *full=elf_begin(fd,ELF_C_READ,NULL),*copy=elf_memory((char *)bytes,size);assert(full && copy);
    Dwarf_CFI *cf=dwarf_getcfi_elf(full),*cc=dwarf_getcfi_elf(copy);assert(cf && cc);
    /* Independent libdw oracle on the complete image, never on copied symbols. */
    unsigned checked=0,functions=0;Elf_Scn *scn=NULL;
    while ((scn=elf_nextscn(full,scn)) && functions<256) {
        GElf_Shdr sh;assert(gelf_getshdr(scn,&sh));
        if (sh.sh_type!=SHT_SYMTAB || !sh.sh_entsize)continue;
        Elf_Data *data=elf_getdata(scn,NULL);assert(data);
        for (size_t i=0;i<sh.sh_size/sh.sh_entsize && functions<256;++i) {
            GElf_Sym sym;assert(gelf_getsym(data,(int)i,&sym));
            if (GELF_ST_TYPE(sym.st_info)!=STT_FUNC || !sym.st_size || !sym.st_shndx || sym.st_shndx>=SHN_LORESERVE)continue;
            ++functions;
            checked+=compare(cf,cc,sym.st_value);
            checked+=compare(cf,cc,sym.st_value+sym.st_size/2);
            checked+=compare(cf,cc,sym.st_value+sym.st_size-1);
        }
    }
    assert(checked);
    struct xcf_progress progress;xcf_progress(image,&progress);
    printf("CFI oracle: %u PCs, %u functions, %zu retained bytes, %llu source bytes, %u slices\n",checked,functions,size,(unsigned long long)progress.source_bytes,slices);
    dwarf_cfi_end(cc);dwarf_cfi_end(cf);elf_end(copy);elf_end(full);
    if (mutation) {
        unsigned char first;assert(pread(fd,&first,1,0)==1);
        assert(pwrite(fd,&first,1,0)==1); /* identical bytes, changed identity */
        struct xbo_budget b=budget(4096);assert(xcf_step(image,&b)==XBO_CHANGED);
        assert(xcf_result(image,&bytes,&size)==XBO_CHANGED && !bytes && !size);
        b=budget(4096);assert(xcf_step(image,&b)==XBO_CHANGED);
        puts("identity change permanently withdraws CFI");
    }
    xcf_destroy(image);xbo_destroy(object);close(fd);return 0;
}
