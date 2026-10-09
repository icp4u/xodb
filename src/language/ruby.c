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
static void decode(const struct xrb_layout *p, struct xrb_reader *r, uint64_t v, struct xrb_value *out, unsigned depth) {
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
        strcpy(out->type,"Symbol");fail(r,"RubySymbolPreviewUnsupported");
    } else {
        unsigned t=(unsigned)(flags(r,v)&RUBY_T_MASK);
        if (r->error) goto done;
        if (t==RUBY_T_STRING) {
            char text[480];
            strcpy(out->type,"String");
            if (string(p,r,v,text,sizeof text,&out->count,&out->truncated))
                snprintf(out->display,sizeof out->display,"\"%s\"%s",text,out->truncated?"...":"");
        } else if (t==RUBY_T_FLOAT) {
            uint64_t bits=field(p,r,v,XRB_FLOAT_VALUE); double d;memcpy(&d,&bits,8);
            strcpy(out->type,"Float");snprintf(out->display,sizeof out->display,"%.17g",d);
        } else if (t==RUBY_T_ARRAY) {
            uint64_t data,n;strcpy(out->type,"Array");
            if (!array(p,r,v,&data,&n)) goto done;
            out->count=n;out->truncated=n>(depth?0:XRB_PREVIEW_ITEMS);
            snprintf(out->display,sizeof out->display,"Array(%"PRIu64")",n);
            if (!depth) for (size_t i=0;i<n && i<XRB_PREVIEW_ITEMS;++i) {
                uint64_t tagged=word(r,add(r,data,i*8),8);struct xrb_value child;
                decode(p,r,tagged,&child,depth+1);
                struct xrb_item *item=&out->items[out->item_count++];item->tagged=tagged;
                snprintf(item->type,sizeof item->type,"%s",child.type);
                snprintf(item->display,sizeof item->display,"%.255s",child.display);item->reason=child.reason;
                if (r->error && !strcmp(r->error,"RubyReadBudget")) break;
                r->error=NULL;
            }
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
void xrb_value_read(const struct xrb_layout *p, struct xrb_reader *r, uint64_t v, struct xrb_value *out) {
    decode(p,r,v,out,0);
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
static int name(const struct xrb_layout *p, struct xrb_reader *r, uint64_t symbols, uint64_t id, char *out, size_t cap) {
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
    uint64_t length;int truncated;
    if (!string(p,r,field(p,r,entry,XRB_ID_NAME),out,cap,&length,&truncated)) return 0;
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
void xrb_locals_read(const struct xrb_layout *p, struct xrb_reader *r, uint64_t ec,
                     uint64_t zjit, uint64_t symbols, size_t frame,
                     size_t start, size_t limit, struct xrb_locals *out) {
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
            if (!row->hidden) name(p,r,symbols,id,row->name,sizeof row->name);
            row->reason=r->error;r->error=NULL;
            row->address=add(r,slots,i*8);row->tagged=word(r,row->address,8);
            xrb_value_read(p,r,row->tagged,&row->value);
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
void xrb_local_find(const struct xrb_layout *p, struct xrb_reader *r, uint64_t ec,
                    uint64_t zjit, uint64_t symbols, size_t frame,
                    const char *expression, struct xrb_locals *out) {
    memset(out,0,sizeof *out);
    size_t length=0;
    if (!expression || !*expression) { out->reason="RubyExpressionUnsupported";return; }
    for (const unsigned char *s=(const unsigned char *)expression;*s;++s,++length) {
        if (length>=128 || !((*s>='a'&&*s<='z') || (*s>='A'&&*s<='Z') || *s=='_' || (length && *s>='0'&&*s<='9'))) {
            out->reason="RubyExpressionUnsupported";return;
        }
    }
    for (size_t start=0;start<4096;start+=XRB_LOCAL_ITEMS) {
        struct xrb_locals page;xrb_locals_read(p,r,ec,zjit,symbols,frame,start,XRB_LOCAL_ITEMS,&page);
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
        struct xrb_value preview;xrb_value_read(p,r,v,&preview);
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
