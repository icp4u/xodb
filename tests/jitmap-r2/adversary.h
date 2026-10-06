// Deterministic adversarial jitdump families for the C07-R2 bound tests and
// scaling tables. Every family puts n code versions over one hot address so
// the original nested scan costs O(n^2) per query (or per build, for
// same_index), while an indexed resolver stays O(log^2 n).
#ifndef XODB_JITMAP_ADVERSARY_H
#define XODB_JITMAP_ADVERSARY_H
#include "jitmap_build.h"

#define ADV_PID 31337u
#define ADV_A 0x7f0000100000ull
#define ADV_B 0x7f0000900000ull
#define ADV_T0 1000000ull

enum adv_family {
    ADV_SAME_TIME,    /* n loads at one address, one start timestamp */
    ADV_NESTED,       /* n strictly nested ranges, later loads inside earlier ones */
    ADV_REUSE,        /* n loads reusing one address at increasing times */
    ADV_MOVES,        /* one code object moved n - 1 times between two addresses */
    ADV_SAME_INDEX,   /* n disjoint loads sharing one code_index (build-time adversary) */
    ADV_OUT_OF_ORDER, /* ADV_REUSE written in reverse time order */
    ADV_UNCERTAIN,    /* ADV_REUSE with 10 ns spacing; callers declare slack/uncertainty */
    ADV_COUNT
};

static const char *const adv_names[ADV_COUNT] = {"same_time", "nested", "reuse", "moves",
                                                 "same_index", "out_of_order", "uncertain"};

/* Hot address and the time span [first, last] of the family's events. */
static inline uint64_t adv_hot(enum adv_family f, uint32_t n)
{
    return f == ADV_NESTED ? ADV_A + 16ull * n : ADV_A + 8;
}

static inline uint64_t adv_last_time(enum adv_family f, uint32_t n)
{
    if (f == ADV_SAME_TIME)
        return ADV_T0;
    if (f == ADV_NESTED)
        return ADV_T0 + n - 1;
    return ADV_T0 + 10ull * (n - 1);
}

static inline void adv_build(struct jb *b, enum adv_family f, uint32_t n)
{
    jb_init(b, 0);
    jb_header(b, ADV_PID, ADV_T0 - 1, 0);
    for (uint32_t i = 0; i < n; ++i) {
        uint32_t k = f == ADV_OUT_OF_ORDER ? n - 1 - i : i;
        switch (f) {
        case ADV_SAME_TIME:
            jb_load(b, ADV_T0, ADV_PID, 1, ADV_A, 0x40, k, "same_time", 0x90);
            break;
        case ADV_NESTED:
            jb_load(b, ADV_T0 + k, ADV_PID, 1, ADV_A + 16ull * k, 32ull * (n - k), k, "nested", 0x90);
            break;
        case ADV_REUSE:
        case ADV_OUT_OF_ORDER:
        case ADV_UNCERTAIN:
            jb_load(b, ADV_T0 + 10ull * k, ADV_PID, 1, ADV_A, 0x40, k, "reuse", 0x90);
            break;
        case ADV_MOVES:
            if (k == 0)
                jb_load(b, ADV_T0, ADV_PID, 1, ADV_A, 0x40, 7, "moving", 0x90);
            else
                jb_move(b, ADV_T0 + 10ull * k, ADV_PID, 1, k & 1 ? ADV_A : ADV_B, k & 1 ? ADV_B : ADV_A, 0x40, 7);
            break;
        case ADV_SAME_INDEX:
            jb_load(b, ADV_T0 + 10ull * k, ADV_PID, 1, ADV_A + 0x40ull * k, 0x40, 7, "same_index", 0x90);
            break;
        case ADV_COUNT:
            break;
        }
    }
}
#endif
