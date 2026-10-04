/* T04 frame-loop workload.
 *
 * A paced game-style loop: the main thread updates, hands jobs to a worker
 * pool, prepares a frame under a shared lock, waits for the jobs, then sleeps
 * to the next frame deadline. On chosen frames it injects ONE known stall
 * cause, selected with --stall. Each cause lives in a function named stall_*
 * marked KNOWN CAUSE, so a profile can be checked against the source.
 *
 * Everything is a function of --seed and the other options. Work is counted in
 * iterations. Output is one JSON summary on stdout and an optional per-frame CSV.
 */
#define _GNU_SOURCE
#include <semaphore.h>
#include <stdatomic.h>
#include <sys/prctl.h>
#include "workload.h"

enum cause { NONE, CPU, LOCK, JOB, ALLOC, IO };
static const char *const cause_names[] = {"none", "cpu", "lock", "job", "alloc", "io"};
/* Ground truth reported with the results: what stalls, where the time is, and which symbol is responsible. */
static const char *const cause_truth[][3] = {
    {"", "", ""},
    {"stall_cpu_hot_path", "main thread on-CPU in update", "extra computation on the main thread"},
    {"stall_lock_holder", "main thread off-CPU in render_prepare, blocked on world_lock; a worker is on-CPU holding it", "lock held across long work"},
    {"stall_long_job", "main thread off-CPU in wait_jobs; one worker on-CPU; no lock involved", "one oversized job"},
    {"stall_alloc_churn", "main thread in malloc/free and kernel page faults", "allocation burst touching fresh pages"},
    {"stall_blocking_read", "main thread off-CPU in read(); the io thread sleeps, then wakes it", "blocking wait on another thread's reply"},
};

static struct {
    uint64_t frames, workers, jobs, job_work, update_work, render_work, pace_us, budget_us, seed;
    uint64_t stall_first, stall_every, stall_work, stall_alloc_mb, stall_io_us, max_seconds;
    enum cause stall;
    const char *csv;
} cfg = {.frames = 300, .workers = 4, .jobs = 16, .job_work = 600000, .update_work = 2000000, .render_work = 500000, .pace_us = 16667, .budget_us = 16667, .seed = 1, .stall_first = 60, .stall_every = 97, .stall_work = 20000000, .stall_alloc_mb = 64, .stall_io_us = 25000, .max_seconds = 60, .stall = NONE};

struct job {
    void (*run)(struct job *);
    uint64_t iterations, seed;
};
#define QUEUE 1024
static struct job queue[QUEUE];
static unsigned head, tail, pending;
static int shutting_down;
static pthread_mutex_t queue_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t queue_ready = PTHREAD_COND_INITIALIZER, jobs_done = PTHREAD_COND_INITIALIZER;
/* Shared state: workers publish under it, the main thread reads under it. */
static pthread_mutex_t world_lock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t world;
static sem_t holder_has_lock;
static int io_request[2], io_reply[2];
static _Atomic uint64_t allocations;

/* Application events: attach by symbol (uprobe) or by USDT probe xodb:frame_begin / frame_end. */
__attribute__((noinline)) static void frame_begin(uint64_t frame) {
    PROBE1(frame_begin, frame);
    __asm__ volatile("");
}
__attribute__((noinline)) static void frame_end(uint64_t frame, uint64_t work_us) {
    PROBE2(frame_end, frame, work_us);
    __asm__ volatile("");
}

static void publish(uint64_t value) {
    pthread_mutex_lock(&world_lock);
    world += burn(2000, value);
    pthread_mutex_unlock(&world_lock);
}
static void ordinary_job(struct job *j) { publish(burn(j->iterations, j->seed)); }

/* KNOWN CAUSE (--stall job): one job is far larger than the rest. The main
 * thread waits for it in wait_jobs. No lock is held while it runs. */
__attribute__((noinline)) static void stall_long_job(struct job *j) { publish(burn(j->iterations, j->seed)); }

/* KNOWN CAUSE (--stall lock): a worker does long work while holding
 * world_lock. The main thread blocks on that lock in render_prepare. */
__attribute__((noinline)) static void stall_lock_holder(struct job *j) {
    pthread_mutex_lock(&world_lock);
    sem_post(&holder_has_lock);
    world += burn(j->iterations, j->seed);
    pthread_mutex_unlock(&world_lock);
}

/* KNOWN CAUSE (--stall cpu): extra computation on the main thread during update. */
__attribute__((noinline)) static uint64_t stall_cpu_hot_path(uint64_t iterations, uint64_t seed) { return burn(iterations, seed); }

/* KNOWN CAUSE (--stall alloc): the main thread allocates, touches, and frees
 * many blocks of 4 KiB to 1 MiB. The time goes to malloc, mmap/munmap, and
 * first-touch page faults, not to application computation. */
__attribute__((noinline)) static uint64_t stall_alloc_churn(uint64_t megabytes, uint64_t seed) {
    enum { BLOCKS = 4096 };
    static char *blocks[BLOCKS];
    uint64_t total = 0, count = 0, sum = 0;
    while (total < megabytes << 20 && count < BLOCKS) {
        size_t size = 4096 + rng_next(&seed) % ((1 << 20) - 4096);
        char *p = malloc(size);
        if (!p) break;
        for (size_t i = 0; i < size; i += 4096) p[i] = (char)i;
        sum += (unsigned char)p[size / 2];
        blocks[count++] = p;
        total += size;
    }
    for (uint64_t i = 0; i < count; i++) free(blocks[i]);
    atomic_fetch_add(&allocations, count);
    return sum;
}

/* KNOWN CAUSE (--stall io): the main thread asks the io thread for a reply
 * and blocks in read() until it arrives. The io thread sleeps first, standing
 * in for slow storage or a slow peer. */
__attribute__((noinline)) static void stall_blocking_read(void) {
    char byte = 1;
    if (write(io_request[1], &byte, 1) != 1 || read(io_reply[0], &byte, 1) != 1) stop_requested = 1;
}
static void *io_thread(void *arg) {
    (void)arg;
    pthread_setname_np(pthread_self(), "io");
    char byte;
    while (read(io_request[0], &byte, 1) == 1) {
        struct timespec ts = {(time_t)(cfg.stall_io_us / 1000000), (long)(cfg.stall_io_us % 1000000) * 1000};
        nanosleep(&ts, NULL);
        if (write(io_reply[1], &byte, 1) != 1) break;
    }
    return NULL;
}

static void *worker(void *arg) {
    char name[16];
    snprintf(name, sizeof name, "worker-%d", (int)(intptr_t)arg);
    pthread_setname_np(pthread_self(), name);
    for (;;) {
        pthread_mutex_lock(&queue_lock);
        while (head == tail && !shutting_down) pthread_cond_wait(&queue_ready, &queue_lock);
        if (head == tail) {
            pthread_mutex_unlock(&queue_lock);
            return NULL;
        }
        struct job j = queue[head++ % QUEUE];
        pthread_mutex_unlock(&queue_lock);
        j.run(&j);
        pthread_mutex_lock(&queue_lock);
        if (--pending == 0) pthread_cond_signal(&jobs_done);
        pthread_mutex_unlock(&queue_lock);
    }
}
static void dispatch(void (*run)(struct job *), uint64_t iterations, uint64_t seed) {
    pthread_mutex_lock(&queue_lock);
    queue[tail++ % QUEUE] = (struct job){run, iterations, seed};
    pending++;
    pthread_cond_signal(&queue_ready);
    pthread_mutex_unlock(&queue_lock);
}
__attribute__((noinline)) static void update(uint64_t seed, int stalled) {
    burn(cfg.update_work, seed);
    if (stalled && cfg.stall == CPU) stall_cpu_hot_path(cfg.stall_work, seed);
    if (stalled && cfg.stall == ALLOC) stall_alloc_churn(cfg.stall_alloc_mb, seed);
    if (stalled && cfg.stall == IO) stall_blocking_read();
}
__attribute__((noinline)) static void render_prepare(uint64_t seed) {
    pthread_mutex_lock(&world_lock);
    world += burn(cfg.render_work, seed);
    pthread_mutex_unlock(&world_lock);
}
__attribute__((noinline)) static void wait_jobs(void) {
    pthread_mutex_lock(&queue_lock);
    while (pending) pthread_cond_wait(&jobs_done, &queue_lock);
    pthread_mutex_unlock(&queue_lock);
}

static void usage(void) {
    fprintf(stderr,
            "usage: frameloop [--stall none|cpu|lock|job|alloc|io] [--frames N] [--workers N] [--jobs N]\n"
            "  [--job-work ITER] [--update-work ITER] [--render-work ITER] [--pace-us US] [--budget-us US]\n"
            "  [--stall-first FRAME] [--stall-every N] [--stall-work ITER] [--stall-alloc-mb MB] [--stall-io-us US]\n"
            "  [--seed N] [--max-seconds S] [--csv FILE]\n");
    exit(2);
}
int main(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i], *v = i + 1 < argc ? argv[i + 1] : NULL;
        if (!v) usage();
        i++;
        if (!strcmp(a, "--stall")) {
            int found = -1;
            for (int c = 0; c < 6; c++) if (!strcmp(v, cause_names[c])) found = c;
            if (found < 0) usage();
            cfg.stall = (enum cause)found;
        } else if (!strcmp(a, "--frames")) cfg.frames = arg_int(a, v);
        else if (!strcmp(a, "--workers")) cfg.workers = arg_int(a, v);
        else if (!strcmp(a, "--jobs")) cfg.jobs = arg_int(a, v);
        else if (!strcmp(a, "--job-work")) cfg.job_work = arg_int(a, v);
        else if (!strcmp(a, "--update-work")) cfg.update_work = arg_int(a, v);
        else if (!strcmp(a, "--render-work")) cfg.render_work = arg_int(a, v);
        else if (!strcmp(a, "--pace-us")) cfg.pace_us = arg_int(a, v);
        else if (!strcmp(a, "--budget-us")) cfg.budget_us = arg_int(a, v);
        else if (!strcmp(a, "--stall-first")) cfg.stall_first = arg_int(a, v);
        else if (!strcmp(a, "--stall-every")) cfg.stall_every = arg_int(a, v);
        else if (!strcmp(a, "--stall-work")) cfg.stall_work = arg_int(a, v);
        else if (!strcmp(a, "--stall-alloc-mb")) cfg.stall_alloc_mb = arg_int(a, v);
        else if (!strcmp(a, "--stall-io-us")) cfg.stall_io_us = arg_int(a, v);
        else if (!strcmp(a, "--seed")) cfg.seed = arg_int(a, v);
        else if (!strcmp(a, "--max-seconds")) cfg.max_seconds = arg_int(a, v);
        else if (!strcmp(a, "--csv")) cfg.csv = v;
        else usage();
    }
    if (cfg.workers < 1 || cfg.workers > 256 || cfg.jobs + 1 > QUEUE || cfg.stall_every < 1 || cfg.frames < 1) usage();
    install_stop((unsigned)cfg.max_seconds);
    pthread_setname_np(pthread_self(), "main");
    prctl(PR_SET_TIMERSLACK, 1); /* pace to the deadline, not 50 us after it */
    sem_init(&holder_has_lock, 0, 0);
    if (pipe(io_request) || pipe(io_reply)) return 1;
    pthread_t io, *workers = calloc(cfg.workers, sizeof *workers);
    pthread_create(&io, NULL, io_thread, NULL);
    for (uint64_t i = 0; i < cfg.workers; i++) pthread_create(&workers[i], NULL, worker, (void *)(intptr_t)i);
    FILE *csv = cfg.csv ? fopen(cfg.csv, "w") : NULL;
    if (cfg.csv && !csv) {
        perror(cfg.csv);
        return 1;
    }
    /* start_us is CLOCK_MONOTONIC, the clock `perf record -k CLOCK_MONOTONIC` stamps samples with. */
    if (csv) fprintf(csv, "frame,start_us,work_us,update_us,render_us,wait_us,injected\n");
    uint32_t *work_us = calloc(cfg.frames, sizeof *work_us);
    uint64_t rng = cfg.seed, frame = 0, missed = 0, injected = 0, unplanned = 0;
    uint64_t start = now_ns(), deadline = start;

    printf("{\"workload\":\"frameloop\",\"stall\":\"%s\",\"seed\":%llu,\"workers\":%llu,\"jobs\":%llu,\"pace_us\":%llu,\"budget_us\":%llu,\n\"stalls\":[", cause_names[cfg.stall], (unsigned long long)cfg.seed, (unsigned long long)cfg.workers, (unsigned long long)cfg.jobs, (unsigned long long)cfg.pace_us, (unsigned long long)cfg.budget_us);
    for (; frame < cfg.frames && !stop_requested; frame++) {
        int stalled = cfg.stall != NONE && frame >= cfg.stall_first && (frame - cfg.stall_first) % cfg.stall_every == 0;
        uint64_t frame_seed = rng_next(&rng);
        uint64_t t0 = now_ns();
        frame_begin(frame);
        update(frame_seed, stalled);
        uint64_t t1 = now_ns();
        if (stalled && cfg.stall == LOCK) {
            dispatch(stall_lock_holder, cfg.stall_work, frame_seed);
            sem_wait(&holder_has_lock);
        }
        if (stalled && cfg.stall == JOB) dispatch(stall_long_job, cfg.stall_work, frame_seed);
        for (uint64_t j = 0; j < cfg.jobs; j++) {
            /* Job sizes vary by +-25%, decided here so scheduling cannot change them. */
            uint64_t r = rng_next(&rng);
            dispatch(ordinary_job, cfg.job_work * 3 / 4 + r % (cfg.job_work / 2 + 1), r);
        }
        render_prepare(frame_seed);
        uint64_t t2 = now_ns();
        wait_jobs();
        uint64_t t3 = now_ns();
        uint64_t us = (t3 - t0) / 1000;
        frame_end(frame, us);
        work_us[frame] = (uint32_t)us;
        int over = us > cfg.budget_us;
        missed += over;
        unplanned += over && !stalled;
        if (csv) fprintf(csv, "%llu,%llu,%llu,%llu,%llu,%llu,%d\n", (unsigned long long)frame, (unsigned long long)t0 / 1000, (unsigned long long)us, (unsigned long long)(t1 - t0) / 1000, (unsigned long long)(t2 - t1) / 1000, (unsigned long long)(t3 - t2) / 1000, stalled);
        if (stalled) printf("%s\n {\"frame\":%llu,\"work_us\":%llu,\"update_us\":%llu,\"render_us\":%llu,\"wait_us\":%llu}", injected++ ? "," : "", (unsigned long long)frame, (unsigned long long)us, (unsigned long long)(t1 - t0) / 1000, (unsigned long long)(t2 - t1) / 1000, (unsigned long long)(t3 - t2) / 1000);
        if (cfg.pace_us) {
            deadline += cfg.pace_us * 1000;
            if (deadline < now_ns()) deadline = now_ns(); /* a late frame does not make the next ones hurry */
            sleep_until_ns(deadline);
        }
    }
    uint64_t elapsed = now_ns() - start;
    pthread_mutex_lock(&queue_lock);
    shutting_down = 1;
    pthread_cond_broadcast(&queue_ready);
    pthread_mutex_unlock(&queue_lock);
    for (uint64_t i = 0; i < cfg.workers; i++) pthread_join(workers[i], NULL);
    close(io_request[1]);
    pthread_join(io, NULL);
    if (csv) fclose(csv);

    uint32_t *sorted = malloc(frame * sizeof *sorted);
    memcpy(sorted, work_us, frame * sizeof *sorted);
    uint32_t p50 = quantile(sorted, frame, 0.50), p99 = quantile(sorted, frame, 0.99), max = frame ? sorted[frame - 1] : 0;
    printf("],\n\"frames\":%llu,\"elapsed_ms\":%llu,\"work_us\":{\"p50\":%u,\"p99\":%u,\"max\":%u},\"over_budget\":%llu,\"over_budget_not_injected\":%llu,\"injected\":%llu,\"allocations\":%llu,\n", (unsigned long long)frame, (unsigned long long)elapsed / 1000000, p50, p99, max, (unsigned long long)missed, (unsigned long long)unplanned, (unsigned long long)injected, (unsigned long long)atomic_load(&allocations));
    print_rusage();
    printf("\"ground_truth\":{\"symbol\":\"%s\",\"where\":\"%s\",\"mechanism\":\"%s\"},\"interrupted\":%s,\"checksum\":%llu}\n", cause_truth[cfg.stall][0], cause_truth[cfg.stall][1], cause_truth[cfg.stall][2], stop_requested ? "true" : "false", (unsigned long long)world);
    return 0;
}
