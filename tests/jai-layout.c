/* Fast lane: synthetic image only. Never includes captured program data. */
#include "../src/language/jai.h"
#include "check.h"
#include <stddef.h>
#include <string.h>
struct span { int64_t count; uint64_t data; };
struct header { uint32_t tag,padding; int64_t size; };
struct schema_struct {
    struct header info;struct span name,parameters,specified_parameters,members,bindings;
    uint32_t status,nontextual,textual;int32_t alignment;
    uint64_t polymorph,initializer;struct span constants,notes;
};
struct schema_member {
    struct span name;uint64_t type;int64_t offset;uint32_t flags,padding;
    struct span notes;int64_t constant_offset;
};
#ifndef JAI_FIXTURE_BYTES
#define JAI_FIXTURE_BYTES 32768
#endif
#ifndef JAI_FIXTURE_ALIGN
#define JAI_FIXTURE_ALIGN 8
#endif
_Alignas(JAI_FIXTURE_ALIGN) static unsigned char arena[JAI_FIXTURE_BYTES];
static uint64_t origin=UINT64_C(0x20000000002000);static size_t used;
static uint64_t self,member,header,tag_enum,flags_enum,tag_values,self_members,member_members;
static unsigned member_stride,struct_bytes;
static uint64_t alloc(size_t n)
{
    used=(used+7)&~(size_t)7;CHECK(n<=sizeof arena-used);uint64_t p=origin+used;used+=n;return p;
}
static void put(uint64_t at,uint64_t v,unsigned n)
{
    CHECK(at>=origin && at-origin<=sizeof arena-n);
    for (unsigned i=0;i<n;++i) arena[at-origin+i]=(unsigned char)(v>>(i*8));
}
static void span(uint64_t at,uint64_t n,uint64_t data) {put(at,n,8);put(at+8,data,8);}
static void name(uint64_t at,const char *s)
{
    size_t n=strlen(s);uint64_t p=alloc(n);memcpy(arena+(p-origin),s,n);span(at,n,p);
}
static uint64_t type(unsigned tag,unsigned size,size_t extent)
{
    uint64_t at=alloc(extent);put(at,tag,4);put(at+4,0xa5a5a5a5,4);put(at+8,size,8);return at;
}
static uint64_t enumeration(const char *label,const char *const *names,const uint64_t *values,size_t n,uint64_t integer,uint64_t *vp)
{
    uint64_t e=type(11,4,80);name(e+16,label);put(e+32,integer,8);
    uint64_t np=alloc(n*16);*vp=alloc(n*8);span(e+40,n,np);span(e+56,n,*vp);
    for (size_t i=0;i<n;++i) {name(np+16*i,names[i]);put(*vp+8*i,values[i],8);}return e;
}
static void field(uint64_t table,unsigned i,const char *n,uint64_t t,uint64_t offset,unsigned flags)
{
    uint64_t m=table+i*member_stride;name(m,n);put(m+16,t,8);put(m+24,offset,8);
    put(m+offsetof(struct schema_member,flags),flags,4);put(m+offsetof(struct schema_member,constant_offset),UINT64_MAX,8);
}
static struct xjai_image fixture(unsigned extension,struct xjai_region *region)
{
    memset(arena,0,sizeof arena);used=0;member_stride=sizeof(struct schema_member)+extension;struct_bytes=sizeof(struct schema_struct)+extension;
    self=type(7,struct_bytes,512);name(self+16,"Type_Info_Struct");
    member=type(7,member_stride,512);name(member+16,"Type_Info_Struct_Member");
    header=type(7,16,512);name(header+16,"Type_Info");
    uint64_t u32=type(0,4,24),s32=type(0,4,24),s64=type(0,8,24),string=type(3,16,16),meta=type(13,8,16);
    put(s32+16,1,1);put(s64+16,1,1);
    uint64_t ptr=type(4,8,24);put(ptr+16,header,8);uint64_t proc=type(5,8,16);
    uint64_t array=type(8,16,40);put(array+16,member,8);put(array+24,1,4);put(array+32,UINT64_MAX,8);
    static const char *const tags[]={"INTEGER","FLOAT","BOOL","STRING","POINTER","PROCEDURE","VOID","STRUCT","ARRAY","OVERLOAD_SET","ANY","ENUM","POLYMORPHIC_VARIABLE","TYPE","CODE","UNTYPED_LITERAL","UNTYPED_ENUM","VARIANT"};
    uint64_t values[18];for (unsigned i=0;i<18;++i) values[i]=i==17?18:i;
    tag_enum=enumeration("Type_Info_Tag",tags,values,18,u32,&tag_values);
    static const char *const flags[]={"CONSTANT","IMPORTED","USING","PROCEDURE_WITH_VOID_POINTER_TYPE_INFO","AS","OVERLAY"};
    uint64_t fv[]={1,2,4,8,16,32},ignored;flags_enum=enumeration("Flags",flags,fv,6,u32,&ignored);
    unsigned mo=offsetof(struct schema_struct,members)+extension;
    self_members=alloc(XJAI_S_FIELDS*member_stride);span(self+mo,XJAI_S_FIELDS,self_members);
    const char *const sn[]={"info","name","parameters","specified_parameters","members","tagged_union_bindings","status_flags","nontextual_flags","textual_flags","alignment","polymorph_source_struct","initializer","constant_storage","notes"};
    uint64_t st[]={header,string,array,array,array,array,flags_enum,flags_enum,flags_enum,s32,ptr,proc,array,array};
    unsigned so[]={offsetof(struct schema_struct,info),offsetof(struct schema_struct,name),offsetof(struct schema_struct,parameters),offsetof(struct schema_struct,specified_parameters),offsetof(struct schema_struct,members),offsetof(struct schema_struct,bindings),offsetof(struct schema_struct,status),offsetof(struct schema_struct,nontextual),offsetof(struct schema_struct,textual),offsetof(struct schema_struct,alignment),offsetof(struct schema_struct,polymorph),offsetof(struct schema_struct,initializer),offsetof(struct schema_struct,constants),offsetof(struct schema_struct,notes)};
    for (unsigned i=0;i<XJAI_S_FIELDS;++i) field(self_members,i,sn[i],st[i],so[i]+(i>=XJAI_S_MEMBERS?extension:0),i==0?20:0);
    member_members=alloc(7*member_stride);span(member+mo,7,member_members);
    const char *const mn[]={"name","type","offset_in_bytes","flags","notes","offset_into_constant_storage","Flags"};
    uint64_t mt[]={string,ptr,s64,flags_enum,array,s64,meta};
    unsigned offsets[]={offsetof(struct schema_member,name),offsetof(struct schema_member,type),offsetof(struct schema_member,offset),offsetof(struct schema_member,flags),offsetof(struct schema_member,notes),offsetof(struct schema_member,constant_offset)};
    for (unsigned i=0;i<7;++i) field(member_members,i,mn[i],mt[i],i==6?UINT64_MAX:offsets[i],i==6?1:0);
    uint64_t hm=alloc(2*member_stride);span(header+mo,2,hm);
    field(hm,0,"type",tag_enum,offsetof(struct header,tag),0);field(hm,1,"runtime_size",s64,offsetof(struct header,size),0);
    *region=(struct xjai_region){origin,arena,used};return (struct xjai_image){region,1};
}
static void rejected(struct xjai_image *im,const char *want)
{
    struct xjai_layout l;memset(&l,0xaa,sizeof l);const char *why=xjai_layout_detect(im,&l);
    CHECK(why && !strcmp(why,want));const unsigned char *p=(const unsigned char *)&l;
    for (size_t i=0;i<sizeof l;++i) CHECK(p[i]==0);
}
int main(int argc,char **argv)
{
    struct xjai_region region;struct xjai_image im=fixture(0,&region);struct xjai_layout l;
    CHECK(!xjai_layout_detect(&im,&l));
    CHECK(l.struct_size==sizeof(struct schema_struct)+(argc>1 && !strcmp(argv[1],"--wrong-oracle")));
    CHECK(l.member_size==sizeof(struct schema_member));CHECK(l.so[XJAI_S_MEMBERS]==offsetof(struct schema_struct,members));
    CHECK(l.mo[XJAI_M_CONSTANT_OFFSET]==offsetof(struct schema_member,constant_offset));CHECK(l.flags[XJAI_F_USING]==4);
    CHECK(l.struct_type==self && l.member_type==member && l.header_type==header && l.tag_type==tag_enum && l.flags_type==flags_enum);
    uint64_t first=l.fingerprint;CHECK(first!=0);
    printf("{\"struct_size\":%zu,\"member_size\":%zu,\"members_offset\":%zu,\"flags_offset\":%zu,\"fingerprint\":\"%016llx\"}\n",sizeof(struct schema_struct),sizeof(struct schema_member),offsetof(struct schema_struct,members),offsetof(struct schema_member,flags),(unsigned long long)first);
    origin+=0x100000;im=fixture(0,&region);CHECK(!xjai_layout_detect(&im,&l) && l.fingerprint==first);
    im=fixture(8,&region);CHECK(!xjai_layout_detect(&im,&l));CHECK(l.member_size==72 && l.struct_size==168 && l.so[XJAI_S_MEMBERS]==72 && l.fingerprint!=first);
    im=fixture(0,&region);put(tag_values+7*8,19,8);rejected(&im,"JaiTagValueMismatch");
    im=fixture(0,&region);put(self_members+XJAI_S_MEMBERS*member_stride+24,72,8);rejected(&im,"JaiSelfDescriptionUnproved");
    im=fixture(0,&region);put(member_members+XJAI_M_FLAGS*member_stride+24,33,8);rejected(&im,"JaiSelfDescriptionUnproved");
    im=fixture(0,&region);put(member_members+6*member_stride+offsetof(struct schema_member,flags),0,4);rejected(&im,"JaiSelfDescriptionUnproved");
    im=fixture(0,&region);put(self+64,UINT64_MAX,8);rejected(&im,"JaiSelfDescriptionUnproved");
    im=fixture(0,&region);put(self+72,UINT64_MAX-7,8);rejected(&im,"JaiSelfDescriptionUnproved");
    im=fixture(0,&region);put(self+16,UINT64_MAX,8);rejected(&im,"JaiLayoutUnavailable");
    im=fixture(0,&region);uint64_t duplicate=alloc(512);memcpy(arena+(duplicate-origin),arena+(self-origin),512);region.size=used;rejected(&im,"JaiLayoutAmbiguous");
    im=fixture(0,&region);region.address=UINT64_MAX-16;rejected(&im,"JaiInvalidImage");
    im=fixture(0,&region);region.size=XJAI_IMAGE_BYTES+1;rejected(&im,"JaiImageLimit");
    im=fixture(0,&region);struct xjai_region split[2]={{origin,arena,512},{origin+512,arena+512,used-512}};im=(struct xjai_image){split,2};CHECK(!xjai_layout_detect(&im,&l) && l.fingerprint==first);
    split[1].address--;rejected(&im,"JaiInvalidImage");
    im=fixture(0,&region);region.size=31;rejected(&im,"JaiLayoutUnavailable");
    puts("Jai layout: self-described offsets, constants, relocation, changed layout and corrupt refusals PASS");return 0;
}
