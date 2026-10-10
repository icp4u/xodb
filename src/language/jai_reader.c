#include "jai_internal.h"
#include <stdlib.h>

struct build {
    struct reader r;struct xjai_graph *g;struct xjai_limits limit;
    uint32_t *slots,slot_count;const char *fatal;
    uint64_t array_enum;int array_enum_ok;unsigned array_kind_width;
};
static void partial(struct build *b,const char *why)
{
    b->g->partial=1;if (!b->g->reason) b->g->reason=why;
}
static int grow(struct build *b,void **p,uint32_t *capacity,uint32_t need,uint32_t limit,size_t width,const char *why)
{
    if (need>limit) {partial(b,why);return 0;}
    if (need<=*capacity) return 1;
    uint32_t next=*capacity?*capacity:32;
    while (next<need) next=next>limit/2?limit:next*2;
    if (next>limit) next=limit;
    void *q=realloc(*p,(size_t)next*width);
    if (!q) {b->fatal="JaiOutOfMemory";return 0;}
    b->g->allocated_bytes+=(uint64_t)(next-*capacity)*width;*p=q;*capacity=next;return 1;
}
static uint32_t hash(uint64_t at,uint32_t count)
{
    at^=at>>33;at*=UINT64_C(0xff51afd7ed558ccd);at^=at>>33;return (uint32_t)at&(count-1);
}
static int hash_grow(struct build *b)
{
    if ((b->g->type_count+1)*2<b->slot_count) return 1;
    uint32_t count=b->slot_count?b->slot_count*2:64;
    uint32_t *p=calloc(count,sizeof *p);if (!p) {b->fatal="JaiOutOfMemory";return 0;}
    for (uint32_t i=0;i<b->g->type_count;++i) {
        uint32_t at=hash(b->g->types[i].address,count);while (p[at]) at=(at+1)&(count-1);p[at]=i+1;
    }
    free(b->slots);b->slots=p;b->slot_count=count;return 1;
}
static uint32_t intern(struct build *b,uint64_t address)
{
    if (!address) return XJAI_NONE;
    if (b->slot_count) {
        uint32_t at=hash(address,b->slot_count);
        while (b->slots[at]) {
            uint32_t i=b->slots[at]-1;if (b->g->types[i].address==address) return i;at=(at+1)&(b->slot_count-1);
        }
    }
    struct xjai_graph *g=b->g;
    if (!grow(b,(void **)&g->types,&g->type_capacity,g->type_count+1,b->limit.types,sizeof *g->types,"JaiTypeLimit") || !hash_grow(b)) return XJAI_NONE;
    uint32_t i=g->type_count++,at=hash(address,b->slot_count);while (b->slots[at]) at=(at+1)&(b->slot_count-1);b->slots[at]=i+1;
    g->types[i]=(struct xjai_type){.address=address,.element=XJAI_NONE,.polymorph=XJAI_NONE,.reason="JaiTypePending"};return i;
}
static int text_ok(const unsigned char *p,size_t n)
{
    for (size_t i=0;i<n;) {
        uint32_t c=p[i++];unsigned rest;uint32_t minimum;
        if (c<128) {if (c<32 || c==127) return 0;continue;}
        if (c>=0xc2 && c<=0xdf) {rest=1;c&=31;minimum=0x80;}
        else if (c>=0xe0 && c<=0xef) {rest=2;c&=15;minimum=0x800;}
        else if (c>=0xf0 && c<=0xf4) {rest=3;c&=7;minimum=0x10000;}
        else return 0;
        if (rest>n-i) return 0;
        while (rest--) {unsigned v=p[i++];if ((v&0xc0)!=0x80) return 0;c=(c<<6)|(v&63);}
        if (c<minimum || c>0x10ffff || (c>=0xd800 && c<=0xdfff)) return 0;
    }
    return 1;
}
static int name_view(struct reader *r,uint64_t at,const unsigned char **p,size_t *n)
{
    const unsigned char *q=bytes(r,at,16);if (!q) return 0;uint64_t count=word(q,8),data=word(q+8,8);
    if (count>1024) return 0;
    *n=(size_t)count;
    if (!count) {*p=(const unsigned char *)"";return 1;}
    *p=bytes(r,data,*n);return *p && text_ok(*p,*n);
}
static uint32_t name_copy(struct build *b,uint64_t at)
{
    const unsigned char *p;size_t n;if (!name_view(&b->r,at,&p,&n)) return XJAI_NONE;
    struct xjai_graph *g=b->g;
    if (!grow(b,(void **)&g->text,&g->text_capacity,g->text_bytes+(uint32_t)n+1,b->limit.text_bytes,1,"JaiTextLimit")) return XJAI_NONE;
    uint32_t first=g->text_bytes;memcpy(g->text+first,p,n);g->text[first+n]=0;g->text_bytes+=(uint32_t)n+1;return first;
}
static int named_root(struct reader *r,uint64_t at,unsigned tag,const struct xjai_layout *l)
{
    const unsigned char *p=bytes(r,at,tag==7?l->struct_size:80),*name;size_t length;
    if (!p || word(p,4)!=tag || word(p+8,8)>INT64_MAX || !name_view(r,at+16,&name,&length) || !length) return 0;
    uint64_t n,table,count,values,base,size=word(p+8,8);
    if (tag==7) {
        uint64_t alignment;
        if (!get(r,at+l->so[XJAI_S_ALIGNMENT],4,&alignment) || (alignment!=UINT32_MAX && (!alignment || alignment>4096 || (alignment&(alignment-1)) || size%alignment))) return 0;
        /* Recognition needs a bounded member table, not just a nearby name.
         * Per-member damage remains explicit after a root is recognized. */
        if (!array(r,at+l->so[XJAI_S_MEMBERS],&n,&table,4096,l->member_size) ||
            !array(r,at+l->so[XJAI_S_SPECIFIED_PARAMETERS],&count,&values,256,l->member_size) ||
            !array(r,at+l->so[XJAI_S_CONSTANT_STORAGE],&count,&values,XJAI_TEXT_BYTES,1)) return 0;
        uint64_t known=0;for (unsigned i=0;i<XJAI_F_FLAGS;++i) known|=l->flags[i];
        /* Corroborate the start of the member table before recognizing a root.
         * This rejects string-pool rows that mimic headers and array spans. */
        for (uint64_t i=0;i<n && i<8;++i) {
            uint64_t m=table+i*l->member_size,flags;
            if (!name_view(r,m+l->mo[XJAI_M_NAME],&name,&length) ||
                !get(r,m+l->mo[XJAI_M_FLAGS],4,&flags) || (flags&~known)) return 0;
        }
        return 1;
    }
    if ((size!=1 && size!=2 && size!=4 && size!=8) || !get(r,at+32,8,&base) ||
        !bytes(r,base,17) || !type(r,base,0,size)) return 0;
    return array(r,at+40,&n,&table,4096,16) && array(r,at+56,&count,&values,4096,8) && n==count;
}
static const char *enum_table(struct build *b,uint64_t at,struct xjai_type *n)
{
    struct reader *r=&b->r;uint64_t base,count,names,vc,values;
    if (!bytes(r,at,80) || !get(r,at+32,8,&base) || !bytes(r,base,17) || !get(r,base,4,&count) || count!=0 ||
        !get(r,base+8,8,&vc) || (vc!=1 && vc!=2 && vc!=4 && vc!=8) || vc!=n->size ||
        !bytes(r,base,17) || !get(r,base+16,1,&count) || count>1) return "JaiEnumBaseUnproved";
    n->is_signed=(int)count;n->element=intern(b,base);
    if (!array(r,at+40,&count,&names,4096,16) || !array(r,at+56,&vc,&values,4096,8) || count!=vc) return "JaiEnumTableInvalid";
    struct xjai_graph *g=b->g;n->first_enum=g->enum_count;
    for (uint64_t i=0;i<count;++i) {
        uint32_t name=name_copy(b,names+16*i);uint64_t value;
        if (name==XJAI_NONE || !get(r,values+8*i,8,&value)) return "JaiEnumNameInvalid";
        /* Values are signed64 slots even for narrow signed enum bases. */
        if (n->size<8) {
            unsigned bits=(unsigned)n->size*8;uint64_t mask=(UINT64_C(1)<<bits)-1,low=value&mask;
            uint64_t expected=n->is_signed && (low&(UINT64_C(1)<<(bits-1))) ? low|~mask : low;
            if (value!=expected) return "JaiEnumValueOutOfRange";
        }
        if (!grow(b,(void **)&g->enums,&g->enum_capacity,g->enum_count+1,b->limit.enums,sizeof *g->enums,"JaiEnumLimit")) return "JaiEnumLimit";
        g->enums[g->enum_count++]=(struct xjai_enum_value){name,value};++n->enum_count;
    }
    return n->element==XJAI_NONE?"JaiTypeLimit":NULL;
}
static int scalar_header(struct reader *r,uint64_t at,uint64_t *tag,uint64_t *size)
{
    const unsigned char *p=bytes(r,at,16);if (!p) return 0;*tag=word(p,4);*size=word(p+8,8);return *size<=INT64_MAX;
}
static const char *members(struct build *b,uint64_t at,uint64_t count,uint64_t owner_size,
                          uint64_t constants,uint64_t constants_size,uint32_t *first,uint32_t *written)
{
    struct xjai_graph *g=b->g;const struct xjai_layout *l=&g->layout;
    *first=g->member_count;*written=0;uint64_t known=0;for (unsigned i=0;i<XJAI_F_FLAGS;++i) known|=l->flags[i];
    for (uint64_t i=0;i<count;++i) {
        uint64_t m=at+i*l->member_size,t=0,tag=0,size=0,flags=0;
        struct xjai_member f={.name=name_copy(b,m+l->mo[XJAI_M_NAME]),.type=XJAI_NONE};
        if (f.name==XJAI_NONE) {f.name=0;f.reason="JaiMemberNameInvalid";}
        get(&b->r,m+l->mo[XJAI_M_FLAGS],4,&flags);f.flags=(uint32_t)flags;
        get(&b->r,m+l->mo[XJAI_M_TYPE],8,&t);get(&b->r,m+l->mo[XJAI_M_OFFSET],8,&f.offset);
        get(&b->r,m+l->mo[XJAI_M_CONSTANT_OFFSET],8,&f.constant_offset);
        /* Never enqueue an unreadable reference as another independent type. */
        if ((flags&~known) && !f.reason) f.reason="JaiMemberFlagsUnproved";
        if (!scalar_header(&b->r,t,&tag,&size)) f.reason="JaiMemberTypeUnreadable";
        else if ((f.type=intern(b,t))==XJAI_NONE) f.reason="JaiTypeLimit";
        else if (flags&l->flags[XJAI_F_CONSTANT]) {
            if (f.constant_offset>constants_size || size>constants_size-f.constant_offset) f.reason="JaiConstantStorageUnproved";
            else f.constant_address=constants+f.constant_offset;
        } else if (f.offset>owner_size || size>owner_size-f.offset) f.reason="JaiMemberOutsideStruct";
        if (!grow(b,(void **)&g->members,&g->member_capacity,g->member_count+1,b->limit.members,sizeof *g->members,"JaiMemberLimit")) return "JaiMemberLimit";
        g->members[g->member_count++]=f;++*written;
        if (f.reason) {++g->invalid_members;partial(b,"JaiPartialMembers");}
    }
    return NULL;
}
static const char *structure(struct build *b,uint64_t at,struct xjai_type *n)
{
    const struct xjai_layout *l=&b->g->layout;uint64_t count,table,constants,size,parameters,parameter_count,source;
    uint64_t alignment;
    if (!bytes(&b->r,at,l->struct_size) || !get(&b->r,at+l->so[XJAI_S_ALIGNMENT],4,&alignment) ||
        (alignment!=UINT32_MAX && (!alignment || alignment>4096 || (alignment&(alignment-1)) || n->size%alignment)) ||
        !array(&b->r,at+l->so[XJAI_S_MEMBERS],&count,&table,4096,l->member_size) ||
        !array(&b->r,at+l->so[XJAI_S_CONSTANT_STORAGE],&size,&constants,XJAI_TEXT_BYTES,1) ||
        !array(&b->r,at+l->so[XJAI_S_SPECIFIED_PARAMETERS],&parameter_count,&parameters,256,l->member_size) ||
        !get(&b->r,at+l->so[XJAI_S_POLYMORPH_SOURCE_STRUCT],8,&source)) return "JaiStructTableInvalid";
    n->polymorph=intern(b,source);
    const char *why=members(b,table,count,n->size,constants,size,&n->first_member,&n->member_count);if (why) return why;
    return members(b,parameters,parameter_count,n->size,constants,size,&n->first_parameter,&n->parameter_count);
}
static void decode(struct build *b,uint32_t index)
{
    struct xjai_type n=b->g->types[index];uint64_t tag,size,at=n.address;const char *why=NULL;
    if (b->r.exhausted) {why="JaiReadBudget";goto finish;}
    if (!scalar_header(&b->r,at,&tag,&size)) {why="JaiTypeUnreadable";goto finish;}
    n.tag=(uint32_t)tag;n.size=size;
    switch (tag) {
    case 0: {
        uint64_t sign;
        if ((size!=1 && size!=2 && size!=4 && size!=8) || !bytes(&b->r,at,17) || !get(&b->r,at+16,1,&sign) || sign>1) why="JaiIntegerUnproved";
        else n.is_signed=(int)sign;
        break;
    }
    case 1:if (size!=4 && size!=8) why="JaiFloatUnproved";break;
    case 2:if (size!=1) why="JaiBoolUnproved";break;
    case 3:if (size!=16) why="JaiStringUnproved";break;
    case 4: {
        uint64_t element;if (size!=8 || !bytes(&b->r,at,24) || !get(&b->r,at+16,8,&element) || !element) why="JaiPointerUnproved";
        else if ((n.element=intern(b,element))==XJAI_NONE) why="JaiTypeLimit";
        break;
    }
    case 6:if (size!=0) why="JaiVoidUnproved";break;
    case 7:
        if (!bytes(&b->r,at,b->g->layout.struct_size) || (n.name=name_copy(b,at+b->g->layout.so[XJAI_S_NAME]))==XJAI_NONE) {n.name=0;why="JaiTypeNameInvalid";}
        else why=structure(b,at,&n);
        break;
    case 8: {
        uint64_t element,kind,count,et,es;
        if (!bytes(&b->r,at,40) || !get(&b->r,at+16,8,&element) || !get(&b->r,at+24,b->array_kind_width?b->array_kind_width:2,&kind) || !get(&b->r,at+32,8,&count) ||
            !scalar_header(&b->r,element,&et,&es) || kind>2) {why="JaiArrayUnproved";break;}
        n.array_kind=(uint32_t)kind;n.array_count=count;n.element=intern(b,element);
        if (!b->array_enum_ok) why="JaiArrayKindUnproved";
        else if (kind==0 && (count>INT64_MAX || (es && count>UINT64_MAX/es) || count*es!=size)) why="JaiArraySizeMismatch";
        else if (kind==1 && size!=16) why="JaiArraySizeMismatch";
        else if (kind==2 && size!=40) why="JaiArraySizeMismatch";
        else if (n.element==XJAI_NONE) why="JaiTypeLimit";
        break;
    }
    case 10:if (size!=16) why="JaiAnyUnproved";break;
    case 11:
        if (!bytes(&b->r,at,80) || (n.name=name_copy(b,at+16))==XJAI_NONE) {n.name=0;why="JaiTypeNameInvalid";}
        else why=enum_table(b,at,&n);
        break;
    case 13:if (size!=8) why="JaiTypeValueUnproved";break;
    default:why="JaiTypeCategoryUnsupported";
        break;
    }
finish:
    if (b->r.exhausted) why="JaiReadBudget";
    n.reason=why;b->g->types[index]=n;
    if (why) {++b->g->invalid_types;partial(b,"JaiPartialTypes");}
}
static int array_enum(struct build *b,uint64_t at)
{
    struct reader *r=&b->r;uint64_t base,n,np,c,vp,width;
    if (!get(r,at+8,8,&width) || (width!=2 && width!=4) || !type(r,at,11,width) || !get(r,at+32,8,&base) || !integer(r,base,width,0) ||
        !array(r,at+40,&n,&np,64,16) || !array(r,at+56,&c,&vp,64,8) || n!=3 || c!=3) return 0;
    const char *names[]={"FIXED","VIEW","RESIZABLE"};unsigned seen=0;
    for (unsigned i=0;i<3;++i) {
        unsigned j;uint64_t v;for (j=0;j<3;++j) if (str_eq(r,np+16*i,names[j])) break;
        if (j==3 || (seen&(1u<<j)) || !get(r,vp+8*i,8,&v) || v!=j) return 0;
        seen|=1u<<j;
    }
    b->array_kind_width=(unsigned)width;return seen==7;
}
void xjai_graph_free(struct xjai_graph *g)
{
    if (!g) return;
    free(g->types);free(g->members);free(g->enums);free(g->text);free(g);
}
const char *xjai_graph_build(const struct xjai_image *im,const struct xjai_limits *limits,struct xjai_graph **out)
{
    if (!out) return "JaiInvalidArgument";
    *out=NULL;
    struct xjai_limits limit=limits?*limits:(struct xjai_limits){XJAI_TYPES,XJAI_MEMBERS,XJAI_ENUMS,XJAI_TEXT_BYTES};
    if (!limit.types || limit.types>XJAI_TYPES || !limit.members || limit.members>XJAI_MEMBERS || !limit.enums || limit.enums>XJAI_ENUMS || !limit.text_bytes || limit.text_bytes>XJAI_TEXT_BYTES) return "JaiInvalidLimits";
    struct xjai_layout l;const char *why=xjai_layout_detect(im,&l);if (why) return why;
    struct xjai_graph *g=calloc(1,sizeof *g);if (!g) return "JaiOutOfMemory";
    g->layout=l;g->allocated_bytes=sizeof *g;struct build b={.r={.image=im,.reads_left=1048576,.bytes_left=128u*1024u*1024u,.bounded=1},.g=g,.limit=limit};
    if (!grow(&b,(void **)&g->text,&g->text_capacity,1,limit.text_bytes,1,"JaiTextLimit")) goto fail;
    g->text[0]=0;g->text_bytes=1;
    for (size_t i=0;i<im->count && !b.fatal;++i) {
        const struct xjai_region *s=&im->regions[i];
        size_t first=(size_t)((8-(s->address&7))&7);
        for (size_t off=first;off<=s->size && s->size-off>=32;off+=8) {
            if (b.r.exhausted) break;
            g->scanned_bytes+=8;
            uint64_t at=s->address+off,tag=word(s->data+off,4);
            if (tag!=7 && tag!=11) continue;
            if (!named_root(&b.r,at,(unsigned)tag,&l)) {
                const unsigned char *candidate_name;size_t length;
                if (name_view(&b.r,at+16,&candidate_name,&length) && length) {
                    ++g->rejected_candidates;partial(&b,"JaiUnprovedRootCandidates");
                }
                continue;
            }
            intern(&b,at);
            if (tag==11 && str_eq(&b.r,at+16,"Array_Type")) {
                if (b.array_enum) b.array_enum_ok=0;
                else {b.array_enum=at;b.array_enum_ok=array_enum(&b,at);}
            }
            if (b.fatal) break;
        }
    }
    /* Append-only queue; interning may realloc types, so decode holds a copy. */
    for (uint32_t i=0;i<g->type_count && !b.fatal;++i) decode(&b,i);
    if (b.fatal) goto fail;
    if (b.r.exhausted) {g->partial=1;g->reason="JaiReadBudget";}
    free(b.slots);*out=g;return NULL;
fail:
    free(b.slots);xjai_graph_free(g);return b.fatal?b.fatal:"JaiOutOfMemory";
}
uint32_t xjai_type_at(const struct xjai_graph *g,uint64_t address)
{
    if (!g) return XJAI_NONE;
    for (uint32_t i=0;i<g->type_count;++i) if (g->types[i].address==address) return i;
    return XJAI_NONE;
}
struct walk {
    const struct xjai_graph *g;struct xjai_flat_field *rows;size_t cap,count;
    uint32_t types[XJAI_FIELD_DEPTH],path[XJAI_FIELD_DEPTH];
    uint64_t visited;const char *reason;
};
static void flat(struct walk *w,uint32_t type_index,uint32_t depth,uint64_t offset)
{
    if (w->reason) return;
    if (depth==XJAI_FIELD_DEPTH) {w->reason="JaiUsingDepthLimit";return;}
    for (uint32_t i=0;i<depth;++i) if (w->types[i]==type_index) {w->reason="JaiUsingCycle";return;}
    if (type_index>=w->g->type_count) {w->reason="JaiUsingTypeUnavailable";return;}
    const struct xjai_type *t=&w->g->types[type_index];
    if (t->reason || t->tag!=7) {w->reason="JaiUsingTypeUnproved";return;}
    w->types[depth]=type_index;
    for (uint32_t i=0;i<t->member_count && !w->reason;++i) {
        if (++w->visited>XJAI_MEMBERS) {w->reason="JaiUsingWorkLimit";break;}
        uint32_t index=t->first_member+i;const struct xjai_member *m=&w->g->members[index];
        if (m->flags&(w->g->layout.flags[XJAI_F_CONSTANT]|w->g->layout.flags[XJAI_F_IMPORTED])) continue;
        w->path[depth]=index;
        if (m->reason || m->offset>UINT64_MAX-offset) {w->reason=m->reason?m->reason:"JaiUsingOffsetOverflow";break;}
        if (m->flags&w->g->layout.flags[XJAI_F_USING]) {flat(w,m->type,depth+1,offset+m->offset);continue;}
        if (w->count==w->cap) {w->reason="JaiFieldLimit";break;}
        struct xjai_flat_field *row=&w->rows[w->count++];memset(row,0,sizeof *row);
        row->member=index;row->depth=depth+1;row->offset=offset+m->offset;memcpy(row->path,w->path,(depth+1)*sizeof *w->path);
    }
}
const char *xjai_fields_flatten(const struct xjai_graph *g,uint32_t index,struct xjai_flat_field *rows,size_t cap,size_t *count)
{
    if (!count) return "JaiInvalidArgument";
    *count=0;
    if (!g || index>=g->type_count || (!rows && cap) || cap>XJAI_MEMBERS) return "JaiInvalidArgument";
    struct walk w={.g=g,.rows=rows,.cap=cap};flat(&w,index,0,0);*count=w.count;return w.reason;
}
