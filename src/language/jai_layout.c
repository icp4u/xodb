#include "jai_internal.h"

static const char *const tags[]={
    "INTEGER","FLOAT","BOOL","STRING","POINTER","PROCEDURE","VOID","STRUCT",
    "ARRAY","OVERLOAD_SET","ANY","ENUM","POLYMORPHIC_VARIABLE","TYPE","CODE",
    "UNTYPED_LITERAL","UNTYPED_ENUM","VARIANT"
};
static const char *const flag_names[]={
    "CONSTANT","IMPORTED","USING","PROCEDURE_WITH_VOID_POINTER_TYPE_INFO","AS","OVERLAY"
};
/* This seed enum encoding is corroborated by both Type_Info_Tag's values and
 * the member flags enum. It is not claimed to come from a missing enum schema. */
static int enum_values(struct reader *r,uint64_t at,const char *const *names,size_t wanted,uint64_t *values)
{
    uint64_t base,n,np,m,vp;
    if (!bytes(r,at,80) || !type(r,at,11,4) || !get(r,at+32,8,&base) || !integer(r,base,4,0) ||
        !array(r,at+40,&n,&np,64,16) || !array(r,at+56,&m,&vp,64,8) || n!=m || n!=wanted) return 0;
    unsigned char seen[64]={0};
    for (size_t i=0;i<n;++i) {
        size_t j;for (j=0;j<wanted;++j) if (str_eq(r,np+16*i,names[j])) break;
        if (j==wanted || seen[j]++ || !get(r,vp+8*i,8,&values[j])) return 0;
    }
    return 1;
}
struct field { const char *name;unsigned tag,size; };
static const struct field sf[]={
    {"info",7,16},{"name",3,16},{"parameters",8,16},{"specified_parameters",8,16},
    {"members",8,16},{"tagged_union_bindings",8,16},{"status_flags",11,4},
    {"nontextual_flags",11,4},{"textual_flags",11,4},{"alignment",0,4},
    {"polymorph_source_struct",4,8},{"initializer",5,8},{"constant_storage",8,16},{"notes",8,16}
};
static const struct field mf[]={
    {"name",3,16},{"type",4,8},{"offset_in_bytes",0,8},{"flags",11,4},
    {"notes",8,16},{"offset_into_constant_storage",0,8}
};
/* Bootstrap member prefix: name string, type pointer, instance offset. The
 * member self-description must explicitly corroborate all three positions. */
static int fields(struct reader *r,uint64_t table,uint64_t count,uint32_t stride,
                  uint32_t size,const struct field *want,size_t n,uint32_t *offsets,uint64_t *types)
{
    unsigned char seen[XJAI_S_FIELDS]={0};
    for (uint64_t i=0;i<count;++i) {
        uint64_t m=table+i*stride,off,t;size_t j;
        for (j=0;j<n;++j) if (str_eq(r,m,want[j].name)) break;
        if (j==n) continue;
        if (seen[j]++ || !get(r,m+16,8,&t) || !get(r,m+24,8,&off) ||
            off>size || want[j].size>size-off || !type(r,t,want[j].tag,want[j].size)) return 0;
        offsets[j]=(uint32_t)off;types[j]=t;
    }
    for (size_t i=0;i<n;++i) if (!seen[i]) return 0;
    /* The required data fields cannot alias each other. */
    for (size_t i=0;i<n;++i) for (size_t j=i+1;j<n;++j)
        if (offsets[i]<offsets[j]+want[j].size && offsets[j]<offsets[i]+want[i].size) return 0;
    return 1;
}
static int validate(struct reader *r,uint64_t self,uint64_t tag_type,uint32_t members,uint32_t stride,struct xjai_layout *l)
{
    uint64_t size,count,table,st[XJAI_S_FIELDS],mt[XJAI_M_FIELDS];
    if (!get(r,self+8,8,&size) || size<32 || size>512 || !bytes(r,self,(size_t)size) || members>size-16 ||
        !array(r,self+members,&count,&table,64,stride) || count<XJAI_S_FIELDS) return 0;
    memset(l,0,sizeof *l);l->profile=XJAI_PROFILE;l->struct_size=(uint32_t)size;l->member_size=stride;
    if (!fields(r,table,count,stride,l->struct_size,sf,XJAI_S_FIELDS,l->so,st) ||
        l->so[XJAI_S_INFO]!=0 || l->so[XJAI_S_NAME]!=16 || l->so[XJAI_S_MEMBERS]!=members) return 0;
    uint64_t member_type,kind;
    if (!bytes(r,st[XJAI_S_MEMBERS],40) || !get(r,st[XJAI_S_MEMBERS]+16,8,&member_type) || !get(r,st[XJAI_S_MEMBERS]+24,2,&kind) || kind!=1 ||
        !bytes(r,member_type,(size_t)size) || !type(r,member_type,7,stride) || !str_eq(r,member_type+16,"Type_Info_Struct_Member") ||
        !array(r,member_type+members,&count,&table,64,stride) ||
        !fields(r,table,count,stride,stride,mf,XJAI_M_FIELDS,l->mo,mt) ||
        l->mo[XJAI_M_NAME]!=0 || l->mo[XJAI_M_TYPE]!=16 || l->mo[XJAI_M_OFFSET]!=24 ||
        !integer(r,mt[XJAI_M_OFFSET],8,1) || !integer(r,mt[XJAI_M_CONSTANT_OFFSET],8,1)) return 0;
    if (!enum_values(r,mt[XJAI_M_FLAGS],flag_names,XJAI_F_FLAGS,l->flags)) return 0;
    uint64_t bits=0;
    for (unsigned i=0;i<XJAI_F_FLAGS;++i) {
        uint64_t v=l->flags[i];if (!v || v>UINT32_MAX || (v&(v-1)) || (bits&v)) return 0;bits|=v;
    }
    /* Constants legitimately have offset -1. Every nonconstant member of the
     * metadata schema must fit the record; all flags must be understood. */
    for (unsigned which=0;which<3;++which) {
        uint64_t rec=which==0 ? self : which==1 ? member_type : st[XJAI_S_INFO];
        uint64_t bytes_size=which==0 ? size : which==1 ? stride : 16;
        if (!bytes(r,rec,(size_t)size) || !array(r,rec+members,&count,&table,64,stride)) return 0;
        for (uint64_t i=0;i<count;++i) {
            uint64_t m=table+i*stride,flags,off,t,z;
            if (!get(r,m+l->mo[XJAI_M_FLAGS],4,&flags) || (flags&~bits) ||
                !get(r,m+24,8,&off) || !get(r,m+16,8,&t) || !get(r,t+8,8,&z)) return 0;
            if (!(flags&l->flags[XJAI_F_CONSTANT]) && (off>bytes_size || z>bytes_size-off)) return 0;
        }
    }
    uint64_t header=st[XJAI_S_INFO],pointee;
    if (!bytes(r,mt[XJAI_M_TYPE],24) || !str_eq(r,header+16,"Type_Info") || !get(r,mt[XJAI_M_TYPE]+16,8,&pointee) || pointee!=header ||
        !array(r,header+members,&count,&table,64,stride)) return 0;
    const struct field hf[]={{"type",11,4},{"runtime_size",0,8}};uint32_t ho[2];uint64_t ht[2];
    if (!fields(r,table,count,stride,16,hf,2,ho,ht) || ho[0]!=0 || ho[1]!=8 || ht[0]!=tag_type || !integer(r,ht[1],8,1)) return 0;
    /* Seed prefix is required to describe actual fields, not constants. */
    for (unsigned which=0;which<3;++which) {
        uint64_t rec=which==0?self:which==1?member_type:header;
        const struct field *fs=which==0?sf:which==1?mf:hf;size_t n=which==0?XJAI_S_FIELDS:which==1?XJAI_M_FIELDS:2;
        if (!bytes(r,rec,(size_t)size) || !array(r,rec+members,&count,&table,64,stride)) return 0;
        for (uint64_t i=0;i<count;++i) for (size_t j=0;j<n;++j) if (str_eq(r,table+i*stride,fs[j].name)) {
            uint64_t flags;if (!get(r,table+i*stride+l->mo[XJAI_M_FLAGS],4,&flags) || (flags&l->flags[XJAI_F_CONSTANT])) return 0;
        }
    }
    l->struct_type=self;l->member_type=member_type;l->header_type=header;l->tag_type=tag_type;l->flags_type=mt[XJAI_M_FLAGS];return 1;
}
static uint64_t mix(uint64_t h,uint64_t v)
{
    for (unsigned i=0;i<8;++i) {h^=(v>>(i*8))&255;h*=UINT64_C(1099511628211);}return h;
}
const char *xjai_layout_detect(const struct xjai_image *image,struct xjai_layout *out)
{
    if (!out) return "JaiInvalidArgument";
    memset(out,0,sizeof *out);
    if (!image || !image->regions || !image->count || image->count>XJAI_REGIONS) return "JaiInvalidImage";
    size_t total=0;
    for (size_t i=0;i<image->count;++i) {
        const struct xjai_region *s=&image->regions[i];
        if (!s->data || !s->size || s->address>UINT64_MAX-s->size ||
            (i && image->regions[i-1].address+image->regions[i-1].size>s->address)) return "JaiInvalidImage";
        if (s->size>XJAI_IMAGE_BYTES-total) return "JaiImageLimit";
        total+=s->size;
    }
    struct reader r={.image=image};uint64_t self=0,tags_at=0;unsigned self_count=0,tag_count=0;
    for (size_t i=0;i<image->count;++i) {
        const struct xjai_region *s=&image->regions[i];
        size_t start=(size_t)((8-(s->address&7))&7);
        for (size_t off=start;off<=s->size && s->size-off>=32;off+=8) {
            const unsigned char *p=s->data+off;uint64_t tag=word(p,4),at=s->address+off;
            if (tag==7 && str_eq(&r,at+16,"Type_Info_Struct")) {self=at;++self_count;}
            if (tag==11 && str_eq(&r,at+16,"Type_Info_Tag")) {tags_at=at;++tag_count;}
        }
    }
    if (!self_count || !tag_count) return "JaiLayoutUnavailable";
    if (self_count!=1 || tag_count!=1) return "JaiLayoutAmbiguous";
    uint64_t values[sizeof tags/sizeof *tags];
    if (!enum_values(&r,tags_at,tags,sizeof tags/sizeof *tags,values)) return "JaiTagTableUnproved";
    for (size_t i=0;i<sizeof tags/sizeof *tags;++i) if (values[i]!=(i==17?18:i)) return "JaiTagValueMismatch";
    struct xjai_layout found={0},candidate;unsigned matches=0;
    for (uint32_t offset=32;offset<=496;offset+=8) for (uint32_t stride=32;stride<=256;stride+=8)
        if (validate(&r,self,tags_at,offset,stride,&candidate)) {found=candidate;++matches;}
    if (!matches) return "JaiSelfDescriptionUnproved";
    if (matches!=1) return "JaiLayoutAmbiguous";
    uint64_t h=UINT64_C(14695981039346656037);
    h=mix(h,found.profile);h=mix(h,found.struct_size);h=mix(h,found.member_size);
    for (unsigned i=0;i<XJAI_S_FIELDS;++i) h=mix(h,found.so[i]);
    for (unsigned i=0;i<XJAI_M_FIELDS;++i) h=mix(h,found.mo[i]);
    for (unsigned i=0;i<XJAI_F_FLAGS;++i) h=mix(h,found.flags[i]);
    for (size_t i=0;i<sizeof tags/sizeof *tags;++i) h=mix(h,values[i]);
    found.fingerprint=h;*out=found;return NULL;
}
