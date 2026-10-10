/* Fast lane: native field/value oracles for a planner that never writes. */
#define JAI_CONTAINER_NO_MAIN
#include "jai-container.c"
#include <limits.h>
struct write_value {
    int8_t i8;uint8_t u8;int16_t i16;uint16_t u16;int32_t i32;uint32_t u32;
    int64_t i64;uint64_t u64;unsigned char flag;float f32;double f64;
    int32_t state;struct span text;struct dynamic_value dynamic;
    struct base_value base;uint64_t pointer;int16_t fixed[3];
};
static struct write_value writable;
static int64_t write_numbers[]={11,22,33};
static struct xjai_graph *write_graph;
static uint32_t write_index;
static struct xjai_live_reader write_reader;
static int owned_read(void *ctx,uint64_t at,void *out,size_t n)
{
    (void)ctx;uint64_t begin=(uintptr_t)&writable;
    if (at<begin || n>sizeof writable || at-begin>sizeof writable-n) return 0;
    memcpy(out,(unsigned char *)&writable+(size_t)(at-begin),n);return 1;
}
static void write_fixture(void)
{
    struct xjai_region region;struct xjai_image im=container_fixture(&region);
    uint64_t ints[8];unsigned sizes[]={1,1,2,2,4,4,8,8};
    for (unsigned i=0;i<8;++i) {ints[i]=type(0,sizes[i],24);put(ints[i]+16,(i&1)==0,1);}
    uint64_t boolean=type(2,1,16),f32=type(1,4,16),f64=type(1,8,16),fields;
    uint64_t root=make_struct("FixtureWritable",sizeof writable,17,&fields);
    uint64_t ptr=type(4,8,24);put(ptr+16,root,8);
    uint64_t fixed=type(8,sizeof writable.fixed,40);put(fixed+16,ints[2],8);put(fixed+24,0,4);put(fixed+32,3,8);
    unsigned i=0;
#define ADD(name,ty) field(fields,i++,#name,ty,offsetof(struct write_value,name),0)
    ADD(i8,ints[0]);ADD(u8,ints[1]);ADD(i16,ints[2]);ADD(u16,ints[3]);
    ADD(i32,ints[4]);ADD(u32,ints[5]);ADD(i64,ints[6]);ADD(u64,ints[7]);
    ADD(flag,boolean);ADD(f32,f32);ADD(f64,f64);ADD(state,enum_type);ADD(text,string_type);
    ADD(dynamic,dynamic_type);ADD(base,base_type);ADD(pointer,ptr);ADD(fixed,fixed);
#undef ADD
    CHECK(i==17);region.size=used;build_graph(&im,&write_graph);write_index=xjai_type_at(write_graph,root);
    CHECK(write_index!=XJAI_NONE && !write_graph->types[write_index].reason);
    writable=(struct write_value){.i8=-8,.u8=8,.i16=-16,.u16=16,.i32=-32,.u32=32,.i64=-64,.u64=64,.flag=1,.f32=1.5,.f64=2.5,.state=7,.text={0,0},.dynamic={3,(uintptr_t)write_numbers,3,{UINT64_MAX,UINT64_MAX}},.base={-42},.pointer=(uintptr_t)&writable,.fixed={1,2,3}};
    write_reader=(struct xjai_live_reader){.read=owned_read};
}
static struct xjai_write_plan planned(const char *path,const char *value,int raw)
{
    struct xjai_write_plan p;write_reader.reads=write_reader.bytes=0;
    const char *why=xjai_write_plan(write_graph,write_index,(uintptr_t)&writable,path,strlen(path),value,strlen(value),raw,&write_reader,&p);
    if (why) fprintf(stderr,"plan %s %s: %s\n",path,value,why);
    CHECK(!why && p.type<write_graph->type_count && p.type_address==write_graph->types[p.type].address);return p;
}
static void invalid(const char *path,const char *value,int raw,const char *want)
{
    struct xjai_write_plan p;memset(&p,0xaa,sizeof p);write_reader.reads=write_reader.bytes=0;
    reason(xjai_write_plan(write_graph,write_index,(uintptr_t)&writable,path,strlen(path),value,strlen(value),raw,&write_reader,&p),want);
    const unsigned char *bytes=(const unsigned char *)&p;for (size_t i=0;i<sizeof p;++i) CHECK(bytes[i]==0);
}
int xjai_write_fixture_main(int argc,char **argv)
{
    write_fixture();struct write_value before=writable;int64_t before_numbers[3];memcpy(before_numbers,write_numbers,sizeof before_numbers);
    unsigned long rss_before=current_rss();struct timespec begin,end;CHECK(!clock_gettime(CLOCK_PROCESS_CPUTIME_ID,&begin));
    struct xjai_write_plan p=planned("base.score","77",0);int64_t expected=argc>1 && !strcmp(argv[1],"--wrong-oracle")?78:77;
    CHECK(p.address==(uintptr_t)&writable.base.score && p.size==sizeof expected && !memcmp(p.bytes,&expected,sizeof expected));
#define NATIVE(field,text,ty,number) do {ty v=(number);p=planned(#field,text,0);CHECK(p.address==(uintptr_t)&writable.field && p.size==sizeof v && !memcmp(p.bytes,&v,sizeof v));} while (0)
    NATIVE(i8,"-128",int8_t,INT8_MIN);NATIVE(i8,"127",int8_t,INT8_MAX);NATIVE(u8,"255",uint8_t,UINT8_MAX);
    NATIVE(i16,"-32768",int16_t,INT16_MIN);NATIVE(i16,"32767",int16_t,INT16_MAX);NATIVE(u16,"65535",uint16_t,UINT16_MAX);
    NATIVE(i32,"-2147483648",int32_t,INT32_MIN);NATIVE(i32,"2147483647",int32_t,INT32_MAX);NATIVE(u32,"4294967295",uint32_t,UINT32_MAX);
    NATIVE(i64,"-9223372036854775808",int64_t,INT64_MIN);NATIVE(i64,"9223372036854775807",int64_t,INT64_MAX);NATIVE(u64,"18446744073709551615",uint64_t,UINT64_MAX);
    NATIVE(i16,"-0x8000",int16_t,INT16_MIN);NATIVE(u32,"0xffffffff",uint32_t,UINT32_MAX);
    NATIVE(flag,"true",unsigned char,1);NATIVE(flag,"false",unsigned char,0);NATIVE(flag,"1",unsigned char,1);
    NATIVE(f32,"12.5",float,12.5f);NATIVE(f64,"-1.25e2",double,-125.0);NATIVE(f64,"-0",double,-0.0);
    NATIVE(state,"NEGATIVE",int32_t,-3);NATIVE(state,"-3",int32_t,-3);NATIVE(state,"READY",int32_t,7);
#undef NATIVE
    p=planned("fixed[2]","-123",0);int16_t small=-123;CHECK(p.address==(uintptr_t)&writable.fixed[2] && p.size==sizeof small && !memcmp(p.bytes,&small,sizeof small));
    p=planned("dynamic[1]","9223372036854775807",0);expected=INT64_MAX;CHECK(p.address==(uintptr_t)&write_numbers[1] && p.size==8 && !memcmp(p.bytes,&expected,8));CHECK(write_reader.reads==1 && write_reader.bytes==24);
    p=planned("pointer","0102030405060708",1);CHECK(p.address==(uintptr_t)&writable.pointer && p.size==8);for (unsigned i=0;i<8;++i) CHECK(p.bytes[i]==i+1);
    p=planned("text","00000000000000000000000000000000",1);CHECK(p.size==16 && p.address==(uintptr_t)&writable.text);
    char zeros[81];memset(zeros,'0',80);zeros[80]=0;p=planned("dynamic",zeros,1);CHECK(p.size==40);
    invalid("i8","128",0,"JaiWriteValueOutOfRange");invalid("i8","-129",0,"JaiWriteValueOutOfRange");
    invalid("u8","256",0,"JaiWriteValueOutOfRange");invalid("u8","-1",0,"JaiWriteValueOutOfRange");
    invalid("i16","32768",0,"JaiWriteValueOutOfRange");invalid("u16","65536",0,"JaiWriteValueOutOfRange");
    invalid("i32","2147483648",0,"JaiWriteValueOutOfRange");invalid("u32","4294967296",0,"JaiWriteValueOutOfRange");
    invalid("i64","9223372036854775808",0,"JaiWriteValueOutOfRange");invalid("i64","-9223372036854775809",0,"JaiWriteValueOutOfRange");
    invalid("u64","18446744073709551616",0,"JaiWriteValueOutOfRange");invalid("u64","0x10000000000000000",0,"JaiWriteValueOutOfRange");
    invalid("i8","+",0,"JaiWriteValueInvalid");invalid("i8","0x",0,"JaiWriteValueInvalid");invalid("i8","1junk",0,"JaiWriteValueInvalid");
    invalid("flag","2",0,"JaiWriteValueOutOfRange");invalid("f32","3.5e38",0,"JaiWriteValueOutOfRange");invalid("f64","1e999",0,"JaiWriteValueOutOfRange");
    invalid("f64","nan",0,"JaiWriteValueInvalid");invalid("f64","inf",0,"JaiWriteValueInvalid");invalid("f32","1e-99",0,"JaiWriteValueOutOfRange");
    invalid("f64","1,5",0,"JaiWriteValueInvalid");invalid("f64","1e+",0,"JaiWriteValueInvalid");invalid("state","8",0,"JaiWriteEnumValueUnknown");
    invalid("pointer","0",0,"JaiWriteNeedsRaw");invalid("text","0",0,"JaiWriteNeedsRaw");invalid("dynamic","0",0,"JaiWriteNeedsRaw");
    invalid("pointer","0000",1,"JaiWriteRawSizeMismatch");invalid("pointer","gg00000000000000",1,"JaiWriteValueInvalid");
    invalid("absent","1",0,"JaiWriteFieldNotFound");invalid("pointer.base.score","1",0,"JaiWriteExpectedStruct");
    invalid("base..score","1",0,"JaiWritePathInvalid");invalid("base.","1",0,"JaiWritePathInvalid");invalid("fixed.[0]","1",0,"JaiWritePathInvalid");
    invalid("fixed[-1]","1",0,"JaiWritePathInvalid");invalid("fixed[3]","1",0,"JaiWriteIndexOutOfRange");invalid("fixed[0]junk","1",0,"JaiWritePathInvalid");
    invalid("fixed[18446744073709551616]","1",0,"JaiWriteIndexOutOfRange");invalid("i8[0]","1",0,"JaiWriteExpectedArray");
    writable.dynamic.count=4;invalid("dynamic[0]","1",0,"JaiArrayHeaderInvalid");writable.dynamic=before.dynamic;
    writable.dynamic.data=UINT64_MAX-1;invalid("dynamic[0]","1",0,"JaiArrayHeaderInvalid");writable.dynamic=before.dynamic;
    struct xjai_member *first=&write_graph->members[write_graph->types[write_index].first_member];uint32_t flags=first[0].flags;
    first[0].flags|=(uint32_t)write_graph->layout.flags[XJAI_F_CONSTANT];invalid("i8","01",1,"JaiWriteConstant");first[0].flags=flags;
    uint32_t name=first[1].name;first[1].name=first[0].name;invalid("i8","1",0,"JaiWriteFieldAmbiguous");first[1].name=name;
    uint64_t offset=first[0].offset;first[0].offset=sizeof writable;invalid("i8","1",0,"JaiWriteTypeUnproved");first[0].offset=offset;
    reason(xjai_write_plan(write_graph,write_index,UINT64_MAX-8,"i8",2,"1",1,0,&write_reader,&p),"JaiWriteAddressInvalid");CHECK(!p.size);
    reason(xjai_write_plan(write_graph,write_index,(uintptr_t)&writable,"i8\0x",4,"1",1,0,&write_reader,&p),"JaiWriteInvalidArguments");
    reason(xjai_write_plan(write_graph,write_index,(uintptr_t)&writable,"i8",2,"1\0x",3,0,&write_reader,&p),"JaiWriteInvalidArguments");
    write_reader.reads=512;reason(xjai_write_plan(write_graph,write_index,(uintptr_t)&writable,"dynamic[0]",10,"1",1,0,&write_reader,&p),"JaiValueReadBudget");
    /* A wide outer struct consumes the same budget as the nested leaf. */
    uint32_t old_first=write_graph->types[write_index].first_member,old_count=write_graph->types[write_index].member_count,old_members=write_graph->member_count;
    struct xjai_member *original=write_graph->members,*wide=calloc(old_members+4096,sizeof *wide);CHECK(wide);
    memcpy(wide,original,old_members*sizeof *wide);
    for (unsigned i=0;i<4096;++i) wide[old_members+i]=first[0];
    wide[old_members]=first[14];
    write_graph->members=wide;write_graph->member_count=old_members+4096;
    write_graph->types[write_index].first_member=old_members;write_graph->types[write_index].member_count=4096;
    invalid("base.score","1",0,"JaiWriteWorkLimit");
    write_graph->types[write_index].member_count=4095;p=planned("base.score","1",0);CHECK(p.address==(uintptr_t)&writable.base.score);
    write_graph->members=original;write_graph->member_count=old_members;write_graph->types[write_index].first_member=old_first;write_graph->types[write_index].member_count=old_count;free(wide);
    uint32_t base_index=first[14].type;offset=first[14].offset;first[14].type=write_index;first[14].offset=0;
    char deep[100]={0};for (unsigned i=0;i<16;++i) strcat(deep,"base.");strcat(deep,"i8");invalid(deep,"1",0,"JaiWritePathDepth");first[14].type=base_index;first[14].offset=offset;
    struct xjai_type *enum_info=&write_graph->types[xjai_type_at(write_graph,enum_type)];struct xjai_enum_value *en=&write_graph->enums[enum_info->first_enum];
    uint64_t old_bits=en[0].bits;en[0].bits=UINT64_C(0x100000001);
    invalid("state","NEGATIVE",0,"JaiWriteEnumValueOutOfRange");invalid("state","1",0,"JaiWriteEnumValueUnknown");en[0].bits=old_bits;
    uint32_t old_enum_name=en[1].name;en[1].name=en[0].name;invalid("state","NEGATIVE",0,"JaiWriteEnumAmbiguous");en[1].name=old_enum_name;
    uint64_t old_size=write_graph->types[first[0].type].size;write_graph->types[first[0].type].size=65;
    invalid("i8",zeros,1,"JaiWriteSizeLimit");write_graph->types[first[0].type].size=old_size;
    CHECK(!memcmp(&writable,&before,sizeof before) && !memcmp(write_numbers,before_numbers,sizeof before_numbers));
    CHECK(!clock_gettime(CLOCK_PROCESS_CPUTIME_ID,&end));printf("{\"cpu_ns\":%llu,\"rss_before\":%lu,\"rss_after\":%lu,\"explicit_plan_heap_bytes\":0,\"plan_bytes\":%zu}\n",(unsigned long long)((end.tv_sec-begin.tv_sec)*1000000000LL+end.tv_nsec-begin.tv_nsec),rss_before,current_rss(),sizeof p);
    xjai_graph_free(write_graph);write_graph=NULL;puts("Jai write plans: native offsets/values, exact ranges, enums, raw headers, paths and unchanged storage PASS");return 0;
}
#ifndef JAI_WRITE_NO_MAIN
int main(int argc,char **argv) {return xjai_write_fixture_main(argc,argv);}
#endif
