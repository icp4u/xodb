#define _POSIX_C_SOURCE 200809L
#include "check.h"
#include "../src/binary/pdb.h"
#include "../src/binary/pe.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/resource.h>
#include <unistd.h>

static void usage(const char *phase) {
    FILE *file=fopen("/proc/self/status","r");CHECK(file);
    char line[256];unsigned long rss=0,peak=0;
    while(fgets(line,sizeof line,file)) {
        unsigned long value;
        if(sscanf(line,"VmRSS: %lu kB",&value)==1)rss=value*1024;
        if(sscanf(line,"VmHWM: %lu kB",&value)==1)peak=value*1024;
    }
    CHECK(!fclose(file));struct rusage r;CHECK(!getrusage(RUSAGE_SELF,&r));
    double cpu=r.ru_utime.tv_sec+r.ru_utime.tv_usec/1000000.0+r.ru_stime.tv_sec+r.ru_stime.tv_usec/1000000.0;
    printf("usage\t%s\t%.6f\t%lu\t%lu\n",phase,cpu,rss,peak);
}
static enum xpe_status read_file(void *context,uint64_t at,void *out,size_t n) {
    FILE *file=context;
    if(at>INT64_MAX || fseeko(file,(off_t)at,SEEK_SET))return XPE_IO;
    return fread(out,1,n,file)==n?XPE_OK:XPE_IO;
}
int main(int argc,char **argv) {
    CHECK(argc==3 || argc==4);
    usage("before");
    FILE *file=fopen(argv[1],"rb");CHECK(file);
    struct stat stat;CHECK(!fstat(fileno(file),&stat));
    struct xpe_source source={file,(uint64_t)stat.st_size,XPE_FILE,read_file};
    struct xpe_image *pe=NULL;CHECK(xpe_load(&source,&pe)==XPE_OK);
    const struct xpe_codeview *cv=xpe_codeview(pe,0);CHECK(cv);
    unsigned count=xpe_info(pe)->section_count;
    struct xpdb_section sections[XPE_MAX_SECTIONS];
    for(unsigned i=0;i<count;++i) {
        const struct xpe_section *s=xpe_section(pe,i);
        sections[i]=(struct xpdb_section){s->rva,s->raw_size>s->virtual_size?s->raw_size:s->virtual_size};
    }
    FILE *pdb=fopen(argv[2],"rb");CHECK(pdb);CHECK(!fstat(fileno(pdb),&stat));
    CHECK(stat.st_size>=0 && (uint64_t)stat.st_size<=XPDB_MAX_FILE_BYTES);
    size_t size=(size_t)stat.st_size;unsigned char *bytes=malloc(size?size:1);CHECK(bytes);
    CHECK(fread(bytes,1,size,pdb)==size);CHECK(!fclose(pdb));
    struct xpdb *image=NULL;
    enum xpdb_status status=xpdb_load(bytes,size,cv->guid,cv->age,sections,count,&image);
    if(argc==4 && !strncmp(argv[3],"status=",7)) {
        CHECK(status==(enum xpdb_status)strtoul(argv[3]+7,NULL,10));CHECK(!image);
        usage("after");
        free(bytes);xpe_destroy(pe);CHECK(!fclose(file));return 0;
    }
    fprintf(stderr,"PDB status: %s\n",xpdb_status_name(status));CHECK(status==XPDB_OK && image);
    /* The result must own its names and rows. Poison/free source before use. */
    memset(bytes,0xa5,size);free(bytes);
    CHECK(xpdb_info(image)->public_count && xpdb_info(image)->line_count);
    CHECK(xpdb_info(image)->retained_bytes<=XPDB_MAX_ALLOCATED_BYTES);
    CHECK(xpdb_info(image)->peak_bytes>=xpdb_info(image)->retained_bytes);
    usage("after");
    if(argc==4 && !strncmp(argv[3],"count=",6)) {
        CHECK(xpdb_info(image)->public_count==strtoul(argv[3]+6,NULL,10));
        CHECK(xpdb_find_public(image,"pdb_twice"));
        printf("cost\t%llu\t%llu\t%llu\n",(unsigned long long)xpdb_info(image)->retained_bytes,
            (unsigned long long)xpdb_info(image)->peak_bytes,(unsigned long long)xpdb_info(image)->work_bytes);
        xpdb_destroy(image);xpe_destroy(pe);CHECK(!fclose(file));return 0;
    }
    const struct xpdb_public *twice=xpdb_find_public(image,"pdb_twice");CHECK(twice);
    CHECK(!xpe_find_export(pe,"pdb_twice"));
    if(argc==4 && !strcmp(argv[3],"wrong-result"))CHECK(twice->rva==UINT32_MAX);
    for(unsigned i=0;i<xpdb_info(image)->public_count;++i) {
        const struct xpdb_public *s=xpdb_public(image,i);
        CHECK(xpdb_find_public(image,s->name));CHECK(xpdb_public_at(image,s->rva));
        printf("public\t%u\t%u\t%s\n",s->rva,s->flags,s->name);
    }
    for(unsigned i=0;i<xpdb_info(image)->line_count;++i) {
        const struct xpdb_line *l=xpdb_line(image,i);CHECK(l->rva<l->end);
        CHECK(xpdb_line_at(image,l->rva)==l);CHECK(xpdb_line_at(image,l->end-1)==l);
        CHECK(xpdb_line_at(image,l->end)!=l);
        printf("line\t%u\t%u\t%u\t%u\t%s\n",l->rva,l->end,l->line,l->column,l->path);
    }
    printf("cost\t%llu\t%llu\t%llu\n",(unsigned long long)xpdb_info(image)->retained_bytes,
        (unsigned long long)xpdb_info(image)->peak_bytes,(unsigned long long)xpdb_info(image)->work_bytes);
    xpdb_destroy(image);xpe_destroy(pe);CHECK(!fclose(file));return 0;
}
