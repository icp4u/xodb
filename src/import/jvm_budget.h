#ifndef XODB_IMPORT_JVM_BUDGET_H
#define XODB_IMPORT_JVM_BUDGET_H
/* Whole-operation accountant for JVM import + adaptation + decode (C05-R3).
 * Every allocation made through it carries a 16-byte size header and is charged
 * with that header, so live/peak are exact for the importer, its JSON arena and
 * container scratch, the adapter's maps and emitted document, and the retained
 * evidence. Bytes allocated elsewhere (the C05 reader's document) are added
 * with jvm_bcharge. A NULL budget allocates without accounting. Exhaustion and
 * cancellation are sticky so a failure deep in a parser is reported correctly. */
#include <stddef.h>
#include <stdint.h>
struct xlf_cancel;
struct jvm_budget {
    size_t live, peak, limit; /* limit 0: unlimited */
    const struct xlf_cancel *cancel;
    uint64_t polls, cancel_at_poll; /* cancel_at_poll: test aid, 0 = off */
    unsigned exhausted, cancelled, oom;
};
enum { JVM_BUDGET_HEADER = 16 };
void *jvm_balloc(struct jvm_budget *, size_t);
void *jvm_bcalloc(struct jvm_budget *, size_t count, size_t size);
void *jvm_brealloc(struct jvm_budget *, void *, size_t);
void jvm_bfree(struct jvm_budget *, void *);
char *jvm_bstrndup(struct jvm_budget *, const char *, size_t);
int jvm_bcharge(struct jvm_budget *, size_t);   /* 0 ok, -1 over limit */
void jvm_buncharge(struct jvm_budget *, size_t);
int jvm_bcancelled(struct jvm_budget *);        /* polls the cancellation object; sticky */
size_t jvm_bremaining(const struct jvm_budget *); /* SIZE_MAX when unlimited */
#endif
