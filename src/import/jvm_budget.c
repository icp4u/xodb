#define _GNU_SOURCE 1
/* Whole-operation accountant (C05-R3); see jvm_budget.h. */
#include "jvm_budget.h"
#include "logical_frames.h"
#include <stdlib.h>
#include <string.h>
int jvm_bcharge(struct jvm_budget *b, size_t n)
{
    if (!b)
        return 0;
    if (b->limit && (n > b->limit || b->live > b->limit - n)) {
        b->exhausted = 1;
        return -1;
    }
    b->live += n;
    if (b->live > b->peak)
        b->peak = b->live;
    return 0;
}
void jvm_buncharge(struct jvm_budget *b, size_t n)
{
    if (b)
        b->live -= n;
}
size_t jvm_bremaining(const struct jvm_budget *b)
{
    return !b || !b->limit ? SIZE_MAX : b->limit - b->live;
}
int jvm_bcancelled(struct jvm_budget *b)
{
    if (!b)
        return 0;
    if (!b->cancelled && ((b->cancel_at_poll && ++b->polls >= b->cancel_at_poll) ||
                          (b->cancel && xlf_cancel_requested(b->cancel))))
        b->cancelled = 1;
    return b->cancelled;
}
void *jvm_balloc(struct jvm_budget *b, size_t n)
{
    if (n > SIZE_MAX - JVM_BUDGET_HEADER || jvm_bcharge(b, n + JVM_BUDGET_HEADER))
        return NULL;
    unsigned char *p = malloc(n + JVM_BUDGET_HEADER);
    if (!p) {
        jvm_buncharge(b, n + JVM_BUDGET_HEADER);
        if (b)
            b->oom = 1;
        return NULL;
    }
    memcpy(p, &n, sizeof n);
    return p + JVM_BUDGET_HEADER;
}
void *jvm_bcalloc(struct jvm_budget *b, size_t count, size_t size)
{
    if (size && count > SIZE_MAX / size)
        return NULL;
    void *p = jvm_balloc(b, count * size);
    if (p)
        memset(p, 0, count * size);
    return p;
}
void jvm_bfree(struct jvm_budget *b, void *q)
{
    if (!q)
        return;
    unsigned char *p = (unsigned char *)q - JVM_BUDGET_HEADER;
    size_t n;
    memcpy(&n, p, sizeof n);
    jvm_buncharge(b, n + JVM_BUDGET_HEADER);
    free(p);
}
void *jvm_brealloc(struct jvm_budget *b, void *q, size_t n)
{
    if (!q)
        return jvm_balloc(b, n);
    unsigned char *p = (unsigned char *)q - JVM_BUDGET_HEADER;
    size_t old;
    memcpy(&old, p, sizeof old);
    if (n > SIZE_MAX - JVM_BUDGET_HEADER)
        return NULL;
    if (n > old && jvm_bcharge(b, n - old))
        return NULL;
    unsigned char *r = realloc(p, n + JVM_BUDGET_HEADER);
    if (!r) {
        if (n > old)
            jvm_buncharge(b, n - old);
        if (b)
            b->oom = 1;
        return NULL;
    }
    if (n < old)
        jvm_buncharge(b, old - n);
    memcpy(r, &n, sizeof n);
    return r + JVM_BUDGET_HEADER;
}
char *jvm_bstrndup(struct jvm_budget *b, const char *s, size_t n)
{
    size_t k = strnlen(s, n);
    char *d = jvm_balloc(b, k + 1);
    if (d) {
        memcpy(d, s, k);
        d[k] = 0;
    }
    return d;
}
