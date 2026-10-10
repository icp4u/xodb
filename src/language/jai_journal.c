#include "jai.h"
#include <stdlib.h>
#include <string.h>

struct xjai_write_journal { struct xjai_write_record *records;size_t count,capacity; };
static int range_valid(uint64_t at,size_t n) {return at && n && n<=XJAI_WRITE_BYTES && at<=UINT64_MAX-n;}
const char *xjai_write_destination(xjai_mapping_fn query,void *ctx,
    const struct xjai_write_range *protected_ranges,size_t count,uint64_t at,size_t n)
{
    if (!query || (count && !protected_ranges) || count>XJAI_WRITE_PROTECTED_RANGES || !range_valid(at,n)) return "JaiWriteDestinationInvalid";
    uint64_t end=at+n;
    for (size_t i=0;i<count;++i) {
        const struct xjai_write_range *r=&protected_ranges[i];
        if (!r->size || r->address>UINT64_MAX-r->size) return "JaiWriteMetadataRangeInvalid";
        if (at<r->address+r->size && r->address<end) return "JaiWriteMetadataProtected";
    }
    while (at<end) {
        struct xjai_write_mapping m={0};
        if (!query(ctx,at,&m)) return "JaiWriteUnmapped";
        if (m.start>at || m.end<=at) return "JaiWriteMappingInvalid";
        if (m.permissions&XJAI_WRITE_MAP_EXEC) return "JaiWriteCodeProtected";
        if (m.permissions&XJAI_WRITE_MAP_SHARED) return "JaiWriteSharedMapping";
        if ((m.permissions&(XJAI_WRITE_MAP_READ|XJAI_WRITE_MAP_WRITE))!=(XJAI_WRITE_MAP_READ|XJAI_WRITE_MAP_WRITE)) return "JaiWriteReadonly";
        at=m.end<end?m.end:end;
    }
    return NULL;
}
struct xjai_write_journal *xjai_write_journal_create(void) {return calloc(1,sizeof(struct xjai_write_journal));}
void xjai_write_journal_free(struct xjai_write_journal *j) {if (j) {free(j->records);free(j);}}
size_t xjai_write_journal_count(const struct xjai_write_journal *j) {return j?j->count:0;}
size_t xjai_write_journal_bytes(const struct xjai_write_journal *j) {return j?sizeof *j+j->capacity*sizeof *j->records:0;}
const struct xjai_write_record *xjai_write_journal_get(const struct xjai_write_journal *j,uint64_t id)
{
    return j && id && id<=j->count?&j->records[id-1]:NULL;
}
static int same_target(const struct xjai_write_stamp *a,const struct xjai_write_stamp *b)
{
    return a->session_id==b->session_id && a->target_id==b->target_id && a->image_epoch==b->image_epoch;
}
uint64_t xjai_write_journal_last(const struct xjai_write_journal *j,const struct xjai_write_stamp *s)
{
    if (!j || !s) return 0;
    for (size_t i=j->count;i>0;--i) if (!j->records[i-1].undone && same_target(&j->records[i-1].initial,s)) return j->records[i-1].id;
    return 0;
}
static const char *reserve(struct xjai_write_journal *j)
{
    if (j->count==XJAI_WRITE_RECORDS) return "JaiWriteJournalFull";
    if (j->count<j->capacity) return NULL;
    size_t cap=j->capacity?j->capacity*2:4;if (cap>XJAI_WRITE_RECORDS) cap=XJAI_WRITE_RECORDS;
    struct xjai_write_record *p=realloc(j->records,cap*sizeof *p);if (!p) return "JaiWriteOutOfMemory";
    j->records=p;j->capacity=cap;return NULL;
}
static const char *arguments(const struct xjai_write_stamp *s,const struct xjai_write_io *io,int raw)
{
    if (!s || !s->session_id || !s->target_id || !s->generation || s->actor>1 || !io || !io->read || !io->write || !io->guard || !io->generation || (raw!=0 && raw!=1)) return "JaiWriteInvalidArguments";
    return NULL;
}
static const char *preflight(const struct xjai_write_io *io,const struct xjai_write_stamp *s,struct xjai_write_change *change)
{
    if (io->generation(io->context)!=s->generation) return "JaiWriteStale";
    const char *why=io->guard(io->context,change->address,change->size);if (why) return why;
    if (!io->read(io->context,change->address,change->before,change->size)) return "JaiWriteBeforeUnreadable";
    change->before_valid=1;
    if (io->generation(io->context)!=s->generation) return "JaiWriteStale";
    return NULL;
}
static const char *before_write(const struct xjai_write_io *io,const struct xjai_write_stamp *s,struct xjai_write_change *change)
{
    const char *why=io->guard(io->context,change->address,change->size);if (why) return why;
    return io->generation(io->context)==s->generation?NULL:"JaiWriteStale";
}
static void retain(struct xjai_write_record *r,const struct xjai_write_stamp *s,const struct xjai_write_change *c)
{
    r->last=*s;r->after_generation=c->after_generation;r->last_raw=c->raw;r->last_undo=c->undo;
    ++r->attempts;r->observed_valid=c->observed_valid;
    memset(r->observed,0,sizeof r->observed);if (c->observed_valid) memcpy(r->observed,c->observed,c->size);
    r->last_reason=c->reason;r->backend_reason=c->backend_reason;
    if (c->undo && c->verified) r->undone=1;
}
static const char *perform(struct xjai_write_record *r,const struct xjai_write_stamp *s,
    const struct xjai_write_io *io,struct xjai_write_change *c)
{
    c->id=r->id;c->write_attempted=1;
    c->backend_reason=io->write(io->context,c->address,c->requested,c->size);
    const uint64_t after=io->generation(io->context);
    c->observed_valid=io->read(io->context,c->address,c->observed,c->size);
    c->after_generation=io->generation(io->context);
    if (after!=c->after_generation) {c->observed_valid=0;c->reason="JaiWriteReadbackStale";}
    else if (!c->observed_valid) c->reason="JaiWriteReadbackUnavailable";
    else {
        c->verified=!memcmp(c->requested,c->observed,c->size);
        c->reason=c->backend_reason?c->backend_reason:(c->verified?NULL:"JaiWriteReadbackMismatch");
    }
    if (!c->observed_valid) memset(c->observed,0,sizeof c->observed);
    retain(r,s,c);return c->reason;
}
const char *xjai_write_apply(struct xjai_write_journal *j,const struct xjai_write_plan *plan,
    const char *path,size_t pn,int raw,const struct xjai_write_stamp *s,
    const struct xjai_write_io *io,struct xjai_write_change *change)
{
    if (!change) return "JaiWriteInvalidArguments";
    memset(change,0,sizeof *change);const char *why=arguments(s,io,raw);
    if (why) return change->reason=why;
    if (!j || !plan || !range_valid(plan->address,plan->size) || !path || !pn || pn>XJAI_WRITE_PATH || memchr(path,0,pn)) return change->reason="JaiWriteInvalidArguments";
    if (j->count==XJAI_WRITE_RECORDS) return change->reason="JaiWriteJournalFull";
    change->address=plan->address;change->size=plan->size;change->raw=raw;change->before_generation=s->generation;
    memcpy(change->requested,plan->bytes,plan->size);
    if ((why=preflight(io,s,change))) return change->reason=why;
    if ((why=reserve(j))) return change->reason=why;
    if ((why=before_write(io,s,change))) return change->reason=why;
    struct xjai_write_record *r=&j->records[j->count];memset(r,0,sizeof *r);
    r->id=++j->count;r->initial=*s;r->plan=*plan;r->raw=raw;
    memcpy(r->path,path,pn);memcpy(r->before,change->before,plan->size);
    return perform(r,s,io,change);
}
const char *xjai_write_undo(struct xjai_write_journal *j,uint64_t id,int raw,
    const struct xjai_write_stamp *s,const struct xjai_write_io *io,struct xjai_write_change *change)
{
    if (!change) return "JaiWriteInvalidArguments";
    memset(change,0,sizeof *change);const char *why=arguments(s,io,raw);
    if (why) return change->reason=why;
    if (!j || !id || id>j->count) return change->reason="JaiWriteUnknown";
    struct xjai_write_record *r=&j->records[id-1];
    if (!same_target(&r->initial,s)) return change->reason="JaiWriteTargetChanged";
    if (r->undone) return change->reason="JaiWriteAlreadyUndone";
    change->address=r->plan.address;change->size=r->plan.size;change->raw=raw;change->undo=1;change->before_generation=s->generation;
    memcpy(change->requested,r->before,r->plan.size);
    if ((why=preflight(io,s,change))) return change->reason=why;
    if (!memcmp(change->before,r->before,r->plan.size)) {
        change->id=id;change->observed_valid=change->verified=1;change->after_generation=s->generation;
        memcpy(change->observed,change->before,change->size);retain(r,s,change);return NULL;
    }
    const unsigned char *expected=r->observed_valid?r->observed:r->plan.bytes;
    if (!raw && memcmp(change->before,expected,r->plan.size)) return change->reason=r->observed_valid?"JaiWriteUndoConflict":"JaiWriteUndoUnverified";
    if ((why=before_write(io,s,change))) return change->reason=why;
    return perform(r,s,io,change);
}
