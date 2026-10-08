#include "dwarf_names.h"
#include <dwarf.h>
#include <elf.h>
#include <stdlib.h>
#include <string.h>

#define PAGE 4096u
#define PAGES 16u
#define NAME 4096u
#define ABBREV 65536u
#define ATTRS 32u
/* DWARF 5, table 7.23; older libdw headers omit these constants. */
enum { IDX_COMPILE_UNIT=1, IDX_TYPE_UNIT=2, IDX_DIE_OFFSET=3, IDX_PARENT=4, IDX_TYPE_HASH=5 };
struct page {uint64_t base,stamp;size_t done,size;unsigned section,used;unsigned char bytes[PAGE];};
struct xdn_query {
    struct xbo_object *object;
    const struct xbo_section *index,*strings,*info;
    enum xdn_kind kind;
    char name[NAME];size_t name_size;
    struct page pages[PAGES];uint64_t clock;
    const char *error;
    unsigned phase,complete,width;
    uint32_t hash;
    uint64_t base,end,cus,tus,buckets,hashes,names,entries,abbrev,pool;
    uint32_t cu_count,tu_count,foreign_count,bucket_count,name_count,abbrev_size;
    uint64_t slot,probes,entry,vector_index,vector_count;
    uint64_t gdb_symbols,gdb_symbol_count,gdb_step,gdb_tus,gdb_address;
    unsigned char abbreviations[ABBREV];size_t abbrev_done;
};
struct stream {struct xdn_query *q;struct xbo_budget *b;unsigned section;uint64_t at,end;};
#define TRY(e) do {enum xbo_status s_=(e);if(s_!=XBO_OK)return s_;} while(0)
static enum xbo_status bad(struct xdn_query *q,const char *s) {q->error=s;return XBO_MALFORMED;}
static enum xbo_status limit(struct xdn_query *q,const char *s) {q->error=s;return XBO_LIMIT;}
static enum xbo_status tick(struct xbo_budget *b) {
    if(!b)return XBO_LIMIT;
    if(b->cancelled&&b->cancelled(b->context))return XBO_CANCELLED;
    if(b->deadline_ns&&xbo_now_ns()>=b->deadline_ns)return XBO_AGAIN;
    return XBO_OK;
}
static enum xbo_status read_bytes(struct stream *s,void *out,size_t size) {
    const struct xbo_section *sec=s->section?s->q->strings:s->q->index;
    if(!sec||s->at>s->end||size>s->end-s->at||s->end>sec->size)return bad(s->q,"DwarfIndexExtent");
    unsigned char *dst=out;
    while(size) {
        TRY(tick(s->b));uint64_t base=s->at-s->at%PAGE,oldest=UINT64_MAX;unsigned slot=0,found=0;
        for(unsigned i=0;i<PAGES;i++) {
            struct page *p=&s->q->pages[i];
            if(p->used&&p->section==s->section&&p->base==base){slot=i;found=1;break;}
            if(!p->used||p->stamp<oldest){oldest=p->used?p->stamp:0;slot=i;}
        }
        struct page *p=&s->q->pages[slot];
        if(!found){p->used=1;p->section=s->section;p->base=base;p->done=0;p->size=(size_t)(sec->size-base<PAGE?sec->size-base:PAGE);}
        p->stamp=++s->q->clock;
        if(p->done<p->size)TRY(xbo_read(s->q->object,sec->offset+base,p->bytes,p->size,&p->done,s->b));
        size_t at=(size_t)(s->at-base),n=p->size-at;if(n>size)n=size;
        memcpy(dst,p->bytes+at,n);dst+=n;s->at+=n;size-=n;
    }
    return XBO_OK;
}
static enum xbo_status number(struct stream *s,unsigned width,uint64_t *v) {
    unsigned char bytes[8];if(!width||width>8)return bad(s->q,"DwarfIndexIntegerWidth");
    TRY(read_bytes(s,bytes,width));*v=0;
    int little=s->q->kind==XDN_GDB_INDEX||xbo_little_endian(s->q->object);
    for(unsigned i=0;i<width;i++)*v=*v<<8|bytes[little?width-i-1:i];
    return XBO_OK;
}
static enum xbo_status leb(struct stream *s,uint64_t *v) {
    *v=0;for(unsigned i=0;i<10;i++) {
        uint64_t b;TRY(number(s,1,&b));if(i==9&&(b&0xfe))return bad(s->q,"DwarfIndexLebOverflow");
        *v|=(b&127)<<(i*7);if(!(b&128))return XBO_OK;
    }return bad(s->q,"DwarfIndexLebOverflow");
}
static enum xbo_status at(struct xdn_query *q,struct xbo_budget *b,uint64_t pos,unsigned width,uint64_t *v) {
    struct stream s={q,b,0,pos,q->end};return number(&s,width,v);
}
static enum xbo_status equal(struct xdn_query *q,struct xbo_budget *b,unsigned section,uint64_t pos,int *match) {
    const struct xbo_section *sec=section?q->strings:q->index;
    if(!sec)return bad(q,"DwarfIndexStringsUnavailable");
    struct stream s={q,b,section,pos,section?sec->size:q->end};*match=1;
    /* A mismatch needs no scan to the end of an unrelated arbitrary string. */
    for(size_t i=0;i<=q->name_size;i++) {
        unsigned char c;TRY(read_bytes(&s,&c,1));
        if(c!=(unsigned char)q->name[i]){*match=0;return XBO_OK;}
    }return XBO_OK;
}
static enum xbo_status gdb_header(struct xdn_query *q,struct xbo_budget *b) {
    q->end=q->index->size;struct stream s={q,b,0,0,q->end};uint64_t h[7]={0};
    TRY(number(&s,4,&h[0]));if(h[0]<7||h[0]>9)return bad(q,"GdbIndexVersionUnsupported");
    unsigned n=h[0]==9?7:6;
    for(unsigned i=1;i<n;i++)TRY(number(&s,4,&h[i]));
    if(h[1]<4*n)return bad(q,"GdbIndexHeaderExtent");
    for(unsigned i=1;i<n;i++)if(h[i]>q->end||(i>1&&h[i]<h[i-1])||(h[i]&3))return bad(q,"GdbIndexHeaderExtent");
    uint64_t symbols=(h[5]-h[4])/8,cus=(h[2]-h[1])/16,tus=(h[3]-h[2])/24;
    if((h[2]-h[1])%16||(h[3]-h[2])%24||(h[4]-h[3])%20||(h[5]-h[4])%8||!symbols||(symbols&(symbols-1))||cus+tus>0xffffff)return bad(q,"GdbIndexTableExtent");
    if(h[0]==9&&h[6]-h[5]!=8)return bad(q,"GdbIndexShortcutExtent");
    q->cus=h[1];q->gdb_tus=h[2];q->gdb_address=h[3];q->gdb_symbols=h[4];q->pool=h[n-1];
    q->cu_count=(uint32_t)cus;q->tu_count=(uint32_t)tus;q->gdb_symbol_count=symbols;
    q->slot=q->hash&(symbols-1);q->gdb_step=((q->hash*UINT32_C(17))&(symbols-1))|1;q->phase=1;return XBO_OK;
}
static enum xbo_status gdb_next(struct xdn_query *q,struct xbo_budget *b,struct xdn_hit *out) {
    if(!q->phase){TRY(gdb_header(q,b));return XBO_AGAIN;}
    if(q->phase==1) {
        if(q->probes==q->gdb_symbol_count)return bad(q,"GdbIndexFullHashTable");
        uint64_t name,vector;TRY(at(q,b,q->gdb_symbols+q->slot*8,4,&name));TRY(at(q,b,q->gdb_symbols+q->slot*8+4,4,&vector));
        if(!name&&!vector){q->complete=1;return XBO_NOT_FOUND;}
        if(name>=q->end-q->pool||vector>=q->end-q->pool)return bad(q,"GdbIndexPoolExtent");
        int match;TRY(equal(q,b,0,q->pool+name,&match));
        if(match) {
            uint64_t count;TRY(at(q,b,q->pool+vector,4,&count));
            if(!count||count>(q->end-q->pool-vector-4)/4)return bad(q,"GdbIndexVectorExtent");
            q->vector_count=count;q->vector_index=0;q->entry=q->pool+vector+4;q->phase=2;
        } else {q->slot=(q->slot+q->gdb_step)&(q->gdb_symbol_count-1);q->probes++;}
        return XBO_AGAIN;
    }
    if(q->vector_index==q->vector_count){q->complete=1;return XBO_NOT_FOUND;}
    uint64_t value;TRY(at(q,b,q->entry+q->vector_index*4,4,&value));
    unsigned kind=(unsigned)(value>>28)&7;uint64_t cu=value&0xffffff;
    if((value&0x0f000000)||!kind||kind>4||cu>=q->cu_count+q->tu_count)return bad(q,"GdbIndexCuInvalid");
    if(cu>=q->cu_count)return limit(q,"DwarfIndexTypeUnitUnsupported");
    struct xdn_hit hit={0};TRY(at(q,b,q->cus+cu*16,8,&hit.unit));TRY(at(q,b,q->cus+cu*16+8,8,&hit.unit_size));
    if(!hit.unit_size||hit.unit>=q->info->size||hit.unit_size>q->info->size-hit.unit)return bad(q,"DwarfIndexCuExtent");
    TRY(xbo_validate(q->object,b));q->vector_index++;*out=hit;return XBO_OK;
}
static enum xbo_status array(struct xdn_query *q,uint64_t *pos,uint64_t count,unsigned width,uint64_t *start) {
    if(*pos>q->end||count>(q->end-*pos)/width)return bad(q,"DwarfIndexTableExtent");
    *start=*pos;*pos+=count*width;return XBO_OK;
}
static enum xbo_status names_header(struct xdn_query *q,struct xbo_budget *b) {
    if(q->base==q->index->size){q->complete=1;return XBO_NOT_FOUND;}
    struct stream s={q,b,0,q->base,q->index->size};uint64_t length,v,padding,h[7];
    TRY(number(&s,4,&length));unsigned width=4;
    if(length==UINT32_MAX){width=8;TRY(number(&s,8,&length));}
    else if(length>=0xfffffff0)return bad(q,"DwarfIndexReservedLength");
    if(!length||length>s.end-s.at)return bad(q,"DwarfIndexContributionExtent");
    s.end=s.at+length;TRY(number(&s,2,&v));TRY(number(&s,2,&padding));
    if(v!=5||padding)return bad(q,"DwarfIndexVersionUnsupported");
    for(unsigned i=0;i<7;i++)TRY(number(&s,4,&h[i]));
    if(!h[0]||(h[6]&3))return bad(q,"DwarfIndexHeaderMalformed");
    if(h[5]>ABBREV)return limit(q,"DwarfIndexAbbreviationLimit");
    /* Calculate into a temporary header: a short budget leaves no half-ready
     * contribution visible. All arrays are bounded by the section extent. */
    q->end=s.end;uint64_t pos=s.at,ignored,cus,tus,buckets,hashes,names,entries,abbrev;
    TRY(array(q,&pos,h[6],1,&ignored));TRY(array(q,&pos,h[0],width,&cus));
    TRY(array(q,&pos,h[1],width,&tus));TRY(array(q,&pos,h[2],8,&ignored));
    TRY(array(q,&pos,h[3],4,&buckets));TRY(array(q,&pos,h[3]?h[4]:0,4,&hashes));
    TRY(array(q,&pos,h[4],width,&names));TRY(array(q,&pos,h[4],width,&entries));
    TRY(array(q,&pos,h[5],1,&abbrev));
    q->width=width;q->cu_count=(uint32_t)h[0];q->tu_count=(uint32_t)h[1];q->foreign_count=(uint32_t)h[2];
    q->bucket_count=(uint32_t)h[3];q->name_count=(uint32_t)h[4];q->abbrev_size=(uint32_t)h[5];
    q->cus=cus;q->tus=tus;q->buckets=buckets;q->hashes=hashes;q->names=names;q->entries=entries;q->abbrev=abbrev;q->pool=pos;
    q->abbrev_done=0;q->phase=1;return XBO_OK;
}
static enum xbo_status memory_leb(struct xdn_query *q,size_t *pos,uint64_t *v) {
    *v=0;for(unsigned i=0;i<10;i++) {
        if(*pos>=q->abbrev_size)return bad(q,"DwarfIndexAbbreviationTruncated");
        unsigned char c=q->abbreviations[(*pos)++];
        if(i==9&&(c&0xfe))return bad(q,"DwarfIndexLebOverflow");
        *v|=(uint64_t)(c&127)<<(i*7);if(!(c&128))return XBO_OK;
    }return bad(q,"DwarfIndexLebOverflow");
}
static enum xbo_status abbreviation(struct xdn_query *q,uint64_t wanted,uint32_t *tag,uint32_t attrs[ATTRS][2],unsigned *count) {
    size_t pos=0;int found=0;unsigned char seen[4096]={0};
    for(;;) {
        uint64_t code,t;TRY(memory_leb(q,&pos,&code));if(!code)break;
        if(code>=sizeof seen)return limit(q,"DwarfIndexAbbreviationCodeLimit");
        if(seen[code])return bad(q,"DwarfIndexDuplicateAbbreviation");
        seen[code]=1;
        TRY(memory_leb(q,&pos,&t));if(!t||t>UINT32_MAX)return bad(q,"DwarfIndexTagInvalid");
        unsigned n=0;uint32_t local[ATTRS][2];
        for(;;) {
            uint64_t idx,form;TRY(memory_leb(q,&pos,&idx));TRY(memory_leb(q,&pos,&form));
            if(!idx&&!form)break;
            if(!idx||!form||idx>UINT32_MAX||form>UINT32_MAX)return bad(q,"DwarfIndexAttributeInvalid");
            if(n==ATTRS)return limit(q,"DwarfIndexAttributeLimit");
            for(unsigned i=0;i<n;i++)if(local[i][0]==idx)return bad(q,"DwarfIndexDuplicateAttribute");
            int constant=form==DW_FORM_data1||form==DW_FORM_data2||form==DW_FORM_data4||form==DW_FORM_data8||form==DW_FORM_udata;
            int reference=form==DW_FORM_ref1||form==DW_FORM_ref2||form==DW_FORM_ref4||form==DW_FORM_ref8||form==DW_FORM_ref_udata;
            if(((idx==IDX_COMPILE_UNIT||idx==IDX_TYPE_UNIT)&&!constant)||
               (idx==IDX_DIE_OFFSET&&!reference)||
               (idx==IDX_PARENT&&!reference&&form!=DW_FORM_flag_present)||
               (idx==IDX_TYPE_HASH&&form!=DW_FORM_data8))return bad(q,"DwarfIndexAttributeForm");
            local[n][0]=(uint32_t)idx;local[n++][1]=(uint32_t)form;
        }
        if(code==wanted){memcpy(attrs,local,n*sizeof *local);*tag=(uint32_t)t;*count=n;found=1;}
    }
    if(!found)return bad(q,"DwarfIndexAbbreviationMissing");
    return XBO_OK;
}
static enum xbo_status value(struct stream *s,unsigned form,uint64_t *v) {
    unsigned n;
    switch(form) {
    case DW_FORM_data1:case DW_FORM_ref1:case DW_FORM_flag:n=1;break;
    case DW_FORM_data2:case DW_FORM_ref2:n=2;break;
    case DW_FORM_data4:case DW_FORM_ref4:n=4;break;
    case DW_FORM_data8:case DW_FORM_ref8:n=8;break;
    case DW_FORM_udata:case DW_FORM_ref_udata:return leb(s,v);
    case DW_FORM_flag_present:*v=1;return XBO_OK;
    default:return bad(s->q,"DwarfIndexFormUnsupported");
    }return number(s,n,v);
}
static enum xbo_status names_next(struct xdn_query *q,struct xbo_budget *b,struct xdn_hit *out) {
    if(!q->phase){TRY(names_header(q,b));return XBO_AGAIN;}
    if(q->phase==1) {
        TRY(xbo_read(q->object,q->index->offset+q->abbrev,q->abbreviations,q->abbrev_size,&q->abbrev_done,b));
        uint64_t slot=q->name_count?1:0;
        if(q->bucket_count)TRY(at(q,b,q->buckets+(q->hash%q->bucket_count)*4,4,&slot));
        if(slot>q->name_count)return bad(q,"DwarfIndexBucketExtent");
        q->slot=slot;q->phase=2;return XBO_AGAIN;
    }
    if(q->phase==2) {
        if(!q->slot||q->slot>q->name_count){q->base=q->end;q->phase=0;return XBO_AGAIN;}
        uint64_t hash=q->hash;
        if(q->bucket_count)TRY(at(q,b,q->hashes+(q->slot-1)*4,4,&hash));
        if(q->bucket_count&&hash%q->bucket_count!=q->hash%q->bucket_count){q->base=q->end;q->phase=0;return XBO_AGAIN;}
        if(hash!=q->hash){q->slot++;return XBO_AGAIN;}
        uint64_t name;TRY(at(q,b,q->names+(q->slot-1)*q->width,q->width,&name));
        int match;TRY(equal(q,b,1,name,&match));
        if(!match){q->slot++;return XBO_AGAIN;}
        uint64_t entry;TRY(at(q,b,q->entries+(q->slot-1)*q->width,q->width,&entry));
        if(entry>=q->end-q->pool)return bad(q,"DwarfIndexEntryExtent");
        q->entry=q->pool+entry;q->phase=3;return XBO_AGAIN;
    }
    struct stream s={q,b,0,q->entry,q->end};uint64_t code;TRY(leb(&s,&code));
    if(!code){q->slot++;q->phase=2;return XBO_AGAIN;}
    uint32_t attrs[ATTRS][2],tag;unsigned count;
    TRY(abbreviation(q,code,&tag,attrs,&count));
    uint64_t cu=0,tu=0,die=0;unsigned have_cu=0,have_tu=0,have_die=0;
    for(unsigned i=0;i<count;i++) {
        uint64_t v;TRY(value(&s,attrs[i][1],&v));
        switch(attrs[i][0]) {
        case IDX_COMPILE_UNIT:cu=v;have_cu=1;break;
        case IDX_TYPE_UNIT:tu=v;have_tu=1;break;
        case IDX_DIE_OFFSET:die=v;have_die=1;break;
        case IDX_PARENT:case IDX_TYPE_HASH:break;
        default:return bad(q,"DwarfIndexAttributeUnsupported");
        }
    }
    if(!have_die||(have_cu&&have_tu)||(!have_cu&&!have_tu&&q->cu_count!=1))return bad(q,"DwarfIndexEntryMalformed");
    uint64_t unit;
    if(have_tu) {
        if(tu>=q->tu_count)return limit(q,"DwarfIndexForeignTypeUnitUnsupported");
        TRY(at(q,b,q->tus+tu*q->width,q->width,&unit));
    } else {
        if(cu>=q->cu_count)return bad(q,"DwarfIndexCuInvalid");
        TRY(at(q,b,q->cus+cu*q->width,q->width,&unit));
    }
    if(unit>=q->info->size||!die||die>=q->info->size-unit)return bad(q,"DwarfIndexDieExtent");
    struct xdn_hit hit={.unit=unit,.die=unit+die,.tag=tag,.has_die=1};
    TRY(xbo_validate(q->object,b));q->entry=s.at;*out=hit;return XBO_OK;
}
enum xbo_status xdn_create(struct xbo_object *object,const char *name,struct xdn_query **out) {
    if(!out)return XBO_MALFORMED;
    *out=NULL;
    if(!object||!name||!*name||!xbo_identity(object))return XBO_MALFORMED;
    size_t size=0;while(size<NAME&&name[size])size++;if(size==NAME)return XBO_LIMIT;
    struct xdn_query *q=calloc(1,sizeof *q);if(!q)return XBO_NOMEM;q->object=object;
    q->name_size=size;memcpy(q->name,name,size+1);q->kind=XDN_DEBUG_NAMES;
    uint32_t index;enum xbo_status s=xbo_find_section(object,".debug_names",&index);
    if(s==XBO_NOT_FOUND){q->kind=XDN_GDB_INDEX;s=xbo_find_section(object,".gdb_index",&index);}
    if(s!=XBO_OK){free(q);return s;}q->index=xbo_section(object,index);
    if(q->index->flags&SHF_COMPRESSED){free(q);return XBO_LIMIT;}
    s=xbo_find_section(object,".debug_info",&index);
    if(s!=XBO_OK){free(q);return s;}q->info=xbo_section(object,index);
    if(q->kind==XDN_DEBUG_NAMES) {
        s=xbo_find_section(object,".debug_str",&index);
        if(s!=XBO_OK){free(q);return s;}q->strings=xbo_section(object,index);
        if(q->strings->flags&SHF_COMPRESSED){free(q);return XBO_LIMIT;}
        q->hash=5381;
    }
    for(size_t i=0;i<size;i++) {
        unsigned char c=(unsigned char)name[i];
        /* ASCII identifiers cover runtime ABI names. Non-ASCII hashing needs
         * Unicode simple folding; refuse rather than miss a bucket silently. */
        if(c>=128){free(q);return XBO_LIMIT;}
        if(c>='A'&&c<='Z')c+='a'-'A';
        q->hash=q->kind==XDN_DEBUG_NAMES?q->hash*33+c:q->hash*67+c-113;
    }
    *out=q;return XBO_OK;
}
void xdn_destroy(struct xdn_query *q) {free(q);}
enum xbo_status xdn_next(struct xdn_query *q,struct xbo_budget *b,uint64_t work,struct xdn_hit *out) {
    if(!q||!out)return XBO_MALFORMED;
    q->error=NULL;TRY(xbo_validate(q->object,b));
    while(work--) {
        TRY(tick(b));if(q->complete)return XBO_NOT_FOUND;
        uint64_t base=q->base,slot=q->slot,entry=q->entry;unsigned phase=q->phase;
        enum xbo_status s=q->kind==XDN_DEBUG_NAMES?names_next(q,b,out):gdb_next(q,b,out);
        if(s!=XBO_AGAIN)return s;
        if(base==q->base&&slot==q->slot&&entry==q->entry&&phase==q->phase)return XBO_AGAIN;
    }return XBO_AGAIN;
}
enum xdn_kind xdn_kind(const struct xdn_query *q) {return q?q->kind:XDN_DEBUG_NAMES;}
const char *xdn_error(const struct xdn_query *q) {return q?q->error:"DwarfIndexUnavailable";}
uint64_t xdn_memory_bytes(const struct xdn_query *q) {return q?sizeof *q:0;}
