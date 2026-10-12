#!/usr/bin/env python3
"""Periodic sweep budget invariants: large executable, followed fork/exec,
release/rebuild/restart, and a stopped capture replaced without retaining it.
All files and processes are owned fixtures. --wrong-result must fail.
"""
import argparse, json, os, signal, subprocess, time
from pathlib import Path
from client import Client
from helpers import orphans
MIB = 1 << 20
root = Path.cwd()
def cc(*args): subprocess.run(['cc', *map(str, args)], check=True, timeout=60)
def text(reply): return '; '.join(x.get('text', '') for x in reply.get('content', []))
def frames(reply):
    return [dict(f, diag=f.get('diagnostic'), inline_diag=f.get('inline_diagnostic')) for f in reply['frames']]
def status(pid, key):
    return next(int(s.split()[1]) // 1024 for s in Path(f'/proc/{pid}/status').read_text().splitlines() if s.startswith(key + ':'))
def resources(pid):
    fields = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
    return {'cpu_ticks': int(fields[11]) + int(fields[12]), 'rss_mib': status(pid, 'VmRSS'), 'load': os.getloadavg(), 'cpus': os.cpu_count()}
LIB = 'int owned_function(int n) { return n + 1; }\n'
def build_lib(w, i, size, name):
    path = w / name
    cc('-g', '-O1', '-shared', '-fPIC', w / 'lib.c', '-o', path)
    os.truncate(path, size)
    return path
PHASE = r'''
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
typedef int (*waitfn)(int *, void (*)(int, int *));
static char **args; static int nargs, next_arg;
static void say(const char *what) {
    int fd = open(getenv("DONE"), O_WRONLY | O_APPEND | O_CREAT, 0644); if (fd < 0) _exit(9);
    char line[128]; int n = snprintf(line, sizeof line, "%s %d\n", what, (int)getpid());
    if (write(fd, line, n) != n) _exit(9);
    close(fd);
}
static void group(void) {  /* dlopen up to the next "--" */
    for (; next_arg < nargs && strcmp(args[next_arg], "--"); next_arg++)
        if (!dlopen(args[next_arg], RTLD_NOW | RTLD_LOCAL)) { fprintf(stderr, "dlopen %s: %s\n", args[next_arg], dlerror()); _exit(2); }
    if (next_arg < nargs) next_arg++;
}
__attribute__((noinline)) int exe_marker(int n) { __asm__ volatile("" ::: "memory"); return n + 1; }
static void command(int c, int *fd) {
    if (c == 'n') { group(); say("phase"); }
    if (c == 'x') { execv(args[0], args); _exit(127); }
    if (c == 'X') { args[0] = getenv("EXEC2"); setenv("SKIP", getenv("SKIP2") ? getenv("SKIP2") : "0", 1); execv(args[0], args); _exit(127); }
    if (c == 'f') {
        pid_t p = fork();
        if (!p) { close(*fd); *fd = open(getenv("CMD2"), O_RDONLY); say("child"); } else say("forked");
    }
    if (c == 'q') _exit(0);
}
int main(int argc, char **argv) {
    args = argv; nargs = argc; next_arg = 2;
    void *h = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!h) { fprintf(stderr, "dlopen %s: %s\n", argv[1], dlerror()); return 2; }
    waitfn wait = (waitfn)dlsym(h, "honest_wait");
    /* SKIP=k: skip k groups (the program an exec starts opens a later set) */
    for (int k = getenv("SKIP") ? atoi(getenv("SKIP")) : 0; k > 0; k--) { while (next_arg < nargs && strcmp(args[next_arg], "--")) next_arg++; if (next_arg < nargs) next_arg++; }
    group();
    int fd = open(getenv("CMD"), O_RDONLY);
    exe_marker(1);
    say("ready");
    return wait(&fd, command);
}
'''
HONEST = r'''
#include <unistd.h>
__attribute__((noinline)) int honest_wait(int *fd, void (*cb)(int, int *)) {
    for (;;) { char b; if (read(*fd, &b, 1) <= 0) _exit(0); cb(b, fd); __asm__ volatile("" ::: "memory"); }
}
'''
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--work', required=True, type=Path)
p.add_argument('--only', default='s4c,s6,s9,replace')
p.add_argument('--agent')
p.add_argument('--per', type=int, default=256)
p.add_argument('--total', type=int, default=1024)
p.add_argument('--exe-mib', type=int, default=256)
p.add_argument('--honest-mib', type=int, default=1)
p.add_argument('--wrong-result', action='store_true')
a = p.parse_args()
os.umask(0o022)
orphans.adopt()
w = a.work.resolve(); w.mkdir(parents=True, exist_ok=True, mode=0o755)
a.opt = ['--runtime-agent', str(Path(a.agent).resolve())] if a.agent else []
a.reply = 90
a.junk_cap = 40
PER, TOTAL = a.per * MIB, a.total * MIB
a.opt += ['--image-limit', f'{a.per}M', '--image-total-limit', f'{a.total}M']
made = []
def build():
    (w / 'phase.c').write_text(PHASE); (w / 'honest.c').write_text(HONEST)
    cc('-g', '-O1', '-fno-optimize-sibling-calls', '-rdynamic', w / 'phase.c', '-o', w / 'phase', '-ldl')
    cc('-g', '-O1', '-fno-optimize-sibling-calls', '-rdynamic', '-DSECOND=1', w / 'phase.c', '-o', w / 'phase2', '-ldl')
    cc('-g', '-O1', '-fno-optimize-sibling-calls', '-shared', '-fPIC', w / 'honest.c', '-o', w / 'honest.so')
    os.truncate(w / 'honest.so', max(int(a.honest_mib * MIB), os.stat(w / 'honest.so').st_size))
def junkset(tag):
    each = min(256 * MIB, PER); order = [each] * min(TOTAL // each, a.junk_cap); size = each
    while size >= MIB: size //= 2; order.append(size)
    out = []
    for i, size in enumerate(reversed(order)):
        path = w / f'junk{tag}{i}.so'; path.write_bytes((w/'small.so').read_bytes()); os.truncate(path, size); out.append(path)
    made.extend(out); return out

class T:
    """Target + xodb. attach: we start the target and attach; else xodb launches it (--break exe_marker)."""
    def __init__(self, program, groups, options=(), launch=False, env=None):
        self.cmd = w / f'cmd{os.getpid()}-{time.monotonic_ns()}'; os.mkfifo(self.cmd)
        self.cmd2 = Path(str(self.cmd) + '.2'); os.mkfifo(self.cmd2)
        self.done = Path(str(self.cmd) + '.done'); self.done.write_text(''); self.seen = 0
        argv = [str(program), str(w / 'honest.so')]
        for i, g in enumerate(groups): argv += ([] if i == 0 else ['--']) + [str(x) for x in g]
        e = {**os.environ, 'CMD': str(self.cmd), 'CMD2': str(self.cmd2), 'DONE': str(self.done), **(env or {})}
        self.target = None; self.client = None; self.w2 = None; self.children = []
        opts = [*a.opt, *options]
        try:
            if launch:
                os.environ.update({k: v for k, v in e.items() if k in ('CMD', 'CMD2', 'DONE') or k in (env or {})})
                self.client = Client('control', argv[0], args=argv[1:], options=[*opts, '--break', 'exe_marker'], reply_seconds=a.reply)
                self.drain()
                self.wfd = os.open(self.cmd, os.O_RDWR)   # never blocks; the target opens its end after the breakpoint
                self.to_breakpoint()
                self.pid = None
            else:
                self.target = subprocess.Popen(argv, env=e, stdin=subprocess.DEVNULL)
                self.wfd = os.open(self.cmd, os.O_WRONLY)
                self.pid = self.wait('ready')
                self.client = Client('control', None, options=['--attach', str(self.pid), *opts], reply_seconds=a.reply)
                self.drain()
                self.client.stopped(seconds=60)
        except BaseException:
            self.kill(); raise
    def to_breakpoint(self):
        # the launch stop is at the entry point: run on to exe_marker, where every library is open
        self.client.stopped(seconds=60); self.client.continue_initial_stop(); self.client.stopped('breakpoint', seconds=60)
    def drain(self):
        # Drain ordinary diagnostics independently of the synchronous MCP client.
        import threading
        self.err = []
        def pump(stream=self.client.p.stderr):
            for line in iter(stream.readline, b''): self.err.append(line)
        self.err_thread = threading.Thread(target=pump, daemon=True); self.err_thread.start()
    def wait(self, word, seconds=120):
        deadline = time.monotonic() + seconds
        while True:
            lines = self.done.read_text().splitlines()
            for i in range(self.seen, len(lines)):
                if lines[i].split()[0] == word:
                    self.seen = i + 1; pid = int(lines[i].split()[1])
                    if word == 'child': self.children.append(pid)
                    return pid
            if self.target and self.target.poll() is not None: raise AssertionError(('target died', self.target.returncode))
            assert time.monotonic() < deadline, (word, lines)
            # A followed child can still be at its fork stop after the parent
            # has reported: resume it, or its word is never written.
            if word == 'child' and self.client:
                for q in range(2, self.client.inspect('get_processes')['total'] + 1):
                    s = self.state(q)
                    if s['state'] == 'stopped' and not s['continue_pending'] and not s['symbol_discovery_pending']:
                        self.client.tool('continue', process_id=q, generation=s['generation'])
            time.sleep(.005)
    def state(self, process=1): return self.client.inspect('get_session', process_id=process)
    def settle(self, process=1, seconds=60):
        deadline = time.monotonic() + seconds
        while True:
            s = self.state(process)
            if s['state'] == 'stopped' and not s['symbol_discovery_pending'] and not s['continue_pending']: return s
            assert time.monotonic() < deadline, s
            time.sleep(.005)
    def go(self, process=1):
        self.client.inspect('continue', process_id=process, generation=self.settle(process)['generation'])
    def halt(self, process=1):
        deadline = time.monotonic() + 60
        while True:   # exec and loader stops come by themselves; run through them, then interrupt
            s = self.state(process)
            if s['state'] == 'running':
                r = self.client.tool('interrupt', process_id=process, generation=s['generation'])
            s = self.settle(process)
            return s
    def send(self, byte, word, process=1, fd=None, others=()):
        """Resume, give the target one command, wait for its word, stop the process again.
        Fork, exec and loader stops arrive on their own: every stopped process is resumed
        until the word is written; then `process` is interrupted."""
        self.go(process); os.write(fd or self.wfd, byte.encode())
        deadline = time.monotonic() + 120; pid = None
        while pid is None:
            lines = self.done.read_text().splitlines()
            for i in range(self.seen, len(lines)):
                if lines[i].split()[0] == word: self.seen = i + 1; pid = int(lines[i].split()[1]); break
            if pid is not None: break
            for q in range(1, self.client.inspect('get_processes')['total'] + 1):
                s = self.state(q)
                if s['state'] == 'stopped' and not s['continue_pending'] and not s['symbol_discovery_pending']:
                    self.client.tool('continue', process_id=q, generation=s['generation'])
            assert time.monotonic() < deadline, (word, lines)
            time.sleep(.01)
        self.stop(process)
        return pid
    def stop(self, process=1):
        """Bring `process` to a quiet stop inside honest_wait (blocked in read)."""
        deadline = time.monotonic() + 60; asked = False
        while True:
            s = self.state(process)
            quiet = s['state'] == 'stopped' and not s['continue_pending'] and not s['symbol_discovery_pending']
            if quiet and asked: return s
            if quiet: self.client.tool('continue', process_id=process, generation=s['generation'])
            elif s['state'] == 'running':
                pid = s['pid']
                state = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()[0]
                if state != 'S':
                    assert time.monotonic() < deadline, (pid, state)
                    time.sleep(.005); continue
                s = self.state(process)
                if s['state'] == 'running':
                    r = self.client.tool('interrupt', process_id=process, generation=s['generation'])['result']
                    asked = not r.get('isError')
            assert time.monotonic() < deadline, s
            time.sleep(.01)
    def tid(self, process=1): return self.settle(process)['threads'][0]['tid']
    def held(self, process=1):
        return self.client.inspect('list_modules', limit=1, process_id=process).get('image_bytes') or {'held': -MIB, 'peak': -MIB}
    def row(self, step, process=1, **more):
        h = self.held(process)
        assert 0 <= h['sweep_held'] <= h['sweep_limit'], h
        assert h['held'] <= h['total_limit'] and h['peak'] <= h['total_limit'], h
        r = {'step': step, 'held_mib': h['held'] // MIB, 'peak_mib': h['peak'] // MIB, 'sweep': h['sweep_held'], 'sweep_limit': h['sweep_limit'], 'resources': resources(self.client.p.pid), 'hwm_mib': status(self.client.p.pid, 'VmHWM'), **more}
        print(json.dumps(r), flush=True); return r
    def line(self, process=1, label='line search'):
        s = self.settle(process); t = time.monotonic()
        reply = self.client.tool('run_to', process_id=process, generation=s['generation'], tid=self.tid(process), file='no_such_file_anywhere.c', line=3)['result']
        return self.row(label, process, seconds=round(time.monotonic() - t, 2), reply=text(reply)[:330])
    def capture(self, process=1, stop=False):
        s = self.settle(process); t = time.monotonic()
        reply = self.client.tool('start_profile', process_id=process, generation=s['generation'], duration_ms=60000, frequency_hz=99, tids=[self.tid(process)])['result']
        assert not reply.get('isError'), reply
        cap = reply['structuredContent']['capture']
        mh = cap.get('mapping_history') or {}
        r = self.row('start_profile', process, seconds=round(time.monotonic() - t, 2), opened_images=mh.get('opened_images'), not_searched=mh.get('images_not_searched'), image_budget=(mh.get('image_budget') or '').replace(str(root), '.'), error=text(reply)[:200] if reply.get('isError') else None)
        deadline = time.monotonic() + 30
        while True:
            current = self.client.inspect('get_profile', process_id=process)['capture']
            rejected = self.client.tool('release_profile', process_id=process, generation=self.settle(process)['generation'], capture_id=current['id'], revision=current['revision'])['result']
            assert rejected['isError'], rejected
            if text(rejected) == 'ProfileStillCollecting': break
            assert text(rejected) == 'StaleProfile' and time.monotonic() < deadline, rejected
        if stop and cap:
            self.client.tool('stop_profile', process_id=process, generation=self.settle(process)['generation'], capture_id=cap['id'])
            self.row('stop_profile', process)
        return r
    def stack(self, process=1, label='stack'):
        t = time.monotonic(); deadline = t + 300
        if a.agent:
            # Remote caller frames use metadata-only unwinding until their image
            # is explicitly selected. Selecting its address must have headroom.
            deadline_symbol = time.monotonic() + 30
            while True:
                reply = self.client.tool('find_symbol', process_id=process, name='honest_wait')['result']
                if not reply.get('isError'): break
                assert text(reply) == 'SymbolDiscoveryPending' and time.monotonic() < deadline_symbol, reply
                time.sleep(.005)
            self.client.inspect('get_source_location', process_id=process, generation=self.settle(process)['generation'], address=reply['structuredContent']['address'])
        while True:
            found = self.client.inspect('get_stack', process_id=process, generation=self.settle(process)['generation'], tid=self.tid(process))
            if not any(f['diagnostic'] == 'DebugMetadataPending' for f in found['frames']): break
            assert time.monotonic() < deadline; time.sleep(.01)
        fr = frames(found); honest = next((f for f in fr if f['symbol'] == ('wrong_name' if a.wrong_result else 'honest_wait')), None)
        assert honest and honest['source'], found
        return self.row(label, process, seconds=round(time.monotonic() - t, 2), frames=len(fr), honest_named=bool(honest), honest_source=bool(honest and honest['source']),
                        symbols=[f['symbol'] for f in fr][:6], budget_frames=sum(1 for f in fr if 'BinarySnapshotLimit' in (f['diag'], f['inline_diag'])), image_budget=(found.get('image_budget') or '').replace(str(root), '.'))
    def symbol(self, name, process=1):
        t = time.monotonic()
        for n in range(4000):
            reply = self.client.tool('find_symbol', name=name, process_id=process)['result']
            if not reply.get('isError') or reply['content'][0]['text'] != 'SymbolDiscoveryPending': break
            time.sleep(.005)
        return self.row(f'find_symbol {name}', process, seconds=round(time.monotonic() - t, 2), reply=text(reply)[:300])
    def close(self):
        err = ''
        if self.client and self.client.p.poll() is None:
            try: self.client.p.stdin.close(); self.client.p.wait(timeout=30)
            except Exception: self.client.p.kill(); self.client.p.wait()
            self.err_thread.join(timeout=5); err = b''.join(getattr(self, 'err', [])).decode(errors='replace')
        self.client = None; self.kill()
        lines = [l.replace(str(root), '.')[:300] for l in err.splitlines() if 'budget' in l or 'not searched' in l]
        print(json.dumps({'step': 'closed', 'stderr': lines[:4]}), flush=True)
    def kill(self):
        if self.client and self.client.p.poll() is None: self.client.p.kill(); self.client.p.wait()
        if self.target and self.target.poll() is None: self.target.kill(); self.target.wait()
        for pid in self.children:
            try: os.kill(pid, signal.SIGKILL)
            except ProcessLookupError: pass
        self.children.clear()
        for fd in (getattr(self, 'wfd', None), self.w2):
            if fd is not None:
                try: os.close(fd)
                except OSError: pass
        self.wfd = None; self.w2 = None

def release(t):
    cap = t.client.inspect('get_profile')['capture']
    for key, value, reason in (('capture_id', cap['id'] + 1, 'StaleCapture'), ('revision', cap['revision'] + 1, 'StaleProfile')):
        args = dict(generation=t.settle()['generation'], capture_id=cap['id'], revision=cap['revision']); args[key] = value
        reply = t.client.tool('release_profile', **args)['result']
        assert reply['isError'] and text(reply) == reason, reply
    deadline = time.monotonic() + 30
    while True:
        reply = t.client.tool('release_profile' , generation=t.settle()['generation'], capture_id=cap['id'], revision=cap['revision'])['result']
        if not reply.get('isError'): break
        assert text(reply) == 'ProfileViewPending' and time.monotonic() < deadline, reply
        time.sleep(.005)
    assert t.client.inspect('get_profile')['capture'] is None
    assert t.held()['sweep_held'] == 0, t.held()
    t.row('released')

def run(case):
    j = junkset('a')
    if case == 's4c':
        big = w/'bigexe'; big.write_bytes((w/'phase').read_bytes()); big.chmod(0o755); os.truncate(big, a.exe_mib * MIB); made.append(big)
        t = T(big, [j])
        try:
            t.row('attached'); t.capture()
            assert t.held()['held'] <= t.held()['total_limit'] - PER, t.held()
            t.stack()
        finally: t.close()
    elif case == 's6':
        k = junkset('b')
        t = T(w/'phase', [j, k], options=['--follow-forks'], env={'EXEC2': str(w/'phase2'), 'SKIP2': '1'})
        try:
            t.line(); before = t.held()['sweep_held']
            assert before > TOTAL // 2 - MIB, before
            t.w2 = os.open(t.cmd2, os.O_RDWR)
            t.send('f', 'forked'); t.wait('child'); t.stop(2); t.line(2)
            t.send('X', 'ready'); after = t.held()['sweep_held']
            if a.agent:
                # Separate agent file transfers have distinct snapshot identities:
                # the child's refused sweep retained only its small executable.
                assert 0 < after < before and after == t.held()['held'], (before, after, t.held())
            else:
                assert after == before, (before, after)
            t.line(); t.stop(2); t.stack(2); t.stack()
        finally: t.close()
    elif case in ('s9', 'replace'):
        own = build_lib(w, 5, 2*MIB, 'own.so'); made.append(own)
        t = T(w/'phase', [[*j, own]], launch=True)
        try:
            t.capture(stop=True)
            before = t.held()['sweep_held']; assert before > TOTAL // 2 - MIB, before
            if case == 's9': release(t)
            else:
                # The search retains its own image references; the restart
                # below clears them before replacement releases the capture.
                reply = t.client.tool('run_to', generation=t.settle()['generation'], tid=t.tid(), file='no_such_file_anywhere.c', line=3)['result']
                assert reply['isError'] and 'images not searched' in text(reply) and 'release_profile' in text(reply), reply
            (w/'lib.c').write_text(LIB + 'int rebuilt_once;\n')
            new = build_lib(w, 5, 2*MIB, 'own.so.new'); os.replace(new, own)
            t.client.inspect('restart', generation=t.settle()['generation']); t.to_breakpoint()
            if case == 's9':
                t.line()
                # The fresh identity is read by the line search after release.
                rows = t.client.inspect('list_modules', limit=64)['regions']
                rows = [r for r in rows if r['path'] == str(own)]
                assert rows and not any(r['full_image_deferred'] for r in rows), rows
                if a.agent:
                    # A second agent transfer is another copy. Release the line
                    # reader's images before testing the capture of that identity.
                    t.client.inspect('restart', generation=t.settle()['generation']); t.to_breakpoint()
                    assert t.held()['sweep_held'] == 0, t.held()
            got = t.capture(stop=True)
            assert 'own.so' not in (got.get('image_budget') or ''), got
            t.stop(); t.stack()
        finally: t.close()
    else: raise ValueError(case)

build()
(w/'lib.c').write_text(LIB)
cc('-g', '-O1', '-shared', '-fPIC', w/'lib.c', '-o', w/'small.so')
started = time.monotonic()
try:
    for case in a.only.split(','):
        print('case', case, flush=True)
        run(case)
finally:
    for path in made: path.unlink(missing_ok=True)
    for path in w.glob('cmd*'): path.unlink(missing_ok=True)
    (w/'honest.so').unlink(missing_ok=True)
    assert orphans.reap(), 'an owned fork child remains'
print(json.dumps({'status':'pass', 'cases':a.only, 'seconds':time.monotonic()-started}))
