#include "../src/language/watch.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
static struct xlw_view get(struct xlw_set *s,size_t i) {
    struct xlw_view v;assert(xlw_get(s,i,&v)==XLW_OK);return v;
}
int main(void) {
    struct xlw_set *s=xlw_create();assert(s && !xlw_count(s));
    struct xlw_scope scope={.language=XLW_LUA,.session=1,.thread=7,.runtime={11},.frame={13,17}};
    uint64_t id;assert(xlw_add(s,&scope,"value",&id)==XLW_OK);assert(get(s,0).state==XLW_PENDING);
    unsigned char bytes[600];memset(bytes,'a',sizeof bytes);
    struct xlw_sample sample={.kind=1,.bytes=bytes,.size=sizeof bytes,.type="string",.display="aaaa..."};
    assert(xlw_feed(s,id,10,&scope,XLW_COMPLETE,&sample,NULL)==XLW_OK);
    assert(get(s,0).has_value && !get(s,0).changed && !get(s,0).has_previous);
    assert(get(s,0).comparison==XLW_NOT_COMPARED);
    assert(xlw_feed(s,id,11,&scope,XLW_COMPLETE,&sample,NULL)==XLW_OK);
    struct xlw_view v=get(s,0);assert(!v.changed && v.previous.generation==10 && v.current.generation==11);
    assert(v.comparison==XLW_SAME_SLOT_EQUAL);
    /* A difference outside the displayed prefix still changes the value. */
    bytes[599]='b';assert(xlw_feed(s,id,12,&scope,XLW_COMPLETE,&sample,NULL)==XLW_OK);
    v=get(s,0);assert(v.changed && !strcmp(v.previous.display,v.current.display));
    assert(v.comparison==XLW_SAME_SLOT_DIFFERENT);
    assert(((const unsigned char *)v.previous.bytes)[599]=='a' && ((const unsigned char *)v.current.bytes)[599]=='b');
    assert(xlw_feed(s,id,12,&scope,XLW_COMPLETE,&sample,NULL)==XLW_OK);assert(get(s,0).changed);
    assert(xlw_feed(s,id,11,&scope,XLW_COMPLETE,&sample,NULL)==XLW_STALE);assert(get(s,0).current.generation==12);
    xlw_running(s);v=get(s,0);assert(v.state==XLW_RUNNING && v.has_value && !v.changed);
    assert(v.comparison==XLW_NOT_COMPARED);
    assert(xlw_feed(s,id,13,&scope,XLW_INCOMPLETE,NULL,"String truncated; comparison unavailable")==XLW_OK);
    v=get(s,0);assert(v.state==XLW_UNAVAILABLE && v.current.generation==12 && !v.changed);
    /* A pending/incomplete attempt can recover at the same stopped generation. */
    bytes[599]='c';assert(xlw_feed(s,id,13,&scope,XLW_COMPLETE,&sample,NULL)==XLW_OK);
    v=get(s,0);assert(v.changed && v.previous.generation==12 && v.current.generation==13);
    /* Missing entire stops is visible in the baseline's generation. */
    assert(xlw_feed(s,id,14,&scope,XLW_INCOMPLETE,NULL,"Memory unreadable")==XLW_OK);
    assert(xlw_feed(s,id,15,&scope,XLW_COMPLETE,&sample,NULL)==XLW_OK);
    v=get(s,0);assert(!v.changed && v.previous.generation==13 && v.current.generation==15);
    sample.kind=2;assert(xlw_feed(s,id,16,&scope,XLW_COMPLETE,&sample,NULL)==XLW_OK);assert(get(s,0).changed);
    sample.size=XLW_SAMPLE_BYTES+1;
    assert(xlw_feed(s,id,17,&scope,XLW_COMPLETE,&sample,NULL)==XLW_INVALID);assert(get(s,0).current.generation==16);
    sample.size=sizeof bytes;
    assert(xlw_feed(s,id,17,&scope,XLW_FRAME_GONE,NULL,NULL)==XLW_OK);assert(get(s,0).state==XLW_GONE);
    assert(xlw_feed(s,id,18,&scope,XLW_COMPLETE,&sample,NULL)==XLW_OK);assert(get(s,0).state==XLW_GONE);
    assert(get(s,0).comparison==XLW_NOT_COMPARED);
    assert(xlw_remove(s,id)==XLW_OK);assert(!xlw_count(s));
    assert(xlw_feed(s,id,19,&scope,XLW_COMPLETE,&sample,NULL)==XLW_NOT_FOUND);
    uint64_t next;assert(xlw_add(s,&scope,"value",&next)==XLW_OK && next!=id);
    assert(xlw_feed(s,next,20,&scope,XLW_COMPLETE,&sample,NULL)==XLW_OK);
    struct xlw_scope replaced=scope;replaced.thread++;
    assert(xlw_feed(s,next,21,&replaced,XLW_COMPLETE,&sample,NULL)==XLW_OK);assert(get(s,0).state==XLW_CONTEXT_CHANGED);
    assert(xlw_feed(s,next,22,&scope,XLW_COMPLETE,&sample,NULL)==XLW_OK);assert(get(s,0).state==XLW_CONTEXT_CHANGED);
    for(unsigned i=1;i<XLW_ENTRIES;++i)assert(xlw_add(s,&scope,"value",&id)==XLW_OK);
    assert(xlw_add(s,&scope,"overflow",&id)==XLW_FULL);
    assert(xlw_remove(s,next)==XLW_OK && xlw_count(s)==XLW_ENTRIES-1);
    assert(xlw_add(s,&scope,"replacement",&id)==XLW_OK && id>next);
    xlw_destroy(s);
    puts("Language watch core: complete bytes beyond preview, typed values, same-stop idempotence, stale generations, incomplete/recovery, old baseline, running, gone/reuse, identity replacement and bounded capacity pass");
}
