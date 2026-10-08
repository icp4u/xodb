#define _GNU_SOURCE 1
#define _FILE_OFFSET_BITS 64
#include "../src/binary/object.h"
#include <assert.h>
#include <elf.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static struct xbo_budget budget(uint64_t bytes,uint64_t reads) {
    return (struct xbo_budget){.bytes_left=bytes,.reads_left=reads,.deadline_ns=xbo_now_ns()+UINT64_C(1000000000)};
}
static void put(unsigned char *p,uint64_t v,unsigned n,int little) {
    for (unsigned i=0;i<n;i++) {p[little?i:n-i-1]=(unsigned char)v;v>>=8;}
}
static void write_at(int fd,uint64_t at,const void *p,size_t n) {assert(pwrite(fd,p,n,(off_t)at)==(ssize_t)n);}
struct fixture {int fd;char path[64];uint64_t size,table,payload;unsigned shsize;};
static struct fixture fixture(int wide,int little,int extended) {
    struct fixture f={.path=".work/object-XXXXXX"};f.fd=mkstemp(f.path);assert(f.fd>=0);assert(fchmod(f.fd,0644)==0);
    f.table=wide?(UINT64_C(4)<<30)+4096:(UINT64_C(3)<<30)+4096;
    f.size=f.table+4096;f.payload=f.table+3000;f.shsize=wide?64:40;
    assert(ftruncate(f.fd,(off_t)f.size)==0);
    unsigned char h[64]={0},ph[56]={0},sh[4*64]={0};
    memcpy(h,ELFMAG,4);h[EI_CLASS]=wide?ELFCLASS64:ELFCLASS32;h[EI_DATA]=little?ELFDATA2LSB:ELFDATA2MSB;h[EI_VERSION]=1;
#define P(p,at,v,n) put((p)+(at),(v),(n),little)
    P(h,16,ET_DYN,2);P(h,18,wide?EM_X86_64:EM_68K,2);P(h,20,1,4);
    P(h,wide?32:28,64,wide?8:4);P(h,wide?40:32,f.table,wide?8:4);
    P(h,wide?52:40,wide?64:52,2);P(h,wide?54:42,wide?56:32,2);P(h,wide?56:44,extended?PN_XNUM:1,2);
    P(h,wide?58:46,f.shsize,2);P(h,wide?60:48,extended?0:4,2);P(h,wide?62:50,extended?SHN_XINDEX:1,2);
    P(ph,0,PT_NOTE,4);P(ph,wide?8:4,256,wide?8:4);P(ph,wide?32:16,24,wide?8:4);P(ph,wide?40:20,24,wide?8:4);
    if (extended) {P(sh,wide?32:20,4,wide?8:4);P(sh,wide?40:24,1,4);P(sh,wide?44:28,1,4);}
    const char names[]="\0.shstrtab\0.note.gnu.build-id\0.debug_info\0";
    for (unsigned i=1;i<4;i++) {
        unsigned char *s=sh+i*f.shsize;
        P(s,0,i==1?1:i==2?11:30,4);P(s,4,i==1?SHT_STRTAB:i==2?SHT_NOTE:SHT_PROGBITS,4);
        P(s,wide?24:16,i==1?f.table+512:i==2?256:f.payload,wide?8:4);
        P(s,wide?32:20,i==1?sizeof names:i==2?24:32,wide?8:4);P(s,wide?48:32,1,wide?8:4);
    }
    unsigned char note[24]={0};P(note,0,4,4);P(note,4,8,4);P(note,8,NT_GNU_BUILD_ID,4);memcpy(note+12,"GNU",4);memcpy(note+16,"abcdefgh",8);
    unsigned char data[32];for(unsigned i=0;i<32;i++) data[i]=(unsigned char)(i+64);
    write_at(f.fd,0,h,wide?64:52);write_at(f.fd,64,ph,wide?56:32);write_at(f.fd,256,note,sizeof note);
    write_at(f.fd,f.table,sh,4*f.shsize);write_at(f.fd,f.table+512,names,sizeof names);write_at(f.fd,f.payload,data,sizeof data);
#undef P
    return f;
}
static void close_fixture(struct fixture *f) {assert(close(f->fd)==0);assert(unlink(f->path)==0);}
static int cancel(void *p) {return *(int *)p;}
static struct xbo_object *object(struct xbo_local *local) {
    struct xbo_source s=xbo_local_source(local);struct xbo_object *o=NULL;assert(xbo_create(&s,&o)==XBO_OK);return o;
}
static uint64_t prepare(struct xbo_object *o,uint64_t size,uint64_t calls) {
    uint64_t bytes=0;unsigned passes=0;
    for(;;) {
        struct xbo_budget b=budget(size,calls);enum xbo_status s=xbo_prepare(o,&b);bytes+=b.bytes_read;
        assert(b.bytes_read<=size && b.reads<=calls);assert(++passes<10000);
        if(s==XBO_OK)break;
        if(s!=XBO_AGAIN)fprintf(stderr,"unexpected prepare: %s\n",xbo_status_name(s));
        assert(s==XBO_AGAIN);assert(xbo_section_count(o)==0);
    }
    return bytes;
}
static void sparse(void) {
    for(int wide=0;wide<=1;wide++)for(int little=0;little<=1;little++)for(int ext=0;ext<=1;ext++) {
        struct fixture f=fixture(wide,little,ext);struct xbo_local local={f.fd};struct xbo_object *o=object(&local);
        int cancelled=1;struct xbo_budget b=budget(5000,100);b.cancelled=cancel;b.context=&cancelled;
        assert(xbo_prepare(o,&b)==XBO_CANCELLED);assert(b.bytes_read==0);cancelled=0;
        b=budget(5000,100);b.deadline_ns=xbo_now_ns()-1;assert(xbo_prepare(o,&b)==XBO_AGAIN);assert(b.bytes_read==0);
        uint64_t bytes=prepare(o,7,2);assert(bytes<1024);assert(xbo_memory_bytes(o)<4096);
        struct xbo_progress progress;xbo_progress(o,&progress);assert(progress.ready && progress.phase==8 && progress.bytes_charged==bytes && progress.source_size==f.size);
        assert(xbo_section_count(o)==4 && xbo_segment_count(o)==1);assert(xbo_address_size(o)==(wide?8u:4u));assert(xbo_little_endian(o)==(unsigned)little);
        uint32_t index;assert(xbo_find_section(o,".debug_info",&index)==XBO_OK && index==3);
        assert(xbo_find_section(o,".absent",&index)==XBO_NOT_FOUND);
        size_t n;const unsigned char *id=xbo_build_id(o,&n);assert(n==8 && !memcmp(id,"abcdefgh",8));
        const struct xbo_section *s=xbo_section(o,3);assert(s && s->offset==f.payload && s->size==32);
        unsigned char out[32]={0};size_t done=0;b=budget(3,1);assert(xbo_read(o,s->offset,out,sizeof out,&done,&b)==XBO_AGAIN && done==3);
        b=budget(32,32);assert(xbo_read(o,s->offset,out,sizeof out,&done,&b)==XBO_OK && done==32);
        for(unsigned i=0;i<32;i++)assert(out[i]==i+64);
        done=0;b=budget(64,10);assert(xbo_read(o,UINT64_MAX,out,sizeof out,&done,&b)==XBO_MALFORMED && done==0);
        struct stat st;assert(fstat(f.fd,&st)==0);assert((uint64_t)st.st_blocks*512<32768);
        assert(ftruncate(f.fd,256)==0);b=budget(64,10);assert(xbo_validate(o,&b)==XBO_CHANGED);assert(xbo_section_count(o)==0);
        assert(ftruncate(f.fd,(off_t)f.size)==0);b=budget(64,10);assert(xbo_validate(o,&b)==XBO_CHANGED);
        xbo_destroy(o);close_fixture(&f);
    }
    puts("8 sparse multi-GB ELF variants, extended numbering, byte/call budgets, cancellation, deadline, identity invalidation: pass");
}
struct unstable {struct xbo_source base;int fd,change,reported_change;};
static enum xbo_status unstable_id(void *p,struct xbo_identity *i) {struct unstable *u=p;if(u->reported_change)return XBO_CHANGED;return u->base.identity(u->base.context,i);}
static enum xbo_status unstable_read(void *p,uint64_t at,void *dst,size_t n) {
    struct unstable *u=p;enum xbo_status s=u->base.read(u->base.context,at,dst,n);
    if(u->change) {u->change=0;assert(ftruncate(u->fd,100)==0);}return s;
}
static void mutation(void) {
    struct fixture f=fixture(1,1,0);struct xbo_local local={f.fd};
    struct unstable u={.base=xbo_local_source(&local),.fd=f.fd,.change=1};
    struct xbo_source s={.context=&u,.identity=unstable_id,.read=unstable_read};struct xbo_object *o=NULL;assert(xbo_create(&s,&o)==XBO_OK);
    struct xbo_budget b=budget(10000,100);assert(xbo_prepare(o,&b)==XBO_CHANGED);assert(xbo_section_count(o)==0);
    xbo_destroy(o);close_fixture(&f);
    f=fixture(1,1,0);local.fd=f.fd;u=(struct unstable){.base=xbo_local_source(&local),.fd=f.fd};
    assert(xbo_create(&s,&o)==XBO_OK);prepare(o,4096,64);u.reported_change=1;
    b=budget(1000,100);assert(xbo_validate(o,&b)==XBO_CHANGED);u.reported_change=0;
    assert(xbo_validate(o,&b)==XBO_CHANGED);xbo_destroy(o);close_fixture(&f);
    int pipefd[2];assert(pipe(pipefd)==0);local.fd=pipefd[0];o=object(&local);b=budget(1000,100);assert(xbo_prepare(o,&b)==XBO_IO);xbo_destroy(o);close(pipefd[0]);close(pipefd[1]);
    puts("mutation during callback and nonregular source refusal: pass");
}
static void malformed(void) {
    for(unsigned i=0;i<8;i++) {
        struct fixture f=fixture(1,1,0);unsigned char data[8]={0};uint64_t at=0;unsigned n=8;
        switch(i) {
        case 0:at=0;n=4;memcpy(data,"nope",4);break;
        case 1:at=40;memset(data,255,8);break;
        case 2:at=f.table+64+24;memset(data,255,8);break;
        case 3:at=f.table+3*64;put(data,99999,4,1);n=4;break;
        case 4:at=260;put(data,65,4,1);n=4;break;
        case 5:at=f.table+64+32;put(data,2*1024*1024,8,1);break;
        case 6:at=56;put(data,5000,2,1);n=2;break;
        case 7:at=f.table+64+48;put(data,3,8,1);break;
        }
        write_at(f.fd,at,data,n);struct xbo_local l={f.fd};struct xbo_object *o=object(&l);struct xbo_budget b=budget(65536,1000);
        enum xbo_status s=xbo_prepare(o,&b);assert(s==XBO_MALFORMED || s==XBO_LIMIT || s==XBO_NOT_ELF);
        b=budget(65536,1000);assert(xbo_prepare(o,&b)==s);assert(xbo_section_count(o)==0);xbo_destroy(o);close_fixture(&f);
    }
    puts("8 malformed header/section/note cases refuse persistently: pass");
}
static void real(const char *path) {
    int fd=open(path,O_RDONLY|O_CLOEXEC|O_NONBLOCK);assert(fd>=0);struct xbo_local local={fd};struct xbo_object *o=object(&local);
    uint64_t bytes=prepare(o,4096,64);uint32_t i;assert(xbo_find_section(o,".debug_info",&i)==XBO_OK);
    const struct xbo_section *s=xbo_section(o,i);assert(s && s->size);unsigned char h[32];size_t done=0;struct xbo_budget b=budget(32,1);assert(xbo_read(o,s->offset,h,sizeof h,&done,&b)==XBO_OK);
    size_t n;const unsigned char *id=xbo_build_id(o,&n);assert(id&&n);
    printf("{\"size\":%"PRIu64",\"metadata_bytes\":%"PRIu64",\"memory_bytes\":%"PRIu64",\"info_offset\":%"PRIu64",\"info_size\":%"PRIu64",\"build_id\":\"",xbo_identity(o)->size,bytes,xbo_memory_bytes(o),s->offset,s->size);
    for(size_t j=0;j<n;j++)printf("%02x",id[j]);
    puts("\"}");xbo_destroy(o);close(fd);
}
int main(int argc,char **argv) {
    assert(argc<=2);sparse();mutation();malformed();if(argc==2)real(argv[1]);return 0;
}
