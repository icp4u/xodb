#include "dwarf_cursor.h"
#include "dwarf_constants.h"
#include <elf.h>
#include <stdlib.h>
#include <string.h>

#define PAGE 16384u
#define PAGES 32u
#define CODES 16384u
#define ATTRS 32768u
#define DEPTH 128u
#define STRING_LIMIT (1024u*1024u)
enum section { INFO, ABBREV, STR, LINE_STR, STR_OFFSETS, SECTION_COUNT };
struct page {uint64_t base, stamp;unsigned section;size_t done, size;int used;unsigned char bytes[PAGE];};
struct abbreviation {uint32_t tag, first, count;unsigned children, present;};
struct attribute {uint32_t name, form;uint64_t value;};
struct xdw_cursor {
    struct xbo_object *object;
    const struct xbo_section *sections[SECTION_COUNT];
    struct page pages[PAGES];
    unsigned last_page;
    uint64_t clock;
    struct abbreviation codes[CODES];
    struct attribute attrs[ATTRS];
    uint32_t attr_count;
    uint64_t abbrev_cursor, loaded_abbrev;
    int abbrev_started, abbrev_ready;
    uint64_t unit, unit_end, pos, abbrev, str_base, units, dies;
    unsigned version, offset_size, address_size, depth, root_seen, unit_ready;
    unsigned skip_depth;
    int complete, unit_only;
    struct xdw_die pending;
    unsigned pending_active, pending_attr;
    uint64_t attr_pos, string_origin, string_resume;
    int string_started;
    const char *error;
};
struct stream {struct xdw_cursor *c;struct xbo_budget *budget;unsigned section;uint64_t pos,end;};
#define TRY(e) do {enum xbo_status s_=(e);if(s_!=XBO_OK)return s_;} while(0)
static enum xbo_status bad(struct xdw_cursor *c,const char *why) {c->error=why;return XBO_MALFORMED;}
static enum xbo_status limit(struct xdw_cursor *c,const char *why) {c->error=why;return XBO_LIMIT;}
static enum xbo_status tick(struct xbo_budget *b) {
    if(!b)return XBO_LIMIT;
    if(b->cancelled&&b->cancelled(b->context))return XBO_CANCELLED;
    if(b->deadline_ns&&xbo_now_ns()>=b->deadline_ns)return XBO_AGAIN;
    return XBO_OK;
}
static enum xbo_status page(struct stream *s,const unsigned char **out,size_t *size) {
    struct xdw_cursor *c=s->c;const struct xbo_section *sec=c->sections[s->section];
    if(!sec || s->pos>=s->end || s->pos>=sec->size)return bad(c,"DwarfSectionExtent");
    uint64_t base=s->pos-s->pos%PAGE;unsigned slot=c->last_page;
    struct page *p=&c->pages[slot];
    if(!p->used || p->section!=s->section || p->base!=base) {
        uint64_t oldest=UINT64_MAX;unsigned victim=0;int found=0;
        for(unsigned i=0;i<PAGES;i++) {
            p=&c->pages[i];
            if(p->used&&p->section==s->section&&p->base==base){slot=i;found=1;break;}
            if(!p->used || p->stamp<oldest){oldest=p->used?p->stamp:0;victim=i;}
        }
        if(!found) {
            slot=victim;p=&c->pages[slot];p->used=1;p->section=s->section;p->base=base;p->done=0;
            p->size=(size_t)(sec->size-base<PAGE?sec->size-base:PAGE);
        }
        c->last_page=slot;p=&c->pages[slot];
    }
    p->stamp=++c->clock;
    if(p->done<p->size)TRY(xbo_read(c->object,sec->offset+base,p->bytes,p->size,&p->done,s->budget));
    size_t at=(size_t)(s->pos-base);*out=p->bytes+at;*size=p->size-at;
    if(*size>s->end-s->pos)*size=(size_t)(s->end-s->pos);
    return XBO_OK;
}
static enum xbo_status bytes(struct stream *s,void *dst,size_t n) {
    if(s->pos>s->end || n>s->end-s->pos)return bad(s->c,"DwarfTruncated");
    unsigned char *out=dst;
    while(n) {
        const unsigned char *p;size_t size;TRY(page(s,&p,&size));if(size>n)size=n;
        if(out){memcpy(out,p,size);out+=size;}s->pos+=size;n-=size;
    }
    return XBO_OK;
}
static enum xbo_status skip(struct stream *s,uint64_t n) {
    if(s->pos>s->end || n>s->end-s->pos)return bad(s->c,"DwarfTruncated");
    s->pos+=n;return XBO_OK;
}
static enum xbo_status number(struct stream *s,unsigned n,uint64_t *v) {
    unsigned char p[8];if(n>8)return bad(s->c,"DwarfIntegerWidth");TRY(bytes(s,p,n));*v=0;
    int little=xbo_little_endian(s->c->object);
    for(unsigned i=0;i<n;i++)*v=*v<<8|p[little?n-i-1:i];
    return XBO_OK;
}
static enum xbo_status leb(struct stream *s,int signed_,uint64_t *v) {
    *v=0;
    for(unsigned i=0;i<10;i++) {
        uint64_t b;TRY(number(s,1,&b));
        if(i==9 && ((!signed_ && (b&0xfe)) || (signed_ && b!=0 && b!=0x7f)))return bad(s->c,"DwarfLebOverflow");
        *v|=(b&0x7f)<<(7*i);
        if(!(b&0x80)) {
            if(signed_ && i<9 && (b&0x40))*v|=UINT64_MAX<<(7*(i+1));
            return XBO_OK;
        }
    }
    return bad(s->c,"DwarfLebOverflow");
}
static enum xbo_status string(struct stream *s,char *out,size_t capacity) {
    uint64_t count=0;
    for(;;) {
        TRY(tick(s->budget));const unsigned char *p;size_t n;TRY(page(s,&p,&n));
        const unsigned char *end=memchr(p,0,n);size_t part=end?(size_t)(end-p)+1:n;
        if(part>STRING_LIMIT-count)return limit(s->c,"DwarfStringLimit");
        if(out && (count>=capacity || part>capacity-count))return limit(s->c,"DwarfNameLimit");
        if(out)memcpy(out+(size_t)count,p,part);
        count+=part;s->pos+=part;if(end)return XBO_OK;
    }
}
static enum xbo_status unit(struct xdw_cursor *c,struct xbo_budget *budget) {
    const struct xbo_section *info=c->sections[INFO];
    if(c->pos==info->size){c->complete=1;return XBO_OK;}
    struct stream s={c,budget,INFO,c->pos,info->size};uint64_t length,version,abbrev,address,kind=DW_UT_compile,ignored;
    TRY(number(&s,4,&length));unsigned width=4;
    if(length==UINT32_MAX){width=8;TRY(number(&s,8,&length));}
    else if(length>=0xfffffff0)return bad(c,"DwarfReservedLength");
    if(!length || length>s.end-s.pos)return bad(c,"DwarfUnitExtent");
    s.end=s.pos+length;TRY(number(&s,2,&version));
    if(version<2||version>5)return bad(c,"DwarfVersionUnsupported");
    if(version==5){TRY(number(&s,1,&kind));TRY(number(&s,1,&address));TRY(number(&s,width,&abbrev));}
    else {TRY(number(&s,width,&abbrev));TRY(number(&s,1,&address));}
    if(address!=4 && address!=8)return bad(c,"DwarfAddressSizeUnsupported");
    if(kind==DW_UT_type){TRY(number(&s,8,&ignored));TRY(number(&s,width,&ignored));}
    else if(kind!=DW_UT_compile && kind!=DW_UT_partial)return bad(c,"DwarfSplitUnitUnsupported");
    if(s.pos>=s.end)return bad(c,"DwarfEmptyUnit");
    c->unit=c->pos;c->unit_end=s.end;c->pos=s.pos;c->abbrev=abbrev;
    c->version=(unsigned)version;c->offset_size=width;c->address_size=(unsigned)address;
    c->depth=0;c->root_seen=0;c->str_base=0;c->skip_depth=0;c->unit_ready=1;c->units++;
    if(!c->abbrev_ready || c->loaded_abbrev!=abbrev) {
        memset(c->codes,0,sizeof c->codes);c->attr_count=0;c->abbrev_cursor=abbrev;c->loaded_abbrev=abbrev;
        c->abbrev_started=1;c->abbrev_ready=0;
    }
    return XBO_OK;
}
static enum xbo_status abbreviations(struct xdw_cursor *c,struct xbo_budget *budget) {
    if(c->abbrev_ready)return XBO_OK;
    const struct xbo_section *sec=c->sections[ABBREV];if(!sec)return bad(c,"DwarfAbbreviationsUnavailable");
    while(!c->abbrev_ready) {
        TRY(tick(budget));struct stream s={c,budget,ABBREV,c->abbrev_cursor,sec->size};uint64_t code,tag,children;
        TRY(leb(&s,0,&code));if(!code){c->abbrev_ready=1;return XBO_OK;}
        if(code>=CODES)return limit(c,"DwarfAbbreviationCodeLimit");
        if(c->codes[code].present)return bad(c,"DwarfDuplicateAbbreviation");
        TRY(leb(&s,0,&tag));TRY(number(&s,1,&children));
        if(!tag||tag>UINT32_MAX||children>1)return bad(c,"DwarfAbbreviationMalformed");
        struct attribute attrs[XDW_ATTRIBUTES];unsigned count=0;
        for(;;) {
            uint64_t name,form,value=0;TRY(leb(&s,0,&name));TRY(leb(&s,0,&form));
            if(!name && !form)break;
            if(!name||!form||name>UINT32_MAX||form>UINT32_MAX)return bad(c,"DwarfAbbreviationMalformed");
            if(count==XDW_ATTRIBUTES)return limit(c,"DwarfAttributeLimit");
            for(unsigned i=0;i<count;i++)if(attrs[i].name==name)return bad(c,"DwarfDuplicateAttribute");
            if(form==DW_FORM_implicit_const)TRY(leb(&s,1,&value));
            attrs[count++]=(struct attribute){(uint32_t)name,(uint32_t)form,value};
        }
        if(count>ATTRS-c->attr_count)return limit(c,"DwarfAbbreviationLimit");
        memcpy(c->attrs+c->attr_count,attrs,count*sizeof *attrs);
        c->codes[code]=(struct abbreviation){(uint32_t)tag,c->attr_count,count,(unsigned)children,1};
        c->attr_count+=count;c->abbrev_cursor=s.pos;
    }
    return XBO_OK;
}
static enum xbo_status form(struct stream *s,uint32_t f,uint64_t implicit,struct xdw_attribute *out,unsigned indirect) {
    struct xdw_cursor *c=s->c;uint64_t v=0,n=0;unsigned width=0;int relative=0;
    out->form=f;
    switch(f) {
    case DW_FORM_addr:width=c->address_size;break;
    case DW_FORM_data1:case DW_FORM_flag:case DW_FORM_ref1:case DW_FORM_strx1:case DW_FORM_addrx1:width=1;break;
    case DW_FORM_data2:case DW_FORM_ref2:case DW_FORM_strx2:case DW_FORM_addrx2:width=2;break;
    case DW_FORM_strx3:case DW_FORM_addrx3:width=3;break;
    case DW_FORM_data4:case DW_FORM_ref4:case DW_FORM_ref_sup4:case DW_FORM_strx4:case DW_FORM_addrx4:width=4;break;
    case DW_FORM_data8:case DW_FORM_ref8:case DW_FORM_ref_sig8:case DW_FORM_ref_sup8:width=8;break;
    case DW_FORM_strp:case DW_FORM_line_strp:case DW_FORM_sec_offset:case DW_FORM_strp_sup:
    case DW_FORM_GNU_ref_alt:case DW_FORM_GNU_strp_alt:width=c->offset_size;break;
    case DW_FORM_ref_addr:width=c->version==2?c->address_size:c->offset_size;break;
    case DW_FORM_sdata:TRY(leb(s,1,&v));break;
    case DW_FORM_udata:case DW_FORM_ref_udata:case DW_FORM_strx:case DW_FORM_addrx:
    case DW_FORM_loclistx:case DW_FORM_rnglistx:case DW_FORM_GNU_addr_index:case DW_FORM_GNU_str_index:TRY(leb(s,0,&v));break;
    case DW_FORM_implicit_const:v=implicit;break;
    case DW_FORM_flag_present:v=1;break;
    case DW_FORM_data16:v=s->pos;TRY(skip(s,16));break;
    case DW_FORM_string: {
        v=s->pos;
        if(c->string_started && c->string_origin==v)s->pos=c->string_resume;
        enum xbo_status status=string(s,NULL,0);
        if(s->pos-v>STRING_LIMIT)return limit(c,"DwarfStringLimit");
        if(status!=XBO_OK) {c->string_started=1;c->string_origin=v;c->string_resume=s->pos;return status;}
        c->string_started=0;break;
    }
    case DW_FORM_exprloc:case DW_FORM_block:TRY(leb(s,0,&n));v=s->pos;TRY(skip(s,n));break;
    case DW_FORM_block1:case DW_FORM_block2:case DW_FORM_block4:
        TRY(number(s,f==DW_FORM_block1?1:f==DW_FORM_block2?2:4,&n));v=s->pos;TRY(skip(s,n));break;
    case DW_FORM_indirect:
        if(indirect==8)return limit(c,"DwarfIndirectFormLimit");
        TRY(leb(s,0,&n));if(n>UINT32_MAX||n==DW_FORM_implicit_const)return bad(c,"DwarfIndirectFormMalformed");
        return form(s,(uint32_t)n,0,out,indirect+1);
    default:return bad(c,"DwarfFormUnsupported");
    }
    if(width)TRY(number(s,width,&v));
    relative=f==DW_FORM_ref1||f==DW_FORM_ref2||f==DW_FORM_ref4||f==DW_FORM_ref8||f==DW_FORM_ref_udata;
    if(relative) {if(v>=c->unit_end-c->unit)return bad(c,"DwarfReferenceExtent");v+=c->unit;}
    out->value=v;return XBO_OK;
}
static enum xbo_status die(struct xdw_cursor *c,struct xbo_budget *budget,struct xdw_die *d,int *null) {
    *null=0;
    if(!c->pending_active) {
        struct stream s={c,budget,INFO,c->pos,c->unit_end};uint64_t code;
        TRY(leb(&s,0,&code));*null=!code;
        if(!code){memset(d,0,sizeof *d);d->end=s.pos;return XBO_OK;}
        if(code>=CODES||!c->codes[code].present)return bad(c,"DwarfAbbreviationMissing");
        const struct abbreviation *a=&c->codes[code];
        c->pending=(struct xdw_die){.unit=c->unit,.offset=c->pos,.unit_end=c->unit_end,.abbrev=c->abbrev,
            .tag=a->tag,.depth=c->depth,.count=a->count,.address_size=c->address_size,.offset_size=c->offset_size,
            .version=c->version,.children=a->children,.str_offsets_base=c->str_base};
        /* Copy form descriptors into the pending DIE. Completed attributes
         * survive a short budget even when their pages leave the cache. */
        for(unsigned i=0;i<a->count;i++) {
            const struct attribute *attr=&c->attrs[a->first+i];
            c->pending.attributes[i]=(struct xdw_attribute){attr->value,attr->name,attr->form};
        }
        c->pending_attr=0;c->attr_pos=s.pos;c->pending_active=1;
    }
    while(c->pending_attr<c->pending.count) {
        struct stream s={c,budget,INFO,c->attr_pos,c->unit_end};
        struct xdw_attribute attr=c->pending.attributes[c->pending_attr];
        TRY(form(&s,attr.form,attr.value,&attr,0));
        c->pending.attributes[c->pending_attr++]=attr;c->attr_pos=s.pos;
    }
    *d=c->pending;d->end=c->attr_pos;
    if(!c->root_seen) {
        if(d->tag!=DW_TAG_compile_unit&&d->tag!=DW_TAG_partial_unit&&d->tag!=DW_TAG_type_unit)return bad(c,"DwarfUnitRootMalformed");
        const struct xdw_attribute *base=xdw_attribute(d,DW_AT_str_offsets_base);
        if(base) {if(base->form!=DW_FORM_sec_offset)return bad(c,"DwarfStringBaseMalformed");d->str_offsets_base=base->value;}
    }
    return XBO_OK;
}
enum xbo_status xdw_create(struct xbo_object *object,struct xdw_cursor **out) {
    if(!out)return XBO_MALFORMED;
    *out=NULL;if(!xbo_identity(object))return XBO_MALFORMED;
    struct xdw_cursor *c=calloc(1,sizeof *c);if(!c)return XBO_NOMEM;c->object=object;
    const char *names[]={".debug_info",".debug_abbrev",".debug_str",".debug_line_str",".debug_str_offsets"};
    for(unsigned i=0;i<SECTION_COUNT;i++) {
        uint32_t index;enum xbo_status s=xbo_find_section(object,names[i],&index);
        if(s==XBO_OK){c->sections[i]=xbo_section(object,index);if(c->sections[i]->flags&SHF_COMPRESSED){free(c);return XBO_LIMIT;}}
        else if(s!=XBO_NOT_FOUND){free(c);return s;}
    }
    if(!c->sections[INFO]||!c->sections[ABBREV]){free(c);return XBO_NOT_FOUND;}
    *out=c;return XBO_OK;
}
void xdw_destroy(struct xdw_cursor *c) {free(c);}
enum xbo_status xdw_select_unit(struct xdw_cursor *c,uint64_t offset) {
    if(!c||offset>=c->sections[INFO]->size)return XBO_MALFORMED;
    c->pos=offset;c->unit=offset;c->unit_ready=0;c->complete=0;c->unit_only=1;
    c->pending_active=0;c->string_started=0;c->error=NULL;c->units=0;c->dies=0;
    return XBO_OK;
}
const struct xdw_attribute *xdw_attribute(const struct xdw_die *d,unsigned name) {
    if(!d)return NULL;
    for(unsigned i=0;i<d->count;i++)if(d->attributes[i].name==name)return &d->attributes[i];
    return NULL;
}
enum xbo_status xdw_walk(struct xdw_cursor *c,struct xbo_budget *budget,uint64_t work,xdw_visit visit,void *context) {
    if(!c||!visit)return XBO_MALFORMED;
    c->error=NULL;TRY(xbo_validate(c->object,budget));
    while(!c->complete) {
        TRY(tick(budget));if(!work--)return XBO_AGAIN;
        if(!c->unit_ready){TRY(unit(c,budget));if(c->complete)break;}
        TRY(abbreviations(c,budget));
        struct xdw_die d;int null;TRY(die(c,budget,&d,&null));
        if(null) {
            if(!c->root_seen||!c->depth)return bad(c,"DwarfChildMalformed");
            c->depth--;c->pos=d.end;
            if(c->skip_depth && c->depth<c->skip_depth)c->skip_depth=0;
        } else {
            if(c->root_seen&&!c->depth)return bad(c,"DwarfTrailingDie");
            c->str_base=d.str_offsets_base;
            enum xdw_action action=XDW_DESCEND;
            if(!c->skip_depth)TRY(visit(context,&d,&action));
            if(action>XDW_STOP)return bad(c,"DwarfVisitorAction");
            c->pos=d.end;c->root_seen=1;c->dies++;c->pending_active=0;
            if(d.children) {
                const struct xdw_attribute *sibling=xdw_attribute(&d,DW_AT_sibling);
                if(action==XDW_SKIP_CHILDREN && sibling) {
                    if((sibling->form!=DW_FORM_ref1 && sibling->form!=DW_FORM_ref2 && sibling->form!=DW_FORM_ref4 && sibling->form!=DW_FORM_ref8 && sibling->form!=DW_FORM_ref_udata && sibling->form!=DW_FORM_ref_addr) || sibling->value<=d.end||sibling->value>=c->unit_end)return bad(c,"DwarfSiblingExtent");
                    c->pos=sibling->value;
                } else {
                    if(c->depth==DEPTH)return limit(c,"DwarfDepthLimit");
                    c->depth++;
                    if(action==XDW_SKIP_CHILDREN)c->skip_depth=c->depth;
                }
            }
            if(action==XDW_STOP) {
                if(c->pos==c->unit_end) {
                    if(c->depth)return bad(c,"DwarfUnterminatedChildren");
                    c->unit_ready=0;if(c->unit_only)c->complete=1;
                }
                return XBO_OK;
            }
        }
        if(c->pos==c->unit_end) {
            if(c->depth)return bad(c,"DwarfUnterminatedChildren");
            c->unit_ready=0;if(c->unit_only)c->complete=1;
        } else if(!c->depth)return bad(c,"DwarfUnitTrailingBytes");
    }
    return xbo_validate(c->object,budget);
}
enum xbo_status xdw_string_attribute(struct xdw_cursor *c,const struct xdw_die *d,unsigned attribute,char *out,size_t n,struct xbo_budget *budget) {
    if(!c||!d||!out||!n)return XBO_MALFORMED;
    TRY(xbo_validate(c->object,budget));const struct xdw_attribute *a=xdw_attribute(d,attribute);
    if(!a){out[0]=0;return XBO_NOT_FOUND;}
    uint64_t at=a->value;unsigned sec=STR;
    switch(a->form) {
    case DW_FORM_string:sec=INFO;break;
    case DW_FORM_strp:break;
    case DW_FORM_line_strp:sec=LINE_STR;break;
    case DW_FORM_strx:case DW_FORM_strx1:case DW_FORM_strx2:case DW_FORM_strx3:case DW_FORM_strx4: {
        const struct xbo_section *offsets=c->sections[STR_OFFSETS];if(!offsets)return bad(c,"DwarfStringOffsetsUnavailable");
        if(at>(UINT64_MAX-d->str_offsets_base)/d->offset_size)return bad(c,"DwarfStringIndexOverflow");
        struct stream s={c,budget,STR_OFFSETS,d->str_offsets_base+at*d->offset_size,offsets->size};TRY(number(&s,d->offset_size,&at));break;
    }
    default:return bad(c,"DwarfNameFormUnsupported");
    }
    if(!c->sections[sec])return bad(c,"DwarfStringSectionUnavailable");
    struct stream s={c,budget,sec,at,c->sections[sec]->size};
    if(sec==INFO)s.end=d->unit_end;
    return string(&s,out,n<65536?n:65536);
}
void xdw_progress(const struct xdw_cursor *c,struct xdw_progress *p) {
    if(!p)return;
    memset(p,0,sizeof *p);if(!c)return;
    *p=(struct xdw_progress){.unit=c->unit,.next=c->pos,.info_size=c->sections[INFO]->size,
        .units=c->units,.dies=c->dies,.memory_bytes=sizeof *c,.complete=c->complete};
}
const char *xdw_error(const struct xdw_cursor *c) {return c?c->error:"DwarfCursorUnavailable";}

enum xbo_status xdw_name(struct xdw_cursor *c,const struct xdw_die *d,char *out,size_t n,struct xbo_budget *budget) {
    return xdw_string_attribute(c,d,DW_AT_name,out,n,budget);
}
