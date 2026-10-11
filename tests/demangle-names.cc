/* Fast component lane: bounded presentation of untrusted symbol bytes. */
#include "../src/debug/demangle.h"
#include "check.h"
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static void check(const char *input,const char *expected) {
    char out[XODB_DEMANGLE_OUTPUT];
    CHECK(xodb_demangle_name(input,strlen(input),out,sizeof out));
    CHECK(!strcmp(out,expected));
}
int main(void) {
    check("_ZN3Foo3BarEv","Foo::Bar()");
    check("_Z1fIiEvi","f<>()");
    check("_ZN4demo6Engine3runEi","demo::Engine::run()");
    check("_ZN3FooC1Ev","Foo::Foo()");
    check("_ZN3FooD1Ev","Foo::~Foo()");
    check("_Z3foov.clone.1","foo()");
    check("_Z3foov@@VERS","foo()@@VERS");
    struct { unsigned char before;char out[XODB_DEMANGLE_OUTPUT];unsigned char after; } guarded;
    memset(&guarded,0xa5,sizeof guarded);
    const char no_nul[]={'_','Z','1','f','v'};
    CHECK(xodb_demangle_name(no_nul,sizeof no_nul,guarded.out,sizeof guarded.out));
    CHECK(!strcmp(guarded.out,"f()"));
    CHECK(!xodb_demangle_name("_Z1fv\0junk",10,guarded.out,sizeof guarded.out));
    CHECK(!guarded.out[0]);
    CHECK(!xodb_demangle_name("_Z1fv",5,guarded.out,2));
    CHECK(!guarded.out[0]);
    CHECK(guarded.before==0xa5 && guarded.after==0xa5);
    char deep[XODB_DEMANGLE_INPUT+1];
    memcpy(deep,"_Z1f",4);memset(deep+4,'P',sizeof deep-5);deep[sizeof deep-2]='i';deep[sizeof deep-1]=0;
    CHECK(!xodb_demangle_name(deep,sizeof deep,guarded.out,sizeof guarded.out));
    CHECK(!xodb_demangle_name(deep,sizeof deep-1,guarded.out,sizeof guarded.out));
    CHECK(!guarded.out[0]);
    uint32_t random=0x9375ace1;
    const char *alphabet="_ZNESTPIJ0123456789abcdefgrv";
    char input[256];
    for(unsigned sample=0;sample<20000;sample++) {
        random=random*1664525u+1013904223u;size_t n=random%sizeof input;
        for(size_t i=0;i<n;i++){random=random*1664525u+1013904223u;input[i]=alphabet[random%strlen(alphabet)];}
        if(n>2){input[0]='_';input[1]='Z';}
        memset(guarded.out,0xa5,sizeof guarded.out);
        int ok=xodb_demangle_name(input,n,guarded.out,sizeof guarded.out);
        CHECK(guarded.before==0xa5 && guarded.after==0xa5);
        CHECK(ok ? memchr(guarded.out,0,sizeof guarded.out)!=NULL : guarded.out[0]==0);
    }
    puts("compact C++ names: exact names, bounded buffers, depth/input refusal, 20000 deterministic malformed inputs passed");
    return 0;
}
