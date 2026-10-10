#define _POSIX_C_SOURCE 200809L
#include "../src/language/go_map.h"
#include "check.h"
#include <string.h>
#include <time.h>
#include <unistd.h>
#define LO UINT64_C(0x10000)
static uint8_t memory[0x90000];
static struct xgm_layout l;
static uint64_t unreadable, changed;
static size_t calls;
enum { MD=0x10000, MT=0x11000, KT=0x11200, VT=0x11400, GT=0x11600, NAME=0x11a00,
       MAP=0x15000, DIR=0x15100, TABLE=0x15200, GROUP=0x16000, PAYLOAD=0x90000 };
static int read_memory(void *ctx,uint64_t at,void *out,size_t n) {
    (void)ctx;++calls;
    if(at<LO || at-LO>sizeof memory || n>sizeof memory-(at-LO))return -1;
    if(unreadable && at<=unreadable && unreadable-at<n)return -1;
    memcpy(out,memory+(at-LO),n);
    if(at==changed)memory[at-LO]^=1;
    return 0;
}
static void raw(uint64_t at,uint64_t value,unsigned n) {
    CHECK(n<=8 && at>=LO && at-LO+n<=sizeof memory);
    for(unsigned i=0;i<n;++i)memory[at-LO+i]=(uint8_t)(value>>(8*i));
}
static void vf(uint64_t at,unsigned f,uint64_t value) { raw(at+l.values.fields[f].offset,value,l.values.fields[f].size); }
static void mf(uint64_t at,unsigned f,uint64_t value) { raw(at+l.fields[f].offset,value,l.fields[f].size); }
static void type(uint64_t at,unsigned kind,uint64_t size,uint64_t pointers,unsigned slot,const char *name) {
    vf(at,XGV_T_SIZE,size);vf(at,XGV_T_PTRBYTES,pointers);vf(at,XGV_T_HASH,slot+11);
    vf(at,XGV_T_FLAGS,size==8 && pointers==8 ? 32:0);vf(at,XGV_T_KIND,kind);
    vf(at,XGV_T_ALIGN,1);vf(at,XGV_T_FIELDALIGN,1);
    uint64_t str=NAME+slot*128;vf(at,XGV_T_NAME,str-MT);raw(str+1,strlen(name),1);
    memcpy(memory+(str+2-LO),name,strlen(name));
}
static void group(uint64_t at,unsigned used) {
    memset(memory+(at-LO),128,8);
    for(unsigned i=0;i<used;++i) {raw(at+i,i,1);raw(at+8+i*16,10+i,8);raw(at+16+i*16,100+i,8);}
}
static void image(void) {
    memset(memory,0,sizeof memory);memset(&l,0,sizeof l);unreadable=changed=0;
#define XGV_FIELD(key, owner, path, kind, width) \
    l.values.fields[XGV_##key]=(struct xgo_field_info){l.values.sizes[XGV_T_##owner],width};l.values.sizes[XGV_T_##owner]+=width;
#include "../src/language/go_value_fields.inc"
#undef XGV_FIELD
#define XGV_CONSTANT(key, name, value) l.values.constants[XGV_C_##key]=value;
#include "../src/language/go_value_constants.inc"
#undef XGV_CONSTANT
    l.values.build_id_len=1;l.values.build_id[0]=1;
    l.sizes[XGM_T_TYPE]=l.values.sizes[XGV_T_TYPE];
#define XGM_FIELD(key, owner, path, kind, width) \
    l.fields[XGM_##key]=(struct xgo_field_info){l.sizes[XGM_T_##owner],width};l.sizes[XGM_T_##owner]+=width;
#include "../src/language/go_map_fields.inc"
#undef XGM_FIELD
#define XGM_CONSTANT(key, name, value) l.constants[XGM_C_##key]=value;
#include "../src/language/go_map_constants.inc"
#undef XGM_CONSTANT
    vf(MD,XGV_MD_TYPES,MT);vf(MD,XGV_MD_ETYPES,0x14000);
    type(MT,21,8,8,0,"map[int]int");type(KT,2,8,0,1,"int");type(VT,2,8,0,2,"int");type(GT,25,136,0,3,"group");
    mf(MT,XGM_T_KEY,KT);mf(MT,XGM_T_ELEM,VT);mf(MT,XGM_T_GROUP,GT);mf(MT,XGM_T_GROUP_SIZE,136);
    mf(MT,XGM_T_KEYS_OFF,8);mf(MT,XGM_T_KEY_STRIDE,16);mf(MT,XGM_T_ELEMS_OFF,16);mf(MT,XGM_T_ELEM_STRIDE,16);
    mf(MAP,XGM_M_USED,3);mf(MAP,XGM_M_DIR,GROUP);group(GROUP,3);
}
static void table(void) {
    mf(MAP,XGM_M_DIR,DIR);mf(MAP,XGM_M_DIR_LEN,1);mf(MAP,XGM_M_SHIFT,64);raw(DIR,TABLE,8);
    mf(TABLE,XGM_TB_USED,3);mf(TABLE,XGM_TB_CAP,8);mf(TABLE,XGM_TB_GROWTH,4);mf(TABLE,XGM_TB_GROUPS,GROUP);
}
static struct xgm_page read_page(uint64_t start,unsigned limit) {
    struct xgm_page p;struct xgo_reader r={.read=read_memory};calls=0;
    xgm_map_read(&l,&r,MD,MT,MAP,start,limit,&p);CHECK(calls==r.reads);return p;
}
static void why(const char *got,const char *want) { CHECK(got && !strcmp(got,want)); }
static uint64_t cpu(void) {struct timespec t;CHECK(!clock_gettime(CLOCK_PROCESS_CPUTIME_ID,&t));return (uint64_t)t.tv_sec*1000000000+(uint64_t)t.tv_nsec;}
static uint64_t rss(void) {FILE*f=fopen("/proc/self/statm","r");unsigned long long a,b;CHECK(f && fscanf(f,"%llu %llu",&a,&b)==2);fclose(f);return b*(uint64_t)sysconf(_SC_PAGESIZE);}
void go_map_tests(void) {
    image();struct xgm_page p=read_page(0,2);CHECK(!p.reason && p.total==3 && p.count==2 && p.next==2 && !p.complete);
    CHECK(p.entries[0].key==GROUP+8 && p.entries[0].value==GROUP+16);
    p=read_page(2,2);CHECK(!p.reason && p.count==1 && p.next==3 && p.complete);
    p=read_page(UINT64_MAX,2);CHECK(!p.reason && !p.count && p.next==3 && p.complete);
    p=read_page(0,65);why(p.reason,"GoMapPageLimit");CHECK(!calls);
    image();table();p=read_page(0,64);CHECK(!p.reason && p.tables==1 && p.groups==1 && p.total==3);
    /* One table shared by two adjacent directory slots must appear once. */
    mf(MAP,XGM_M_DIR_LEN,2);mf(MAP,XGM_M_DEPTH,1);mf(MAP,XGM_M_SHIFT,63);raw(DIR+8,TABLE,8);
    p=read_page(0,64);CHECK(!p.reason && p.tables==1 && p.count==3);
    raw(DIR+8,TABLE+128,8);p=read_page(0,64);why(p.reason,"GoMapDirectoryInvalid");CHECK(!p.count);
    image();table();mf(TABLE,XGM_TB_INDEX,UINT64_MAX);p=read_page(0,64);why(p.reason,"GoMapTableInvalid");
    image();table();mf(TABLE,XGM_TB_MASK,2);p=read_page(0,64);why(p.reason,"GoMapTableInvalid");
    image();table();mf(TABLE,XGM_TB_USED,4);p=read_page(0,64);why(p.reason,"GoMapCountMismatch");
    image();table();mf(TABLE,XGM_TB_GROWTH,3);p=read_page(0,64);why(p.reason,"GoMapCountMismatch");
    image();table();mf(MAP,XGM_M_USED,4);p=read_page(0,64);why(p.reason,"GoMapCountMismatch");
    image();table();mf(TABLE,XGM_TB_GROWTH,3);mf(MAP,XGM_M_TOMBSTONES,1);raw(GROUP+7,254,1);
    p=read_page(0,64);CHECK(!p.reason && p.deleted==1 && p.count==3);
    mf(MAP,XGM_M_TOMBSTONES,0);p=read_page(0,64);why(p.reason,"GoMapControlInvalid");
    image();raw(GROUP+7,254,1);mf(MAP,XGM_M_TOMBSTONES,1);p=read_page(0,64);why(p.reason,"GoMapControlInvalid");
    image();raw(GROUP+7,255,1);p=read_page(0,64);why(p.reason,"GoMapControlInvalid");
    image();mf(MAP,XGM_M_WRITING,1);p=read_page(0,64);why(p.reason,"GoMapBusy");
    image();mf(MAP,XGM_M_USED,9);p=read_page(0,64);why(p.reason,"GoMapHeaderInvalid");
    image();mf(MAP,XGM_M_DIR_LEN,UINT64_MAX);p=read_page(0,64);why(p.reason,"GoMapDirectoryLimit");
    image();table();mf(MAP,XGM_M_SHIFT,0);p=read_page(0,64);why(p.reason,"GoMapDirectoryInvalid");
    image();mf(MT,XGM_T_GROUP_SIZE,128);p=read_page(0,64);why(p.reason,"GoMapGroupSizeMismatch");
    image();mf(MT,XGM_T_KEY_STRIDE,UINT64_MAX);p=read_page(0,64);why(p.reason,"GoMapSlotLayoutInvalid");
    image();mf(MT,XGM_T_KEYS_OFF,16);p=read_page(0,64);why(p.reason,"GoMapSlotLayoutInvalid");
    image();mf(MT,XGM_T_FLAGS,4);p=read_page(0,64);why(p.reason,"GoMapIndirectFlagMismatch");
    image();type(KT,17,129,0,1,"[129]uint8");mf(MT,XGM_T_FLAGS,4);
    for(unsigned i=0;i<3;++i)raw(GROUP+8+i*16,PAYLOAD+i*256,8);
    p=read_page(0,64);CHECK(!p.reason && p.entries[0].key==PAYLOAD);
    raw(GROUP+8,0,8);p=read_page(0,64);why(p.reason,"GoMapIndirectStorageInvalid");
    image();changed=MAP;p=read_page(0,64);why(p.reason,"GoValueChanged");CHECK(!p.count);
    image();table();changed=DIR;p=read_page(0,64);why(p.reason,"GoValueChanged");
    image();table();changed=TABLE;p=read_page(0,64);why(p.reason,"GoValueChanged");
    image();changed=GROUP;p=read_page(0,64);why(p.reason,"GoValueChanged");
    image();unreadable=GROUP;p=read_page(0,64);why(p.reason,"GoValueUnreadable");
    image();struct xgo_reader r={.read=read_memory,.bytes=XGV_BYTE_LIMIT+1};calls=0;
    xgm_map_read(&l,&r,MD,MT,MAP,0,64,&p);why(p.reason,"GoValueReadLimit");CHECK(!calls);
    image();r=(struct xgo_reader){.read=read_memory};xgm_map_read(&l,&r,MD,MT,0,0,64,&p);CHECK(!p.reason && p.is_nil && p.complete && !p.count);
    image();table();mf(MAP,XGM_M_USED,0);mf(TABLE,XGM_TB_USED,0);mf(TABLE,XGM_TB_CAP,1024);mf(TABLE,XGM_TB_MASK,127);mf(TABLE,XGM_TB_GROWTH,896);
    for(unsigned i=0;i<128;++i)group(GROUP+i*136,0);
    uint64_t rb=rss(),cb=cpu();p=read_page(0,64);uint64_t ca=cpu(),ra=rss();
    CHECK(!p.reason && p.groups==128 && p.complete && !p.count);
    printf("go-maps-cost: groups=%u cpu_ns=%llu rss_before=%llu rss_after=%llu\n",p.groups,(unsigned long long)(ca-cb),(unsigned long long)rb,(unsigned long long)ra);
    image();mf(MAP,XGM_M_USED,0);mf(MAP,XGM_M_DIR,DIR);mf(MAP,XGM_M_DIR_LEN,32);mf(MAP,XGM_M_DEPTH,5);mf(MAP,XGM_M_SHIFT,59);
    for(unsigned t=0;t<32;++t) {
        uint64_t at=0x14000+t*64,groups=GROUP+t*128*136;
        raw(DIR+t*8,at,8);mf(at,XGM_TB_CAP,1024);mf(at,XGM_TB_GROWTH,896);mf(at,XGM_TB_DEPTH,5);mf(at,XGM_TB_INDEX,t);
        mf(at,XGM_TB_GROUPS,groups);mf(at,XGM_TB_MASK,127);
        for(unsigned g=0;g<128;++g)group(groups+g*136,0);
    }
    rb=rss();cb=cpu();p=read_page(0,64);ca=cpu();ra=rss();
    why(p.reason,"GoMapGroupLimit");CHECK(p.groups==XGM_GROUP_LIMIT && !p.count && !p.total);
    printf("go-maps-limit-cost: groups=%u cpu_ns=%llu rss_before=%llu rss_after=%llu\n",p.groups,(unsigned long long)(ca-cb),(unsigned long long)rb,(unsigned long long)ra);
    puts("go-maps-component: pages, shared tables, count corroboration, corruptions, stale reads and bounds pass");
}
#ifdef XGM_TEST_MAIN
int main(int argc,char **argv) {(void)argv;go_map_tests();if(argc>1){image();struct xgm_page p=read_page(0,64);CHECK(p.total==4);}return 0;}
#endif
