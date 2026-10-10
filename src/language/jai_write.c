#include "jai_live_internal.h"
#include <errno.h>
#include <float.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

static int digit(unsigned char c)
{
    if (c>='0' && c<='9') return c-'0';
    if (c>='a' && c<='f') return c-'a'+10;
    if (c>='A' && c<='F') return c-'A'+10;
    return -1;
}
static uint64_t mask(unsigned n) { return n==8?UINT64_MAX:(UINT64_C(1)<<(n*8))-1; }
static void encode(unsigned char *out,uint64_t v,unsigned n)
{
    for (unsigned i=0;i<n;++i) out[i]=(unsigned char)(v>>(i*8));
}
static const char *integer(const char *s,size_t n,unsigned size,int sign,uint64_t *out)
{
    if (!n || (size!=1 && size!=2 && size!=4 && size!=8)) return "JaiWriteValueInvalid";
    size_t i=0;int negative=s[0]=='-';if (negative || s[0]=='+') ++i;
    unsigned base=10;
    if (i+2<=n && s[i]=='0' && (s[i+1]=='x' || s[i+1]=='X')) {base=16;i+=2;}
    if (i==n) return "JaiWriteValueInvalid";
    uint64_t v=0;
    for (;i<n;++i) {
        int d=digit((unsigned char)s[i]);if (d<0 || (unsigned)d>=base) return "JaiWriteValueInvalid";
        if (v>(UINT64_MAX-(unsigned)d)/base) return "JaiWriteValueOutOfRange";
        v=v*base+(unsigned)d;
    }
    uint64_t limit=sign?(negative?UINT64_C(1)<<(size*8-1):(UINT64_C(1)<<(size*8-1))-1):mask(size);
    if ((negative && !sign && v!=0) || v>limit) return "JaiWriteValueOutOfRange";
    *out=(negative?UINT64_C(0)-v:v)&mask(size);return NULL;
}
static int decimal(const char *s,size_t n)
{
    size_t i=0,digits=0;if (i<n && (s[i]=='+' || s[i]=='-')) ++i;
    while (i<n && s[i]>='0' && s[i]<='9') {++i;++digits;}
    if (i<n && s[i]=='.') {++i;while (i<n && s[i]>='0' && s[i]<='9') {++i;++digits;}}
    if (!digits) return 0;
    if (i<n && (s[i]=='e' || s[i]=='E')) {
        ++i;if (i<n && (s[i]=='+' || s[i]=='-')) ++i;
        size_t start=i;while (i<n && s[i]>='0' && s[i]<='9') ++i;if (i==start) return 0;
    }
    return i==n;
}
static const char *scalar(const struct xjai_graph *g,uint32_t index,const char *s,size_t n,unsigned char *out,unsigned *work)
{
    const struct xjai_type *t=&g->types[index];uint64_t v=0;const char *why;
    if (t->tag==2) {
        if (t->size!=1) return "JaiWriteTypeUnproved";
        if ((n==4 && !memcmp(s,"true",4)) || (n==1 && s[0]=='1')) out[0]=1;
        else if ((n==5 && !memcmp(s,"false",5)) || (n==1 && s[0]=='0')) out[0]=0;
        else return "JaiWriteValueOutOfRange";
        return NULL;
    }
    if (t->tag==0) {
        why=integer(s,n,(unsigned)t->size,t->is_signed,&v);if (why) return why;
        encode(out,v,(unsigned)t->size);return NULL;
    }
    if (t->tag==11) {
        if (t->element>=g->type_count || t->first_enum>g->enum_count || t->enum_count>g->enum_count-t->first_enum) return "JaiWriteTypeUnproved";
        const struct xjai_type *under=&g->types[t->element];
        if (under->reason || under->tag!=0 || under->size!=t->size || (t->size!=1 && t->size!=2 && t->size!=4 && t->size!=8)) return "JaiWriteTypeUnproved";
        uint64_t numeric=0;const char *numeric_error=integer(s,n,(unsigned)t->size,under->is_signed,&numeric);
        int named=0,found=0;
        for (uint32_t i=0;i<t->enum_count;++i) {
            if (++*work>4096) return "JaiWriteWorkLimit";
            const struct xjai_enum_value *e=&g->enums[t->first_enum+i];const char *name=g->text+e->name;
            uint64_t width=mask((unsigned)t->size),bits=e->bits&width;
            uint64_t canonical=under->is_signed && (bits&(UINT64_C(1)<<(t->size*8-1)))?bits|~width:bits;
            if (!numeric_error && e->bits==canonical && bits==numeric) found=1;
            if (!strncmp(name,s,n) && name[n]==0) {
                if (e->bits!=canonical) return "JaiWriteEnumValueOutOfRange";
                if (named && bits!=v) return "JaiWriteEnumAmbiguous";
                v=bits;named=1;
            }
        }
        if (!named) {
            if (numeric_error) return numeric_error;
            if (!found) return "JaiWriteEnumValueUnknown";
            v=numeric;
        }
        encode(out,v,(unsigned)t->size);return NULL;
    }
    if (t->tag==1) {
#if FLT_RADIX != 2 || FLT_MANT_DIG != 24 || FLT_MAX_EXP != 128 || DBL_MANT_DIG != 53 || DBL_MAX_EXP != 1024
        return "JaiWriteFloatFormatUnproved";
#else
        if ((t->size!=4 && t->size!=8) || sizeof(float)!=4 || sizeof(double)!=8) return "JaiWriteFloatFormatUnproved";
        if (!decimal(s,n)) return "JaiWriteValueInvalid";
        char input[XJAI_WRITE_VALUE+1];memcpy(input,s,n);input[n]=0;char *end=NULL;errno=0;
        double d=strtod(input,&end);if (end!=input+n) return "JaiWriteValueInvalid";
        if (errno==ERANGE || !isfinite(d)) return "JaiWriteValueOutOfRange";
        if (t->size==8) memcpy(&v,&d,8);
        else {
            if (d>FLT_MAX || d< -FLT_MAX) return "JaiWriteValueOutOfRange";
            float f=(float)d;if (d!=0 && f==0) return "JaiWriteValueOutOfRange";
            uint32_t bits;memcpy(&bits,&f,4);v=bits;
        }
        encode(out,v,(unsigned)t->size);return NULL;
#endif
    }
    return t->tag==3 || t->tag==4 || t->tag==8 || t->tag==13?"JaiWriteNeedsRaw":"JaiWriteTypeUnsupported";
}
static const char *checked_type(const struct xjai_graph *g,uint32_t index,uint64_t at)
{
    if (index>=g->type_count || g->types[index].reason || !g->types[index].size) return "JaiWriteTypeUnproved";
    if (!at || at>UINT64_MAX-g->types[index].size) return "JaiWriteAddressInvalid";
    return NULL;
}
const char *xjai_write_plan(const struct xjai_graph *g,uint32_t index,uint64_t at,
    const char *path,size_t pn,const char *value,size_t vn,int raw,
    struct xjai_live_reader *reader,struct xjai_write_plan *out)
{
    if (!out) return "JaiWriteInvalidArguments";
    memset(out,0,sizeof *out);
    if (!g || !path || !value || !pn || pn>XJAI_WRITE_PATH || !vn || vn>XJAI_WRITE_VALUE ||
        (raw!=0 && raw!=1) || memchr(path,0,pn) || memchr(value,0,vn)) return "JaiWriteInvalidArguments";
    if (g->layout.profile!=XJAI_PROFILE) return "JaiWriteTypeUnproved";
    size_t p=0;unsigned depth=0,work=0;const char *why;
    while (p<pn) {
        if (++depth>16) return "JaiWritePathDepth";
        if ((why=checked_type(g,index,at))) return why;
        const struct xjai_type *t=&g->types[index];
        if (path[p]=='[') {
            size_t begin=++p;uint64_t i=0;
            while (p<pn && path[p]>='0' && path[p]<='9') {
                unsigned d=(unsigned)(path[p++]-'0');if (i>(UINT64_MAX-d)/10) return "JaiWriteIndexOutOfRange";i=i*10+d;
            }
            if (p==begin || p==pn || path[p++]!=']') return "JaiWritePathInvalid";
            if (t->tag!=8) return "JaiWriteExpectedArray";
            struct xjai_array_span span;
            if ((why=xjai_array_span(g,index,at,reader,&span))) return why;
            if (i>=span.count || span.element>=g->type_count) return "JaiWriteIndexOutOfRange";
            uint64_t size=g->types[span.element].size;
            if (!size || i>UINT64_MAX/size || span.data>UINT64_MAX-i*size) return "JaiWriteAddressInvalid";
            at=span.data+i*size;index=span.element;
        } else {
            if (t->tag!=7 || t->first_member>g->member_count || t->member_count>g->member_count-t->first_member) return "JaiWriteExpectedStruct";
            size_t begin=p;while (p<pn && path[p]!='.' && path[p]!='[') {
                if ((unsigned char)path[p]<=32 || path[p]==']') return "JaiWritePathInvalid";
                ++p;
            }
            if (begin==p) return "JaiWritePathInvalid";
            uint32_t member=XJAI_NONE;
            for (uint32_t i=0;i<t->member_count;++i) {
                if (++work>4096) return "JaiWriteWorkLimit";
                const struct xjai_member *m=&g->members[t->first_member+i];const char *name=g->text+m->name;
                if (!strncmp(name,path+begin,p-begin) && name[p-begin]==0) {
                    if (member!=XJAI_NONE) return "JaiWriteFieldAmbiguous";
                    member=t->first_member+i;
                }
            }
            if (member==XJAI_NONE) return "JaiWriteFieldNotFound";
            const struct xjai_member *m=&g->members[member];
            if (m->flags&(g->layout.flags[XJAI_F_CONSTANT]|g->layout.flags[XJAI_F_IMPORTED])) return "JaiWriteConstant";
            if (m->reason || m->type>=g->type_count || m->offset>t->size || g->types[m->type].size>t->size-m->offset) return "JaiWriteTypeUnproved";
            at+=m->offset;index=m->type;
        }
        if (p<pn && path[p]=='.') {if (++p==pn || path[p]=='[') return "JaiWritePathInvalid";}
        else if (p<pn && path[p]!='[') return "JaiWritePathInvalid";
    }
    if ((why=checked_type(g,index,at))) return why;
    const struct xjai_type *t=&g->types[index];if (t->size>XJAI_WRITE_BYTES) return "JaiWriteSizeLimit";
    struct xjai_write_plan plan={.address=at,.type_address=t->address,.type=index,.size=(uint32_t)t->size};
    if (raw) {
        if (vn!=t->size*2) return "JaiWriteRawSizeMismatch";
        for (unsigned i=0;i<t->size;++i) {
            int hi=digit((unsigned char)value[i*2]),lo=digit((unsigned char)value[i*2+1]);
            if (hi<0 || lo<0) return "JaiWriteValueInvalid";
            plan.bytes[i]=(unsigned char)((unsigned)hi*16+(unsigned)lo);
        }
    } else if ((why=scalar(g,index,value,vn,plan.bytes,&work))) return why;
    *out=plan;return NULL;
}
