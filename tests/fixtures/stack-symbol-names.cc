/* Owned compiler names for compact stack display; no external C++ runtime. */
#include "../check.h"
extern "C" __attribute__((noinline)) void symbol_name_stop(void) {
    __asm__ volatile("" ::: "memory");
}
namespace demo {
template<class T> __attribute__((noinline)) T leaf(T n) {
    symbol_name_stop();
    __asm__ volatile("" : "+r"(n));
    return n+1;
}
struct Engine {
    __attribute__((noinline)) int run(int n);
};
int Engine::run(int n) {
    int result=leaf<int>(n);
    __asm__ volatile("" : "+r"(result));
    return result;
}
}
int main(void) {
    demo::Engine engine;
    CHECK(engine.run(40)==41);
    return 0;
}
