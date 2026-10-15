/* Owned PE/Mach-O fixture for image-only pseudo-C; never executed. */
volatile int xodb_static_seed = 3;
#ifdef _WIN32
#define XODB_STATIC_EXPORT __declspec(dllexport) __declspec(noinline)
#else
#define XODB_STATIC_EXPORT __attribute__((noinline))
#endif
XODB_STATIC_EXPORT int xodb_static_target(int value) {
    switch (value & 3) {
        case 0: return value + xodb_static_seed;
        case 1: return value * 7;
        case 2: return value - 11;
        default: return value ^ 0x55;
    }
}
void entry(void) { xodb_static_seed = xodb_static_target(xodb_static_seed); }
int main(void) { return xodb_static_target(xodb_static_seed); }
