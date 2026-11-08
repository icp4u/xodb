// Owned fixture for execute_call: a C ABI surface (scalars, small and large
// aggregates, stack-passed arguments, varargs, a function pointer, PLT/IFUNC
// imports) and C++ members, overloads, templates, a non-trivial copy and an
// escaping exception. The debugger stops at checkpoint(); the locals it
// passes are in scene() (frame 1). A second thread holds g_lock forever.
#include <pthread.h>
#include <stdarg.h>
#include <stdexcept>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

extern "C" {
struct pair { long a; double b; };
struct fpair { float x, y; };
struct triple { long a, b, c; };
struct ipair { int x, y; };

volatile long g_counter = 0;
pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static volatile int g_holding = 0;

__attribute__((noinline)) long add_ints(long a, long b) { return a + b; }
__attribute__((noinline)) int add_small(int a, short b, signed char c) { return a + b + c; }
__attribute__((noinline)) unsigned char low_byte(unsigned long v) { return (unsigned char)v; }
__attribute__((noinline)) int is_odd(long v) { return (int)(v & 1); }
__attribute__((noinline)) double scale(double x, int k) { return x * k; }
__attribute__((noinline)) float halve(float x) { return x / 2.0f; }
__attribute__((noinline)) double mix(int a, double b, long c, float d) { return a + b + c + d; }
__attribute__((noinline)) struct pair make_pair(long a, double b) { struct pair p = {a, b}; return p; }
__attribute__((noinline)) double pair_sum(struct pair p) { return (double)p.a + p.b; }
__attribute__((noinline)) struct fpair swap_f(struct fpair p) { struct fpair q = {p.y, p.x}; return q; }
__attribute__((noinline)) struct ipair add_ipair(struct ipair p, int k) { struct ipair q = {p.x + k, p.y + k}; return q; }
__attribute__((noinline)) struct triple make_triple(long a) { struct triple t = {a, a * 2, a * 3}; return t; }
__attribute__((noinline)) long triple_sum(struct triple t) { return t.a + t.b + t.c; }
__attribute__((noinline)) long eight(long a, long b, long c, long d, long e, long f, long g, long h)
{ return a + 2 * b + 3 * c + 4 * d + 5 * e + 6 * f + 7 * g + 8 * h; }
__attribute__((noinline)) double ten(double a, double b, double c, double d, double e, double f,
                                     double g, double h, double i, double j)
{ return a + b * 2 + c * 3 + d * 4 + e * 5 + f * 6 + g * 7 + h * 8 + i * 9 + j * 10; }
__attribute__((noinline)) const char *pick(const char *s, long i) { return s + i; }
__attribute__((noinline)) long sum_ints(int n, ...)
{
    va_list ap;
    va_start(ap, n);
    long total = 0;
    for (int i = 0; i < n; ++i) total += va_arg(ap, int);
    va_end(ap);
    return total;
}
__attribute__((noinline)) double sum_doubles(int n, ...)
{
    va_list ap;
    va_start(ap, n);
    double total = 0;
    for (int i = 0; i < n; ++i) total += va_arg(ap, double);
    va_end(ap);
    return total;
}
__attribute__((noinline)) long bump(long by) { g_counter += by; return g_counter; }
__attribute__((noinline)) int add_two(int a, int b) { return a + b; }
__attribute__((noinline)) void spin(void) { for (;;) g_counter = g_counter + 1; }
__attribute__((noinline)) int crash(int *p) { return *p + 1; }
__attribute__((noinline)) int take_lock(void)
{
    pthread_mutex_lock(&g_lock);
    pthread_mutex_unlock(&g_lock);
    return 7;
}
__attribute__((noinline)) int breakme(int x) { return x + 1; }
// Clobbers every vector register and then traps in breakme, so a stop
// inside the call shows changed vector state.
__attribute__((noinline)) int clobber(int x)
{
    __asm__ volatile("vpcmpeqd %%ymm0, %%ymm0, %%ymm0\n\t"
                     "vmovdqa %%ymm0, %%ymm1\n\tvmovdqa %%ymm0, %%ymm2\n\tvmovdqa %%ymm0, %%ymm3\n\t"
                     "vmovdqa %%ymm0, %%ymm4\n\tvmovdqa %%ymm0, %%ymm5\n\tvmovdqa %%ymm0, %%ymm6\n\t"
                     "vmovdqa %%ymm0, %%ymm7\n\tvmovdqa %%ymm0, %%ymm8\n\tvmovdqa %%ymm0, %%ymm9\n\t"
                     "vmovdqa %%ymm0, %%ymm10\n\tvmovdqa %%ymm0, %%ymm11\n\tvmovdqa %%ymm0, %%ymm12\n\t"
                     "vmovdqa %%ymm0, %%ymm13\n\tvmovdqa %%ymm0, %%ymm14\n\tvmovdqa %%ymm0, %%ymm15\n\t"
                     "fldpi\n\tfldpi\n\t"
                     ::: "xmm0", "xmm1", "xmm2", "xmm3", "xmm4", "xmm5", "xmm6", "xmm7", "xmm8",
                     "xmm9", "xmm10", "xmm11", "xmm12", "xmm13", "xmm14", "xmm15", "st", "st(1)");
    int r = breakme(x);
    __asm__ volatile("fstp %%st(0)\n\tfstp %%st(0)\n\t" ::: "st", "st(1)");
    return r;
}
// 0 when the call frame obeys the ABI's 16-byte alignment at entry.
__attribute__((noinline)) long stack_align(void) { return (long)((uintptr_t)__builtin_frame_address(0) & 15); }
__attribute__((noinline)) void checkpoint(void) { __asm__ volatile("" ::: "memory"); }
}

struct Counter {
    long total;
    __attribute__((noinline)) long add(long v) { total += v; return total; }
    __attribute__((noinline)) long get() const { return total; }
};
struct Shape {
    long id = 7;
    virtual ~Shape() {}
    virtual double area() const { return -1; }
};
struct Circle : Shape {
    double r;
    explicit Circle(double r) : r(r) {}
    double area() const override { return 3.0 * r * r; }
};
struct Square : Shape {
    double s;
    explicit Square(double s) : s(s) {}
    double area() const override { return s * s; }
};
struct Tracked {
    long v;
    explicit Tracked(long v) : v(v) {}
    Tracked(const Tracked &o) : v(o.v) {}
    ~Tracked() { v = -1; }
};
__attribute__((noinline)) long overloaded(long x) { return x; }
__attribute__((noinline)) long overloaded(double x) { return (long)(x * 10); }
template <typename T> __attribute__((noinline)) T maxof(T a, T b) { return a > b ? a : b; }
__attribute__((noinline)) long take_tracked(Tracked t) { return t.v; }
__attribute__((noinline)) long thrower(long x)
{
    if (x) throw std::runtime_error("escaping");
    return 0;
}

static void *holder(void *)
{
    pthread_mutex_lock(&g_lock);
    g_holding = 1;
    for (;;) pause();
    return nullptr;
}

// The vector pattern is loaded right before the stop so a restore can be
// compared against non-trivial ymm/x87/mxcsr state.
__attribute__((noinline)) static void scene(void)
{
    char buf[32];
    char dst[32];
    strcpy(buf, "hello, debugger");
    memset(dst, 0, sizeof(dst));
    long x = 40;
    int small = 5;
    double d = 1.25;
    float f = 3.5f;
    struct pair pr = {3, 4.5};
    struct fpair fp2 = {1.5f, -2.25f};
    struct ipair ip = {10, 20};
    struct triple tr = {1, 2, 3};
    Counter counter{100};
    Circle circle(2.0);
    Square square(3.0);
    Shape *shape = &circle;
    Tracked tracked(9);
    int (*fp)(int, int) = add_two;
    int *nullp = nullptr;
    // Bind the imports now (the fixture also links with -z now).
    volatile size_t warm = strlen(buf);
    memcpy(dst, buf, (size_t)small - 4); // a runtime length keeps the PLT call
    dst[0] = 0;
    (void)warm;
    static const unsigned char pattern[32] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
                                              17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32};
    __asm__ volatile("vmovdqu %0, %%ymm8\n\tvmovdqu %0, %%ymm15\n\t" :: "m"(pattern) : "xmm8", "xmm15");
    checkpoint();
    printf("%s %s %ld %d %g %g %ld %g %g %d %d %ld %ld %ld %g %g %ld %d %p\n", buf, dst, x, small,
           d, (double)f, pr.a, pr.b, (double)fp2.x, ip.x, ip.y, tr.a, counter.get() + counter.add(0), square.id,
           shape->area(), square.area(), tracked.v, fp(1, 2), (void *)nullp);
    printf("%ld %ld %ld %ld\n", overloaded(1L), overloaded(1.0), (long)maxof(1, 2),
           (long)maxof(1.0, 2.0));
    printf("%ld\n", take_tracked(tracked));
}

int main(int argc, char **argv)
{
    pthread_t thread;
    pthread_create(&thread, nullptr, holder, nullptr);
    while (!g_holding) usleep(1000);
    // "attach": give an attaching debugger time to plant its breakpoint.
    if (argc == 2 && !strcmp(argv[1], "attach")) sleep(3);
    scene();
    if (argc > 5) {
        // Never runs; keeps the callees in the image.
        printf("%ld %d %u %d %g %g %g %g %g %ld %g %ld %s %ld %g %ld %d %d %d %d %ld\n",
               add_ints(1, 2), add_small(1, 2, 3), low_byte(1), is_odd(1), scale(1, 2), halve(1),
               mix(1, 2, 3, 4), make_pair(1, 2).b, pair_sum({1, 2}), (long)swap_f({1, 2}).x,
               (double)add_ipair({1, 2}, 3).x, make_triple(1).c, pick("ab", 1), triple_sum({1, 2, 3}),
               ten(1, 2, 3, 4, 5, 6, 7, 8, 9, 10), eight(1, 2, 3, 4, 5, 6, 7, 8), clobber(1),
               take_lock(), crash(nullptr), (int)sum_ints(1, 2), thrower(0) + bump(0) + stack_align());
        printf("%g\n", sum_doubles(1, 2.0));
        spin();
    }
    return 0;
}
