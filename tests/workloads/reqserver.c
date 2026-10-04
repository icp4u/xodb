/* T04 server-like request workload.
 *
 * Open-loop clients generate requests on a seeded schedule. Workers take them
 * from a bounded queue, do CPU work, then update shared state under one of
 * --shards locks. Three knobs produce three distinct problems:
 *
 *   --work ITER    CPU per request outside any lock (service time)
 *   --rate, --workers, --queue   load against capacity (queue pressure, drops)
 *   --hold ITER, --shards N      work done while holding a lock (contention)
 *
 * Each request's latency is split into queue wait, lock wait, and service
 * time, measured inside the program. That split is the ground truth a
 * profiler's explanation can be checked against. Latency is counted from the
 * scheduled send time, so a slow server cannot hide its own backlog.
 *
 * --transport queue keeps requests in process (mutex + condition variable).
 * --transport socket sends them through a local AF_UNIX SOCK_SEQPACKET pair,
 * so queueing happens in the kernel and shows up as syscalls and wakeups.
 */
#define _GNU_SOURCE
#include <math.h>
#include <stdatomic.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include "workload.h"

static struct {
    uint64_t workers, clients, rate, seconds, work, hold, shards, queue, seed, max_seconds;
    int use_socket, constant_arrival;
} cfg = {.workers = 4, .clients = 4, .rate = 4000, .seconds = 4, .work = 100000, .hold = 2000, .shards = 16, .queue = 1024, .seed = 1, .max_seconds = 60};

struct request {
    uint64_t id, key, scheduled_ns;
};
struct sample {
    uint32_t total_us, queue_us, lock_us, service_us;
};
struct shard {
    pthread_mutex_t lock;
    uint64_t value, acquisitions;
} __attribute__((aligned(64)));
struct worker_state {
    pthread_t thread;
    struct sample *samples;
    size_t count, capacity;
} __attribute__((aligned(64)));

static struct request *ring;
static uint64_t ring_head, ring_tail, max_depth;
static int closed;
static pthread_mutex_t ring_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t ring_ready = PTHREAD_COND_INITIALIZER;
static int sockets[2];
static struct shard *shards;
static _Atomic uint64_t sent, dropped;

/* Application events: attach by symbol or by USDT probe xodb:request_begin / request_end. */
__attribute__((noinline)) static void request_begin(uint64_t id) {
    PROBE1(request_begin, id);
    __asm__ volatile("");
}
__attribute__((noinline)) static void request_end(uint64_t id, uint64_t total_us) {
    PROBE2(request_end, id, total_us);
    __asm__ volatile("");
}

/* Service time: CPU work with no lock held. */
__attribute__((noinline)) static uint64_t handle_request(const struct request *r) { return burn(cfg.work, r->key); }

/* Contention point: --hold iterations run inside the shard's lock. With one
 * shard and a long hold, every worker queues here. Returns nanoseconds spent waiting. */
__attribute__((noinline)) static uint64_t update_shared(const struct request *r, uint64_t result) {
    struct shard *s = &shards[r->key % cfg.shards];
    uint64_t before = now_ns();
    pthread_mutex_lock(&s->lock);
    uint64_t waited = now_ns() - before;
    s->value += burn(cfg.hold, result);
    s->acquisitions++;
    pthread_mutex_unlock(&s->lock);
    return waited;
}

__attribute__((noinline)) static int submit(const struct request *r) {
    if (cfg.use_socket) return send(sockets[0], r, sizeof *r, MSG_DONTWAIT) == (ssize_t)sizeof *r;
    int accepted = 0;
    pthread_mutex_lock(&ring_lock);
    if (ring_tail - ring_head < cfg.queue) {
        ring[ring_tail++ % cfg.queue] = *r;
        if (ring_tail - ring_head > max_depth) max_depth = ring_tail - ring_head;
        accepted = 1;
        pthread_cond_signal(&ring_ready);
    }
    pthread_mutex_unlock(&ring_lock);
    return accepted;
}
/* Workers idle here when there is nothing to do. */
__attribute__((noinline)) static int take(struct request *r) {
    if (cfg.use_socket) return recv(sockets[1], r, sizeof *r, 0) == (ssize_t)sizeof *r;
    pthread_mutex_lock(&ring_lock);
    while (ring_head == ring_tail && !closed) pthread_cond_wait(&ring_ready, &ring_lock);
    int got = ring_head != ring_tail;
    if (got) *r = ring[ring_head++ % cfg.queue];
    pthread_mutex_unlock(&ring_lock);
    return got;
}

static void *worker(void *arg) {
    struct worker_state *w = arg;
    struct request r;
    while (take(&r)) {
        uint64_t dequeued = now_ns();
        request_begin(r.id);
        uint64_t result = handle_request(&r);
        uint64_t lock_ns = update_shared(&r, result);
        uint64_t done = now_ns();
        request_end(r.id, (done - r.scheduled_ns) / 1000);
        if (w->count < w->capacity) {
            uint64_t queue_ns = dequeued > r.scheduled_ns ? dequeued - r.scheduled_ns : 0;
            w->samples[w->count++] = (struct sample){(uint32_t)((done - r.scheduled_ns) / 1000), (uint32_t)(queue_ns / 1000), (uint32_t)(lock_ns / 1000), (uint32_t)((done - dequeued - lock_ns) / 1000)};
        }
    }
    return NULL;
}

/* Open loop: the schedule does not depend on how fast the server answers. */
static void *client(void *arg) {
    uint64_t index = (uint64_t)(intptr_t)arg, rng = cfg.seed * 1000003 + index;
    char name[16];
    snprintf(name, sizeof name, "client-%d", (int)index);
    pthread_setname_np(pthread_self(), name);
    prctl(PR_SET_TIMERSLACK, 1); /* the default 50 us slack would delay every scheduled send */
    double mean_ns = 1e9 * (double)cfg.clients / (double)cfg.rate;
    uint64_t start = now_ns(), end = start + cfg.seconds * 1000000000ull, next = start, n = 0;
    while (!stop_requested) {
        double u = ((double)(rng_next(&rng) >> 11) + 1.0) / 9007199254740993.0;
        next += (uint64_t)(cfg.constant_arrival ? mean_ns : -log(u) * mean_ns);
        if (next >= end) break;
        sleep_until_ns(next);
        struct request r = {.id = index << 40 | n++, .key = rng_next(&rng), .scheduled_ns = next};
        atomic_fetch_add(&sent, 1);
        if (!submit(&r)) atomic_fetch_add(&dropped, 1);
    }
    return NULL;
}

static void usage(void) {
    fprintf(stderr,
            "usage: reqserver [--workers N] [--clients N] [--rate REQ_PER_S] [--seconds S] [--work ITER]\n"
            "  [--hold ITER] [--shards N] [--queue N] [--transport queue|socket] [--arrival poisson|constant]\n"
            "  [--seed N] [--max-seconds S]\n");
    exit(2);
}
static void report(const char *name, uint32_t *v, size_t n, double total_mean) {
    double sum = 0;
    for (size_t i = 0; i < n; i++) sum += v[i];
    double mean = n ? sum / (double)n : 0;
    uint32_t p50 = quantile(v, n, 0.50), p95 = quantile(v, n, 0.95), p99 = quantile(v, n, 0.99);
    printf("\"%s\":{\"mean\":%.0f,\"p50\":%u,\"p95\":%u,\"p99\":%u,\"max\":%u,\"share\":%.3f},\n", name, mean, p50, p95, p99, n ? v[n - 1] : 0, total_mean > 0 ? mean / total_mean : 1.0);
}
int main(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i], *v = i + 1 < argc ? argv[i + 1] : NULL;
        if (!v) usage();
        i++;
        if (!strcmp(a, "--workers")) cfg.workers = arg_int(a, v);
        else if (!strcmp(a, "--clients")) cfg.clients = arg_int(a, v);
        else if (!strcmp(a, "--rate")) cfg.rate = arg_int(a, v);
        else if (!strcmp(a, "--seconds")) cfg.seconds = arg_int(a, v);
        else if (!strcmp(a, "--work")) cfg.work = arg_int(a, v);
        else if (!strcmp(a, "--hold")) cfg.hold = arg_int(a, v);
        else if (!strcmp(a, "--shards")) cfg.shards = arg_int(a, v);
        else if (!strcmp(a, "--queue")) cfg.queue = arg_int(a, v);
        else if (!strcmp(a, "--seed")) cfg.seed = arg_int(a, v);
        else if (!strcmp(a, "--max-seconds")) cfg.max_seconds = arg_int(a, v);
        else if (!strcmp(a, "--transport") && !strcmp(v, "socket")) cfg.use_socket = 1;
        else if (!strcmp(a, "--transport") && !strcmp(v, "queue")) cfg.use_socket = 0;
        else if (!strcmp(a, "--arrival") && !strcmp(v, "constant")) cfg.constant_arrival = 1;
        else if (!strcmp(a, "--arrival") && !strcmp(v, "poisson")) cfg.constant_arrival = 0;
        else usage();
    }
    if (!cfg.workers || cfg.workers > 256 || !cfg.clients || cfg.clients > 256 || !cfg.rate || !cfg.seconds || !cfg.shards || !cfg.queue) usage();
    install_stop((unsigned)cfg.max_seconds);
    pthread_setname_np(pthread_self(), "main");
    ring = calloc(cfg.queue, sizeof *ring);
    shards = aligned_alloc(64, cfg.shards * sizeof *shards);
    for (uint64_t i = 0; i < cfg.shards; i++) {
        pthread_mutex_init(&shards[i].lock, NULL);
        shards[i].value = shards[i].acquisitions = 0;
    }
    if (cfg.use_socket) {
        if (socketpair(AF_UNIX, SOCK_SEQPACKET, 0, sockets)) return 1;
        /* The kernel's send buffer is the queue; its capacity in requests is approximate. */
        int bytes = (int)(cfg.queue * 256);
        setsockopt(sockets[0], SOL_SOCKET, SO_SNDBUF, &bytes, sizeof bytes);
    }
    size_t capacity = cfg.rate * cfg.seconds * 2 / cfg.workers + 4096;
    struct worker_state *workers = aligned_alloc(64, cfg.workers * sizeof *workers);
    pthread_t *clients = calloc(cfg.clients, sizeof *clients);
    for (uint64_t i = 0; i < cfg.workers; i++) {
        workers[i].samples = malloc(capacity * sizeof(struct sample));
        workers[i].count = 0;
        workers[i].capacity = capacity;
        pthread_create(&workers[i].thread, NULL, worker, &workers[i]);
        char name[16];
        snprintf(name, sizeof name, "worker-%d", (int)i);
        pthread_setname_np(workers[i].thread, name);
    }
    uint64_t start = now_ns();
    for (uint64_t i = 0; i < cfg.clients; i++) pthread_create(&clients[i], NULL, client, (void *)(intptr_t)i);
    for (uint64_t i = 0; i < cfg.clients; i++) pthread_join(clients[i], NULL);
    /* No more requests: let the workers drain what is queued, then stop. */
    if (cfg.use_socket) shutdown(sockets[0], SHUT_WR);
    pthread_mutex_lock(&ring_lock);
    closed = 1;
    pthread_cond_broadcast(&ring_ready);
    pthread_mutex_unlock(&ring_lock);
    size_t completed = 0;
    for (uint64_t i = 0; i < cfg.workers; i++) {
        pthread_join(workers[i].thread, NULL);
        completed += workers[i].count;
    }
    double elapsed = (double)(now_ns() - start) / 1e9;

    uint32_t *column = malloc((completed + 1) * sizeof *column);
    double total_sum = 0;
    for (uint64_t i = 0; i < cfg.workers; i++)
        for (size_t j = 0; j < workers[i].count; j++) total_sum += workers[i].samples[j].total_us;
    double total_mean = completed ? total_sum / (double)completed : 0;
    uint64_t checksum = 0, busiest = 0;
    for (uint64_t i = 0; i < cfg.shards; i++) {
        checksum += shards[i].value;
        if (shards[i].acquisitions > busiest) busiest = shards[i].acquisitions;
    }
    printf("{\"workload\":\"reqserver\",\"transport\":\"%s\",\"arrival\":\"%s\",\"seed\":%llu,\"workers\":%llu,\"clients\":%llu,\"rate\":%llu,\"seconds\":%llu,\"work\":%llu,\"hold\":%llu,\"shards\":%llu,\"queue\":%llu,\n", cfg.use_socket ? "socket" : "queue", cfg.constant_arrival ? "constant" : "poisson", (unsigned long long)cfg.seed, (unsigned long long)cfg.workers, (unsigned long long)cfg.clients, (unsigned long long)cfg.rate, (unsigned long long)cfg.seconds, (unsigned long long)cfg.work, (unsigned long long)cfg.hold, (unsigned long long)cfg.shards, (unsigned long long)cfg.queue);
    printf("\"sent\":%llu,\"completed\":%zu,\"dropped\":%llu,\"elapsed_s\":%.2f,\"throughput\":%.0f,\"max_queue_depth\":%lld,\"busiest_shard_share\":%.3f,\n", (unsigned long long)atomic_load(&sent), completed, (unsigned long long)atomic_load(&dropped), elapsed, (double)completed / elapsed, cfg.use_socket ? -1ll : (long long)max_depth, completed ? (double)busiest / (double)completed : 0);
    const char *names[] = {"latency_us", "queue_wait_us", "lock_wait_us", "service_us"};
    for (int field = 0; field < 4; field++) {
        size_t n = 0;
        for (uint64_t i = 0; i < cfg.workers; i++)
            for (size_t j = 0; j < workers[i].count; j++) column[n++] = ((uint32_t *)&workers[i].samples[j])[field];
        report(names[field], column, n, total_mean);
    }
    print_rusage();
    printf("\"interrupted\":%s,\"checksum\":%llu}\n", stop_requested ? "true" : "false", (unsigned long long)checksum);
    return 0;
}
