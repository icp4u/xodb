/* Fast lane: owned byte storage, injected partial IO and exact rollback oracles. */
#define _POSIX_C_SOURCE 200809L
#include "../src/language/jai.h"
#include "check.h"
#include <string.h>
#include <time.h>
#include <unistd.h>

enum mode { FULL,PARTIAL_ERROR,REFUSE,LIE,UNREADABLE_FULL,UNREADABLE_PART,STALE_AFTER,ERROR_FULL };
struct target {
    unsigned char bytes[128];uint64_t generation;
    unsigned reads,writes,guards,queries,permissions;
    enum mode mode;
    int before_unreadable,stale_before,guard_second,denied,bad_map,missing_map;
    struct xjai_write_range protected_range;size_t protected_count;
};
static int covered(struct target *t,uint64_t at,size_t n)
{
    uint64_t base=(uintptr_t)t->bytes;return at>=base && n<=sizeof t->bytes && at-base<=sizeof t->bytes-n;
}
static int query(void *ctx,uint64_t at,struct xjai_write_mapping *out)
{
    struct target *t=ctx;++t->queries;if (!covered(t,at,1)) return 0;
    uint64_t base=(uintptr_t)t->bytes,offset=at-base;
    if (t->missing_map && offset>=4) return 0;
    *out=(struct xjai_write_mapping){base+(offset/4)*4,base+(offset/4)*4+4,t->permissions};
    if (t->bad_map) out->end=at;
    return 1;
}
static const char *guard(void *ctx,uint64_t at,size_t n)
{
    struct target *t=ctx;++t->guards;
    if (t->denied) return "AgentScopeDenied";
    if (t->guard_second && t->guards==2) return "InjectedGuardChanged";
    return xjai_write_destination(query,t,&t->protected_range,t->protected_count,at,n);
}
static int read_bytes(void *ctx,uint64_t at,void *out,size_t n)
{
    struct target *t=ctx;++t->reads;
    if (!covered(t,at,n) || (!t->writes && t->before_unreadable) ||
        (t->writes && (t->mode==UNREADABLE_FULL || t->mode==UNREADABLE_PART))) return 0;
    memcpy(out,t->bytes+(at-(uintptr_t)t->bytes),n);
    if ((!t->writes && t->stale_before) || (t->writes && t->mode==STALE_AFTER)) ++t->generation;
    return 1;
}
static const char *write_bytes(void *ctx,uint64_t at,const void *bytes,size_t n)
{
    struct target *t=ctx;++t->writes;CHECK(covered(t,at,n));
    if (t->mode==REFUSE) return "InjectedWriteFailure";
    size_t count=t->mode==PARTIAL_ERROR || t->mode==LIE || t->mode==UNREADABLE_PART?n/2:n;
    memcpy(t->bytes+(at-(uintptr_t)t->bytes),bytes,count);++t->generation;
    return t->mode==ERROR_FULL?"InjectedFullWriteError":t->mode==PARTIAL_ERROR || t->mode==UNREADABLE_PART?"InjectedPartialWrite":NULL;
}
static uint64_t generation(void *ctx) {return ((struct target *)ctx)->generation;}
static struct xjai_write_stamp stamp(struct target *t)
{
    return (struct xjai_write_stamp){.session_id=1,.target_id=2,.image_epoch=3,.generation=t->generation,.client_id=7,.actor=1};
}
static struct xjai_write_io io_for(struct target *t)
{
    return (struct xjai_write_io){t,read_bytes,write_bytes,guard,generation};
}
static void clean_mode(struct target *t)
{
    t->mode=FULL;t->reads=t->writes=t->guards=t->queries=0;
    t->permissions=XJAI_WRITE_MAP_READ|XJAI_WRITE_MAP_WRITE;
    t->before_unreadable=t->stale_before=t->guard_second=t->denied=t->bad_map=t->missing_map=0;
    t->protected_count=0;
}
static void why(const char *actual,const char *expected)
{
    if (!actual || strcmp(actual,expected)) fprintf(stderr,"expected %s got %s\n",expected,actual?actual:"success");
    CHECK(actual && !strcmp(actual,expected));
}
static unsigned long rss(void)
{
    FILE *f=fopen("/proc/self/statm","r");unsigned long total,resident;CHECK(f && fscanf(f,"%lu %lu",&total,&resident)==2);CHECK(!fclose(f));return resident*(unsigned long)sysconf(_SC_PAGESIZE);
}
int xjai_journal_fixture_main(int argc,char **argv)
{
    struct target t={.generation=100};memset(t.bytes,0x5a,sizeof t.bytes);clean_mode(&t);
    int64_t initial=41,desired=77;memcpy(t.bytes,&initial,8);unsigned char original[128];memcpy(original,t.bytes,sizeof original);
    struct xjai_write_plan p={.address=(uintptr_t)t.bytes,.type_address=0x1234,.type=5,.size=8};memcpy(p.bytes,&desired,8);
    struct xjai_write_journal *j=xjai_write_journal_create();CHECK(j && !xjai_write_journal_count(j));
    const size_t empty_bytes=xjai_write_journal_bytes(j);unsigned long before_rss=rss();struct timespec start,end;CHECK(!clock_gettime(CLOCK_PROCESS_CPUTIME_ID,&start));
    struct xjai_write_io io=io_for(&t);struct xjai_write_stamp s=stamp(&t);struct xjai_write_change c;
    CHECK(!xjai_write_apply(j,&p,"health",6,0,&s,&io,&c));
    desired=argc>1 && !strcmp(argv[1],"--wrong-oracle")?78:77;CHECK(!memcmp(t.bytes,&desired,8));
    CHECK(c.id==1 && c.verified && c.write_attempted && c.before_valid && c.observed_valid && c.before_generation==100 && c.after_generation==101);
    CHECK(!memcmp(c.before,&initial,8) && !memcmp(c.requested,&desired,8) && !memcmp(c.observed,&desired,8));
    const struct xjai_write_record *r=xjai_write_journal_get(j,1);CHECK(r && !strcmp(r->path,"health") && r->initial.client_id==7 && r->attempts==1 && !r->undone);
    size_t first_bytes=xjai_write_journal_bytes(j);CHECK(first_bytes>empty_bytes && first_bytes<empty_bytes+XJAI_WRITE_RECORDS*sizeof *r);
    desired=88;memcpy(p.bytes,&desired,8);clean_mode(&t);s=stamp(&t);CHECK(!xjai_write_apply(j,&p,"health",6,0,&s,&io,&c) && c.id==2);
    clean_mode(&t);s=stamp(&t);why(xjai_write_undo(j,1,0,&s,&io,&c),"JaiWriteUndoConflict");CHECK(!t.writes && !c.id && !xjai_write_journal_get(j,1)->undone);
    clean_mode(&t);s=stamp(&t);s.actor=0;s.client_id=0;CHECK(!xjai_write_undo(j,2,0,&s,&io,&c) && c.verified && c.undo);CHECK(xjai_write_journal_get(j,2)->last.actor==0);
    s=stamp(&t);CHECK(xjai_write_journal_last(j,&s)==1);clean_mode(&t);CHECK(!xjai_write_undo(j,1,0,&s,&io,&c));CHECK(!memcmp(t.bytes,original,sizeof original));s=stamp(&t);CHECK(!xjai_write_journal_last(j,&s));
    why(xjai_write_undo(j,1,0,&s,&io,&c),"JaiWriteAlreadyUndone");
    /* Every preflight refusal leaves bytes, write count and record count alone. */
#define REJECT(setup,reason) do {clean_mode(&t);setup;s=stamp(&t);why(xjai_write_apply(j,&p,"health",6,1,&s,&io,&c),reason);CHECK(!c.id && !t.writes && xjai_write_journal_count(j)==2 && !memcmp(t.bytes,original,sizeof original));} while (0)
    REJECT(t.denied=1,"AgentScopeDenied");REJECT(t.permissions=XJAI_WRITE_MAP_READ,"JaiWriteReadonly");
    REJECT(t.permissions|=XJAI_WRITE_MAP_EXEC,"JaiWriteCodeProtected");REJECT(t.permissions|=XJAI_WRITE_MAP_SHARED,"JaiWriteSharedMapping");REJECT(t.bad_map=1,"JaiWriteMappingInvalid");REJECT(t.missing_map=1,"JaiWriteUnmapped");
    REJECT((t.protected_count=1,t.protected_range=(struct xjai_write_range){p.address+7,1}),"JaiWriteMetadataProtected");
    REJECT((t.protected_count=1,t.protected_range=(struct xjai_write_range){UINT64_MAX,8}),"JaiWriteMetadataRangeInvalid");
    REJECT(t.before_unreadable=1,"JaiWriteBeforeUnreadable");REJECT(t.stale_before=1,"JaiWriteStale");REJECT(t.guard_second=1,"InjectedGuardChanged");
#undef REJECT
    clean_mode(&t);s=stamp(&t);--s.generation;why(xjai_write_apply(j,&p,"health",6,0,&s,&io,&c),"JaiWriteStale");CHECK(!t.reads && !t.writes);
    /* Partial effects stay in the journal, and a checked retry can restore them. */
    desired=INT64_C(0x1122334455667788);memcpy(p.bytes,&desired,8);
    for (unsigned mode=PARTIAL_ERROR;mode<=STALE_AFTER;++mode) {
        clean_mode(&t);t.mode=(enum mode)mode;s=stamp(&t);
        const char *want=mode==PARTIAL_ERROR?"InjectedPartialWrite":mode==REFUSE?"InjectedWriteFailure":mode==LIE?"JaiWriteReadbackMismatch":mode==STALE_AFTER?"JaiWriteReadbackStale":"JaiWriteReadbackUnavailable";
        why(xjai_write_apply(j,&p,"health",6,0,&s,&io,&c),want);CHECK(c.id && c.write_attempted && !c.verified);
        uint64_t id=c.id;r=xjai_write_journal_get(j,id);CHECK(!memcmp(r->before,&initial,8) && !memcmp(r->plan.bytes,&desired,8));
        if (mode==PARTIAL_ERROR || mode==LIE || mode==REFUSE) CHECK(r->observed_valid);
        else CHECK(!r->observed_valid);
        clean_mode(&t);s=stamp(&t);
        if (mode==UNREADABLE_PART) {
            why(xjai_write_undo(j,id,0,&s,&io,&c),"JaiWriteUndoUnverified");CHECK(!t.writes);
            clean_mode(&t);CHECK(!xjai_write_undo(j,id,1,&s,&io,&c) && c.raw);
        } else CHECK(!xjai_write_undo(j,id,0,&s,&io,&c));
        CHECK(c.verified && xjai_write_journal_get(j,id)->undone && !memcmp(t.bytes,original,sizeof original));
    }
    clean_mode(&t);t.mode=ERROR_FULL;s=stamp(&t);
    why(xjai_write_apply(j,&p,"health",6,0,&s,&io,&c),"InjectedFullWriteError");
    CHECK(c.verified && c.observed_valid && c.backend_reason && c.id);
    clean_mode(&t);s=stamp(&t);CHECK(!xjai_write_undo(j,c.id,0,&s,&io,&c));
    CHECK(!memcmp(t.bytes,original,sizeof original));
    /* Partial undo preserves its original before bytes and can be retried. */
    clean_mode(&t);s=stamp(&t);CHECK(!xjai_write_apply(j,&p,"health",6,0,&s,&io,&c));uint64_t id=c.id;
    clean_mode(&t);t.mode=LIE;s=stamp(&t);why(xjai_write_undo(j,id,0,&s,&io,&c),"JaiWriteReadbackMismatch");CHECK(!xjai_write_journal_get(j,id)->undone);
    clean_mode(&t);s=stamp(&t);CHECK(!xjai_write_undo(j,id,0,&s,&io,&c));CHECK(!memcmp(t.bytes,original,sizeof original));
    /* Raw recovery cannot override a new target/image or protected destination. */
    clean_mode(&t);s=stamp(&t);CHECK(!xjai_write_apply(j,&p,"health",6,1,&s,&io,&c));id=c.id;
    clean_mode(&t);s=stamp(&t);++s.session_id;why(xjai_write_undo(j,id,1,&s,&io,&c),"JaiWriteTargetChanged");
    s=stamp(&t);++s.target_id;why(xjai_write_undo(j,id,1,&s,&io,&c),"JaiWriteTargetChanged");s=stamp(&t);++s.image_epoch;why(xjai_write_undo(j,id,1,&s,&io,&c),"JaiWriteTargetChanged");CHECK(!t.writes);
    clean_mode(&t);s=stamp(&t);t.permissions|=XJAI_WRITE_MAP_EXEC;why(xjai_write_undo(j,id,1,&s,&io,&c),"JaiWriteCodeProtected");CHECK(!t.writes);
    clean_mode(&t);t.protected_count=1;t.protected_range=(struct xjai_write_range){p.address+7,1};
    why(xjai_write_undo(j,id,1,&s,&io,&c),"JaiWriteMetadataProtected");CHECK(!t.writes);
    clean_mode(&t);t.denied=1;why(xjai_write_undo(j,id,1,&s,&io,&c),"AgentScopeDenied");CHECK(!t.writes);
    clean_mode(&t);t.bytes[0]^=1;s=stamp(&t);why(xjai_write_undo(j,id,0,&s,&io,&c),"JaiWriteUndoConflict");CHECK(!t.writes);
    clean_mode(&t);CHECK(!xjai_write_undo(j,id,1,&s,&io,&c));CHECK(c.before[0]!=(unsigned char)desired && c.verified && !memcmp(t.bytes,original,sizeof original));
    xjai_write_journal_free(j);j=xjai_write_journal_create();CHECK(j);clean_mode(&t);p.size=1;
    for (unsigned i=0;i<XJAI_WRITE_RECORDS;++i) {p.bytes[0]=(unsigned char)i;s=stamp(&t);CHECK(!xjai_write_apply(j,&p,"byte",4,0,&s,&io,&c) && c.id==i+1);}
    size_t peak=xjai_write_journal_bytes(j);unsigned long after_rss=rss();s=stamp(&t);unsigned calls=t.writes;
    why(xjai_write_apply(j,&p,"byte",4,0,&s,&io,&c),"JaiWriteJournalFull");CHECK(!c.id && t.writes==calls && xjai_write_journal_count(j)==XJAI_WRITE_RECORDS);
    for (unsigned i=XJAI_WRITE_RECORDS;i>0;--i) {clean_mode(&t);s=stamp(&t);CHECK(!xjai_write_undo(j,i,0,&s,&io,&c));}
    CHECK(!memcmp(t.bytes,original,sizeof original) && !xjai_write_journal_last(j,&s));
    /* Failed new-target preflight preserves history. A valid new incarnation
       releases the full old journal; no old ID is ever reused for new bytes. */
    clean_mode(&t);s=stamp(&t);++s.target_id;t.denied=1;
    why(xjai_write_apply(j,&p,"byte",4,0,&s,&io,&c),"AgentScopeDenied");
    CHECK(xjai_write_journal_count(j)==XJAI_WRITE_RECORDS && xjai_write_journal_get(j,1));
    clean_mode(&t);CHECK(!xjai_write_apply(j,&p,"byte",4,0,&s,&io,&c));
    id=c.id;CHECK(id==XJAI_WRITE_RECORDS+1 && xjai_write_journal_count(j)==1);
    CHECK(!xjai_write_journal_get(j,1) && !xjai_write_journal_get(j,XJAI_WRITE_RECORDS));
    CHECK(xjai_write_journal_get(j,id)->id==id && xjai_write_journal_last(j,&s)==id);
    CHECK(xjai_write_journal_at(j,0)->id==id && !xjai_write_journal_at(j,1));
    CHECK(!xjai_write_journal_at(NULL,0) && !xjai_write_journal_at(j,SIZE_MAX));
    size_t recycled=xjai_write_journal_bytes(j);CHECK(recycled==first_bytes && recycled<peak);
    unsigned long recycled_rss=rss();
    s.generation=t.generation;why(xjai_write_undo(j,1,1,&s,&io,&c),"JaiWriteUnknown");
    CHECK(!xjai_write_undo(j,id,0,&s,&io,&c) && !memcmp(t.bytes,original,sizeof original));
    s.generation=t.generation;++s.image_epoch;CHECK(!xjai_write_apply(j,&p,"byte",4,0,&s,&io,&c));
    CHECK(c.id==id+1 && xjai_write_journal_count(j)==1 && !xjai_write_journal_get(j,id));id=c.id;
    s.generation=t.generation;++s.session_id;CHECK(!xjai_write_apply(j,&p,"byte",4,0,&s,&io,&c));
    CHECK(c.id==id+1 && xjai_write_journal_count(j)==1 && !xjai_write_journal_get(j,id));
    CHECK(!clock_gettime(CLOCK_PROCESS_CPUTIME_ID,&end));
    printf("{\"cpu_ns\":%llu,\"rss_before\":%lu,\"rss_at_capacity\":%lu,\"rss_recycled\":%lu,\"empty_bytes\":%zu,\"first_write_bytes\":%zu,\"capacity_bytes\":%zu,\"recycled_bytes\":%zu,\"records\":%u}\n",(unsigned long long)((end.tv_sec-start.tv_sec)*1000000000LL+end.tv_nsec-start.tv_nsec),before_rss,after_rss,recycled_rss,empty_bytes,first_bytes,peak,recycled,XJAI_WRITE_RECORDS);
    xjai_write_journal_free(j);puts("Jai journal: guarded writes/readback, retained partial effects, identity/conflicts, raw recovery and full-capacity undo PASS");return 0;
}
#ifndef JAI_JOURNAL_NO_MAIN
int main(int argc,char **argv) {return xjai_journal_fixture_main(argc,argv);}
#endif
