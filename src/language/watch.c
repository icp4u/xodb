#include "watch.h"
#include <stdlib.h>
#include <string.h>
#define TYPE 64
#define DISPLAY 1024
#define REASON 128
struct sample {
    uint64_t generation;
    uint32_t kind;
    unsigned char *bytes;
    size_t size;
    char type[TYPE], display[DISPLAY];
};
struct entry {
    uint64_t id, observed_generation;
    struct xlw_scope scope;
    enum xlw_state state;
    char expression[XLW_EXPRESSION+1], reason[REASON];
    int changed, has_value, has_previous;
    struct sample current, previous;
};
struct xlw_set { struct entry *items[XLW_ENTRIES]; size_t count; uint64_t serial; };
static int copy(char *out, size_t cap, const char *text) {
    if (!text) return 0;
    size_t n=0;while(n<cap && text[n]) ++n;
    if(n==cap) return 0;
    memcpy(out,text,n+1);return 1;
}
static int same_scope(const struct xlw_scope *a,const struct xlw_scope *b) {
    return a->language==b->language && a->session==b->session && a->image==b->image && a->thread==b->thread &&
        !memcmp(a->runtime,b->runtime,sizeof a->runtime) && !memcmp(a->frame,b->frame,sizeof a->frame);
}
static struct entry *find(struct xlw_set *s,uint64_t id) {
    if(s) for(size_t i=0;i<s->count;++i) if(s->items[i]->id==id) return s->items[i];
    return NULL;
}
static void destroy(struct entry *e) {
    free(e->current.bytes);free(e->previous.bytes);free(e);
}
struct xlw_set *xlw_create(void) { return calloc(1,sizeof(struct xlw_set)); }
void xlw_destroy(struct xlw_set *s) {
    if(!s)return;
    for(size_t i=0;i<s->count;++i)destroy(s->items[i]);
    free(s);
}
size_t xlw_count(const struct xlw_set *s) { return s?s->count:0; }
enum xlw_result xlw_add(struct xlw_set *s,const struct xlw_scope *scope,const char *text,uint64_t *id) {
    if(!s || !scope || !text || !*text || !id || scope->language>XLW_RUBY || scope->language<XLW_LUA ||
       !scope->session || !scope->thread || s->serial==UINT64_MAX) return XLW_INVALID;
    if(s->count==XLW_ENTRIES)return XLW_FULL;
    struct entry *e=calloc(1,sizeof *e);if(!e)return XLW_NOMEM;
    if(!copy(e->expression,sizeof e->expression,text)){free(e);return XLW_INVALID;}
    e->scope=*scope;e->id=++s->serial;e->state=XLW_PENDING;
    s->items[s->count++]=e;*id=e->id;return XLW_OK;
}
enum xlw_result xlw_remove(struct xlw_set *s,uint64_t id) {
    if(!s)return XLW_INVALID;
    for(size_t i=0;i<s->count;++i)if(s->items[i]->id==id){
        destroy(s->items[i]);--s->count;
        memmove(s->items+i,s->items+i+1,(s->count-i)*sizeof *s->items);return XLW_OK;
    }
    return XLW_NOT_FOUND;
}
enum xlw_result xlw_feed(struct xlw_set *s,uint64_t id,uint64_t generation,
                         const struct xlw_scope *scope,enum xlw_observation observation,
                         const struct xlw_sample *input,const char *reason) {
    struct entry *e=find(s,id);if(!e)return XLW_NOT_FOUND;
    if(!generation || !scope || observation<XLW_COMPLETE || observation>XLW_FRAME_GONE)return XLW_INVALID;
    if(generation<e->observed_generation)return XLW_STALE;
    if(e->state==XLW_GONE || e->state==XLW_CONTEXT_CHANGED)return XLW_OK;
    if(!same_scope(&e->scope,scope)) {
        e->state=XLW_CONTEXT_CHANGED;e->observed_generation=generation;e->changed=0;
        copy(e->reason,sizeof e->reason,"Runtime/frame location changed");return XLW_OK;
    }
    /* Repainting or another client reading this stop must not consume the
     * old/new transition. An incomplete attempt may still become ready. */
    if(e->has_value && e->current.generation==generation)return XLW_OK;
    if(observation!=XLW_COMPLETE) {
        char why[REASON]={0};
        if(!copy(why,sizeof why,reason?reason:(observation==XLW_FRAME_GONE?"Frame gone":"Comparison unavailable")))return XLW_INVALID;
        e->state=observation==XLW_FRAME_GONE?XLW_GONE:XLW_UNAVAILABLE;
        e->observed_generation=generation;e->changed=0;memcpy(e->reason,why,sizeof why);return XLW_OK;
    }
    if(!input || input->size>XLW_SAMPLE_BYTES || (input->size && !input->bytes))return XLW_INVALID;
    struct sample next={.generation=generation,.kind=input->kind,.size=input->size};
    if(!copy(next.type,sizeof next.type,input->type) || !copy(next.display,sizeof next.display,input->display))return XLW_INVALID;
    if(input->size){next.bytes=malloc(input->size);if(!next.bytes)return XLW_NOMEM;memcpy(next.bytes,input->bytes,input->size);}
    int changed=e->has_value && (e->current.kind!=next.kind || e->current.size!=next.size ||
        (next.size && memcmp(e->current.bytes,next.bytes,next.size)));
    free(e->previous.bytes);e->previous=e->current;e->has_previous=e->has_value;
    e->current=next;e->has_value=1;e->changed=changed;e->observed_generation=generation;
    e->state=XLW_VALUE;e->reason[0]=0;return XLW_OK;
}
void xlw_running(struct xlw_set *s) {
    if(!s)return;
    for(size_t i=0;i<s->count;++i){struct entry *e=s->items[i];
        if(e->state==XLW_GONE || e->state==XLW_CONTEXT_CHANGED)continue;
        e->state=XLW_RUNNING;e->changed=0;
    }
}
static struct xlw_value view(const struct sample *v) {
    return (struct xlw_value){v->generation,v->kind,v->bytes,v->size,v->type,v->display};
}
enum xlw_result xlw_get(const struct xlw_set *s,size_t ordinal,struct xlw_view *out) {
    if(!s || !out)return XLW_INVALID;
    if(ordinal>=s->count)return XLW_NOT_FOUND;
    const struct entry *e=s->items[ordinal];
    *out=(struct xlw_view){.id=e->id,.observed_generation=e->observed_generation,.scope=e->scope,
        .comparison=e->state==XLW_VALUE && e->has_previous ?
            (e->changed?XLW_SAME_SLOT_DIFFERENT:XLW_SAME_SLOT_EQUAL):XLW_NOT_COMPARED,
        .state=e->state,.expression=e->expression,.reason=e->reason,.changed=e->changed,
        .has_value=e->has_value,.has_previous=e->has_previous,.current=view(&e->current),.previous=view(&e->previous)};
    return XLW_OK;
}
