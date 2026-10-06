// xodb-jitmap: reference CLI for the jitdump/perf-map decoder and resolver.
//   xodb-jitmap decode  [identity/clock options] SOURCES
//   xodb-jitmap resolve [options] SOURCES --at ADDR[@TIME] ...
//   xodb-jitmap stack   [options] SOURCES --time T --pcs PC,PC,... [--maps FILE] [--logical TEXT]
// SOURCES: --jitdump FILE and/or --perfmap FILE (repeatable). Identity and
// clock options apply to the sources that follow them; --truth resets them.
// Query identity/clock default to the first source's. Output is JSON.
// Unsigned 64-bit addresses are hex strings, times decimal strings.
#define _GNU_SOURCE
#include "jitmap.h"
#include <errno.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define FORMAT "xodb-jitmap-cli/2-draft"
#define MAX_SOURCES 16
#define MAX_AT 256
#define MAX_PCS 64

/* ---- SHA-256 (FIPS 180-4) for artifact identity ------------------------- */

struct sha256 {
    uint32_t h[8];
    uint8_t block[64];
    uint64_t bytes;
    size_t used;
};

static const uint32_t K[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

#define ROR(x, n) ((x) >> (n) | (x) << (32 - (n)))

static void sha_block(struct sha256 *s, const uint8_t *p)
{
    uint32_t w[64], v[8];
    for (int i = 0; i < 16; ++i)
        w[i] = (uint32_t)p[4 * i] << 24 | (uint32_t)p[4 * i + 1] << 16 | (uint32_t)p[4 * i + 2] << 8 | p[4 * i + 3];
    for (int i = 16; i < 64; ++i) {
        uint32_t s0 = ROR(w[i - 15], 7) ^ ROR(w[i - 15], 18) ^ (w[i - 15] >> 3);
        uint32_t s1 = ROR(w[i - 2], 17) ^ ROR(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    memcpy(v, s->h, sizeof v);
    for (int i = 0; i < 64; ++i) {
        uint32_t t1 = v[7] + (ROR(v[4], 6) ^ ROR(v[4], 11) ^ ROR(v[4], 25)) + ((v[4] & v[5]) ^ (~v[4] & v[6])) + K[i] + w[i];
        uint32_t t2 = (ROR(v[0], 2) ^ ROR(v[0], 13) ^ ROR(v[0], 22)) + ((v[0] & v[1]) ^ (v[0] & v[2]) ^ (v[1] & v[2]));
        memmove(v + 1, v, 7 * sizeof *v);
        v[4] += t1;
        v[0] = t1 + t2;
    }
    for (int i = 0; i < 8; ++i)
        s->h[i] += v[i];
}

static void sha256_hex(const uint8_t *p, size_t n, char out[65])
{
    struct sha256 s = {{0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19},
                       {0}, 0, 0};
    s.bytes = n;
    for (; n >= 64; p += 64, n -= 64)
        sha_block(&s, p);
    uint8_t tail[128] = {0};
    memcpy(tail, p, n);
    tail[n] = 0x80;
    size_t len = n + 9 <= 64 ? 64 : 128;
    uint64_t bits = s.bytes * 8;
    for (int i = 0; i < 8; ++i)
        tail[len - 1 - i] = (uint8_t)(bits >> (8 * i));
    sha_block(&s, tail);
    if (len == 128)
        sha_block(&s, tail + 64);
    for (int i = 0; i < 8; ++i)
        snprintf(out + 8 * i, 9, "%08x", s.h[i]);
}

/* ---- options ------------------------------------------------------------ */

struct input {
    int kind;
    const char *path;
    uint8_t *bytes;
    size_t len;
    char sha[65];
    struct xodb_jit_source_meta meta; /* options given before this source */
};

static struct input inputs[MAX_SOURCES];
static int input_count;
static struct xodb_jit_source_meta meta;
static struct xodb_jit_query base_query;
static int query_identity_set, query_clock_set;
static const char *at_specs[MAX_AT];
static int at_count;
static uint64_t pcs[MAX_PCS];
static int pc_count, stack_has_time;
static uint64_t stack_time;
static const char *maps_path, *logical_text;
static int show_code;
static struct xodb_jit_limits limits;

static void usage(void)
{
    fprintf(stderr,
            "usage: xodb-jitmap decode|resolve|stack [options]\n"
            "  sources:  --jitdump FILE --perfmap FILE (repeatable)\n"
            "  identity: --pid N --start-ticks N --boot-id UUID | --truth FIXTURE_TRUTH\n"
            "  clock:    --clock monotonic|arch|unknown --clock-scope HEX32 --slack N --coverage-end T\n"
            "            --header-time-in-clock (declare header timestamp uses the record clock)\n"
            "            --debug-address-bias N (declared producer bias of debug entry addresses)\n"
            "  mapping:  --map-offset N --map-uncertainty N --map-target-scope HEX32 [--map-target-clock K]\n"
            "  query:    --q-pid N --q-start-ticks N --q-boot-id UUID --q-unknown-identity\n"
            "            --q-clock K --q-clock-scope HEX32 --at ADDR[@TIME]\n"
            "  stack:    --time T --pcs PC,PC,... --maps FILE --logical TEXT\n"
            "  decode:   --code (include retained code bytes, first 4096 per version)\n"
            "  limits:   --prepare-work-limit N --query-work-limit N --max-versions N --max-memory N\n"
            "  identity/clock options apply to sources that follow; --truth resets them\n");
    exit(2);
}

static uint64_t number(const char *text)
{
    char *end;
    errno = 0;
    unsigned long long v = strtoull(text, &end, 0);
    if (errno || end == text || *end || text[0] == '-') {
        fprintf(stderr, "xodb-jitmap: bad number '%s'\n", text);
        exit(2);
    }
    return v;
}

static int64_t signed_number(const char *text)
{
    char *end;
    errno = 0;
    long long v = strtoll(text, &end, 0);
    if (errno || end == text || *end) {
        fprintf(stderr, "xodb-jitmap: bad number '%s'\n", text);
        exit(2);
    }
    return v;
}

static void hex_bytes(const char *text, uint8_t *out, size_t n)
{
    size_t k = 0;
    for (const char *p = text; *p && k < 2 * n; ++p) {
        int d;
        if (*p == '-')
            continue;
        if (*p >= '0' && *p <= '9')
            d = *p - '0';
        else if (*p >= 'a' && *p <= 'f')
            d = *p - 'a' + 10;
        else if (*p >= 'A' && *p <= 'F')
            d = *p - 'A' + 10;
        else
            break;
        out[k / 2] = (uint8_t)(out[k / 2] << 4 | d);
        k++;
    }
    if (k != 2 * n) {
        fprintf(stderr, "xodb-jitmap: expected %zu hex bytes in '%s'\n", n, text);
        exit(2);
    }
}

static uint32_t clock_kind(const char *text)
{
    if (!strcmp(text, "monotonic"))
        return XODB_JIT_CLOCK_MONOTONIC;
    if (!strcmp(text, "arch"))
        return XODB_JIT_CLOCK_ARCH;
    if (!strcmp(text, "other"))
        return XODB_JIT_CLOCK_OTHER;
    if (!strcmp(text, "unknown"))
        return XODB_JIT_CLOCK_UNKNOWN;
    usage();
    return 0;
}

/* Clock scope for CLOCK_MONOTONIC: boot_id bytes with the time-namespace
 * inode XORed little-endian into bytes 8..15. Declared, not measured. */
static void scope_from(const uint8_t boot[16], uint64_t timens, uint8_t scope[16])
{
    memcpy(scope, boot, 16);
    for (int i = 0; i < 8; ++i)
        scope[8 + i] ^= (uint8_t)(timens >> (8 * i));
}

static void read_truth(const char *path)
{
    FILE *f = fopen(path, "re");
    if (!f) {
        fprintf(stderr, "xodb-jitmap: %s: %s\n", path, strerror(errno));
        exit(2);
    }
    char line[8192];
    uint64_t timens = 0;
    while (fgets(line, sizeof line, f)) {
        line[strcspn(line, "\n")] = 0;
        char *value = strchr(line, ' ');
        if (!value)
            continue;
        *value++ = 0;
        if (!strcmp(line, "pid"))
            meta.process.pid = (uint32_t)number(value);
        else if (!strcmp(line, "start_ticks"))
            meta.process.start_ticks = number(value);
        else if (!strcmp(line, "boot_id"))
            hex_bytes(value, meta.process.boot_id, 16);
        else if (!strcmp(line, "time_ns") && !strncmp(value, "time:[", 6))
            timens = strtoull(value + 6, NULL, 10);
        else if (!strcmp(line, "coverage_end")) {
            meta.has_coverage_end = 1;
            meta.coverage_end = number(value);
        }
    }
    fclose(f);
    meta.process.known = 1;
    meta.clock.kind = XODB_JIT_CLOCK_MONOTONIC;
    meta.clock.scope_known = 1;
    scope_from(meta.process.boot_id, timens, meta.clock.scope);
}

static uint8_t *slurp(const char *path, size_t *len)
{
    FILE *f = fopen(path, "rbe");
    if (!f) {
        fprintf(stderr, "xodb-jitmap: %s: %s\n", path, strerror(errno));
        exit(2);
    }
    size_t cap = 65536, n = 0;
    uint8_t *b = malloc(cap);
    for (;;) {
        if (!b) {
            fprintf(stderr, "xodb-jitmap: out of memory\n");
            exit(2);
        }
        n += fread(b + n, 1, cap - n, f);
        if (n < cap)
            break;
        if (cap >= (size_t)512 << 20) {
            fprintf(stderr, "xodb-jitmap: %s exceeds 512 MiB read limit\n", path);
            exit(2);
        }
        cap *= 2;
        b = realloc(b, cap);
    }
    int bad = ferror(f);
    fclose(f);
    if (bad) {
        fprintf(stderr, "xodb-jitmap: %s: read error\n", path);
        exit(2);
    }
    *len = n;
    return b;
}

/* ---- JSON --------------------------------------------------------------- */

static void json_string(const uint8_t *s, size_t n)
{
    putchar('"');
    for (size_t i = 0; i < n; ++i) {
        uint8_t c = s[i];
        if (c == '"' || c == '\\')
            printf("\\%c", c);
        else if (c < 0x20 || c == 0x7f)
            printf("\\u%04x", c);
        else
            putchar(c);
    }
    putchar('"');
}

static void json_text(const char *s)
{
    if (s)
        json_string((const uint8_t *)s, strlen(s));
    else
        printf("null");
}

static void json_name(const struct xodb_jit_model *model, const struct xodb_jit_version *v)
{
    const uint8_t *p = model->sources[v->source].bytes + v->name_offset;
    if (!v->name_len && (v->flags & XODB_JIT_V_ORPHAN_MOVE)) {
        printf("\"name\":null,\"name_status\":\"unknown_moved_code\"");
    } else if (v->flags & XODB_JIT_V_NAME_NOT_UTF8) {
        printf("\"name\":null,\"name_hex\":\"");
        for (uint32_t i = 0; i < v->name_len; ++i)
            printf("%02x", p[i]);
        printf("\"");
    } else {
        printf("\"name\":");
        json_string(p, v->name_len);
    }
}

static void json_bound(const char *key, const struct xodb_jit_bound *b)
{
    printf("\"%s\":{\"kind\":\"%s\"", key, xodb_jit_bound_name(b->kind));
    if (b->has_time)
        printf(",\"time\":\"%" PRIu64 "\"", b->time);
    if (b->kind != XODB_JIT_BOUND_NONE)
        printf(",\"%s\":%" PRIu64 ",\"offset\":%" PRIu64, b->kind == XODB_JIT_BOUND_SNAPSHOT ? "line" : "record",
               b->ordinal, b->offset);
    printf("}");
}

static void json_version(const struct xodb_jit_model *model, const struct xodb_jit_version *v)
{
    const struct xodb_jit_source *s = &model->sources[v->source];
    printf("{\"version\":%u,\"source\":%u,\"start\":\"0x%" PRIx64 "\",\"size\":\"0x%" PRIx64 "\",", v->id, v->source,
           v->start, v->size);
    json_name(model, v);
    if (v->has_code_index)
        printf(",\"code_index\":\"%" PRIu64 "\"", v->code_index);
    if (s->kind == XODB_JIT_SOURCE_JITDUMP)
        printf(",\"pid\":%u,\"tid\":%u,\"vma\":\"0x%" PRIx64 "\"", v->pid, v->tid, v->vma);
    printf(",");
    json_bound("begin", &v->begin);
    printf(",");
    json_bound("end", &v->end);
    if (v->predecessor)
        printf(",\"moved_from_version\":%u", v->predecessor);
    printf(",\"flags\":[");
    static const char *const names[] = {"orphan_move", "code_bytes", "vma_differs", "duplicate_code_index",
                                        "name_not_utf8", "hex_prefix"};
    int first = 1;
    for (unsigned i = 0; i < 6; ++i)
        if (v->flags & (1u << i)) {
            printf("%s\"%s\"", first ? "" : ",", names[i]);
            first = 0;
        }
    printf("]");
    if ((v->flags & XODB_JIT_V_HAS_CODE) && show_code) {
        printf(",\"code_hex\":\"");
        for (uint64_t i = 0; i < v->size && i < 4096; ++i)
            printf("%02x", s->bytes[v->code_offset + i]);
        printf("\"%s", v->size > 4096 ? ",\"code_hex_truncated\":true" : "");
    }
    if (v->debug_count)
        printf(",\"debug\":{\"record\":%" PRIu64 ",\"entries\":%u}", v->debug_record_ordinal, v->debug_count);
    if (v->unwind_record >= 0) {
        const struct xodb_jit_unwind *u = &model->unwinds[v->unwind_record];
        printf(",\"unwind\":{\"record\":%" PRIu64 ",\"unwind_size\":\"%" PRIu64 "\",\"eh_frame_hdr_size\":\"%" PRIu64
               "\",\"mapped_size\":\"%" PRIu64 "\",\"interpreted\":false}",
               u->ordinal, u->unwind_size, u->eh_frame_hdr_size, u->mapped_size);
    }
    printf("}");
}

static void json_reasons(uint32_t reasons)
{
    static const char *const names[] = {
        "identity_unverified", "identity_skipped", "no_query_time", "clock_unrelated", "untimed_snapshot",
        "boundary_uncertain", "overlap", "after_coverage", "no_coverage", "partial_source", "no_end_evidence",
        "corroborated", "before_coverage", "candidates_truncated", "query_stopped"};
    printf("[");
    int first = 1;
    for (unsigned i = 0; i < sizeof names / sizeof *names; ++i)
        if (reasons & (1u << i)) {
            printf("%s\"%s\"", first ? "" : ",", names[i]);
            first = 0;
        }
    printf("]");
}

static const char *clock_name(uint32_t kind)
{
    switch (kind) {
    case XODB_JIT_CLOCK_MONOTONIC: return "monotonic";
    case XODB_JIT_CLOCK_ARCH: return "arch";
    case XODB_JIT_CLOCK_OTHER: return "other";
    }
    return "unknown";
}

static void json_clock(const struct xodb_jit_clock *c)
{
    printf("{\"kind\":\"%s\",\"scope\":", clock_name(c->kind));
    if (c->scope_known) {
        printf("\"");
        for (int i = 0; i < 16; ++i)
            printf("%02x", c->scope[i]);
        printf("\"");
    } else {
        printf("null");
    }
    printf("}");
}

static void json_process(const struct xodb_jit_process *p)
{
    printf("{\"pid\":%u,\"incarnation_known\":%s", p->pid, p->known ? "true" : "false");
    if (p->known) {
        printf(",\"start_ticks\":\"%" PRIu64 "\",\"boot_id\":\"", p->start_ticks);
        for (int i = 0; i < 16; ++i)
            printf("%02x", p->boot_id[i]);
        printf("\"");
    }
    printf("}");
}

static void json_sources(const struct xodb_jit_model *model)
{
    printf("\"sources\":[");
    for (size_t i = 0; i < model->source_count; ++i) {
        const struct xodb_jit_source *s = &model->sources[i];
        printf("%s{\"index\":%zu,\"kind\":\"%s\",\"path\":", i ? "," : "", i,
               s->kind == XODB_JIT_SOURCE_JITDUMP ? "jitdump" : "perfmap");
        json_text(s->meta.label);
        printf(",\"sha256\":");
        json_text(s->meta.artifact_sha256);
        printf(",\"bytes\":%zu,\"decoded_bytes\":%" PRIu64 ",\"complete\":%s,\"tail_truncated\":%s,\"partial\":%s,",
               s->len, s->decoded_bytes, s->complete ? "true" : "false", s->tail_truncated ? "true" : "false",
               s->partial ? "true" : "false");
        printf("\"process\":");
        json_process(&s->meta.process);
        printf(",\"clock\":");
        json_clock(&s->meta.clock);
        if (s->kind == XODB_JIT_SOURCE_JITDUMP) {
            printf(",\"jitdump\":{\"version\":%u,\"byte_order\":\"%s\",\"header_size\":%u,\"elf_mach\":%u,"
                   "\"header_pid\":%u,\"header_time\":\"%" PRIu64 "\",\"header_time_clock\":\"%s\",\"flags\":\"0x%" PRIx64
                   "\",\"timestamp_mode\":\"%s\",\"closed\":%s",
                   s->version, s->big_endian ? "big" : "little", s->header_size, s->elf_mach, s->header_pid,
                   s->header_time, s->meta.header_time_in_clock ? "declared_record_clock" : "producer_defined_unrelated",
                   s->header_flags, s->arch_timestamp ? "arch_counter" : "clock_monotonic_by_convention",
                   s->closed ? "true" : "false");
            if (s->closed)
                printf(",\"close_time\":\"%" PRIu64 "\"", s->close_time);
            if (s->has_last_time)
                printf(",\"first_record_time\":\"%" PRIu64 "\",\"last_record_time\":\"%" PRIu64 "\"", s->first_time,
                       s->last_time);
            printf("}");
        }
        printf(",\"records\":%" PRIu64 ",\"unknown_records\":%" PRIu64 ",\"malformed_records\":%" PRIu64, s->records,
               s->unknown_records, s->malformed_records);
        if (s->has_coverage)
            printf(",\"coverage_end\":\"%" PRIu64 "\"", s->coverage_end);
        else
            printf(",\"coverage_end\":null");
        if (s->meta.map.method != XODB_JIT_MAP_NONE) {
            printf(",\"clock_map\":{\"method\":\"%s\",\"offset\":\"%" PRId64 "\",\"uncertainty\":\"%" PRIu64
                   "\",\"target\":",
                   s->meta.map.method == XODB_JIT_MAP_OFFSET ? "offset" : "perf_tsc", s->meta.map.offset,
                   s->meta.map.uncertainty);
            json_clock(&s->meta.map.target);
            printf(",\"measured_by\":");
            json_text(s->meta.map.measured_by);
            printf("}");
        }
        printf(",\"slack\":\"%" PRIu64 "\",\"debug_address_bias\":\"0x%" PRIx64 "\"", s->meta.slack,
               s->meta.debug_address_bias);
        printf(",\"lookup_index\":{\"versions\":%zu,\"endpoints\":%zu,\"entries\":%zu,\"charged_bytes\":%zu,"
               "\"build_work\":%" PRIu64 "}}",
               s->version_count, s->index.coord_count, s->index.entry_count, s->charged, s->build_work);
    }
    printf("]");
}

static void json_diags(const struct xodb_jit_model *model)
{
    printf("\"diagnostics\":[");
    for (size_t i = 0; i < model->diag_count; ++i) {
        const struct xodb_jit_diag *d = &model->diags[i];
        printf("%s{\"source\":%u,\"code\":\"%s\",\"%s\":%" PRIu64 ",\"offset\":%" PRIu64 ",\"value\":\"0x%" PRIx64
               "\"}",
               i ? "," : "", d->source, xodb_jit_diag_name(d->code),
               model->sources[d->source].kind == XODB_JIT_SOURCE_PERFMAP ? "line" : "record", d->ordinal, d->offset,
               d->value);
    }
    printf("],\"diagnostics_dropped\":%" PRIu64, model->diags_dropped);
}

/* Derived line evidence: greatest declared entry address <= lookup pc,
 * through the move chain (line_base/line_delta, precomputed when the
 * versions were built). Scans one DEBUG_INFO record's entries. */
static void json_line(const struct xodb_jit_model *model, const struct xodb_jit_version *v, uint64_t pc)
{
    if (!v->line_base) {
        printf("null");
        return;
    }
    const struct xodb_jit_version *base = &model->versions[v->line_base - 1];
    uint64_t delta = v->line_delta;
    uint64_t lookup = pc - delta, bias = model->sources[base->source].meta.debug_address_bias;
    const struct xodb_jit_debug_entry *best = NULL;
    for (uint32_t i = 0; i < base->debug_count; ++i) {
        const struct xodb_jit_debug_entry *e = &model->debug[base->debug_first + i];
        if (e->in_range && e->address - bias <= lookup && (!best || e->address >= best->address))
            best = e;
    }
    if (!best) {
        printf("null");
        return;
    }
    printf("{\"derived\":true,\"method\":\"greatest_declared_entry_le_lookup_pc\",\"file\":");
    json_string(model->sources[base->source].bytes + best->file_offset, best->file_len);
    printf(",\"line\":%u,\"discriminator\":%u,\"entry_address\":\"0x%" PRIx64 "\",\"declared_address_bias\":\"0x%" PRIx64
           "\",\"debug_record\":%" PRIu64 ",\"via_version\":%u,\"move_delta\":\"0x%" PRIx64
           "\",\"meaning\":\"producer-declared code address to source line; not a variable or bytecode location\"}",
           best->line, best->discriminator, best->address, bias, base->debug_record_ordinal, base->id, delta);
}

static void json_result(const struct xodb_jit_model *model, const struct xodb_jit_result *r,
                        const struct xodb_jit_control *c, uint64_t pc)
{
    printf("{\"outcome\":\"%s\",\"reasons\":", xodb_jit_outcome_name(r->outcome));
    json_reasons(r->reasons);
    printf(",\"total_candidates\":%zu,\"total_exact\":%s,\"work\":%" PRIu64 ",\"stop\":\"%s\",\"candidates\":[",
           r->total, r->total_exact ? "true" : "false", c->work,
           c->stop == XODB_JIT_STOP_WORK ? "work_limit" : c->stop == XODB_JIT_STOP_CANCELLED ? "cancelled" : "none");
    for (size_t i = 0; i < r->count; ++i) {
        const struct xodb_jit_candidate *c = &r->candidates[i];
        const struct xodb_jit_version *v = &model->versions[c->version - 1];
        printf("%s{\"state\":\"%s\",\"reasons\":", i ? "," : "", c->state == XODB_JIT_C_LIVE ? "live" : "possible");
        json_reasons(c->reasons);
        printf(",\"code\":");
        json_version(model, v);
        printf(",\"source_line\":");
        json_line(model, v, pc);
        printf("}");
    }
    printf("]}");
}

/* ---- native mapping labels from a /proc/PID/maps snapshot --------------- */

struct native_map {
    uint64_t start, end, offset;
    char perms[5];
    char path[512];
};

static struct native_map *maps;
static size_t map_count;

static void load_maps(const char *path)
{
    FILE *f = fopen(path, "re");
    if (!f) {
        fprintf(stderr, "xodb-jitmap: %s: %s\n", path, strerror(errno));
        exit(2);
    }
    char line[4096];
    while (map_count < 65536 && fgets(line, sizeof line, f)) {
        struct native_map m = {0};
        unsigned long long s, e, o, ino;
        int used = 0;
        if (sscanf(line, "%llx-%llx %4s %llx %*x:%*x %llu %n", &s, &e, m.perms, &o, &ino, &used) < 5)
            continue;
        m.start = s;
        m.end = e;
        m.offset = o;
        snprintf(m.path, sizeof m.path, "%s", line + used);
        m.path[strcspn(m.path, "\n")] = 0;
        struct native_map *grown = realloc(maps, (map_count + 1) * sizeof *maps);
        if (!grown)
            exit(2);
        maps = grown;
        maps[map_count++] = m;
    }
    fclose(f);
}

static const struct native_map *find_map(uint64_t pc)
{
    for (size_t i = 0; i < map_count; ++i)
        if (pc >= maps[i].start && pc < maps[i].end)
            return &maps[i];
    return NULL;
}

/* ---- commands ----------------------------------------------------------- */

static void load_sources(struct xodb_jit_model *model)
{
    for (int i = 0; i < input_count; ++i) {
        struct input *in = &inputs[i];
        in->bytes = slurp(in->path, &in->len);
        sha256_hex(in->bytes, in->len, in->sha);
        struct xodb_jit_source_meta m = in->meta;
        m.artifact_sha256 = in->sha;
        m.label = in->path;
        struct xodb_jit_control c = {0};
        int index, e = in->kind == XODB_JIT_SOURCE_JITDUMP
                           ? xodb_jit_add_jitdump_ctl(model, &m, in->bytes, in->len, &c, &index)
                           : xodb_jit_add_perfmap_ctl(model, &m, in->bytes, in->len, &c, &index);
        if (e) {
            fprintf(stderr, "xodb-jitmap: %s: %s%s\n", in->path, xodb_jit_error_name(e),
                    index >= 0 ? " (source kept as partial)" : "");
            if (index < 0) {
                printf("{\"format\":\"" FORMAT "\",\"error\":\"%s\",\"path\":", xodb_jit_error_name(e));
                json_text(in->path);
                printf(",\"sha256\":\"%s\",\"work\":%" PRIu64 ",\"memory_peak\":%zu}\n", in->sha, c.work,
                       c.memory_peak);
                exit(3);
            }
        }
        free(in->bytes);
        in->bytes = NULL;
    }
}

static struct xodb_jit_query query_for(uint64_t address, int has_time, uint64_t time)
{
    struct xodb_jit_query q = base_query;
    if (!query_identity_set)
        q.process = inputs[0].meta.process;
    if (!query_clock_set)
        q.clock = inputs[0].meta.clock;
    q.address = address;
    q.has_time = has_time;
    q.time = time;
    return q;
}

static void header(const char *command, const struct xodb_jit_model *model)
{
    printf("{\"format\":\"" FORMAT "\",\"model\":\"" XODB_JIT_MODEL_VERSION "\",\"command\":\"%s\",", command);
    json_sources(model);
    printf(",");
}

static int cmd_decode(struct xodb_jit_model *model)
{
    header("decode", model);
    printf("\"versions\":[");
    for (size_t i = 0; i < model->version_count; ++i) {
        printf(i ? ",\n" : "\n");
        json_version(model, &model->versions[i]);
    }
    printf("],\"debug_entries\":%zu,\"unwind_records\":%zu,", model->debug_count, model->unwind_count);
    json_diags(model);
    printf("}\n");
    return 0;
}

static int cmd_resolve(struct xodb_jit_model *model)
{
    header("resolve", model);
    struct xodb_jit_query q0 = query_for(0, 0, 0);
    printf("\"query_process\":");
    json_process(&q0.process);
    printf(",\"query_clock\":");
    json_clock(&q0.clock);
    printf(",\"results\":[");
    for (int i = 0; i < at_count; ++i) {
        char spec[128];
        snprintf(spec, sizeof spec, "%s", at_specs[i]);
        char *at = strchr(spec, '@');
        if (at)
            *at++ = 0;
        struct xodb_jit_query q = query_for(number(spec), at != NULL, at ? number(at) : 0);
        struct xodb_jit_result r;
        struct xodb_jit_control c = {0};
        int e = xodb_jit_resolve_ctl(model, &q, &c, &r);
        if (e && e != XODB_JIT_E_WORK && e != XODB_JIT_E_CANCELLED)
            return 2;
        printf("%s\n{\"address\":\"0x%" PRIx64 "\",\"time\":", i ? "," : "", q.address);
        if (q.has_time)
            printf("\"%" PRIu64 "\"", q.time);
        else
            printf("null");
        printf(",\"result\":");
        json_result(model, &r, &c, q.address);
        printf("}");
    }
    printf("]}\n");
    return 0;
}

static int cmd_stack(struct xodb_jit_model *model)
{
    if (maps_path)
        load_maps(maps_path);
    header("stack", model);
    struct xodb_jit_query q0 = query_for(0, stack_has_time, stack_time);
    printf("\"observation\":{\"process\":");
    json_process(&q0.process);
    printf(",\"clock\":");
    json_clock(&q0.clock);
    printf(",\"time\":");
    if (stack_has_time)
        printf("\"%" PRIu64 "\"", stack_time);
    else
        printf("null");
    printf(",\"native_maps_snapshot\":");
    json_text(maps_path);
    printf("},\n\"physical_frames\":[");
    for (int i = 0; i < pc_count; ++i) {
        /* Every walked PC is a return address: attribute pc - 1, keep raw pc. */
        uint64_t lookup = pcs[i] ? pcs[i] - 1 : 0;
        struct xodb_jit_query q = query_for(lookup, stack_has_time, stack_time);
        struct xodb_jit_result r;
        struct xodb_jit_control c = {0};
        int e = xodb_jit_resolve_ctl(model, &q, &c, &r);
        if (e && e != XODB_JIT_E_WORK && e != XODB_JIT_E_CANCELLED)
            return 2;
        const char *kind = "unknown";
        const struct native_map *m = find_map(pcs[i]);
        if (r.outcome == XODB_JIT_RESOLVED || r.outcome == XODB_JIT_UNVERIFIED)
            kind = "jit";
        else if (r.outcome == XODB_JIT_AMBIGUOUS)
            kind = "jit_ambiguous";
        else if (r.outcome == XODB_JIT_NO_MATCH && m && m->path[0] && m->path[0] != '[')
            kind = "native";
        printf("%s\n{\"order\":%d,\"raw_pc\":\"0x%" PRIx64 "\",\"lookup_pc\":\"0x%" PRIx64
               "\",\"pc_role\":\"return_address\",\"kind\":\"%s\",\"jit\":",
               i ? "," : "", i, pcs[i], lookup, kind);
        json_result(model, &r, &c, lookup);
        printf(",\"native_mapping\":");
        if (m) {
            printf("{\"start\":\"0x%" PRIx64 "\",\"end\":\"0x%" PRIx64 "\",\"perms\":\"%s\",\"path\":", m->start, m->end,
                   m->perms);
            json_text(m->path[0] ? m->path : NULL);
            printf(",\"file_offset\":\"0x%" PRIx64 "\",\"note\":\"maps snapshot label; not symbolized\"}",
                   pcs[i] - m->start + m->offset);
        } else {
            printf("null");
        }
        printf("}");
    }
    printf("],\n\"logical_frames\":");
    if (logical_text) {
        printf("{\"producer\":\"declared by caller (fixture toy runtime report)\",\"frames\":[");
        const char *p = logical_text;
        int first = 1;
        while (*p) {
            size_t n = strcspn(p, ">");
            printf("%s", first ? "" : ",");
            json_string((const uint8_t *)p, n);
            first = 0;
            p += n;
            if (*p)
                p++;
        }
        printf("],\"order\":\"outermost_first\",\"bridge\":null,\"note\":\"no bridge observation; logical frames are "
               "not interleaved with physical frames\"}");
    } else {
        printf("null");
    }
    printf("}\n");
    return 0;
}

int main(int argc, char **argv)
{
    if (argc < 2)
        usage();
    const char *command = argv[1];
    memset(&meta, 0, sizeof meta);
    xodb_jit_limits_default(&limits);
    for (int i = 2; i < argc; ++i) {
        const char *a = argv[i];
        const char *v = i + 1 < argc ? argv[i + 1] : NULL;
#define TAKE()            \
    do {                  \
        if (!v)           \
            usage();      \
        ++i;              \
    } while (0)
        if (!strcmp(a, "--jitdump") || !strcmp(a, "--perfmap")) {
            TAKE();
            if (input_count == MAX_SOURCES)
                usage();
            inputs[input_count].kind = a[2] == 'j' ? XODB_JIT_SOURCE_JITDUMP : XODB_JIT_SOURCE_PERFMAP;
            inputs[input_count].meta = meta;
            inputs[input_count++].path = v;
        } else if (!strcmp(a, "--truth")) {
            TAKE();
            memset(&meta, 0, sizeof meta);
            read_truth(v);
        } else if (!strcmp(a, "--pid")) {
            TAKE();
            meta.process.pid = (uint32_t)number(v);
        } else if (!strcmp(a, "--start-ticks")) {
            TAKE();
            meta.process.start_ticks = number(v);
            meta.process.known = 1;
        } else if (!strcmp(a, "--boot-id")) {
            TAKE();
            hex_bytes(v, meta.process.boot_id, 16);
        } else if (!strcmp(a, "--unknown-identity")) {
            meta.process.known = 0;
        } else if (!strcmp(a, "--clock")) {
            TAKE();
            meta.clock.kind = clock_kind(v);
        } else if (!strcmp(a, "--clock-scope")) {
            TAKE();
            hex_bytes(v, meta.clock.scope, 16);
            meta.clock.scope_known = 1;
        } else if (!strcmp(a, "--no-coverage-end")) {
            meta.has_coverage_end = 0;
        } else if (!strcmp(a, "--debug-address-bias")) {
            TAKE();
            meta.debug_address_bias = number(v);
        } else if (!strcmp(a, "--header-time-in-clock")) {
            meta.header_time_in_clock = 1;
        } else if (!strcmp(a, "--slack")) {
            TAKE();
            meta.slack = number(v);
        } else if (!strcmp(a, "--coverage-end")) {
            TAKE();
            meta.has_coverage_end = 1;
            meta.coverage_end = number(v);
        } else if (!strcmp(a, "--map-offset")) {
            TAKE();
            meta.map.method = XODB_JIT_MAP_OFFSET;
            meta.map.offset = signed_number(v);
            meta.map.measured_by = "declared on command line";
            if (!meta.map.target.kind)
                meta.map.target.kind = XODB_JIT_CLOCK_MONOTONIC;
        } else if (!strcmp(a, "--map-uncertainty")) {
            TAKE();
            meta.map.uncertainty = number(v);
        } else if (!strcmp(a, "--map-target-clock")) {
            TAKE();
            meta.map.target.kind = clock_kind(v);
        } else if (!strcmp(a, "--map-target-scope")) {
            TAKE();
            hex_bytes(v, meta.map.target.scope, 16);
            meta.map.target.scope_known = 1;
        } else if (!strcmp(a, "--q-pid")) {
            TAKE();
            if (!query_identity_set)
                base_query.process = meta.process;
            base_query.process.pid = (uint32_t)number(v);
            query_identity_set = 1;
        } else if (!strcmp(a, "--q-start-ticks")) {
            TAKE();
            if (!query_identity_set)
                base_query.process = meta.process;
            base_query.process.start_ticks = number(v);
            base_query.process.known = 1;
            query_identity_set = 1;
        } else if (!strcmp(a, "--q-boot-id")) {
            TAKE();
            if (!query_identity_set)
                base_query.process = meta.process;
            hex_bytes(v, base_query.process.boot_id, 16);
            query_identity_set = 1;
        } else if (!strcmp(a, "--q-unknown-identity")) {
            if (!query_identity_set)
                base_query.process = meta.process;
            base_query.process.known = 0;
            query_identity_set = 1;
        } else if (!strcmp(a, "--q-clock")) {
            TAKE();
            if (!query_clock_set)
                base_query.clock = meta.clock;
            base_query.clock.kind = clock_kind(v);
            query_clock_set = 1;
        } else if (!strcmp(a, "--q-clock-scope")) {
            TAKE();
            if (!query_clock_set)
                base_query.clock = meta.clock;
            hex_bytes(v, base_query.clock.scope, 16);
            base_query.clock.scope_known = 1;
            query_clock_set = 1;
        } else if (!strcmp(a, "--at")) {
            TAKE();
            if (at_count == MAX_AT)
                usage();
            at_specs[at_count++] = v;
        } else if (!strcmp(a, "--time")) {
            TAKE();
            stack_has_time = 1;
            stack_time = number(v);
        } else if (!strcmp(a, "--pcs")) {
            TAKE();
            char buf[4096];
            snprintf(buf, sizeof buf, "%s", v);
            for (char *save, *t = strtok_r(buf, ",", &save); t && pc_count < MAX_PCS; t = strtok_r(NULL, ",", &save))
                pcs[pc_count++] = number(t);
        } else if (!strcmp(a, "--prepare-work-limit")) {
            TAKE();
            limits.max_prepare_work = number(v);
        } else if (!strcmp(a, "--query-work-limit")) {
            TAKE();
            limits.max_query_work = number(v);
        } else if (!strcmp(a, "--max-versions")) {
            TAKE();
            limits.max_versions = number(v);
        } else if (!strcmp(a, "--max-memory")) {
            TAKE();
            limits.max_memory_bytes = number(v);
        } else if (!strcmp(a, "--code")) {
            show_code = 1;
        } else if (!strcmp(a, "--maps")) {
            TAKE();
            maps_path = v;
        } else if (!strcmp(a, "--logical")) {
            TAKE();
            logical_text = v;
        } else {
            usage();
        }
    }
    if (!input_count)
        usage();
    struct xodb_jit_model model;
    xodb_jit_model_init(&model, &limits);
    load_sources(&model);
    int rc;
    if (!strcmp(command, "decode"))
        rc = cmd_decode(&model);
    else if (!strcmp(command, "resolve"))
        rc = cmd_resolve(&model);
    else if (!strcmp(command, "stack"))
        rc = cmd_stack(&model);
    else
        usage(), rc = 2;
    xodb_jit_model_free(&model);
    free(maps);
    return rc;
}
