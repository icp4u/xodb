// Scaling table for the bounded resolver. For each adversarial family and
// size, a forked child builds the jitdump in memory, prepares it, runs a fixed
// query set over the hot address, and prints one JSON object per line:
// input sha256, preparation work/time/index size/accounted peak/RSS, per-query
// work and time, candidate totals/truncation, the declared query bound, the
// exhaustive oracle (old nested scan) agreement and visit count for small n,
// and preparation cancellation latency. Writes each input to DIR when given.
//   jitmap-scaling [--write DIR] [--oracle-max N] [--sizes a,b,..] [--families f,g]
#define _GNU_SOURCE
#include "jitmap.h"
#include "adversary.h"
#include "oracle.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

/* ---- SHA-256 (FIPS 180-4) ----------------------------------------------- */

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

static void sha_block(uint32_t h[8], const uint8_t *p)
{
    uint32_t w[64], v[8];
    for (int i = 0; i < 16; ++i)
        w[i] = (uint32_t)p[4 * i] << 24 | (uint32_t)p[4 * i + 1] << 16 | (uint32_t)p[4 * i + 2] << 8 | p[4 * i + 3];
    for (int i = 16; i < 64; ++i)
        w[i] = w[i - 16] + (ROR(w[i - 15], 7) ^ ROR(w[i - 15], 18) ^ (w[i - 15] >> 3)) + w[i - 7] +
               (ROR(w[i - 2], 17) ^ ROR(w[i - 2], 19) ^ (w[i - 2] >> 10));
    memcpy(v, h, sizeof v);
    for (int i = 0; i < 64; ++i) {
        uint32_t t1 = v[7] + (ROR(v[4], 6) ^ ROR(v[4], 11) ^ ROR(v[4], 25)) + ((v[4] & v[5]) ^ (~v[4] & v[6])) + K[i] + w[i];
        uint32_t t2 = (ROR(v[0], 2) ^ ROR(v[0], 13) ^ ROR(v[0], 22)) + ((v[0] & v[1]) ^ (v[0] & v[2]) ^ (v[1] & v[2]));
        memmove(v + 1, v, 7 * sizeof *v);
        v[4] += t1;
        v[0] = t1 + t2;
    }
    for (int i = 0; i < 8; ++i)
        h[i] += v[i];
}

static void sha256_hex(const uint8_t *p, size_t n, char out[65])
{
    uint32_t h[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
    uint64_t bits = (uint64_t)n * 8;
    for (; n >= 64; p += 64, n -= 64)
        sha_block(h, p);
    uint8_t tail[128] = {0};
    memcpy(tail, p, n);
    tail[n] = 0x80;
    size_t len = n + 9 <= 64 ? 64 : 128;
    for (int i = 0; i < 8; ++i)
        tail[len - 1 - i] = (uint8_t)(bits >> (8 * i));
    sha_block(h, tail);
    if (len == 128)
        sha_block(h, tail + 64);
    for (int i = 0; i < 8; ++i)
        snprintf(out + 8 * i, 9, "%08x", h[i]);
}

/* ---- run ---------------------------------------------------------------- */

static const struct xodb_jit_clock mono = {XODB_JIT_CLOCK_MONOTONIC, 1, {1, 2, 3}};
static const struct xodb_jit_clock mapped = {XODB_JIT_CLOCK_MONOTONIC, 1, {7, 7, 7}};

static double now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

static uint64_t ceil_log2(uint64_t n)
{
    uint64_t k = 0;
    while (k < 64 && (1ull << k) < n)
        k++;
    return k;
}

struct canceller {
    struct xodb_jit_cancel *token;
    double delay, requested_at;
};

static void *cancel_later(void *arg)
{
    struct canceller *c = arg;
    double until = now() + c->delay;
    while (now() < until)
        ;
    c->requested_at = now();
    xodb_jit_cancel_request(c->token);
    return NULL;
}

static void meta_for(enum adv_family f, uint32_t n, struct xodb_jit_source_meta *meta)
{
    memset(meta, 0, sizeof *meta);
    meta->process = (struct xodb_jit_process){ADV_PID, 1, 1, {0xb0}};
    meta->clock = mono;
    meta->label = "scaling";
    meta->has_coverage_end = 1;
    meta->coverage_end = adv_last_time(f, n) + 100000;
    if (f == ADV_UNCERTAIN) {
        meta->slack = 25;
        meta->map = (struct xodb_jit_clock_map){XODB_JIT_MAP_OFFSET, mapped, 1000, 0, 0, 0, 40, "declared"};
    }
}

static void run(enum adv_family f, uint32_t n, const char *dir, uint32_t oracle_max)
{
    struct jb b;
    adv_build(&b, f, n);
    char sha[65];
    sha256_hex(b.bytes, b.len, sha);
    if (dir) {
        char path[4096];
        snprintf(path, sizeof path, "%s/%s-%u.dump", dir, adv_names[f], n);
        FILE *out = fopen(path, "wb");
        if (!out || fwrite(b.bytes, 1, b.len, out) != b.len || fclose(out)) {
            perror(path);
            exit(1);
        }
    }
    struct xodb_jit_source_meta meta;
    meta_for(f, n, &meta);
    struct xodb_jit_model m;
    xodb_jit_model_init(&m, NULL);
    struct xodb_jit_control c = {0};
    double t0 = now();
    int e = xodb_jit_add_jitdump_ctl(&m, &meta, b.bytes, b.len, &c, NULL);
    double prep = now() - t0;
    const struct xodb_jit_source *s = e == XODB_JIT_OK ? &m.sources[0] : NULL;
    printf("{\"family\":\"%s\",\"versions\":%u,\"input_bytes\":%zu,\"input_sha256\":\"%s\",\"add\":\"%s\"", adv_names[f],
           n, b.len, sha, xodb_jit_error_name(e));
    if (!s) {
        fflush(stdout);
        return;
    }
    uint64_t h = ceil_log2(s->index.base) + 1;
    uint64_t bound = 1 + 16 + ceil_log2(s->index.coord_count) + 1 + h * (1 + 4 * (ceil_log2(s->version_count + 1) + 1));
    printf(",\"prepare\":{\"seconds\":%.6f,\"work\":%llu,\"index_entries\":%zu,\"index_endpoints\":%zu,"
           "\"index_bytes\":%zu,\"model_memory\":%zu,\"accounted_peak\":%zu}",
           prep, (unsigned long long)c.work, s->index.entry_count, s->index.coord_count,
           s->index.coord_count * 8 + (2 * s->index.base + 1) * 4 + s->index.entry_count * 4,
           m.memory, c.memory_peak);
    /* Fixed query set: hot address at 200 times across and around the span, plus no time. */
    uint64_t hot = adv_hot(f, n), first = ADV_T0, last = adv_last_time(f, n);
    struct oracle_result o = {0};
    uint64_t worst = 0, total_work = 0, max_total = 0, oracle_visits = 0;
    int truncated = 0, agree = 0, compared = 0, outcomes[8] = {0};
    double qtime = 0;
    int queries = 0;
    for (int i = 0; i <= 200; ++i) {
        struct xodb_jit_query q = {meta.process, hot, i < 200, 0, f == ADV_UNCERTAIN && (i & 1) ? mapped : mono};
        uint64_t span = last - first + 2;
        q.time = first - 1 + span * (uint64_t)i / 199 + (q.clock.scope[0] == 7 ? 1000 : 0);
        struct xodb_jit_result r;
        struct xodb_jit_control qc = {0};
        double q0 = now();
        int qe = 0;
        for (int rep = 0; rep < 20; ++rep)
            qe |= xodb_jit_resolve_ctl(&m, &q, &qc, &r);
        qtime += (now() - q0) / 20;
        queries++;
        if (qe)
            outcomes[0]++;
        else
            outcomes[r.outcome]++;
        if (qc.work > worst)
            worst = qc.work;
        total_work += qc.work;
        if (r.total > max_total)
            max_total = r.total;
        truncated += (r.reasons & XODB_JIT_R_CANDIDATES_TRUNCATED) != 0;
        if (n <= oracle_max) {
            oracle_resolve(&m, &q, &o);
            compared++;
            agree += !oracle_compare(&r, &o);
            if (o.visits > oracle_visits)
                oracle_visits = o.visits;
        }
    }
    free(o.candidates);
    printf(",\"queries\":{\"count\":%d,\"work_max\":%llu,\"work_mean\":%.1f,\"declared_bound\":%llu,"
           "\"within_bound\":%s,\"seconds_mean\":%.9f,\"candidates_max\":%llu,\"truncated\":%d,"
           "\"outcomes\":{\"incomplete_or_error\":%d,\"resolved\":%d,\"unverified\":%d,\"ambiguous\":%d,"
           "\"no_match\":%d,\"unavailable\":%d}}",
           queries, (unsigned long long)worst, (double)total_work / queries, (unsigned long long)bound,
           worst <= bound ? "true" : "false", qtime / queries, (unsigned long long)max_total, truncated, outcomes[0],
           outcomes[1], outcomes[2], outcomes[3], outcomes[4], outcomes[5]);
    if (compared)
        printf(",\"oracle\":{\"compared\":%d,\"agree\":%d,\"old_scan_visits_max\":%llu}", compared, agree,
               (unsigned long long)oracle_visits);
    else
        printf(",\"oracle\":null,\"old_scan_visits_model\":%llu", (unsigned long long)n * (n + 1));
    xodb_jit_model_free(&m);
    /* Preparation cancellation latency: request at half the measured preparation time. */
    if (n >= 8192) {
        struct xodb_jit_cancel token;
        xodb_jit_cancel_init(&token);
        xodb_jit_model_init(&m, NULL);
        struct canceller cn = {&token, prep / 2, 0};
        pthread_t th;
        pthread_create(&th, NULL, cancel_later, &cn);
        struct xodb_jit_control cc = {0, &token, 0, 0, 0};
        int ce = xodb_jit_add_jitdump_ctl(&m, &meta, b.bytes, b.len, &cc, NULL);
        double done = now();
        pthread_join(th, NULL);
        printf(",\"cancel\":{\"result\":\"%s\",\"latency_seconds\":%.6f,\"work_at_stop\":%llu,\"rolled_back\":%s}",
               xodb_jit_error_name(ce), ce == XODB_JIT_E_CANCELLED ? done - cn.requested_at : 0.0,
               (unsigned long long)cc.work, m.source_count == 0 && m.version_count == 0 ? "true" : "false");
        xodb_jit_model_free(&m);
    }
    jb_free(&b);
    fflush(stdout);
}

int main(int argc, char **argv)
{
    const char *dir = NULL;
    uint32_t oracle_max = 2048;
    uint32_t sizes[16] = {128, 512, 2048, 8192, 32768};
    size_t nsizes = 5;
    int family_on[ADV_COUNT];
    for (int f = 0; f < ADV_COUNT; ++f)
        family_on[f] = 1;
    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--write") && i + 1 < argc) {
            dir = argv[++i];
        } else if (!strcmp(argv[i], "--oracle-max") && i + 1 < argc) {
            oracle_max = (uint32_t)strtoul(argv[++i], NULL, 0);
        } else if (!strcmp(argv[i], "--sizes") && i + 1 < argc) {
            nsizes = 0;
            for (char *save, *t = strtok_r(argv[++i], ",", &save); t && nsizes < 16; t = strtok_r(NULL, ",", &save))
                sizes[nsizes++] = (uint32_t)strtoul(t, NULL, 0);
        } else if (!strcmp(argv[i], "--families") && i + 1 < argc) {
            for (int f = 0; f < ADV_COUNT; ++f)
                family_on[f] = 0;
            for (char *save, *t = strtok_r(argv[++i], ",", &save); t; t = strtok_r(NULL, ",", &save))
                for (int f = 0; f < ADV_COUNT; ++f)
                    if (!strcmp(t, adv_names[f]))
                        family_on[f] = 1;
        } else {
            fprintf(stderr, "usage: jitmap-scaling [--write DIR] [--oracle-max N] [--sizes a,b] [--families f,g]\n");
            return 2;
        }
    }
    for (int f = 0; f < ADV_COUNT; ++f) {
        if (!family_on[f])
            continue;
        for (size_t i = 0; i < nsizes; ++i) {
            fflush(stdout);
            pid_t child = fork();
            if (child == 0) {
                run((enum adv_family)f, sizes[i], dir, oracle_max);
                _exit(0);
            }
            int status;
            struct rusage ru;
            if (child < 0 || wait4(child, &status, 0, &ru) != child || !WIFEXITED(status) || WEXITSTATUS(status)) {
                printf("{\"family\":\"%s\",\"versions\":%u,\"error\":\"child failed\"}\n", adv_names[f], sizes[i]);
                continue;
            }
            printf(",\"child_peak_rss_kib\":%ld}\n", ru.ru_maxrss);
        }
    }
    return 0;
}
