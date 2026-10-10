#ifndef PE_COUNT
#define PE_COUNT 0
#endif
typedef unsigned long DWORD;
typedef unsigned long long U64;
__declspec(dllimport) void *LoadLibraryA(const char *);
__declspec(dllimport) void *GetProcAddress(void *, const char *);
__declspec(dllimport) void *GetStdHandle(DWORD);
__declspec(dllimport) int WriteFile(void *, const void *, DWORD, DWORD *, void *);
__declspec(dllimport) void Sleep(DWORD);
__declspec(dllimport) __declspec(noreturn) void ExitProcess(DWORD);
__declspec(dllexport) __declspec(noinline) void pe_ready(void) { __asm__ volatile("" ::: "memory"); }
static __declspec(noinline) long pe_hidden(long value) { volatile long stack[20];stack[0]=value;Sleep(1);return stack[0]+5; }
static char *hex(char *p,U64 value){const char digits[]="0123456789abcdef";for(int i=15;i>=0;--i)*p++=digits[(value>>(i*4))&15];return p;}
void entry(void) {
    void *dll=LoadLibraryA("owned-pe.dll");if(!dll)ExitProcess(90);
    void *inner=GetProcAddress(dll,"pe_inner"),*outer=GetProcAddress(dll,"pe_outer");if(!inner || !outer)ExitProcess(91);
#ifdef PE_UNWIND
    void *unwind=GetProcAddress(dll,"uw_dynamic");if(!unwind)ExitProcess(94);
#endif
    void *first=0,*last=0,*first_inner=0,*last_inner=0;
    for (unsigned i=0;i<PE_COUNT;++i) {
        char name[]="module-000.dll";name[7]=(char)('0'+i/100);name[8]=(char)('0'+i/10%10);name[9]=(char)('0'+i%10);
        void *module=LoadLibraryA(name);if(!module)ExitProcess(92);
        void *function=GetProcAddress(module,"pe_inner");if(!function)ExitProcess(93);
        if(!i){first=module;first_inner=function;}last=module;last_inner=function;
    }
    char text[192],*p=text;p=hex(p,(U64)dll);*p++=' ';p=hex(p,(U64)inner);*p++=' ';p=hex(p,(U64)&pe_ready);*p++=' ';p=hex(p,(U64)&pe_hidden);*p++=' ';p=hex(p,(U64)first);*p++=' ';p=hex(p,(U64)first_inner);*p++=' ';p=hex(p,(U64)last);*p++=' ';p=hex(p,(U64)last_inner);*p++='\n';
    DWORD done;WriteFile(GetStdHandle((DWORD)-11),text,(DWORD)(p-text),&done,0);
    long result=0;
    for (int i=0;i<6000;++i) { pe_ready();result+=((long (*)(long))outer)(i);result+=pe_hidden(i);if(first_inner)result+=((long (*)(long))first_inner)(i);if(last_inner)result+=((long (*)(long))last_inner)(i);
#ifdef PE_UNWIND
        result+=((long (*)(long))unwind)(8);
#endif
        Sleep(10); }
    ExitProcess((DWORD)result&255);
}
