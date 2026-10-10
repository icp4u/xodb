typedef unsigned long DWORD;
typedef unsigned long long U64;
__declspec(dllimport) unsigned short RtlCaptureStackBackTrace(DWORD,DWORD,void **,DWORD *);
__declspec(dllimport) void *GetStdHandle(DWORD);
__declspec(dllimport) int WriteFile(void *,const void *,DWORD,DWORD *,void *);
__declspec(dllexport) __declspec(noinline) void uw_stop_marker(void) { __asm__ volatile("" ::: "memory"); }
#ifdef PE_PROFILE
/* A bounded workload in the same deep stack as the runtime backtrace oracle. */
__declspec(dllexport) __declspec(noinline) long uw_hot(long n) {
    for (unsigned i=0;i<300000000;++i) __asm__ volatile("" : "+r"(n) :: "memory");
    return n;
}
#endif
static char *hex(char *p,U64 n) { const char d[]="0123456789abcdef";for(int i=15;i>=0;--i)*p++=d[(n>>(4*i))&15];return p; }
__declspec(dllexport) __declspec(noinline) long uw_leaf_live(long n) {
    void *frames[32];
    unsigned count=RtlCaptureStackBackTrace(0,32,frames,0);
    char text[640],*p=text;*p++='U';*p++='W';*p++=' ';
    p=hex(p,(U64)__builtin_return_address(0));*p++=' ';
    for(unsigned i=0;i<count;++i){p=hex(p,(U64)frames[i]);*p++=' ';}
    *p++='\n';DWORD done;WriteFile(GetStdHandle((DWORD)-11),text,(DWORD)(p-text),&done,0);
    uw_stop_marker();
#ifdef PE_PROFILE
    n=uw_hot(n);
#endif
    return n+count;
}
__declspec(dllexport) __declspec(noinline) long uw_recurse(long n) {
    volatile long pad[36];pad[0]=n;pad[35]=n+7;
    long result;
    __try { result=n?uw_recurse(n-1):uw_leaf_live(n); }
    __except(1) { result=-1000; }
    return result+pad[0]+pad[35];
}
__declspec(dllexport) __declspec(noinline) long uw_dynamic(long n) {
    volatile char *pad=__builtin_alloca((unsigned)n*16+64);
    pad[0]=(char)n;pad[(unsigned)n*16+63]=3;
    long result=uw_recurse(n);
    return result+pad[0]+pad[(unsigned)n*16+63];
}
