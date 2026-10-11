#define _POSIX_C_SOURCE 200809L
#include "check.h"
#include "../src/binary/pdb.h"
#include "../src/binary/pe.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

static unsigned char guid[16];
static uint32_t age;
static struct xpdb_section sections[XPE_MAX_SECTIONS];
static unsigned count;
static enum xpe_status read_file(void *context,uint64_t at,void *out,size_t size) {
    FILE *file=context;
    return at>INT64_MAX || fseeko(file,(off_t)at,SEEK_SET) || fread(out,1,size,file)!=size?XPE_IO:XPE_OK;
}
int LLVMFuzzerInitialize(int *argc,char ***argv) {
    CHECK(*argc>=2 && !strncmp((*argv)[1],"--pe=",5));
    FILE *file=fopen((*argv)[1]+5,"rb");CHECK(file);
    struct stat st;CHECK(!fstat(fileno(file),&st));
    struct xpe_source source={file,(uint64_t)st.st_size,XPE_FILE,read_file};
    struct xpe_image *pe=NULL;CHECK(xpe_load(&source,&pe)==XPE_OK);
    const struct xpe_codeview *cv=xpe_codeview(pe,0);CHECK(cv);
    memcpy(guid,cv->guid,16);age=cv->age;count=xpe_info(pe)->section_count;
    for(unsigned i=0;i<count;++i) {
        const struct xpe_section *s=xpe_section(pe,i);
        sections[i]=(struct xpdb_section){s->rva,s->raw_size>s->virtual_size?s->raw_size:s->virtual_size};
    }
    xpe_destroy(pe);CHECK(!fclose(file));
    for(int i=1;i<*argc;++i)(*argv)[i]=(*argv)[i+1];--*argc;
    return 0;
}
int LLVMFuzzerTestOneInput(const unsigned char *data,size_t size) {
    struct xpdb *p=NULL;
    if(xpdb_load(data,size,guid,age,sections,count,&p)==XPDB_OK) {
        CHECK(p && xpdb_info(p)->retained_bytes<=XPDB_MAX_ALLOCATED_BYTES);
        for(unsigned i=0;i<xpdb_info(p)->public_count && i<32;++i) {
            const struct xpdb_public *s=xpdb_public(p,i);CHECK(s && xpdb_find_public(p,s->name));
            (void)xpdb_public_at(p,s->rva);
        }
        for(unsigned i=0;i<xpdb_info(p)->line_count && i<32;++i) {
            const struct xpdb_line *l=xpdb_line(p,i);CHECK(l && l->rva<l->end);
            CHECK(xpdb_line_at(p,l->rva)==l && xpdb_line_at(p,l->end-1)==l);
        }
    } else CHECK(!p);
    xpdb_destroy(p);p=NULL;
    uint64_t allowance=size?(uint64_t)data[size-1]*1024:0;
    if(xpdb_load_budget(data,size,guid,age,sections,count,allowance,&p)==XPDB_OK)
        CHECK(p && xpdb_info(p)->peak_bytes<=allowance);
    else CHECK(!p);
    xpdb_destroy(p);return 0;
}
