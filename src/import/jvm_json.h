#ifndef XODB_IMPORT_JVM_JSON_H
#define XODB_IMPORT_JVM_JSON_H
/* Bounded JSON reader for declared runtime exports. Values live in an arena that
 * the caller may reset between top-level records. Numbers keep their literal text
 * so 64-bit integers never round-trip through floating point. */
#include "jvm_budget.h"
#include <stddef.h>
#include <stdint.h>
enum jj_type { JJ_NULL, JJ_FALSE, JJ_TRUE, JJ_NUMBER, JJ_STRING, JJ_ARRAY, JJ_OBJECT };
struct jj_value {
    enum jj_type type;
    uint32_t count;
    const char *text; /* decoded UTF-8 string or number literal, NUL-terminated */
    size_t length;
    struct jj_value *items;
    const char **keys;
    size_t start, end; /* C05-R3: byte span of the value in the parsed text */
};
struct jj_block;
struct jj_arena {
    struct jj_block *head;
    size_t used, limit; /* bytes currently held / maximum */
    struct jvm_budget *budget; /* C05-R3: whole-operation accountant, may be NULL */
};
struct jj_parser {
    const char *start, *p, *end;
    struct jj_arena *arena;
    uint32_t depth, max_depth;
    size_t max_string;
    unsigned lossy; /* lone surrogates replaced with U+FFFD */
    const char *error;
    size_t error_offset;
};
void jj_init(struct jj_parser *, const char *, size_t, struct jj_arena *, uint32_t max_depth,
             size_t max_string);
void jj_arena_reset(struct jj_arena *);
void jj_arena_free(struct jj_arena *);
int jj_value(struct jj_parser *, struct jj_value *);
int jj_string(struct jj_parser *, const char **, size_t *);
int jj_skip_space(struct jj_parser *); /* returns next byte or -1 at end */
int jj_expect(struct jj_parser *, char);
int jj_fail(struct jj_parser *, const char *);
const struct jj_value *jj_get(const struct jj_value *, const char *);
const char *jj_str(const struct jj_value *, const char *); /* string member or NULL */
int jj_i64(const struct jj_value *, int64_t *);           /* exact integer only */
int jj_utf8_valid(const char *, size_t);
size_t jj_utf8_one(const unsigned char *, size_t); /* valid sequence length or 0 */
#endif
