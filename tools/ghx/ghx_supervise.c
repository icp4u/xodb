/* ghx_supervise: bounded request/response driver for ghx_worker.
 *
 * C01 candidate for xodb (GPLv3).  Provisional host-side protocol; it is
 * NOT the xodb C runtime wire protocol and allocates no production RPC numbers.
 *
 * stdin  (one request per line, tab separated key=value fields):
 *   DECOMPILE \t id=ID \t elf=/PATH \t entry=0xHEX [\t size=0xHEX] [\t name=SYM]
 *             [\t lang=ID] [\t cspec=ID] [\t symbols=0|1] [\t imports=0|1]
 *             [\t bounds=advisory|strict] [\t function_map=/PATH]
 *   CANCEL \t id=ID          cancel an in-flight or queued request
 * stdout (one event per line):
 *   WORKER \t pid=N \t event=start|exit|killed \t detail=.. [\t reap=done|pending \t reap_ms=T]
 *   RESULT \t id=ID \t status=S \t bytes=N \t ms=T \t overshoot_ms=T \t cleanup_ms=T
 *          [\t worker_status=S \t detail=..] \t file=PATH
 *     S: ok error timeout cancelled worker_died output_limit bad_request publish_failed
 *
 * Contract (docs/SEMANTIC_QUERIES.md, "C01 worker export contract", supervisor):
 *  - every artifact is published with RENAME_NOREPLACE into OUTDIR (opened
 *    once as a directory descriptor); an existing artifact is never replaced
 *    and a failed publication is the explicit outcome publish_failed;
 *  - -t bounds spawn, request write, header/body read and stdout EOF; on any
 *    abnormal decision the worker's process group gets SIGKILL at once;
 *  - reaping is bounded by -g (waitpid WNOHANG polling, never a blocking wait);
 *  - results.jsonl and worker-stderr.log must be regular files (a FIFO or
 *    device is refused with exit 2, never opened blocking);
 *  - exit 0 only if every RESULT and results.jsonl record was published,
 *    4 if a publication failed, 5 if a worker could not be reaped, 130 on
 *    SIGTERM/SIGINT, 2 on usage errors.
 * Requests never reach a shell: the worker is started with execv() and
 * fields are validated against a fixed key set.
 */
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define MAXLINE 8192
#define MAXQ 1024
#define MAXIDS 65536
#define MAXPENDING 64
#define MAX_ELF_BYTES (512ull << 20)

static const char *worker_path, *sleighhome, *outdir, *snaproot;
static long timeout_ms = 60000, grace_ms = 250, pipe_bytes;
static long long max_out = 64ll << 20;
static long mem_mb = 4096;
static int test_hooks;

static pid_t wpid = -1;
static int win = -1, wout = -1, odir = -1, jsonl = -1, errlog = -1;
static char snapdir[PATH_MAX];
static char *rbuf;			/* worker stdout bytes read but not consumed */
static size_t rlen, rcap;
static volatile sig_atomic_t got_term;
static int publish_failures, unreaped;
static unsigned tmp_counter;

static pid_t pending[MAXPENDING];	/* killed workers not yet reaped */
static int npending;

static char *queue[MAXQ];
static int qhead, qlen;
static char *seen[MAXIDS];
static int nseen;

static double now_ms(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

static void out(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	vprintf(fmt, ap);
	va_end(ap);
	fflush(stdout);
}

static void on_term(int sig) { (void)sig; got_term = 1; }

static void sleep_ms(double ms)
{
	struct timespec ts = { 0, (long)(ms * 1e6) };
	if (ms <= 0) return;
	nanosleep(&ts, NULL);
}

/* ------------------------------------------------------------ cleanup */

static void remove_tree_at(int dfd, const char *name, int depth)
{
	int fd;
	DIR *d;
	struct dirent *e;
	if (depth > 16) return;
	fd = openat(dfd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
	if (fd < 0) { unlinkat(dfd, name, 0); return; }
	d = fdopendir(fd);
	if (!d) { close(fd); return; }
	while ((e = readdir(d)) != NULL) {
		struct stat st;
		if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
		if (fstatat(fd, e->d_name, &st, AT_SYMLINK_NOFOLLOW) == 0 && S_ISDIR(st.st_mode))
			remove_tree_at(fd, e->d_name, depth + 1);
		else
			unlinkat(fd, e->d_name, 0);
	}
	closedir(d);
	unlinkat(dfd, name, AT_REMOVEDIR);
}

static void remove_snapdir(void)
{
	if (!snapdir[0]) return;
	remove_tree_at(AT_FDCWD, snapdir, 0);
	snapdir[0] = 0;
}

/* Wait at most ms for pid; never blocks without a bound.  1 reaped, 0 not. */
static int reap_bounded(pid_t pid, double ms, int *status)
{
	double end = now_ms() + ms;
	for (;;) {
		pid_t r = waitpid(pid, status, WNOHANG);
		if (r == pid) return 1;
		if (r < 0 && errno != EINTR) { *status = 0; return 1; }	/* ECHILD: already gone */
		if (now_ms() >= end) return 0;
		sleep_ms(1);
	}
}

static void reap_pending(double ms)
{
	double end = now_ms() + ms;
	for (int i = 0; i < npending;) {
		int st;
		double left = end - now_ms();
		if (reap_bounded(pending[i], left > 0 ? left : 0, &st)) {
			out("WORKER\tpid=%d\tevent=reaped\tdetail=late reap\n", (int)pending[i]);
			pending[i] = pending[--npending];
			continue;
		}
		i++;
	}
}

/* ------------------------------------------------------------ worker */

static void close_pipes(void)
{
	if (win >= 0) close(win);
	if (wout >= 0) close(wout);
	win = wout = -1;
	rlen = 0;
}

/* Stop the worker.  kill=1: SIGKILL its process group now.  kill=0: it has
 * been asked to QUIT (or already exited); escalate to SIGKILL after grace. */
static void worker_stop(const char *event, int kill_now, double *cleanup_ms, int *reaped_out)
{
	int st = 0, reaped;
	double t = now_ms();
	if (wpid <= 0) { if (reaped_out) *reaped_out = 1; return; }
	close_pipes();
	if (kill_now) { kill(-wpid, SIGKILL); kill(wpid, SIGKILL); }
	reaped = reap_bounded(wpid, grace_ms, &st);
	if (!reaped && !kill_now) {
		kill(-wpid, SIGKILL);
		kill(wpid, SIGKILL);
		reaped = reap_bounded(wpid, grace_ms, &st);
	}
	if (!reaped) {
		/* make sure nothing of the group survives, then remember it */
		kill(-wpid, SIGKILL);
		if (npending < MAXPENDING) pending[npending++] = wpid;
		else unreaped++;
		out("WORKER\tpid=%d\tevent=%s\tdetail=not reaped within %ld ms\treap=pending\treap_ms=%.1f\n",
		    (int)wpid, event, grace_ms, now_ms() - t);
	} else {
		kill(-wpid, SIGKILL);	/* stray grandchildren in the worker's group */
		if (WIFSIGNALED(st))
			out("WORKER\tpid=%d\tevent=%s\tdetail=signal %d\treap=done\treap_ms=%.1f\n",
			    (int)wpid, event, WTERMSIG(st), now_ms() - t);
		else
			out("WORKER\tpid=%d\tevent=%s\tdetail=exit %d\treap=done\treap_ms=%.1f\n",
			    (int)wpid, event, WEXITSTATUS(st), now_ms() - t);
	}
	remove_snapdir();
	wpid = -1;
	if (cleanup_ms) *cleanup_ms = now_ms() - t;
	if (reaped_out) *reaped_out = reaped;
}

static int worker_start(void)
{
	int a[2], b[2];
	pid_t parent = getpid();
	char tmpl[PATH_MAX];

	if (snprintf(tmpl, sizeof tmpl, "%s/ghx-spec-XXXXXX", snaproot) >= (int)sizeof tmpl) return -1;
	if (!mkdtemp(tmpl)) return -1;
	chmod(tmpl, 0700);	/* private, integrity-sensitive worker storage */
	snprintf(snapdir, sizeof snapdir, "%s", tmpl);
	if (pipe2(a, O_CLOEXEC)) { remove_snapdir(); return -1; }
	if (pipe2(b, O_CLOEXEC)) { close(a[0]); close(a[1]); remove_snapdir(); return -1; }
	wpid = fork();
	if (wpid < 0) {
		close(a[0]); close(a[1]); close(b[0]); close(b[1]);
		remove_snapdir();
		return -1;
	}
	if (wpid == 0) {
		struct rlimit rl;
		sigset_t none;
		setpgid(0, 0);
		prctl(PR_SET_PDEATHSIG, SIGKILL);
		if (getppid() != parent) _exit(127);
		sigemptyset(&none);
		sigprocmask(SIG_SETMASK, &none, NULL);
		signal(SIGPIPE, SIG_DFL);
		signal(SIGTERM, SIG_DFL);
		signal(SIGINT, SIG_DFL);
		dup2(a[0], 0);
		dup2(b[1], 1);
		if (errlog >= 0) dup2(errlog, 2);
		rl.rlim_cur = rl.rlim_max = (rlim_t)mem_mb << 20;
		setrlimit(RLIMIT_AS, &rl);
		rl.rlim_cur = rl.rlim_max = 0;
		setrlimit(RLIMIT_CORE, &rl);
		rl.rlim_cur = rl.rlim_max = 64 << 20;	/* stderr log bound */
		setrlimit(RLIMIT_FSIZE, &rl);
		{
			char *argv[8];
			int n = 0;
			argv[n++] = (char *)worker_path;
			argv[n++] = "--sleighhome";
			argv[n++] = (char *)sleighhome;
			argv[n++] = "--spec-snapshot";
			argv[n++] = snapdir;
			if (test_hooks) argv[n++] = "--test-hooks";
			argv[n] = NULL;
			execv(worker_path, argv);
		}
		_exit(127);
	}
	setpgid(wpid, wpid);	/* also from the parent: no window without a group */
	close(a[0]);
	close(b[1]);
	win = a[1];
	wout = b[0];
	fcntl(win, F_SETFL, fcntl(win, F_GETFL) | O_NONBLOCK);
	fcntl(wout, F_SETFL, fcntl(wout, F_GETFL) | O_NONBLOCK);
	if (pipe_bytes > 0) fcntl(win, F_SETPIPE_SZ, (int)pipe_bytes);
	out("WORKER\tpid=%d\tevent=start\tdetail=%s\n", (int)wpid, worker_path);
	return 0;
}

/* ------------------------------------------------------------ output */

/* append s as a JSON string (dynamic buffer; on allocation failure *p is left as is) */
static void json_str(char **p, size_t *n, size_t *cap, const char *s)
{
	size_t need = *n + strlen(s) * 6 + 3;
	char *o;
	if (need > *cap) {
		char *q = realloc(*p, need * 2);
		if (!q) return;
		*p = q;
		*cap = need * 2;
	}
	o = *p + *n;
	*o++ = '"';
	for (; *s; s++) {
		unsigned char c = (unsigned char)*s;
		if (c == '"' || c == '\\') { *o++ = '\\'; *o++ = (char)c; }
		else if (c < 0x20) o += sprintf(o, "\\u%04x", c);
		else *o++ = (char)c;
	}
	*o++ = '"';
	*o = 0;
	*n = (size_t)(o - *p);
}

static void cat(char **p, size_t *n, size_t *cap, const char *s)
{
	size_t k = strlen(s);
	if (*n + k + 1 > *cap) {
		size_t nc = (*n + k + 1) * 2;
		char *q = realloc(*p, nc);
		if (!q) return;
		*p = q;
		*cap = nc;
	}
	memcpy(*p + *n, s, k + 1);
	*n += k;
}

/* Publish OUTDIR/ID.json without ever replacing an existing entry.
 * returns 0 ok, -1 with err set. */
static int publish(const char *id, const char *data, size_t n, char *err, size_t el)
{
	char tmp[160], final[96];
	int fd, rc = -1;
	size_t off = 0;
	snprintf(final, sizeof final, "%s.json", id);
	snprintf(tmp, sizeof tmp, ".%s.json.%d.%u.tmp", id, (int)getpid(), tmp_counter++);
	fd = openat(odir, tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0644);
	if (fd < 0) { snprintf(err, el, "cannot create temporary artifact: %s", strerror(errno)); return -1; }
	while (off < n) {
		ssize_t k = write(fd, data + off, n - off);
		if (k < 0 && errno == EINTR) continue;
		if (k <= 0) { snprintf(err, el, "write failed: %s", k < 0 ? strerror(errno) : "short write"); close(fd); goto out; }
		off += (size_t)k;
	}
	if (close(fd) != 0) { snprintf(err, el, "close failed: %s", strerror(errno)); goto out; }
	if (renameat2(odir, tmp, odir, final, RENAME_NOREPLACE) == 0) return 0;
	if (errno == EINVAL || errno == ENOSYS) {	/* filesystem without RENAME_NOREPLACE */
		if (linkat(odir, tmp, odir, final, 0) == 0) { unlinkat(odir, tmp, 0); return 0; }
	}
	if (errno == EEXIST)
		snprintf(err, el, "%s already exists; existing artifact not replaced", final);
	else
		snprintf(err, el, "publication of %s failed: %s", final, strerror(errno));
out:
	unlinkat(odir, tmp, 0);
	return rc;
}

static int jsonl_write(const char *line, size_t n)
{
	ssize_t k;
	do k = write(jsonl, line, n); while (k < 0 && errno == EINTR);
	return k == (ssize_t)n ? 0 : -1;
}

/* Record one outcome: publish the artifact (if any), write RESULT and the
 * results.jsonl line.  A publication failure turns the outcome into
 * publish_failed and is counted for the exit status. */
static void finish(const char *id, const char *status, const char *data, size_t n,
		   const char *msg, double t0, double decided, double cleanup)
{
	char err[256] = "", path[PATH_MAX] = "", num[160];
	const char *final = status;
	char *rec = NULL;
	size_t rn = 0, rc = 0;
	double end, ms;

	if (strcmp(id, "-") != 0 && data) {
		if (publish(id, data, n, err, sizeof err) == 0) snprintf(path, sizeof path, "%s/%s.json", outdir, id);
		else final = "publish_failed";
	}
	cat(&rec, &rn, &rc, "{\"id\":");
	json_str(&rec, &rn, &rc, id);
	cat(&rec, &rn, &rc, ",\"status\":");
	json_str(&rec, &rn, &rc, final);
	if (final != status) {
		cat(&rec, &rn, &rc, ",\"worker_status\":");
		json_str(&rec, &rn, &rc, status);
	}
	end = now_ms();
	ms = end - t0;
	snprintf(num, sizeof num, ",\"bytes\":%zu,\"ms\":%.1f,\"overshoot_ms\":%.1f,\"cleanup_ms\":%.1f",
		 n, ms, ms > timeout_ms ? ms - timeout_ms : 0.0, cleanup);
	cat(&rec, &rn, &rc, num);
	if (msg || err[0]) {
		cat(&rec, &rn, &rc, ",\"message\":");
		json_str(&rec, &rn, &rc, err[0] ? err : msg);
	}
	cat(&rec, &rn, &rc, "}\n");
	if (!rec || jsonl_write(rec, rn) != 0) {
		if (final == status) { final = "publish_failed"; snprintf(err, sizeof err, "results.jsonl write failed"); }
	}
	free(rec);
	if (final != status) publish_failures++;
	(void)decided;
	if (final != status)
		out("RESULT\tid=%s\tstatus=%s\tbytes=%zu\tms=%.0f\tovershoot_ms=%.1f\tcleanup_ms=%.1f\tworker_status=%s\tdetail=%s\tfile=\n",
		    id, final, n, ms, ms > timeout_ms ? ms - timeout_ms : 0.0, cleanup, status, err);
	else
		out("RESULT\tid=%s\tstatus=%s\tbytes=%zu\tms=%.0f\tovershoot_ms=%.1f\tcleanup_ms=%.1f\tfile=%s\n",
		    id, final, n, ms, ms > timeout_ms ? ms - timeout_ms : 0.0, cleanup, path);
}

/* supervisor-generated envelope for outcomes without worker JSON */
static void result_local(const char *id, const char *status, const char *msg, double t0, double cleanup)
{
	char *buf = NULL;
	size_t n = 0, cap = 0;
	double decided = now_ms();
	cat(&buf, &n, &cap, "{\"schema\":\"xodb.ghidra.function_graph\",\"schema_version\":\"0.4.1\","
		"\"producer\":{\"kind\":\"ghx_supervise\",\"java\":false},\"status\":\"error\",\"request\":{\"id\":");
	json_str(&buf, &n, &cap, id);
	cat(&buf, &n, &cap, "},\"error\":{\"code\":");
	json_str(&buf, &n, &cap, status);
	cat(&buf, &n, &cap, ",\"message\":");
	json_str(&buf, &n, &cap, msg);
	cat(&buf, &n, &cap, "}}");
	finish(id, status, buf, buf ? n : 0, msg, t0, decided, cleanup);
	free(buf);
}

/* ------------------------------------------------------------ requests */

static const char *allowed[] = { "id", "elf", "entry", "size", "name", "lang", "cspec",
				 "symbols", "imports", "bounds", "function_map", NULL };
static const char *hook_keys[] = { "test_sleep_ms", "test_crash", "test_alloc_mb", "test_barrier",
				   "test_read_barrier", NULL };

static int in_list(const char *k, size_t kl, const char **l)
{
	for (; *l; l++)
		if (strlen(*l) == kl && memcmp(*l, k, kl) == 0) return 1;
	return 0;
}

/* value of key into v; returns 1 present, 0 absent, -1 present but too long */
static int field(const char *line, const char *key, char *v, size_t vl)
{
	size_t kl = strlen(key);
	const char *p = line;
	while ((p = strchr(p, '\t')) != NULL) {
		p++;
		if (strncmp(p, key, kl) == 0 && p[kl] == '=') {
			const char *e = strchr(p + kl + 1, '\t');
			size_t n = e ? (size_t)(e - p - kl - 1) : strlen(p + kl + 1);
			if (n >= vl) { v[0] = 0; return -1; }
			memcpy(v, p + kl + 1, n);
			v[n] = 0;
			return 1;
		}
	}
	return 0;
}

static int valid_id(const char *s)
{
	size_t n = strlen(s);
	if (n == 0 || n > 64) return 0;
	for (; *s; s++)
		if (!((*s >= 'a' && *s <= 'z') || (*s >= 'A' && *s <= 'Z') || (*s >= '0' && *s <= '9') ||
		      *s == '_' || *s == '-' || *s == '.'))
			return 0;
	return 1;
}

/* returns NULL if ok else reason */
static const char *validate(const char *line, char *id, size_t idl)
{
	const char *p = line;
	char elf[PATH_MAX];
	struct stat st;
	int i, r;

	for (const char *c = line; *c; c++)
		if ((unsigned char)*c < 0x20 && *c != '\t') return "control character in request";
	if (field(line, "id", id, idl) != 1 || !valid_id(id)) { id[0] = 0; return "missing or invalid id"; }
	if (id[0] == '.') return "id must not start with '.'";
	while ((p = strchr(p, '\t')) != NULL) {
		const char *eq, *e;
		p++;
		eq = strchr(p, '=');
		e = strchr(p, '\t');
		if (!eq || (e && eq > e)) return "field without '='";
		if (!in_list(p, eq - p, allowed) && !(test_hooks && in_list(p, eq - p, hook_keys)))
			return "unknown field";
	}
	r = field(line, "elf", elf, sizeof elf);
	if (r < 0) return "elf path too long";
	if (r == 0 || elf[0] != '/') return "elf must be an absolute path";
	if (stat(elf, &st) != 0 || !S_ISREG(st.st_mode)) return "elf is not a readable regular file";
	if ((unsigned long long)st.st_size > MAX_ELF_BYTES) return "elf exceeds input size limit";
	if (access(elf, R_OK) != 0) return "elf not readable";
	{
		char ent[32];
		if (field(line, "entry", ent, sizeof ent) != 1) return "missing or overlong entry";
	}
	r = field(line, "function_map", elf, sizeof elf);
	if (r < 0) return "function_map path too long";
	if (r == 1 && (elf[0] != '/' || stat(elf, &st) != 0 || !S_ISREG(st.st_mode) || st.st_size > (1 << 20)))
		return "function_map must be an absolute regular file <= 1 MiB";
	for (i = 0; i < nseen; i++)
		if (strcmp(seen[i], id) == 0) return "duplicate id";
	return NULL;
}

/* stdin handling during a request: queue new requests, act on CANCEL */
static char inbuf[MAXLINE * 2];
static size_t inlen;
static int stdin_eof, stdin_skip;

static void enqueue(const char *l)
{
	char *c;
	if (qlen >= MAXQ) { result_local("-", "bad_request", "queue full", now_ms(), 0); return; }
	c = strdup(l);
	if (!c) { result_local("-", "bad_request", "out of memory", now_ms(), 0); return; }
	queue[(qhead + qlen) % MAXQ] = c;
	qlen++;
}

static int handle_cancel(const char *l, const char *curid)
{
	char id[80];
	int i;
	if (field(l, "id", id, sizeof id) != 1) return 0;
	if (curid && strcmp(id, curid) == 0) return 1;
	for (i = 0; i < qlen; i++) {
		char qid[80];
		char *q = queue[(qhead + i) % MAXQ];
		if (q && field(q, "id", qid, sizeof qid) == 1 && strcmp(qid, id) == 0) {
			free(q);
			queue[(qhead + i) % MAXQ] = NULL;	/* tombstone */
			if (nseen < MAXIDS) seen[nseen++] = strdup(id);
			result_local(id, "cancelled", "cancelled while queued", now_ms(), 0);
			return 0;
		}
	}
	return 0;
}

/* returns 1 if the current request was cancelled */
static int check_stdin(const char *curid)
{
	ssize_t k;
	int cancel = 0;
	if (stdin_eof) return 0;
	k = read(0, inbuf + inlen, sizeof inbuf - inlen - 1);
	if (k < 0 && (errno == EINTR || errno == EAGAIN)) return 0;
	if (k <= 0) {
		stdin_eof = 1;
		if (inlen && !stdin_skip) { inbuf[inlen] = 0; if (strncmp(inbuf, "CANCEL\t", 7) == 0) cancel |= handle_cancel(inbuf, curid); else enqueue(inbuf); }
		inlen = 0;
		return cancel;
	}
	inlen += (size_t)k;
	for (;;) {
		char *nl = memchr(inbuf, '\n', inlen);
		size_t used;
		if (!nl) {
			if (inlen >= MAXLINE) { inlen = 0; stdin_skip = 1; }	/* overlong line: drop it */
			break;
		}
		*nl = 0;
		if (stdin_skip) stdin_skip = 0;
		else if (strncmp(inbuf, "CANCEL\t", 7) == 0) cancel |= handle_cancel(inbuf, curid);
		else if (inbuf[0]) enqueue(inbuf);
		used = (size_t)(nl - inbuf) + 1;
		memmove(inbuf, nl + 1, inlen - used);
		inlen -= used;
	}
	return cancel;
}

/* Wait for worker I/O (POLLIN on wout or POLLOUT on win) until the deadline,
 * servicing stdin for CANCEL.  returns 1 ready, -2 timeout, -3 cancelled */
static int wait_io(int fd, short ev, double deadline, const char *curid)
{
	for (;;) {
		struct pollfd pf[2] = { { fd, ev, 0 }, { stdin_eof ? -1 : 0, POLLIN, 0 } };
		double left = deadline - now_ms();
		int r;
		if (got_term) return -3;
		if (left <= 0) return -2;
		r = poll(pf, 2, left > 1000 ? 1000 : (int)left + 1);
		if (r < 0) { if (errno == EINTR) continue; return -2; }
		if (pf[1].revents & (POLLIN | POLLHUP | POLLERR))
			if (check_stdin(curid)) return -3;
		if (pf[0].revents) return 1;
	}
}

/* returns 0 ok, -1 worker closed/broken, -2 timeout, -3 cancelled */
static int write_all(const char *p, size_t n, double deadline, const char *curid)
{
	size_t off = 0;
	while (off < n) {
		ssize_t k = write(win, p + off, n - off);
		if (k > 0) { off += (size_t)k; continue; }
		if (k < 0 && errno == EINTR) continue;
		if (k < 0 && errno != EAGAIN) return -1;	/* EPIPE: worker gone */
		int r = wait_io(win, POLLOUT, deadline, curid);
		if (r < 0) return r;
	}
	return 0;
}

/* make at least want bytes available in rbuf; 0 ok, -1 eof/err, -2, -3 */
static int fill(size_t want, double deadline, const char *curid)
{
	while (rlen < want) {
		ssize_t k;
		if (rcap < want) {
			size_t nc = rcap * 2 > want ? rcap * 2 : want;
			char *q;
			if (nc < 4096) nc = 4096;
			q = realloc(rbuf, nc);
			if (!q) return -1;
			rbuf = q;
			rcap = nc;
		}
		k = read(wout, rbuf + rlen, rcap - rlen);
		if (k > 0) { rlen += (size_t)k; continue; }
		if (k == 0) return -1;	/* stdout EOF: no further reply can come */
		if (errno == EINTR) continue;
		if (errno != EAGAIN) return -1;
		int r = wait_io(wout, POLLIN, deadline, curid);
		if (r < 0) return r;
	}
	return 0;
}

/* header line (<= 511 bytes) into hdr; 0 ok, -1, -2, -3, -4 protocol */
static int read_header(char *hdr, size_t hl, double deadline, const char *curid)
{
	for (;;) {
		char *nl = rlen ? memchr(rbuf, '\n', rlen) : NULL;
		if (nl) {
			size_t n = (size_t)(nl - rbuf);
			if (n >= hl) return -4;
			memcpy(hdr, rbuf, n);
			hdr[n] = 0;
			memmove(rbuf, nl + 1, rlen - n - 1);
			rlen -= n + 1;
			return 0;
		}
		if (rlen >= hl) return -4;
		int r = fill(rlen + 1, deadline, curid);
		if (r) return r;
	}
}

static void run_request(const char *line)
{
	char id[80], hdr[512], st[32], bytes_s[32], rid[80];
	const char *why;
	double t0 = now_ms(), deadline = t0 + timeout_ms, cleanup = 0;
	char *req, *body;
	unsigned long long n;
	int r;

	if (strncmp(line, "DECOMPILE\t", 10) != 0) { result_local("-", "bad_request", "unknown verb", t0, 0); return; }
	why = validate(line, id, sizeof id);
	if (why) {
		int ok = valid_id(id) && id[0] != '.';
		int dup = strcmp(why, "duplicate id") == 0;
		if (ok && !dup && nseen < MAXIDS) seen[nseen++] = strdup(id);
		result_local(ok && !dup ? id : "-", "bad_request", why, t0, 0);
		return;
	}
	if (nseen < MAXIDS) seen[nseen++] = strdup(id);
	if (wpid <= 0 && worker_start() != 0) { result_local(id, "worker_died", "cannot start worker", t0, 0); return; }
	req = malloc(strlen(line) + 64);
	if (!req) { result_local(id, "worker_died", "out of memory", t0, 0); return; }
	sprintf(req, "%s\tmax_out=%lld\n", line, max_out);
	r = write_all(req, strlen(req), deadline, id);
	free(req);
	if (r == 0) r = read_header(hdr, sizeof hdr, deadline, id);
	if (r == 0) {
		if (strncmp(hdr, "RESULT\t", 7) != 0 || field(hdr, "id", rid, sizeof rid) != 1 ||
		    field(hdr, "status", st, sizeof st) != 1 || field(hdr, "bytes", bytes_s, sizeof bytes_s) != 1 ||
		    strcmp(rid, id) != 0 || strspn(bytes_s, "0123456789") != strlen(bytes_s) || !bytes_s[0] ||
		    (strcmp(st, "ok") != 0 && strcmp(st, "error") != 0)) {
			worker_stop("killed", 1, &cleanup, NULL);
			result_local(id, "worker_died", "protocol error from worker", t0, cleanup);
			return;
		}
		n = strtoull(bytes_s, NULL, 10);
		if (strlen(bytes_s) > 15 || n > (unsigned long long)max_out + 4096) {
			worker_stop("killed", 1, &cleanup, NULL);
			result_local(id, "output_limit", "worker response exceeds max_out", t0, cleanup);
			return;
		}
		r = fill((size_t)n, deadline, id);
		if (r == 0) {
			body = malloc((size_t)n + 1);
			if (!body) {
				worker_stop("killed", 1, &cleanup, NULL);
				result_local(id, "worker_died", "supervisor out of memory", t0, cleanup);
				return;
			}
			memcpy(body, rbuf, (size_t)n);
			memmove(rbuf, rbuf + n, rlen - (size_t)n);
			rlen -= (size_t)n;
			finish(id, st, body, (size_t)n, NULL, t0, now_ms(), 0);
			free(body);
			return;
		}
	}
	if (r == -2) { worker_stop("killed", 1, &cleanup, NULL); result_local(id, "timeout", "request exceeded timeout", t0, cleanup); }
	else if (r == -3) {
		worker_stop("killed", 1, &cleanup, NULL);
		result_local(id, "cancelled", got_term ? "supervisor terminating" : "cancelled in flight", t0, cleanup);
	} else if (r == -4) { worker_stop("killed", 1, &cleanup, NULL); result_local(id, "worker_died", "protocol error: overlong header", t0, cleanup); }
	else { worker_stop("killed", 1, &cleanup, NULL); result_local(id, "worker_died", "worker closed its pipes, exited or crashed during request", t0, cleanup); }
}

/* Open an append-only log in OUTDIR without blocking: O_NONBLOCK makes a FIFO
 * with no reader fail (ENXIO) instead of hanging before any deadline applies;
 * anything but a regular file is refused (EINVAL).  After C03-R2 PC2. */
static int open_log(int dir, const char *name)
{
	struct stat st;
	int fd = openat(dir, name, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NOCTTY | O_NONBLOCK, 0644);
	if (fd < 0) return -1;
	if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || fcntl(fd, F_SETFL, O_APPEND) != 0) {
		close(fd);
		errno = EINVAL;
		return -1;
	}
	return fd;
}

int main(int argc, char **argv)
{
	int c;
	struct sigaction sa;
	struct stat st;
	const char *tmp = getenv("TMPDIR");

	snaproot = tmp && *tmp ? tmp : "/tmp";
	while ((c = getopt(argc, argv, "w:s:o:t:g:m:M:S:P:T")) != -1) {
		switch (c) {
		case 'w': worker_path = optarg; break;
		case 's': sleighhome = optarg; break;
		case 'o': outdir = optarg; break;
		case 't': timeout_ms = atol(optarg); break;
		case 'g': grace_ms = atol(optarg); break;
		case 'm': max_out = atoll(optarg); break;
		case 'M': mem_mb = atol(optarg); break;
		case 'S': snaproot = optarg; break;
		case 'P': pipe_bytes = atol(optarg); break;
		case 'T': test_hooks = 1; break;
		default:
			fprintf(stderr, "usage: ghx_supervise -w WORKER -s SLEIGHHOME -o OUTDIR [-t ms] [-g grace_ms] [-m bytes] [-M MiB] [-S snaproot] [-T [-P pipe_bytes]]\n");
			return 2;
		}
	}
	if (!worker_path || !sleighhome || !outdir || timeout_ms <= 0 || grace_ms < 1 || grace_ms > 60000 ||
	    max_out < 1024 || mem_mb < 64 || (pipe_bytes && !test_hooks)) {
		fprintf(stderr, "ghx_supervise: -w -s -o required; bad limits\n");
		return 2;
	}
	umask(022);
	if (mkdir(outdir, 0755) != 0 && errno != EEXIST) { perror(outdir); return 2; }
	odir = open(outdir, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
	if (odir < 0 || fstat(odir, &st) != 0 || st.st_uid != geteuid()) {
		fprintf(stderr, "ghx_supervise: %s must be a directory (not a symlink) owned by this user\n", outdir);
		return 2;
	}
	jsonl = open_log(odir, "results.jsonl");
	if (jsonl < 0) { fprintf(stderr, "ghx_supervise: %s/results.jsonl: %s\n", outdir, strerror(errno)); return 2; }
	errlog = open_log(odir, "worker-stderr.log");
	if (errlog < 0) { fprintf(stderr, "ghx_supervise: %s/worker-stderr.log: %s\n", outdir, strerror(errno)); return 2; }
	memset(&sa, 0, sizeof sa);
	sa.sa_handler = on_term;
	sigaction(SIGTERM, &sa, NULL);
	sigaction(SIGINT, &sa, NULL);
	signal(SIGPIPE, SIG_IGN);

	while (!got_term) {
		if (npending) reap_pending(0);
		if (qlen == 0) {
			struct pollfd pf = { 0, POLLIN, 0 };
			if (stdin_eof) break;
			if (poll(&pf, 1, 1000) < 0 && errno != EINTR) break;
			if (pf.revents) check_stdin(NULL);
			continue;
		}
		{
			char *l = queue[qhead];
			qhead = (qhead + 1) % MAXQ;
			qlen--;
			if (!l) continue;	/* cancelled tombstone */
			run_request(l);
			free(l);
		}
	}
	if (wpid > 0) {
		if (got_term) worker_stop("killed", 1, NULL, NULL);
		else {
			if (write(win, "QUIT\n", 5) < 0) { /* escalated below */ }
			worker_stop("exit", 0, NULL, NULL);
		}
	}
	while (qlen > 0) {	/* terminated with queued work: report, do not drop silently */
		char *l = queue[qhead], id[80];
		qhead = (qhead + 1) % MAXQ;
		qlen--;
		if (l && field(l, "id", id, sizeof id) == 1 && valid_id(id) && id[0] != '.')
			result_local(id, "cancelled", "supervisor terminating", now_ms(), 0);
		free(l);
	}
	if (npending) reap_pending(grace_ms);
	unreaped += npending;
	for (int i = 0; i < npending; i++) out("SUPERVISOR\tunreaped_pid=%d\n", (int)pending[i]);
	close(jsonl);
	if (got_term) return 130;
	if (publish_failures) return 4;
	if (unreaped) return 5;
	return 0;
}
