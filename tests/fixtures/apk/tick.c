#ifndef TICK
#define TICK apk_left_tick
#endif
#ifndef INITIAL
#define INITIAL 7
#endif
__attribute__((noinline, visibility("default"))) int TICK(int amount) {
    static volatile int value = INITIAL;
    int before = value;
    int next = before + amount;
    value = next; /* APK_STORE */
    return value;
}
