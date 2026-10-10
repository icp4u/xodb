#define _GNU_SOURCE 1
#include "check.h"
#include "xrt_fdflow.h"
#include <dirent.h>
#include <errno.h>
#include <sched.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static uint64_t now(clockid_t clock) {
  struct timespec t;
  CHECK(!clock_gettime(clock, &t));
  return (uint64_t)t.tv_sec * 1000000000u + (uint64_t)t.tv_nsec;
}
static uint64_t rss(void) {
  FILE *f = fopen("/proc/self/statm", "r");
  CHECK(f);
  unsigned long pages, resident;
  CHECK(fscanf(f, "%lu %lu", &pages, &resident) == 2);
  CHECK(!fclose(f));
  return resident * (uint64_t)sysconf(_SC_PAGESIZE);
}
static int pin(pid_t pid, int cpu) {
  cpu_set_t set;
  CPU_ZERO(&set);
  CPU_SET(cpu, &set);
  return sched_setaffinity(pid, sizeof set, &set);
}
static unsigned fd_count(void) {
  DIR *d = opendir("/proc/self/fd");
  CHECK(d);
  unsigned count = 0;
  for (struct dirent *e; (e = readdir(d));)
    if (e->d_name[0] >= '0' && e->d_name[0] <= '9')
      ++count;
  CHECK(!closedir(d));
  return count - 1;
}
static void child_work(int control, int data, int ready, int file, int cpu,
                       int burst, pid_t parent) {
  if (prctl(PR_SET_PDEATHSIG, SIGKILL) || getppid() != parent || pin(0, cpu))
    _exit(10);
  if (write(ready, "r", 1) != 1)
    _exit(11);
  char command;
  if (read(control, &command, 1) != 1)
    _exit(12);
  if (burst) {
    for (unsigned i = 0; i < 50000; ++i)
      if (write(file, "x", 1) != 1)
        _exit(13);
  } else {
    char bytes[17];
    if (read(data, bytes, sizeof bytes) != sizeof bytes ||
        write(file, bytes, sizeof bytes) != sizeof bytes)
      _exit(14);
#if defined(__x86_64__)
    /* 64-bit code may use the 32-bit syscall entry convention. Number20
     * is compat getpid, not native writev; never count its result as IO. */
    int compat;
    __asm__ volatile("int $0x80"
                     : "=a"(compat)
                     : "0"(20), "b"(file)
                     : "memory");
    if (compat != getpid())
      _exit(15);
#endif
  }
  if (raise(SIGSTOP))
    _exit(16);
  _exit(0);
}
int main(int argc, char **argv) {
  int burst = argc == 2 && !strcmp(argv[1], "--burst-silence");
  int tiny = argc == 2 && !strcmp(argv[1], "--tiny");
  int partial = argc == 2 && !strcmp(argv[1], "--partial");
  cpu_set_t allowed;
  CHECK(!sched_getaffinity(0, sizeof allowed, &allowed));
  int first = -1, second = -1;
  for (int i = 0; i < CPU_SETSIZE; ++i)
    if (CPU_ISSET(i, &allowed)) {
      if (first < 0)
        first = i;
      else {
        second = i;
        break;
      }
    }
  CHECK(first >= 0);
  if (!burst && !partial && second < 0) {
    puts("BLOCKED: migration fixture needs two permitted CPUs");
    return 77;
  }
  uint64_t wall = now(CLOCK_MONOTONIC), cpu = now(CLOCK_PROCESS_CPUTIME_ID),
           before = rss(), after = 0;
  int command[2], data[2], ready[2];
  CHECK(!pipe(command) && !pipe(data) && !pipe(ready));
  int file = memfd_create("owned-flow-fixture", MFD_CLOEXEC);
  CHECK(file >= 0);
  pid_t parent = getpid(), child = fork();
  CHECK(child >= 0);
  if (!child) {
    close(command[1]);
    close(data[1]);
    close(ready[0]);
    child_work(command[0], data[0], ready[1], file, first, burst, parent);
  }
  close(command[0]);
  close(data[0]);
  close(ready[1]);
  char byte;
  CHECK(read(ready[0], &byte, 1) == 1 && byte == 'r');
  struct xrt_fdflow_options o = {.scoped = 1,
                                 .tids = &child,
                                 .tid_count = 1,
                                 .data_pages = burst ? 1 : 64};
  if (tiny)
    o.record_limit = 1;
  if (partial) {
    o.data_pages = 1;
    o.ring_budget = (uint64_t)sysconf(_SC_PAGESIZE);
  }
  unsigned baseline_fds = fd_count();
  struct xrt_fdflow *flow = NULL;
  struct xrt_perf_failure failure = {0};
  enum xrt_status opened = xrt_fdflow_open(&o, &flow, &failure);
  int rc = 1, stopped = 0, moved = 0, seen_compat = 0;
  uint64_t read_bytes = 0, write_bytes = 0;
  int32_t pending_fd = -1;
  int64_t pending_number = -1;
  uint32_t pending_cpu = 0, entry_cpu = UINT32_MAX, exit_cpu = UINT32_MAX;
  struct xrt_fdflow_snapshot snapshot = {0};
  if (opened != XRT_OK) {
    fprintf(stderr, "flow open status=%u syscall=%s errno=%d detail=%s\n",
            opened, failure.syscall ? failure.syscall : "none", failure.error,
            failure.detail ? failure.detail : "none");
    if (opened == XRT_PERMISSION_DENIED)
      rc = 77;
    goto cleanup;
  }
  if (partial) {
    if (xrt_fdflow_drain(flow, &snapshot) != XRT_OK ||
        snapshot.online_cpus <= 1 || snapshot.active_cpus != 1 ||
        !(snapshot.flags & XRT_FDFLOW_CPU_PARTIAL))
      goto cleanup;
    unsigned refused = 0;
    for (uint32_t i = 0; i < snapshot.cpu_count; ++i)
      if (!snapshot.cpus[i].active && snapshot.cpus[i].error == ENOMEM)
        ++refused;
    if (refused + 1 != snapshot.cpu_count)
      goto cleanup;
    after = rss();
    xrt_fdflow_stop(flow);
    if (fd_count() != baseline_fds)
      goto cleanup;
    rc = 0;
    goto cleanup;
  }
  if (write(command[1], "g", 1) != 1)
    goto cleanup;
  uint64_t deadline = now(CLOCK_MONOTONIC) + UINT64_C(20000000000);
  while (now(CLOCK_MONOTONIC) < deadline) {
    int status;
    pid_t got = waitpid(child, &status, WNOHANG | WUNTRACED);
    if (got < 0)
      goto cleanup;
    if (got == child) {
      if (!WIFSTOPPED(status) || WSTOPSIG(status) != SIGSTOP) {
        fprintf(stderr, "fixture status=%d\n", status);
        child = 0;
        goto cleanup;
      }
      stopped = 1;
    }
    if (!burst || stopped) {
      enum xrt_status status = xrt_fdflow_drain(flow, &snapshot);
      if (status != XRT_OK) {
        fprintf(stderr, "drain status=%u flags=%u reason=%s\n", status,
                snapshot.flags, snapshot.reason);
        goto cleanup;
      }
      for (uint32_t i = 0; i < snapshot.record_count; ++i) {
        const struct xrt_fdflow_record *r = &snapshot.records[i];
        if (r->kind == XRT_FDFLOW_LOST || r->kind == XRT_FDFLOW_THROTTLED)
          continue;
        if (r->pid != child || r->tid != child) {
          fprintf(stderr, "kernel TID filter admitted an unowned task\n");
          goto cleanup;
        }
        if (r->operation == XRT_FDFLOW_RAW && r->number == 20)
          seen_compat = 1;
        if (!burst && r->operation != XRT_FDFLOW_RAW && r->number == 20) {
          fprintf(stderr, "compat getpid mislabelled as native writev\n");
          goto cleanup;
        }
        if (r->kind == XRT_FDFLOW_ENTER) {
          pending_fd = (int32_t)r->args[0];
          pending_number = r->number;
          pending_cpu = r->cpu;
          /* No thread movement until its blocked read entry was
           * actually observed, including the exact known fd. */
          if (!burst && pending_fd == data[0] && r->number == 0 && !moved) {
            entry_cpu = r->cpu;
            if (pin(child, second) ||
                write(data[1], "flow-fixture-data", 17) != 17)
              goto cleanup;
            moved = 1;
          }
        } else if (r->kind == XRT_FDFLOW_EXIT &&
                   r->operation != XRT_FDFLOW_RAW &&
                   r->number == pending_number) {
          if (r->result > 0) {
            if (pending_fd == file && r->operation == XRT_FDFLOW_WRITE)
              write_bytes += (uint64_t)r->result;
            if (pending_fd == data[0] && r->operation == XRT_FDFLOW_READ) {
              read_bytes += (uint64_t)r->result;
              entry_cpu = pending_cpu;
              exit_cpu = r->cpu;
            }
          }
          pending_fd = -1;
          pending_number = -1;
        }
      }
      if (stopped && !snapshot.pending && !snapshot.record_count)
        break;
    }
    struct timespec delay = {0, 1000000};
    nanosleep(&delay, NULL);
  }
  if (!stopped) {
    fprintf(stderr, "fixture did not reach its silent stop\n");
    goto cleanup;
  }
  struct stat st;
  if (fstat(file, &st))
    goto cleanup;
  if (burst) {
    if (st.st_size != 50000 || !snapshot.lost || snapshot.lost_records ||
        (snapshot.flags & XRT_FDFLOW_LOSS_UNKNOWN)) {
      fprintf(stderr,
              "burst evidence size=%lld lost=%llu record_lost=%llu flags=%u\n",
              (long long)st.st_size, (unsigned long long)snapshot.lost,
              (unsigned long long)snapshot.lost_records, snapshot.flags);
      goto cleanup;
    }
    uint64_t lost = snapshot.lost;
    if (xrt_fdflow_drain(flow, &snapshot) != XRT_OK || snapshot.record_count ||
        snapshot.lost != lost)
      goto cleanup;
  } else if (st.st_size != 17 || read_bytes != 17 || write_bytes != 17 ||
             !moved || !seen_compat || entry_cpu != (uint32_t)first ||
             exit_cpu != (uint32_t)second || snapshot.lost ||
             (snapshot.flags &
              (XRT_FDFLOW_BAD_RECORD | XRT_FDFLOW_LOSS_UNKNOWN |
               XRT_FDFLOW_CPU_PARTIAL))) {
    fprintf(stderr,
            "normal evidence size=%lld read=%llu write=%llu moved=%d compat=%d "
            "cpu=%u->%u "
            "flags=%u\n",
            (long long)st.st_size, (unsigned long long)read_bytes,
            (unsigned long long)write_bytes, moved, seen_compat, entry_cpu,
            exit_cpu, snapshot.flags);
    goto cleanup;
  }
  after = rss();
  xrt_fdflow_stop(flow);
  if (xrt_fdflow_drain(flow, &snapshot) != XRT_OK || snapshot.running ||
      fd_count() != baseline_fds)
    goto cleanup;
  rc = 0;
cleanup:
  xrt_fdflow_close(flow);
  if (fd_count() != baseline_fds)
    rc = 1;
  if (child > 0) {
    if (rc == 0 && stopped)
      kill(child, SIGCONT);
    else
      kill(child, SIGKILL);
    int status;
    CHECK(waitpid(child, &status, 0) == child);
    if (rc == 0 && stopped && (!WIFEXITED(status) || WEXITSTATUS(status)))
      rc = 1;
  }
  close(command[1]);
  close(data[1]);
  close(ready[0]);
  close(file);
  if (rc == 77) {
    puts("BLOCKED: owned system-wide perf fixture needs existing perf/tracefs "
         "access");
    return 77;
  }
  CHECK(rc == 0);
  printf("{\"tiny\":%d,\"partial\":%d,\"burst_silence\":%d,\"cpus\":%u,"
         "\"active_cpus\":%u,\"records\":%llu,\"lost\":%llu,"
         "\"lost_records\":%llu,\"read_bytes\":%llu,\"write_bytes\":%llu,"
         "\"entry_cpu\":%u,\"exit_"
         "cpu\":%u,\"rss_before\":%llu,\"rss_after\":%llu,\"cpu_ns\":%llu,"
         "\"wall_ns\":%llu}\n",
         tiny, partial, burst, snapshot.online_cpus, snapshot.active_cpus,
         (unsigned long long)snapshot.records_seen,
         (unsigned long long)snapshot.lost,
         (unsigned long long)snapshot.lost_records,
         (unsigned long long)read_bytes, (unsigned long long)write_bytes,
         entry_cpu, exit_cpu, (unsigned long long)before,
         (unsigned long long)after,
         (unsigned long long)(now(CLOCK_PROCESS_CPUTIME_ID) - cpu),
         (unsigned long long)(now(CLOCK_MONOTONIC) - wall));
  puts("owned CPU-wide IO stream: scope, native ABI, migration/loss and "
       "cleanup PASS");
  return 0;
}
