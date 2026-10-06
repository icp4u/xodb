/* Unit checks for the C06 JVM importer primitives. */
#include "jvm_import.h"
#include "jvm_json.h"
#include "sha256.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static int parse(const char *text, struct jj_value *v, struct jj_arena *a, struct jj_parser *j)
{
    a->limit = 1 << 24;
    jj_init(j, text, strlen(text), a, 64, 1 << 20);
    int rc = jj_value(j, v);
    if (!rc && jj_skip_space(j) >= 0)
        rc = -1;
    return rc;
}
static void json_cases(void)
{
    struct jj_arena a = {0};
    struct jj_parser j;
    struct jj_value v;
    int64_t n;
    assert(!parse("{\"a\":[1,-2,{\"b\":null}],\"c\":\"x\\u00fc\\ud83d\\ude00\"}", &v, &a, &j));
    assert(v.type == JJ_OBJECT && v.count == 2);
    assert(!strcmp(jj_str(&v, "c"), "x\xc3\xbc\xf0\x9f\x98\x80"));
    assert(!jj_i64(&jj_get(&v, "a")->items[1], &n) && n == -2);
    jj_arena_reset(&a);
    assert(!parse("\"\\ud800x\"", &v, &a, &j) && j.lossy == 1); /* lone surrogate */
    assert(!strcmp(v.text, "\xef\xbf\xbdx"));
    jj_arena_reset(&a);
    assert(!parse("9223372036854775807", &v, &a, &j) && !jj_i64(&v, &n) && n == INT64_MAX);
    assert(!parse("9223372036854775808", &v, &a, &j) && jj_i64(&v, &n)); /* no rounding */
    assert(!parse("18446744073709551615", &v, &a, &j) && jj_i64(&v, &n));
    assert(!parse("1.5", &v, &a, &j) && jj_i64(&v, &n));
    assert(!parse("1e3", &v, &a, &j) && jj_i64(&v, &n));
    assert(parse("01", &v, &a, &j));
    assert(parse("-", &v, &a, &j));
    assert(parse("[1,]", &v, &a, &j));
    assert(parse("{\"a\" 1}", &v, &a, &j));
    assert(parse("\"\x01\"", &v, &a, &j));
    assert(parse("\"\xc3\x28\"", &v, &a, &j));      /* invalid UTF-8 */
    assert(parse("\"\xed\xa0\x80\"", &v, &a, &j));  /* encoded surrogate */
    assert(parse("\"\xe0\x80\xaf\"", &v, &a, &j));  /* overlong */
    assert(parse("\"abc", &v, &a, &j));
    assert(parse("\"\\x\"", &v, &a, &j));
    assert(parse("tru", &v, &a, &j));
    assert(parse("{\"a\":1,\"a\":2}", &v, &a, &j) && !strcmp(j.error, "duplicate object key"));
    char deep[300];
    memset(deep, '[', 200);
    memset(deep + 200, ']', 99);
    deep[299] = 0;
    assert(parse(deep, &v, &a, &j) && !strcmp(j.error, "nesting budget exhausted"));
    jj_arena_free(&a);
    struct jj_arena small = {0};
    small.limit = 1;
    jj_init(&j, "\"x\"", 3, &small, 8, 16);
    assert(jj_value(&j, &v) && !strcmp(j.error, "memory budget exhausted"));
    jj_arena_free(&small);
}
static void sha_cases(void)
{
    char h[65];
    sha256_hex("", 0, h);
    assert(!strcmp(h, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"));
    sha256_hex("abc", 3, h);
    assert(!strcmp(h, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"));
    const char *two = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq";
    sha256_hex(two, strlen(two), h);
    assert(!strcmp(h, "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"));
    char *million = malloc(1000000);
    memset(million, 'a', 1000000);
    sha256_hex(million, 1000000, h);
    assert(!strcmp(h, "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"));
    free(million);
}
static void time_cases(void)
{
    int64_t t;
    assert(!jvm_parse_iso_time("1970-01-01T00:00:00Z", &t) && t == 0);
    assert(!jvm_parse_iso_time("2026-10-05T13:09:55.165454909+05:30", &t) &&
           t == 1791185995165454909LL);
    assert(!jvm_parse_iso_time("2026-10-05T07:39:55.165454909Z", &t) && t == 1791185995165454909LL);
    assert(!jvm_parse_iso_time("2026-10-05T07:39:57.2Z", &t) && t == 1791185997200000000LL);
    assert(!jvm_parse_iso_time("1969-12-31T23:59:59Z", &t) && t == -1000000000LL);
    assert(jvm_parse_iso_time("2026-10-05T00:39:55", &t));         /* unzoned: no epoch */
    assert(jvm_parse_iso_time("2026-10-05 00:39:55Z", &t));
    assert(jvm_parse_iso_time("2026-10-05T00:39:55.1234567891Z", &t)); /* >ns precision */
    assert(jvm_parse_iso_time("2026-13-05T00:39:55Z", &t));
    assert(jvm_parse_iso_time("", &t));
    assert(jvm_parse_iso_time(NULL, &t));
}
int main(void)
{
    json_cases();
    sha_cases();
    time_cases();
    puts("jvm-import unit: ok");
    return 0;
}
