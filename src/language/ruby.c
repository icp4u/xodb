#include "ruby.h"
#include <inttypes.h>
#include <stdio.h>
#include <string.h>

/* CRuby 4eed7d64ea: vm_core.h environment indices; symbol.c ID_ENTRY_UNIT;
 * internal/numeric.h flonum encoding; iseq.c succ_index_lookup. Field offsets,
 * strides and the constants below are checked against the same image's DWARF. */
enum {
#define XRB_CONSTANT(name, value) name = value,
#include "ruby_constants.inc"
#undef XRB_CONSTANT
};
static int fail(struct xrb_reader *r, const char *why) {
    if (!r->error) r->error = why;
    return 0;
}
static uint64_t add(struct xrb_reader *r, uint64_t a, uint64_t n) {
    if (a < 4096 || a >= (UINT64_C(1)<<63) || n >= (UINT64_C(1)<<63)-a) {
        fail(r,"RubyAddressInvalid"); return 0;
    }
    return a+n;
}
static int memory(struct xrb_reader *r, uint64_t a, void *out, size_t n) {
    if (r->error) return 0;
    if (!n) return 1;
    if (!add(r,a,n)) return 0;
    if (r->reads >= XRB_READ_LIMIT || n > XRB_BYTE_LIMIT || r->bytes > XRB_BYTE_LIMIT-n) return fail(r,"RubyReadBudget");
    ++r->reads; r->bytes += n;
    if (!r->read || r->read(r->context,a,out,n)) return fail(r,"RubyMemoryUnavailable");
    return 1;
}
static uint64_t word(struct xrb_reader *r, uint64_t a, size_t n) {
    uint8_t b[8]; uint64_t value=0;
    if (!n || n>8) { fail(r,"RubyLayoutUnsupported"); return 0; }
    if (!memory(r,a,b,n)) return 0;
    for (size_t i=0;i<n;++i) value|=(uint64_t)b[i]<<(i*8);
    return value;
}
static uint64_t field(const struct xrb_layout *p, struct xrb_reader *r, uint64_t a, enum xrb_field f) {
    return word(r,add(r,a,p->fields[f].offset),p->fields[f].size);
}
static uint64_t flags(struct xrb_reader *r, uint64_t a) {
    if (a&7) { fail(r,"RubyObjectAddressInvalid"); return 0; }
    return word(r,a,8);
}
static int header(struct xrb_reader *r, uint64_t a, unsigned type, int imemo) {
    uint64_t f=flags(r,a);
    if (r->error) return 0;
    if ((f&RUBY_T_MASK)!=type || (imemo>=0 && ((f>>RUBY_FL_USHIFT)&15)!=(unsigned)imemo)) return fail(r,"RubyObjectTypeMismatch");
    return 1;
}
/* CRuby's builtin UTF-8 encoding index is 1 (encindex.h).
 * Preserve valid UTF-8; all other non-ASCII bytes remain explicit escapes. */
static size_t utf8_width(const uint8_t *s,size_t n) {
    unsigned c=s[0];size_t width=c>=0xc2&&c<=0xdf?2:c>=0xe0&&c<=0xef?3:c>=0xf0&&c<=0xf4?4:0;
    if(!width || n<width)return 0;
    for(size_t i=1;i<width;++i)if((s[i]&0xc0)!=0x80)return 0;
    if((c==0xe0 && s[1]<0xa0) || (c==0xed && s[1]>=0xa0) ||
       (c==0xf0 && s[1]<0x90) || (c==0xf4 && s[1]>=0x90))return 0;
    return width;
}
static int string(const struct xrb_layout *p, struct xrb_reader *r, uint64_t a,
                  char *out, size_t cap, uint64_t *length, int *truncated) {
    if (!header(r,a,RUBY_T_STRING,-1)) return 0;
    uint64_t f=field(p,r,a,XRB_STRING_FLAGS),n=field(p,r,a,XRB_STRING_LEN);
    uint64_t data=f&RSTRING_NOEMBED ? field(p,r,a,XRB_STRING_PTR) : add(r,a,p->fields[XRB_STRING_EMBED].offset);
    if (r->error || n>=(UINT64_C(1)<<56) || (n && !add(r,data,n))) return fail(r,"RubyStringLengthInvalid");
    uint8_t bytes[128]; size_t count=n>sizeof bytes?sizeof bytes:(size_t)n,k=0;
    if (!memory(r,data,bytes,count)) return 0;
    *length=n; *truncated=count<n;
    for (size_t i=0;i<count;++i) {
        unsigned c=bytes[i]; size_t needed=c>=32&&c<127&&c!='\\'&&c!='"'?1:4;
        size_t width=((f>>22)&127)==1?utf8_width(bytes+i,count-i):0;
        if(width) {
            if(width>=cap-k) { *truncated=1; break; }
            memcpy(out+k,bytes+i,width);k+=width;i+=width-1;continue;
        }
        /* Do not emit a broken codepoint at the raw-byte preview boundary. */
        size_t leading=c>=0xc2&&c<=0xdf?2:c>=0xe0&&c<=0xef?3:c>=0xf0&&c<=0xf4?4:0;
        if(((f>>22)&127)==1 && n>count && leading>count-i) { *truncated=1;break; }
        if (needed>=cap-k) { *truncated=1; break; }
        if (needed==1) out[k++]=(char)c;
        else { snprintf(out+k,cap-k,"\\x%02x",c); k+=4; }
    }
    if (cap) out[k]=0;
    return 1;
}
static int array(const struct xrb_layout *p, struct xrb_reader *r, uint64_t a, uint64_t *data, uint64_t *n) {
    if (!header(r,a,RUBY_T_ARRAY,-1)) return 0;
    uint64_t f=field(p,r,a,XRB_ARRAY_FLAGS);
    *n=f&RARRAY_EMBED_FLAG ? (f&RARRAY_EMBED_LEN_MASK)>>RARRAY_EMBED_LEN_SHIFT : field(p,r,a,XRB_ARRAY_LEN);
    *data=f&RARRAY_EMBED_FLAG ? add(r,a,p->fields[XRB_ARRAY_EMBED].offset) : field(p,r,a,XRB_ARRAY_PTR);
    if (r->error) return 0;
    if (*n>(UINT64_C(1)<<48) || (*n && !add(r,*data,*n*8))) return fail(r,"RubyArrayLengthInvalid");
    return 1;
}
struct hash_storage { uint64_t table,entries,start,bound,count; int st; };
/* Both paths and previews use the same validated raw entry layout. A preview
 * does not compute hashes or apply Ruby lookup/default/method semantics. */
static int hash_storage(const struct xrb_layout *p,struct xrb_reader *r,uint64_t value,
                         uint64_t f,struct hash_storage *out) {
    memset(out,0,sizeof *out);out->table=add(r,value,p->sizes[XRB_T_HASH]);
    out->st=(f&RHASH_ST_TABLE_FLAG)!=0;
    if(out->st) {
        uint64_t power=field(p,r,out->table,XRB_ST_POWER);
        out->start=field(p,r,out->table,XRB_ST_START);out->bound=field(p,r,out->table,XRB_ST_BOUND);
        out->count=field(p,r,out->table,XRB_ST_COUNT);out->entries=field(p,r,out->table,XRB_ST_ENTRIES);
        if(power<2 || power>32 || out->start>out->bound || out->bound>(UINT64_C(1)<<power) ||
           out->count>out->bound-out->start)return fail(r,"RubyPathHashInvalid");
    } else {
        out->count=(f&RHASH_AR_TABLE_SIZE_MASK)>>RHASH_AR_TABLE_SIZE_SHIFT;
        out->bound=(f&RHASH_AR_TABLE_BOUND_MASK)>>RHASH_AR_TABLE_BOUND_SHIFT;
        out->entries=add(r,out->table,p->fields[XRB_AR_PAIRS].offset);
        if(out->bound>8 || out->count>out->bound)return fail(r,"RubyPathHashInvalid");
    }
    return !r->error;
}
static int hash_entry(const struct xrb_layout *p,struct xrb_reader *r,const struct hash_storage *h,
                       uint64_t i,uint64_t *stored,uint64_t *key,uint64_t *address) {
    uint64_t entry=add(r,h->entries,i*p->sizes[h->st?XRB_T_ST_ENTRY:XRB_T_AR_PAIR]);
    *stored=h->st?field(p,r,entry,XRB_ST_HASH):word(r,add(r,h->table,p->fields[XRB_AR_HINTS].offset+i),1);
    if((h->st && *stored==UINT64_MAX) || (!h->st && !*stored))return 0;
    *key=field(p,r,entry,h->st?XRB_ST_KEY:XRB_AR_KEY);
    *address=add(r,entry,p->fields[h->st?XRB_ST_VALUE:XRB_AR_VALUE].offset);
    return !r->error;
}
static void container_display(struct xrb_value *out,int hash) {
    size_t used=(size_t)snprintf(out->display,sizeof out->display,"%s(%"PRIu64") %c",out->type,out->count,hash?'{':'[');
    int shortened=0;
    for(size_t i=0;i<out->item_count;++i) {
        const struct xrb_item *item=&out->items[i];
        size_t need=strlen(item->display)+(i?2:0)+(hash?strlen(item->key)+4:0);
        /* Leave room for an explicit ellipsis, closing delimiter and NUL. */
        if(need>=sizeof out->display-used-8) {shortened=1;break;}
        used+=(size_t)snprintf(out->display+used,sizeof out->display-used,
            hash?"%s%s => %s":"%s%s%s",i?", ":"",hash?item->key:"",item->display);
    }
    if(shortened || out->count>out->item_count) {
        used+=(size_t)snprintf(out->display+used,sizeof out->display-used,"%s...",used && out->display[used-1]!='[' && out->display[used-1]!='{'?", ":"");
        out->truncated=1;
    }
    snprintf(out->display+used,sizeof out->display-used,"%c",hash?'}':']');
}
static uint64_t id_string(const struct xrb_layout *,struct xrb_reader *,uint64_t,uint64_t);
static int preview_class(const struct xrb_layout *p,struct xrb_reader *r,uint64_t value,uint64_t global) {
    if(!global)return fail(r,"RubyPreviewClassUnproved");
    uint64_t expected=word(r,global,8),actual=field(p,r,value,XRB_BASIC_CLASS);
    if(r->error)return 0;
    if(expected<4096)return fail(r,"RubyPreviewClassUnproved");
    return actual==expected?1:fail(r,"RubyPreviewContainerClassUnsupported");
}
static void symbol_preview(const struct xrb_layout *p,struct xrb_reader *r,uint64_t symbols,
                            uint64_t v,struct xrb_value *out,unsigned depth) {
    strcpy(out->type,"Symbol");
    uint64_t text;
    if((v&0xff)==0x0c) {
        if(!symbols) {fail(r,"RubySymbolNamesUnavailable");return;}
        text=id_string(p,r,symbols,v>>8);
    } else text=field(p,r,v,XRB_SYMBOL_STRING);
    char display[480];
    if(!string(p,r,text,display,depth?220:sizeof display,&out->count,&out->truncated))return;
    int plain=!out->truncated && display[0] &&
        ((display[0]>='a'&&display[0]<='z') || (display[0]>='A'&&display[0]<='Z') || display[0]=='_');
    for(size_t i=1;display[i];++i) {
        unsigned char c=(unsigned char)display[i];
        if(!((c>='a'&&c<='z') || (c>='A'&&c<='Z') || (c>='0'&&c<='9') || c=='_'))plain=0;
    }
    if(plain)snprintf(out->display,sizeof out->display,":%s",display);
    else snprintf(out->display,sizeof out->display,":\"%s\"%s",display,out->truncated?"...":"");
}
static void decode(const struct xrb_layout *p, struct xrb_reader *r, const struct xrb_context *ctx, uint64_t v, uint64_t root, struct xrb_value *out, unsigned depth) {
    memset(out,0,sizeof *out);out->tagged=v;
    if (r->error) goto done;
    if (v&1) {
        int64_t signed_value;memcpy(&signed_value,&v,8);
        strcpy(out->type,"Integer");snprintf(out->display,sizeof out->display,"%"PRId64,signed_value>>1);
    } else if (v==0 || v==4 || v==20) {
        strcpy(out->type,v==4?"NilClass":v==20?"TrueClass":"FalseClass");
        strcpy(out->display,v==4?"nil":v==20?"true":"false");
    } else if ((v&3)==2) {
        uint64_t bits=0;
        if (v!=UINT64_C(0x8000000000000002)) {
            bits=(2-(v>>63))|(v&~UINT64_C(3));bits=(bits>>3)|(bits<<61);
        }
        double d;memcpy(&d,&bits,8);strcpy(out->type,"Float");snprintf(out->display,sizeof out->display,"%.17g",d);
    } else if ((v&0xff)==0x0c) {
        symbol_preview(p,r,ctx?ctx->symbols:0,v,out,depth);
    } else {
        unsigned t=(unsigned)(flags(r,v)&RUBY_T_MASK);
        if (r->error) goto done;
        if (t==RUBY_T_STRING) {
            char text[480];
            strcpy(out->type,"String");
            if (string(p,r,v,text,depth?220:sizeof text,&out->count,&out->truncated))
                snprintf(out->display,sizeof out->display,"\"%s\"%s",text,out->truncated?"...":"");
        } else if (t==RUBY_T_FLOAT) {
            uint64_t bits=field(p,r,v,XRB_FLOAT_VALUE); double d;memcpy(&d,&bits,8);
            strcpy(out->type,"Float");snprintf(out->display,sizeof out->display,"%.17g",d);
        } else if (t==RUBY_T_SYMBOL) {
            symbol_preview(p,r,ctx?ctx->symbols:0,v,out,depth);
        } else if (t==RUBY_T_HASH) {
            struct hash_storage h;strcpy(out->type,"Hash");
            if(!preview_class(p,r,v,ctx?ctx->hash_class:0))goto done;
            if(!hash_storage(p,r,v,flags(r,v),&h))goto done;
            out->count=h.count;out->truncated=h.count>(depth?0:XRB_PREVIEW_ITEMS);
            snprintf(out->display,sizeof out->display,"Hash(%"PRIu64")",h.count);
            if(depth && v==root)strcpy(out->display,"{...}");
            if(!depth) {
                uint64_t i=h.start,actual=0;
                for(;i<h.bound && i-h.start<512 && out->item_count<XRB_PREVIEW_ITEMS;++i) {
                    uint64_t stored,key,address;
                    if(!hash_entry(p,r,&h,i,&stored,&key,&address)) {if(r->error)break;continue;}
                    ++actual;uint64_t tagged=word(r,address,8);if(r->error)break;
                    struct xrb_value key_value,child;
                    decode(p,r,ctx,key,root,&key_value,depth+1);
                    if(r->error && !strcmp(r->error,"RubyReadBudget"))break;
                    r->error=NULL;decode(p,r,ctx,tagged,root,&child,depth+1);
                    struct xrb_item *item=&out->items[out->item_count++];item->tagged=tagged;
                    snprintf(item->key,sizeof item->key,"%.255s",key_value.display);
                    snprintf(item->type,sizeof item->type,"%s",child.type);
                    snprintf(item->display,sizeof item->display,"%.255s",child.display);
                    item->reason=key_value.reason?key_value.reason:child.reason;
                    out->truncated|=key_value.truncated|child.truncated;
                    if(r->error && !strcmp(r->error,"RubyReadBudget"))break;
                    r->error=NULL;
                }
                if(!r->error && (actual>h.count || (i==h.bound && actual!=h.count)))fail(r,"RubyPathHashInvalid");
                if(!r->error && i<h.bound && out->item_count<XRB_PREVIEW_ITEMS)fail(r,"RubyHashPreviewScanLimit");
                if(!r->error)container_display(out,1);
            }
        } else if (t==RUBY_T_ARRAY) {
            uint64_t data,n;strcpy(out->type,"Array");
            if(!preview_class(p,r,v,ctx?ctx->array_class:0))goto done;
            if (!array(p,r,v,&data,&n)) goto done;
            out->count=n;out->truncated=n>(depth?0:XRB_PREVIEW_ITEMS);
            snprintf(out->display,sizeof out->display,"Array(%"PRIu64")",n);
            if(depth && v==root)strcpy(out->display,"[...]");
            if (!depth) for (size_t i=0;i<n && i<XRB_PREVIEW_ITEMS;++i) {
                uint64_t tagged=word(r,add(r,data,i*8),8);struct xrb_value child;
                decode(p,r,ctx,tagged,root,&child,depth+1);
                struct xrb_item *item=&out->items[out->item_count++];item->tagged=tagged;
                snprintf(item->key,sizeof item->key,"%zu",i);
                snprintf(item->type,sizeof item->type,"%s",child.type);
                snprintf(item->display,sizeof item->display,"%.255s",child.display);item->reason=child.reason;
                out->truncated|=child.truncated;
                if (r->error && !strcmp(r->error,"RubyReadBudget")) break;
                r->error=NULL;
            }
            if(!depth && !r->error)container_display(out,0);
        } else {
            const char *name=t==RUBY_T_HASH?"Hash":t==RUBY_T_OBJECT?"Object":t==RUBY_T_CLASS?"Class":t==RUBY_T_MODULE?"Module":t==RUBY_T_BIGNUM?"Integer":t==RUBY_T_DATA?"Data":"unsupported";
            snprintf(out->type,sizeof out->type,"%s",name);fail(r,"RubyValueKindUnsupported");
        }
    }
done:
    out->reason=r->error;
    if (out->reason) {
        if (!out->type[0]) strcpy(out->type,"unavailable");
        snprintf(out->display,sizeof out->display,"unavailable (%s)",out->reason);
    }
}
void xrb_value_read(const struct xrb_layout *p, struct xrb_reader *r, const struct xrb_context *ctx, uint64_t v, struct xrb_value *out) {
    decode(p,r,ctx,v,v,out,0);
}
static uint64_t body(const struct xrb_layout *p, struct xrb_reader *r, uint64_t iseq) {
    if (!header(r,iseq,RUBY_T_IMEMO,imemo_iseq)) return 0;
    return field(p,r,iseq,XRB_ISEQ_BODY);
}
static uint32_t line(const struct xrb_layout *p, struct xrb_reader *r, uint64_t b, uint64_t pc) {
    if (!p->succinct_lines) { fail(r,"RubyLineTableUnproved");return 0; }
    uint64_t code=field(p,r,b,XRB_BODY_CODE),n=field(p,r,b,XRB_BODY_SIZE),pos;
    if (!n || n>INT32_MAX || pc<code || (pc-code)%8 || (pc-code)/8>n) { fail(r,"RubyInstructionInvalid");return 0; }
    pos=(pc-code)/8;if(pos) --pos;
    uint64_t count=field(p,r,b,XRB_BODY_INFO_SIZE),rank=1;
    if (!count || count>n) { fail(r,"RubyLineTableInvalid");return 0; }
    if (count>1) {
        uint64_t table=field(p,r,b,XRB_BODY_POSITIONS);
        if (pos<54) rank=(word(r,add(r,table,pos/9*8),8)>>(pos%9*7))&127;
        else {
            uint64_t bit=(pos-54)%512,small=bit/64;
            uint64_t block=add(r,table,p->sizes[XRB_T_INDEX]+(pos-54)/512*p->sizes[XRB_T_RANK]);
            rank=field(p,r,block,XRB_RANK_BASE);
            uint64_t ranks=field(p,r,block,XRB_RANK_SMALL);
            if (small) rank+=(ranks>>((small-1)*9))&511;
            uint64_t bits=word(r,add(r,block,p->fields[XRB_RANK_BITS].offset+small*8),8);
            rank+=(unsigned)__builtin_popcountll(bits & (UINT64_MAX>>(63-bit%64)));
        }
    }
    if (r->error) return 0;
    if (!rank || rank>count) { fail(r,"RubyLineTableInvalid");return 0; }
    uint64_t info=field(p,r,b,XRB_BODY_INFO);
    uint64_t got=field(p,r,add(r,info,(rank-1)*p->sizes[XRB_T_INFO]),XRB_INFO_LINE);
    if (!got || got>INT32_MAX) { fail(r,"RubyLineUnavailable");return 0; }
    return (uint32_t)got;
}
static const char *frame_kind(uint64_t f) {
    switch(f&VM_FRAME_MAGIC_MASK) {
        case VM_FRAME_MAGIC_METHOD:return "method";
        case VM_FRAME_MAGIC_BLOCK:return "block";
        case VM_FRAME_MAGIC_CLASS:return "class";
        case VM_FRAME_MAGIC_TOP:return "top";
        case VM_FRAME_MAGIC_CFUNC:return "cfunc";
        case VM_FRAME_MAGIC_IFUNC:return "ifunc";
        case VM_FRAME_MAGIC_EVAL:return "eval";
        case VM_FRAME_MAGIC_RESCUE:return "rescue";
        case VM_FRAME_MAGIC_DUMMY:return "dummy";
        default:return NULL;
    }
}
void xrb_stack_read(const struct xrb_layout *p, struct xrb_reader *r, uint64_t ec, uint64_t zjit, struct xrb_stack *out) {
    memset(out,0,sizeof *out);out->ec=ec;
    out->thread=field(p,r,ec,XRB_EC_THREAD);
    if (field(p,r,out->thread,XRB_THREAD_EC)!=ec) fail(r,"RubyExecutionContextMismatch");
    out->stack_lo=field(p,r,ec,XRB_EC_STACK);uint64_t words=field(p,r,ec,XRB_EC_STACK_SIZE);
    if (!words || words>16*1024*1024 || !p->sizes[XRB_T_CFP]) { fail(r,"RubyStackBoundsInvalid");goto done; }
    out->stack_hi=add(r,out->stack_lo,words*8);out->cfp=field(p,r,ec,XRB_EC_CFP);
    uint64_t cfp=out->cfp,stride=p->sizes[XRB_T_CFP];
    if (r->error) goto done;
    if (cfp<out->stack_lo || cfp>=out->stack_hi || cfp%8 || (out->stack_hi-cfp)%stride) {
        fail(r,"RubyStackBoundsInvalid");goto done;
    }
    while (cfp<out->stack_hi && out->count<XRB_STACK_FRAMES) {
        struct xrb_frame *f=&out->frames[out->count];f->cfp=cfp;
        f->ep=field(p,r,cfp,XRB_CFP_EP);f->pc=field(p,r,cfp,XRB_CFP_PC);
        f->iseq=field(p,r,cfp,XRB_CFP_ISEQ);f->self=field(p,r,cfp,XRB_CFP_SELF);
        if (field(p,r,cfp,XRB_CFP_JIT)) {
            ++out->count;strcpy(f->kind,"jit");strcpy(f->name,"<JIT frame>");
            f->reason=zjit?"RubyZjitFrameUnsupported":"RubyJitFrameUnsupported";
            cfp+=stride;continue;
        }
        uint64_t env=word(r,f->ep,8);const char *kind=frame_kind(env);
        if (r->error || !kind) { fail(r,"RubyFrameKindInvalid");break; }
        if (!strcmp(kind,"dummy")) break;
        snprintf(f->kind,sizeof f->kind,"%s",kind);++out->count;
        if (!strcmp(kind,"cfunc") || !strcmp(kind,"ifunc")) {
            snprintf(f->name,sizeof f->name,"<%s>",kind);f->reason="RubyNativeBoundary";
        } else {
            uint64_t b=body(p,r,f->iseq),length;int truncated;
            if (!r->error && string(p,r,field(p,r,b,XRB_BODY_LABEL),f->name,sizeof f->name,&length,&truncated) && truncated)
                fail(r,"RubyFrameNameTruncated");
            uint64_t path=field(p,r,b,XRB_BODY_PATH);
            if (!r->error && (flags(r,path)&RUBY_T_MASK)==RUBY_T_ARRAY) {
                uint64_t data,n;
                if (array(p,r,path,&data,&n) && n>=1) path=word(r,data,8);else fail(r,"RubySourcePathInvalid");
            }
            if (!r->error && string(p,r,path,f->file,sizeof f->file,&length,&truncated) && truncated)
                fail(r,"RubySourcePathTruncated");
            f->reason=r->error;r->error=NULL;
            f->line=line(p,r,b,f->pc);f->line_reason=r->error;r->error=NULL;
        }
        if (r->error) { f->reason=r->error;break; }
        cfp+=stride;
    }
    if (out->count==XRB_STACK_FRAMES && cfp<out->stack_hi) fail(r,"RubyFrameLimit");
done:out->reason=r->error;
}
static uint64_t typed_data(const struct xrb_layout *p, struct xrb_reader *r, uint64_t v) {
    return header(r,v,RUBY_T_DATA,-1)?field(p,r,v,XRB_DATA_PTR):0;
}
static uint64_t id_string(const struct xrb_layout *p, struct xrb_reader *r, uint64_t symbols, uint64_t id) {
    uint64_t serial=id>tLAST_OP_ID?id>>RUBY_ID_SCOPE_SHIFT:id;
    if (!serial || serial>=field(p,r,symbols,XRB_SYMBOLS_NEXT)) return fail(r,"RubyLocalIdInvalid");
    uint64_t dir=typed_data(p,r,field(p,r,symbols,XRB_SYMBOLS_IDS));
    uint64_t capacity=field(p,r,dir,XRB_DIRECTORY_CAPA),index=serial/512,pos=serial%512;
    if (capacity>UINT32_MAX || index>=capacity) return fail(r,"RubySymbolDirectoryInvalid");
    uint64_t entries=field(p,r,dir,XRB_DIRECTORY_ENTRIES);
    uint64_t block=typed_data(p,r,word(r,add(r,entries,index*8),8));
    uint64_t size=field(p,r,block,XRB_DARRAY_SIZE),capa=field(p,r,block,XRB_DARRAY_CAPA);
    if (size>capa || capa>512 || pos>=size) return fail(r,"RubySymbolBlockInvalid");
    uint64_t entry=add(r,block,p->sizes[XRB_T_DARRAY]+pos*p->sizes[XRB_T_ID]);
    return field(p,r,entry,XRB_ID_NAME);
}
static int name(const struct xrb_layout *p, struct xrb_reader *r, uint64_t symbols, uint64_t id, char *out, size_t cap) {
    uint64_t value=id_string(p,r,symbols,id),length;int truncated;
    if (!string(p,r,value,out,cap,&length,&truncated)) return 0;
    if (!length || truncated) return fail(r,"RubyLocalNameTruncated");
    return 1;
}
static int environment(const struct xrb_layout *p, struct xrb_reader *r, const struct xrb_stack *stack,
                       uint64_t ep, uint64_t iseq, uint64_t n, uint64_t *envflags, uint64_t *slots) {
    *envflags=word(r,ep,8);
    if (ep%8 || n>4096 || ep<(n+2)*8) return fail(r,"RubyEnvironmentInvalid");
    *slots=ep-(n+2)*8;
    if (*envflags&VM_ENV_FLAG_ESCAPED) {
        uint64_t env=word(r,add(r,ep,8),8);
        if (!header(r,env,RUBY_T_IMEMO,imemo_env)) return 0;
        if (field(p,r,env,XRB_ENV_EP)!=ep || field(p,r,env,XRB_ENV_ISEQ)!=iseq) return fail(r,"RubyEnvironmentIdentityMismatch");
        uint64_t data=field(p,r,env,XRB_ENV_DATA),size=field(p,r,env,XRB_ENV_SIZE);
        if (!size || size>65536 || *slots<data || ep<data || (ep-data)%8 || (ep-data)/8>=size)
            return fail(r,"RubyEnvironmentBoundsInvalid");
    } else if (*slots<stack->stack_lo || ep>=stack->cfp) return fail(r,"RubyEnvironmentBoundsInvalid");
    return !r->error;
}
/* Mirror rb_vm_frame_method_entry's bounded environment walk. The local
 * environment may wrap its method entry in one vm_svar; a cref is not a method.
 * Do not infer an owner from self: inherited/included methods belong elsewhere. */
static uint64_t frame_method(const struct xrb_layout *p, struct xrb_reader *r,
                             const struct xrb_stack *stack, const struct xrb_frame *f) {
    uint64_t ep=f->ep,iseq=f->iseq,seen[64];
    for(size_t depth=0;depth<64;++depth) {
        for(size_t i=0;i<depth;++i) if(seen[i]==ep) {fail(r,"RubyEnvironmentCycle");return 0;}
        seen[depth]=ep;
        uint64_t env,slots;
        if(!environment(p,r,stack,ep,iseq,0,&env,&slots))return 0;
        uint64_t me=word(r,ep-16,8);
        if(me) {
            if(!header(r,me,RUBY_T_IMEMO,-1))return 0;
            unsigned type=(unsigned)((flags(r,me)>>RUBY_FL_USHIFT)&15);
            if(type==imemo_svar && (env&VM_ENV_FLAG_LOCAL)) {
                me=field(p,r,me,XRB_SVAR_METHOD);
                if(me && !header(r,me,RUBY_T_IMEMO,-1))return 0;
                type=me?(unsigned)((flags(r,me)>>RUBY_FL_USHIFT)&15):imemo_cref;
            }
            if(type==imemo_ment)return r->error?0:me;
            if(type!=imemo_cref) {fail(r,"RubyFrameMethodUnproved");return 0;}
        }
        if(r->error)return 0;
        if(env&VM_ENV_FLAG_LOCAL) {fail(r,"RubyFrameMethodUnavailable");return 0;}
        if(env&VM_ENV_FLAG_ISOLATED) {fail(r,"RubyIsolatedEnvironmentBoundary");return 0;}
        uint64_t b=body(p,r,iseq);
        iseq=field(p,r,b,XRB_BODY_PARENT);
        ep=word(r,ep-8,8)&~UINT64_C(3);
        if(r->error)return 0;
    }
    fail(r,"RubyEnvironmentDepthLimit");return 0;
}
static int class_name(const struct xrb_layout *p, struct xrb_reader *r,
                       uint64_t klass, char *out, size_t cap, char *separator) {
    uint64_t f=flags(r,klass);unsigned type=(unsigned)(f&RUBY_T_MASK);
    if(type!=RUBY_T_CLASS && type!=RUBY_T_MODULE)return fail(r,"RubyFrameOwnerUnproved");
    if((f&(UINT64_C(1)<<(RUBY_FL_USHIFT+4))) && field(p,r,klass,XRB_CLASS_BOX_TABLE))return fail(r,"RubyFrameBoxUnsupported");
    if(type==RUBY_T_CLASS && (f&RUBY_FL_SINGLETON)) {
        klass=field(p,r,klass,XRB_CLASS_ATTACHED);
        f=flags(r,klass);type=(unsigned)(f&RUBY_T_MASK);
        if((type!=RUBY_T_CLASS && type!=RUBY_T_MODULE) || (type==RUBY_T_CLASS && (f&RUBY_FL_SINGLETON)))
            return fail(r,"RubyFrameSingletonOwnerUnproved");
        if((f&(UINT64_C(1)<<(RUBY_FL_USHIFT+4))) && field(p,r,klass,XRB_CLASS_BOX_TABLE))return fail(r,"RubyFrameBoxUnsupported");
        *separator='.';
    }
    uint64_t path=field(p,r,klass,XRB_CLASS_PATH),length;int truncated;
    if(r->error)return 0;
    if(!path || path==4)return fail(r,"RubyFrameOwnerUnnamed");
    if(!string(p,r,path,out,cap,&length,&truncated))return 0;
    if(!length || truncated)return fail(r,"RubyFrameOwnerTruncated");
    return 1;
}
void xrb_stack_names(const struct xrb_layout *p, struct xrb_reader *r, uint64_t symbols, struct xrb_stack *stack) {
    const char *prior=r->error;
    for(size_t i=0;i<stack->count && i<XRB_STACK_FRAMES;++i) {
        struct xrb_frame *f=&stack->frames[i];f->qualified_name[0]=0;f->name_reason=NULL;r->error=NULL;
        /* A proved top-level instruction sequence has no method owner. */
        if(!strcmp(f->name,"<main>") && (!strcmp(f->kind,"top") || !strcmp(f->kind,"eval"))) {
            uint64_t type=field(p,r,body(p,r,f->iseq),XRB_BODY_TYPE);
            if(!r->error && (type==ISEQ_TYPE_TOP || type==ISEQ_TYPE_MAIN)) {
                strcpy(f->qualified_name,"<main>");continue;
            }
            if(r->error) {f->name_reason=r->error;continue;}
        }
        if(!symbols) {f->name_reason="RubyRuntimeSymbolsUnavailable";continue;}
        if(!strcmp(f->kind,"jit") || !strcmp(f->kind,"ifunc")) {f->name_reason="RubyFrameMethodUnproved";continue;}
        uint64_t me=frame_method(p,r,stack,f);
        char owner[192],method[192],original[192]="",separator='#';
        if(!r->error) {
            uint64_t defined=field(p,r,me,XRB_CALLABLE_CLASS);
            unsigned type=(unsigned)(flags(r,defined)&RUBY_T_MASK);
            if(type!=RUBY_T_CLASS && type!=RUBY_T_MODULE && type!=RUBY_T_ICLASS)fail(r,"RubyFrameDefinedClassUnproved");
        }
        uint64_t def=field(p,r,me,XRB_CALLABLE_DEF),type=field(p,r,def,XRB_METHOD_TYPE)&15;
        uint64_t called=field(p,r,me,XRB_CALLABLE_ID),original_id=field(p,r,def,XRB_METHOD_ORIGINAL_ID);
        uint64_t env=word(r,f->ep,8);
        int bmethod=type==VM_METHOD_TYPE_BMETHOD,body_frame=(env&VM_FRAME_FLAG_BMETHOD)!=0;
        if(!r->error && ((!strcmp(f->kind,"cfunc") && type!=VM_METHOD_TYPE_CFUNC) || (body_frame && !bmethod)))
            fail(r,"RubyFrameMethodUnproved");
        if(!r->error && original_id!=called)name(p,r,symbols,original_id,original,sizeof original);
        if(!r->error && name(p,r,symbols,called,method,sizeof method) &&
           class_name(p,r,field(p,r,me,XRB_CALLABLE_OWNER),owner,sizeof owner,&separator)) {
            const char *prefix="";
            if(!strcmp(f->kind,"block") && !body_frame)prefix="block in ";
            else if(!strcmp(f->kind,"rescue"))prefix="rescue in ";
            int n=snprintf(f->qualified_name,sizeof f->qualified_name,"%s%s%c%s%s%s%s%s",prefix,owner,separator,method,
                original[0]?" (alias of ":"",original,original[0]?")":"",bmethod?" (define_method)":"");
            if(n<0 || (size_t)n>=sizeof f->qualified_name)fail(r,"RubyFrameNameTruncated");
        }
        f->name_reason=r->error;
        if(f->name_reason)f->qualified_name[0]=0;
    }
    r->error=prior;
}
static void locals_read(const struct xrb_layout *p, struct xrb_reader *r, uint64_t ec,
                     uint64_t zjit, const struct xrb_context *ctx, size_t frame,
                     size_t start, size_t limit, int preview, struct xrb_locals *out) {
    memset(out,0,sizeof *out);out->start=start;
    if (limit>XRB_LOCAL_ITEMS || start>4096) { out->reason="RubyLocalPageInvalid";return; }
    struct xrb_stack stack;xrb_stack_read(p,r,ec,zjit,&stack);
    if (frame>=stack.count) { out->reason=stack.reason?stack.reason:"RubyFrameUnavailable";return; }
    const struct xrb_frame *f=&stack.frames[frame];
    if (f->reason) { out->reason=f->reason;return; }
    r->error=NULL;uint64_t ep=f->ep,iseq=f->iseq,seen[64];size_t depth=0;
    while (depth<64) {
        for (size_t i=0;i<depth;++i) if (seen[i]==ep) { fail(r,"RubyEnvironmentCycle");goto done; }
        seen[depth]=ep;
        uint64_t b=body(p,r,iseq),n=field(p,r,b,XRB_BODY_LOCAL_SIZE),table=field(p,r,b,XRB_BODY_LOCALS),env,slots;
        if (n>4096-out->total) { fail(r,"RubyLocalLimit");break; }
        if (!environment(p,r,&stack,ep,iseq,n,&env,&slots)) break;
        for (size_t i=0;i<n;++i) {
            size_t ordinal=out->total++;
            if (ordinal<start || out->count==limit) continue;
            struct xrb_local *row=&out->items[out->count++];
            row->ordinal=ordinal;row->depth=depth;row->escaped=(env&VM_ENV_FLAG_ESCAPED)!=0;
            uint64_t id=word(r,add(r,table,i*8),8);row->hidden=!id || (id&RUBY_ID_SCOPE_MASK)==RUBY_ID_INTERNAL;
            if (!row->hidden) name(p,r,ctx?ctx->symbols:0,id,row->name,sizeof row->name);
            row->reason=r->error;r->error=NULL;
            row->address=add(r,slots,i*8);row->tagged=word(r,row->address,8);
            if (preview) xrb_value_read(p,r,ctx,row->tagged,&row->value);
            if (r->error && !strcmp(r->error,"RubyReadBudget")) goto done;
            r->error=NULL;
        }
        if (env&VM_ENV_FLAG_LOCAL) break;
        if (env&VM_ENV_FLAG_ISOLATED) { fail(r,"RubyIsolatedEnvironmentBoundary");break; }
        if (ep<8) { fail(r,"RubyEnvironmentInvalid");break; }
        ep=word(r,ep-8,8)&~UINT64_C(3);iseq=field(p,r,b,XRB_BODY_PARENT);++depth;
        if (r->error) break;
    }
    if (depth==64) fail(r,"RubyEnvironmentDepthLimit");
done:
    out->reason=r->error;out->truncated=out->total>start+out->count || out->reason!=NULL;
}
void xrb_locals_read(const struct xrb_layout *p, struct xrb_reader *r, uint64_t ec,
                     uint64_t zjit, const struct xrb_context *ctx, size_t frame,
                     size_t start, size_t limit, struct xrb_locals *out) {
    locals_read(p,r,ec,zjit,ctx,frame,start,limit,1,out);
}
static void local_find(const struct xrb_layout *p, struct xrb_reader *r, uint64_t ec,
                    uint64_t zjit, const struct xrb_context *ctx, size_t frame,
                    const char *expression, int preview, struct xrb_locals *out) {
    memset(out,0,sizeof *out);
    size_t length=0;
    if (!expression || !*expression) { out->reason="RubyExpressionUnsupported";return; }
    for (const unsigned char *s=(const unsigned char *)expression;*s;++s,++length) {
        if (length>=128 || !((*s>='a'&&*s<='z') || (*s>='A'&&*s<='Z') || *s=='_' || (length && *s>='0'&&*s<='9'))) {
            out->reason="RubyExpressionUnsupported";return;
        }
    }
    for (size_t start=0;start<4096;start+=XRB_LOCAL_ITEMS) {
        struct xrb_locals page;locals_read(p,r,ec,zjit,ctx,frame,start,XRB_LOCAL_ITEMS,preview,&page);
        for (size_t i=0;i<page.count;++i) {
            struct xrb_local *row=&page.items[i];
            if (row->hidden) continue;
            /* An unreadable inner name might shadow any outer name. */
            if (row->reason) { out->reason=row->reason;return; }
            if (!strcmp(row->name,expression)) {
                out->count=out->total=1;out->items[0]=*row;return;
            }
        }
        if (page.reason) { out->reason=page.reason;return; }
        if (!page.truncated) break;
    }
    out->reason="RubyLocalNotFound";
}

void xrb_local_find(const struct xrb_layout *p, struct xrb_reader *r, uint64_t ec,
                    uint64_t zjit, const struct xrb_context *ctx, size_t frame,
                    const char *expression, struct xrb_locals *out) {
    local_find(p,r,ec,zjit,ctx,frame,expression,1,out);
}

/* The exact supported revision's encoding.h defines seven bits starting at
 * FL_USHIFT+10. These enum names are absent from the runtime-owned DWARF units;
 * the public-macro oracle verifies this additional source-pinned contract. */
enum { XRB_ENCODING_SHIFT = RUBY_FL_USHIFT+10, XRB_ENCODING_INLINE_MAX = 127 };
static void sample_word(struct xrb_sample *out, uint64_t value) {
    for (size_t i=0;i<8;++i) out->bytes[out->size++]=(unsigned char)(value>>(8*i));
}
void xrb_sample_read(const struct xrb_layout *p, struct xrb_reader *r, uint64_t v,
                     struct xrb_sample *out) {
    memset(out,0,sizeof *out);
    if (r->error) goto done;
    if (v&1) {
        out->kind=1;
        /* Arithmetic decoding without an implementation-defined signed shift. */
        sample_word(out,(v>>1)|(v&(UINT64_C(1)<<63)));
    } else if (v==4 || v==0 || v==20) {
        out->kind=v==4?3:v==0?4:5;
    } else if ((v&3)==2) {
        uint64_t bits=0;
        if (v!=UINT64_C(0x8000000000000002)) {
            bits=(2-(v>>63))|(v&~UINT64_C(3));bits=(bits>>3)|(bits<<61);
        }
        out->kind=2;sample_word(out,bits);
    } else if ((v&0xff)==0x0c) {
        fail(r,"RubyWatchValueUnsupported");
    } else {
        uint64_t f=flags(r,v);
        if (r->error) goto done;
        if ((f&RUBY_T_MASK)==RUBY_T_FLOAT) {
            out->kind=2;sample_word(out,field(p,r,v,XRB_FLOAT_VALUE));
        } else if ((f&RUBY_T_MASK)==RUBY_T_STRING) {
            uint64_t encoding=(f>>XRB_ENCODING_SHIFT)&XRB_ENCODING_INLINE_MAX;
            uint64_t n=field(p,r,v,XRB_STRING_LEN);
            if (encoding==XRB_ENCODING_INLINE_MAX) { fail(r,"RubyWatchEncodingUnsupported");goto done; }
            if (n>sizeof out->bytes-1) { fail(r,"RubyWatchSampleLimit");goto done; }
            uint64_t data=f&RSTRING_NOEMBED?field(p,r,v,XRB_STRING_PTR):add(r,v,p->fields[XRB_STRING_EMBED].offset);
            out->kind=6;out->bytes[0]=(unsigned char)encoding;
            if (!memory(r,data,out->bytes+1,(size_t)n)) goto done;
            out->size=(size_t)n+1;
        } else fail(r,"RubyWatchValueUnsupported");
    }
    if (!r->error) {
        struct xrb_value preview;xrb_value_read(p,r,0,v,&preview);
        if (preview.reason) fail(r,preview.reason);
        else {
            snprintf(out->type,sizeof out->type,"%s",preview.type);
            snprintf(out->display,sizeof out->display,"%s",preview.display);
        }
    }
done:
    out->reason=r->error;
    if (out->reason) out->size=0;
}

/* Raw builtin subscriptions. The method/class checks deliberately refuse
 * subclasses, singleton methods, refinements, prepend and box-specific tables.
 * They do not execute dispatch or assume that a T_HASH has builtin semantics. */
enum { XRB_PATH_DEPTH=8, XRB_PATH_ENTRIES=512, XRB_PATH_KEY_BYTES=1024 };
struct ruby_step { unsigned kind; uint64_t index; char key[129]; size_t length; };
struct ruby_path { char root[129]; size_t count; struct ruby_step steps[XRB_PATH_DEPTH]; };
static int path_identifier(unsigned char c, int first) {
    return c=='_' || (c>='a'&&c<='z') || (c>='A'&&c<='Z') || (!first&&c>='0'&&c<='9');
}
static const char *ruby_path_parse(const char *text, struct ruby_path *out) {
    memset(out,0,sizeof *out);size_t n=0;
    if(!text) return "RubyExpressionUnsupported";
    while(n<=128 && text[n])++n;
    if(!n || n>128 || !path_identifier((unsigned char)text[0],1)) return "RubyExpressionUnsupported";
    size_t at=1;
    while(at<n && path_identifier((unsigned char)text[at],0))++at;
    memcpy(out->root,text,at);
    while(at<n) {
        if(out->count==XRB_PATH_DEPTH || text[at++]!='[' || at==n) return "RubyExpressionUnsupported";
        struct ruby_step *step=&out->steps[out->count++];
        if(text[at]==':' || text[at]=='\'' || text[at]=='"') {
            char quote=text[at++];step->kind=quote==':'?2:1;size_t begin=at;
            if(quote==':') {
                if(at==n || !path_identifier((unsigned char)text[at],1)) return "RubyExpressionUnsupported";
                while(at<n && path_identifier((unsigned char)text[at],0))++at;
            } else {
                while(at<n && text[at]!=quote) {
                    unsigned char c=(unsigned char)text[at++];
                    if(c<32 || c>=127 || c=='\\' || c=='#') return "RubyExpressionUnsupported";
                }
                if(at==n) return "RubyExpressionUnsupported";
            }
            step->length=at-begin;memcpy(step->key,text+begin,step->length);
            if(quote!=':')++at;
        } else {
            size_t begin=at;
            while(at<n && text[at]>='0' && text[at]<='9') {
                unsigned digit=(unsigned)(text[at++]-'0');
                if(step->index>(INT32_MAX-digit)/10u) return "RubyExpressionUnsupported";
                step->index=step->index*10+digit;
            }
            if(at==begin || (at-begin>1 && text[begin]=='0')) return "RubyExpressionUnsupported";
        }
        if(at==n || text[at++]!=']') return "RubyExpressionUnsupported";
    }
    return NULL;
}
const char *xrb_expression_check(const char *text) {
    struct ruby_path path;return ruby_path_parse(text,&path);
}
struct path_proof { uint64_t classes[5],seed,k0,k1; unsigned checked; };
static int builtin_method(const struct xrb_layout *p, struct xrb_reader *r,
                           uint64_t klass, uint64_t id, uint64_t function, int argc) {
    uint64_t seen[16];size_t depth=0;
    while(klass && depth<16) {
        for(size_t i=0;i<depth;++i) if(seen[i]==klass) return fail(r,"RubyPathClassCycle");
        seen[depth++]=klass;
        uint64_t f=flags(r,klass);unsigned t=(unsigned)(f&RUBY_T_MASK);
        if(t!=RUBY_T_CLASS && t!=RUBY_T_MODULE && t!=RUBY_T_ICLASS) return fail(r,"RubyPathClassUnproved");
        /* RCLASS_BOXABLE is FL_USER4 in this source-pinned revision. */
        if((f&(UINT64_C(1)<<(RUBY_FL_USHIFT+4))) && field(p,r,klass,XRB_CLASS_BOX_TABLE)) return fail(r,"RubyPathBoxUnsupported");
        uint64_t origin=field(p,r,klass,XRB_CLASS_ORIGIN);
        if(t!=RUBY_T_ICLASS && origin!=klass) return fail(r,"RubyPathPrependUnsupported");
        uint64_t table=field(p,r,klass,XRB_CLASS_METHODS);
        if(r->error) return 0;
        if(table) {
            int32_t cap=(int32_t)field(p,r,table,XRB_METHOD_CAPACITY);
            int32_t count=(int32_t)field(p,r,table,XRB_METHOD_COUNT);
            int32_t used_=(int32_t)field(p,r,table,XRB_METHOD_USED);
            uint64_t buffer=field(p,r,table,XRB_METHOD_BUFFER);
            if(cap<0 || cap>4096 || (cap && (cap&(cap-1))) || count<0 || count>used_ || used_>cap || (cap && !buffer))
                return fail(r,"RubyPathMethodTableUnproved");
            uint8_t data[4096*12];
            if(!memory(r,buffer,data,(size_t)cap*12)) return 0;
            uint64_t found=0;unsigned actual=0;
            uint32_t serial=(uint32_t)(id>tLAST_OP_ID?id>>RUBY_ID_SCOPE_SHIFT:id);
            for(int32_t i=0;i<cap;++i) {
                const uint8_t *key=data+(size_t)cap*8+(size_t)i*4;
                uint32_t k=(uint32_t)key[0]|(uint32_t)key[1]<<8|(uint32_t)key[2]<<16|(uint32_t)key[3]<<24;
                if(!k) continue;
                ++actual;uint64_t v=0;
                for(unsigned j=0;j<8;++j)v|=(uint64_t)data[(size_t)i*8+j]<<(8*j);
                if(!v) return fail(r,"RubyPathMethodTableUnproved");
                if(k==serial) {if(found)return fail(r,"RubyPathMethodTableUnproved");found=v;}
            }
            if(actual!=(unsigned)count) return fail(r,"RubyPathMethodTableUnproved");
            if(found) {
                if(!header(r,found,RUBY_T_IMEMO,imemo_ment) || field(p,r,found,XRB_METHOD_ID)!=id) return fail(r,"RubyPathMethodUnproved");
                uint64_t def=field(p,r,found,XRB_METHOD_DEF);
                if((field(p,r,def,XRB_METHOD_TYPE)&15)!=VM_METHOD_TYPE_CFUNC ||
                   field(p,r,def,XRB_METHOD_FUNC)!=function || field(p,r,def,XRB_METHOD_ORIGINAL_ID)!=id ||
                   (int32_t)field(p,r,def,XRB_METHOD_ARGC)!=argc) return fail(r,"RubyPathCustomMethodUnsupported");
                return !r->error;
            }
        }
        klass=field(p,r,klass,XRB_CLASS_SUPER);
        if(r->error) return 0;
    }
    return fail(r,"RubyPathMethodUnproved");
}
static int path_methods(const struct xrb_layout *p, struct xrb_reader *r,
                        const struct xrb_context *ctx, struct path_proof *proof, unsigned kind) {
    if(proof->checked&(1u<<kind)) return 1;
    uint64_t klass=proof->classes[kind];
    if(kind<2) {
        if(!builtin_method(p,r,klass,idAREF,kind?ctx->array_aref:ctx->hash_aref,kind?-1:1)) return 0;
    } else {
        uint64_t hash=kind==2?ctx->string_hash:ctx->object_hash;
        uint64_t eql=kind==2?ctx->string_eql:kind==3?ctx->numeric_eql:ctx->object_eql;
        if(!builtin_method(p,r,klass,idHash,hash,0) || !builtin_method(p,r,klass,idEqlP,eql,1)) return 0;
    }
    proof->checked|=1u<<kind;return 1;
}
static uint64_t rotl(uint64_t v,unsigned n) {return (v<<n)|(v>>(64-n));}
static void sip_round(uint64_t v[4]) {
    v[0]+=v[1];v[1]=rotl(v[1],13);v[1]^=v[0];v[0]=rotl(v[0],32);
    v[2]+=v[3];v[3]=rotl(v[3],16);v[3]^=v[2];
    v[0]+=v[3];v[3]=rotl(v[3],21);v[3]^=v[0];
    v[2]+=v[1];v[1]=rotl(v[1],17);v[1]^=v[2];v[2]=rotl(v[2],32);
}
static uint64_t sip13(const struct path_proof *p,const uint8_t *bytes,size_t n) {
    uint64_t v[]={UINT64_C(0x736f6d6570736575)^p->k0,UINT64_C(0x646f72616e646f6d)^p->k1,
                  UINT64_C(0x6c7967656e657261)^p->k0,UINT64_C(0x7465646279746573)^p->k1};
    size_t at=0;
    while(n-at>=8) {
        uint64_t m=0;for(unsigned j=0;j<8;++j)m|=(uint64_t)bytes[at+j]<<(8*j);
        v[3]^=m;sip_round(v);v[0]^=m;at+=8;
    }
    uint64_t last=(uint64_t)n<<56;
    for(unsigned j=0;at<n;++at,++j)last|=(uint64_t)bytes[at]<<(8*j);
    v[3]^=last;sip_round(v);v[0]^=last;v[2]^=255;
    for(unsigned i=0;i<3;++i)sip_round(v);
    return v[0]^v[1]^v[2]^v[3];
}
static uint64_t mul_mix(uint64_t a,uint64_t b) {
    uint64_t al=(uint32_t)a,ah=a>>32,bl=(uint32_t)b,bh=b>>32;
    uint64_t low=al*bl,mid=ah*bl+(low>>32),carry=mid>>32;
    mid=(uint32_t)mid+al*bh;
    uint64_t high=ah*bh+carry+(mid>>32);
    return high^(a*b);
}
static uint64_t hash_fixnum_range(uint64_t hash) {
    return hash>>63 ? hash|UINT64_C(0xc000000000000000) : hash&UINT64_C(0x3fffffffffffffff);
}
static int raw_ascii_key(const struct xrb_layout *p,struct xrb_reader *r,uint64_t value,
                          uint8_t bytes[XRB_PATH_KEY_BYTES],size_t *length) {
    if(!header(r,value,RUBY_T_STRING,-1)) return 0;
    uint64_t f=field(p,r,value,XRB_STRING_FLAGS),n=field(p,r,value,XRB_STRING_LEN);
    unsigned encoding=(unsigned)((f>>XRB_ENCODING_SHIFT)&XRB_ENCODING_INLINE_MAX);
    if(encoding>2 || n>XRB_PATH_KEY_BYTES) return fail(r,"RubyPathKeyUnsupported");
    uint64_t data=f&RSTRING_NOEMBED?field(p,r,value,XRB_STRING_PTR):add(r,value,p->fields[XRB_STRING_EMBED].offset);
    if(!memory(r,data,bytes,(size_t)n)) return 0;
    for(size_t i=0;i<n;++i)if(bytes[i]>=128) return fail(r,"RubyPathKeyUnsupported");
    *length=(size_t)n;return 1;
}
static int path_key(const struct xrb_layout *p,struct xrb_reader *r,const struct xrb_context *ctx,
                     struct path_proof *proof,uint64_t key,const struct ruby_step *wanted,
                     uint64_t *hash,int *equal) {
    *equal=0;
    if(key&1) {
        if(!path_methods(p,r,ctx,proof,3)) return 0;
        *hash=mul_mix(proof->seed+key+UINT64_C(0x830fcab9),UINT64_C(0x2e0bb864e9ea7df5));
        *equal=wanted->kind==0 && key==(wanted->index*2+1);
    } else if((key&0xff)==0x0c) {
        if(!path_methods(p,r,ctx,proof,4)) return 0;
        char text[256];
        if(!name(p,r,ctx->symbols,key>>8,text,sizeof text)) return 0;
        *hash=proof->seed+(key>>(8+RUBY_ID_SCOPE_SHIFT));
        *equal=wanted->kind==2 && strlen(text)==wanted->length && !memcmp(text,wanted->key,wanted->length);
    } else {
        if(key<4096 || key&7) return fail(r,"RubyPathKeyUnsupported");
        unsigned type=(unsigned)(flags(r,key)&RUBY_T_MASK);
        uint64_t klass=field(p,r,key,XRB_BASIC_CLASS);
        if(type!=RUBY_T_STRING && type!=RUBY_T_SYMBOL) return fail(r,"RubyPathKeyUnsupported");
        unsigned k=type==RUBY_T_STRING?2:4;
        if(klass!=proof->classes[k] || !path_methods(p,r,ctx,proof,k)) return fail(r,"RubyPathKeyClassUnsupported");
        uint64_t str=type==RUBY_T_STRING?key:field(p,r,key,XRB_SYMBOL_STRING);
        uint8_t bytes[XRB_PATH_KEY_BYTES];size_t n;
        if(!raw_ascii_key(p,r,str,bytes,&n)) return 0;
        *hash=sip13(proof,bytes,n);
        if(type==RUBY_T_SYMBOL) {
            if(field(p,r,key,XRB_SYMBOL_HASH)!=*hash) return fail(r,"RubyPathHashUnproved");
            *hash>>=1;
        }
        *equal=wanted->kind==(type==RUBY_T_STRING?1u:2u) && n==wanted->length && !memcmp(bytes,wanted->key,n);
    }
    *hash=hash_fixnum_range(*hash);return !r->error;
}
static int path_hash_lookup(const struct xrb_layout *p,struct xrb_reader *r,const struct xrb_context *ctx,
                             struct path_proof *proof,uint64_t value,const struct ruby_step *step,
                             struct xrb_path_value *out) {
    /* A missing key still has a requested key type. Prove its hash/eql?
     * methods even when the table contains no key of that type. */
    if(!path_methods(p,r,ctx,proof,step->kind==0?3:step->kind==1?2:4)) return 0;
    uint64_t f=flags(r,value);
    if(f&RHASH_COMPARE_BY_IDENTITY) return fail(r,"RubyPathIdentityHashUnsupported");
    if(f&RHASH_PROC_DEFAULT) return fail(r,"RubyPathDefaultUnsupported");
    struct hash_storage h;
    if(!hash_storage(p,r,value,f,&h))return 0;
    uint64_t start=h.start,bound=h.bound,count=h.count;int st=h.st;
    if(st) {
        uint64_t type=field(p,r,h.table,XRB_ST_TYPE);
        if(field(p,r,type,XRB_ST_COMPARE_FN)!=ctx->any_cmp || field(p,r,type,XRB_ST_HASH_FN)!=ctx->any_hash) return fail(r,"RubyPathHashTypeUnsupported");
    }
    if(bound-start>XRB_PATH_ENTRIES) return fail(r,"RubyPathHashLimit");
    size_t actual=0;int found=0;struct xrb_path_value match={0};
    for(uint64_t i=start;i<bound;++i) {
        uint64_t stored,key,address,hash;int equal;
        if(!hash_entry(p,r,&h,i,&stored,&key,&address)) {if(r->error)return 0;continue;}
        ++actual;
        if(!path_key(p,r,ctx,proof,key,step,&hash,&equal)) return 0;
        if(st) {if(hash==UINT64_MAX)hash=0;}
        else {hash&=255;if(!hash)hash=1;}
        if(hash!=stored) return fail(r,"RubyPathHashUnproved");
        if(equal) {
            if(found++) return fail(r,"RubyPathDuplicateKey");
            match.address=address;
            match.tagged=word(r,match.address,8);
        }
    }
    if(r->error) return 0;
    if(actual!=count) return fail(r,"RubyPathHashInvalid");
    if(!found) {
        if(field(p,r,value,XRB_HASH_DEFAULT)!=4) return fail(r,"RubyPathDefaultUnsupported");
        return fail(r,"RubyPathKeyNotFound");
    }
    *out=match;return 1;
}
static void ruby_path_read(const struct xrb_layout *p,struct xrb_reader *r,const struct xrb_context *ctx,
                            uint64_t root,const struct ruby_path *path,struct xrb_path_value *out) {
    memset(out,0,sizeof *out);out->tagged=root;
    struct path_proof proof={0};
    if(path->count) {
        const uint64_t globals[]={ctx->hash_class,ctx->array_class,ctx->string_class,ctx->integer_class,ctx->symbol_class};
        for(size_t i=0;i<5;++i)proof.classes[i]=word(r,globals[i],8);
        proof.seed=field(p,r,ctx->hash_salt,XRB_HASH_SEED);
        proof.k0=word(r,add(r,ctx->hash_salt,p->fields[XRB_SIP_SEED].offset),8);
        proof.k1=word(r,add(r,ctx->hash_salt,p->fields[XRB_SIP_SEED].offset+8),8);
    }
    for(size_t i=0;i<path->count && !r->error;++i) {
        const struct ruby_step *step=&path->steps[i];uint64_t current=out->tagged;
        if(current<4096 || current&7) {fail(r,"RubyPathContainerRequired");break;}
        unsigned type=(unsigned)(flags(r,current)&RUBY_T_MASK),k=type==RUBY_T_HASH?0:1;
        if(type!=RUBY_T_HASH && type!=RUBY_T_ARRAY) {fail(r,"RubyPathContainerRequired");break;}
        if(field(p,r,current,XRB_BASIC_CLASS)!=proof.classes[k]) {fail(r,"RubyPathContainerClassUnsupported");break;}
        if(!path_methods(p,r,ctx,&proof,k))break;
        if(type==RUBY_T_HASH) {
            if(!path_hash_lookup(p,r,ctx,&proof,current,step,out))break;
        } else {
            uint64_t data,n;
            if(step->kind) {fail(r,"RubyPathArrayIndexRequired");break;}
            if(!array(p,r,current,&data,&n))break;
            if(step->index>=n) {fail(r,"RubyPathIndexOutOfRange");break;}
            out->address=add(r,data,step->index*8);out->tagged=word(r,out->address,8);
        }
    }
    out->reason=r->error;
    if(out->reason)out->tagged=out->address=0;
}
void xrb_path_read(const struct xrb_layout *p,struct xrb_reader *r,const struct xrb_context *ctx,
                   uint64_t root,const char *text,struct xrb_path_value *out) {
    struct ruby_path path;memset(out,0,sizeof *out);out->reason=ruby_path_parse(text,&path);
    if(!out->reason)ruby_path_read(p,r,ctx,root,&path,out);
}
void xrb_expression_find(const struct xrb_layout *p,struct xrb_reader *r,const struct xrb_context *ctx,
                         uint64_t ec,uint64_t zjit,size_t frame,const char *text,struct xrb_locals *out) {
    struct ruby_path path;memset(out,0,sizeof *out);out->reason=ruby_path_parse(text,&path);
    if(out->reason)return;
    local_find(p,r,ec,zjit,ctx,frame,path.root,!path.count,out);
    if(out->reason || out->count!=1 || !path.count)return;
    struct xrb_local *row=&out->items[0];struct xrb_path_value value;
    ruby_path_read(p,r,ctx,row->tagged,&path,&value);
    row->address=value.address;row->tagged=value.tagged;row->reason=value.reason;
    snprintf(row->name,sizeof row->name,"%s",text);
    memset(&row->value,0,sizeof row->value);
    if(!row->reason)xrb_value_read(p,r,ctx,row->tagged,&row->value);
    /* A path refusal belongs to the row. Preserve no partial value/address. */
    if(value.reason) { row->value.reason=value.reason; r->error=NULL; }
}
