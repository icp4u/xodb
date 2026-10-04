#include <dlfcn.h>
#include <unistd.h>
#include <stdlib.h>
volatile int total, iteration;
__attribute__((noinline)) void before_load(void) { __asm__ volatile("" ::: "memory"); }
__attribute__((noinline)) void after_unload(void) { __asm__ volatile("" ::: "memory"); }
int main(int argc,char **argv) {
    alarm(20);
    if(argc!=2) return 2;
    before_load();
    for(iteration=0;iteration<2;iteration++) {
        void *h=dlopen(argv[1],RTLD_NOW);
        if(!h) return 3;
        int (*f)(int)=dlsym(h,"late_function");
        if(!f) return 4;
        total+=f(iteration+10);
        if(dlclose(h)) return 5;
        after_unload();
    }
    return total==23 ? 0:6;
}
