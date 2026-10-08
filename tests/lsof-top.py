#!/usr/bin/env python3
"""lsof-top on owned fixtures only.

Cross-checks the JSON snapshot against /proc (and lsof when installed), checks
known byte rates, leaks, churn and a deleted-but-open file, renders every view
with --once, then drives the interactive UI through a pseudo-terminal at a fixed
size with a small screen model: views, drill-in, filter, sort, freeze, help,
resize, colour modes and terminal restoration after q, SIGTERM and a crash.

--screens DIR saves the redacted screens as text. --overhead N also measures
the interactive view's CPU at 1 s and 250 ms with N extra idle processes.
"""
import argparse
import fcntl
import getpass
import json
import os
from pathlib import Path
import re
import select
import shutil
import signal
import socket
import struct
import subprocess
import sys
import termios
import time

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--screens', help='save redacted text screens here')
parser.add_argument('--overhead', type=int, default=0, help='also measure with this many idle processes')
args = parser.parse_args()
xodb = Path(os.environ.get('XODB_BIN', root / 'zig-out/bin/xodb'))
fixture = root / 'zig-out/bin/xodb-fd-fixture'
work = root / '.work' / ('lsof-top-' + str(time.time_ns()))
work.mkdir(parents=True, mode=0o755)
os.chmod(work, 0o755)
started = []
forked = []
tuis = []
results = {}


def check(condition, message):
    if not condition:
        raise AssertionError(message)


def spawn(*argv):
    proc = subprocess.Popen([str(fixture), *map(str, argv)], stdout=subprocess.PIPE, stdin=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL, text=True)
    started.append(proc)
    line = proc.stdout.readline().split()
    check(line and line[0] == 'ready', f'fixture {argv} did not start: {line}')
    pids = [int(x) for x in line[1:] if x.isdigit()]
    forked.extend(pids[1:])
    return pids


def stop_all():
    for proc in started:
        if proc.poll() is None:
            proc.terminate()
    for proc in started:
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
    started.clear()
    # The fixtures reap their own children on SIGTERM.
    left = [pid for pid in forked if Path(f'/proc/{pid}').exists()]
    forked.clear()
    return left


def lsof_json(pids, *extra, samples=2, interval=1):
    out = subprocess.run([str(xodb), '--lsof-top', '--json', '--pid', ','.join(map(str, pids)), '--samples', str(samples),
                          '--interval', str(interval), *extra], capture_output=True, text=True, timeout=120)
    check(out.returncode == 0, f'--json failed: {out.stderr}')
    return json.loads(out.stdout)


def near(value, expected, tolerance):
    return abs(value - expected) <= expected * tolerance


# ------------------------------------------------------------------ screen
class Screen:
    """Enough of a VT100 to replay what lsof-top emits."""

    def __init__(self, cols, lines):
        self.resize(cols, lines)
        self.modes = set()
        self.raw = b''
        self.pending = b''

    def resize(self, cols, lines):
        self.cols, self.lines = cols, lines
        self.grid = [[' '] * cols for _ in range(lines)]
        self.row = self.col = 0

    def feed(self, data):
        self.raw += data
        data = self.pending + data
        self.pending = b''
        i = 0
        while i < len(data):
            b = data[i]
            if b == 0x1b:
                m = re.compile(rb'\x1b\[([?0-9;]*)([A-Za-z])').match(data, i)
                if not m:
                    if len(data) - i < 32:
                        self.pending = data[i:]
                        return
                    i += 1
                    continue
                self.csi(m.group(1).decode(), m.group(2).decode())
                i = m.end()
            elif b == 0x0d:
                self.col = 0
                i += 1
            elif b == 0x0a:
                self.row = min(self.row + 1, self.lines - 1)
                i += 1
            elif b < 0x20:
                i += 1
            else:
                n = 1 if b < 0x80 else 2 if b < 0xe0 else 3 if b < 0xf0 else 4
                if i + n > len(data):
                    self.pending = data[i:]
                    return
                ch = data[i:i + n].decode('utf-8', 'replace')
                if self.row < self.lines and self.col < self.cols:
                    self.grid[self.row][self.col] = ch
                # Autowrap is off (?7l): the cursor stays on the last column,
                # so a later erase-to-end-of-line would blank that cell.
                if 7 in self.modes or self.col < self.cols - 1:
                    self.col += 1
                i += n

    def csi(self, params, final):
        if params.startswith('?'):
            for p in params[1:].split(';'):
                (self.modes.add if final == 'h' else self.modes.discard)(int(p))
            return
        nums = [int(p) if p else 0 for p in params.split(';')] if params else []
        if final == 'H':
            self.row = max(1, nums[0] if nums else 1) - 1
            self.col = max(1, nums[1] if len(nums) > 1 else 1) - 1
        elif final == 'J':
            self.grid = [[' '] * self.cols for _ in range(self.lines)]
        elif final == 'K':
            for c in range(self.col, self.cols):
                self.grid[self.row][c] = ' '

    def text(self):
        return '\n'.join(''.join(line).rstrip() for line in self.grid)


class Tui:
    def __init__(self, argv, cols=120, lines=32, env=None, job_control=False, ctty=False):
        self.master, slave = os.openpty()
        self.setsize(slave, cols, lines)
        e = dict(os.environ, TERM='xterm-256color', LANG='C.UTF-8', LC_ALL='C.UTF-8')
        e.pop('NO_COLOR', None)
        e.pop('COLORTERM', None)
        e.update(env or {})
        # An orphaned process group discards SIGTSTP; job_control keeps this
        # test as the parent in the same session, like a shell.
        group = dict(process_group=0) if job_control else dict(start_new_session=True)
        if ctty:  # the pty becomes the controlling terminal, so Ctrl+\\ raises SIGQUIT
            group['preexec_fn'] = lambda: fcntl.ioctl(0, termios.TIOCSCTTY, 0)
        self.proc = subprocess.Popen([str(xodb), '--lsof-top', *argv], stdin=slave, stdout=slave, stderr=slave,
                                     env=e, close_fds=True, **group)
        os.close(slave)
        self.screen = Screen(cols, lines)
        self.cols, self.lines = cols, lines
        tuis.append(self)

    @staticmethod
    def setsize(fd, cols, lines):
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', lines, cols, 0, 0))

    def pump(self, seconds=0.05):
        end = time.monotonic() + seconds
        while True:
            left = end - time.monotonic()
            if left <= 0:
                return
            ready, _, _ = select.select([self.master], [], [], left)
            if not ready:
                return
            try:
                data = os.read(self.master, 65536)
            except OSError:
                return
            if not data:
                return
            self.screen.feed(data)

    def wait(self, predicate, what, timeout=15):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            self.pump(0.1)
            if predicate(self.screen.text()):
                return self.screen.text()
        raise AssertionError(f'timed out waiting for {what}:\n{self.screen.text()}')

    def keys(self, text):
        os.write(self.master, text.encode() if isinstance(text, str) else text)

    def resize(self, cols, lines):
        self.setsize(self.master, cols, lines)
        self.screen.resize(cols, lines)
        self.cols, self.lines = cols, lines
        os.kill(self.proc.pid, signal.SIGWINCH)

    def finish(self, timeout=10):
        end = time.monotonic() + timeout
        while self.proc.poll() is None and time.monotonic() < end:
            self.pump(0.05)
        self.pump(0.1)
        attrs = termios.tcgetattr(self.master)
        os.close(self.master)
        if self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait()
            raise AssertionError('lsof-top did not exit')
        return self.proc.returncode, attrs


def save(name, text):
    if args.screens:
        Path(args.screens).mkdir(parents=True, exist_ok=True)
        (Path(args.screens) / f'{name}.txt').write_text(text + '\n')


def private(text):
    """Strings that must never appear in a redacted capture."""
    paths = [str(work), str(root)]
    names = [getpass.getuser(), socket.gethostname()]  # whole tokens, as redaction matches them
    return [w for w in paths if w in text] + [w for w in names if w and re.search(rf'(?<![A-Za-z0-9_]){re.escape(w)}(?![A-Za-z0-9_])', text)]


try:
    # --------------------------------------------------------- fixtures
    churn = spawn('churn', work, 40)[0]
    leak = spawn('leak', 10, 5000)[0]  # still growing when the interactive part starts
    deleted_size = 3 * 1024 * 1024 + 123
    held = spawn('deleted', work, deleted_size)[0]
    writer = spawn('write', work, 1 << 20)[0]
    reader = spawn('read', work, 1 << 19, 64 << 20)[0]
    pair, pair_child = spawn('pair', 1 << 18)
    pids = [churn, leak, held, writer, reader, pair, pair_child]
    names = dict(zip(pids, ['churn', 'leak', 'held', 'writer', 'reader', 'pair', 'pair-child']))

    # ------------------------------------------------- JSON and /proc
    snap = lsof_json(pids, '--fds', samples=3)
    procs = {p['pid']: p for p in snap['processes']}
    check(set(procs) == set(pids), f'processes {sorted(procs)} != {sorted(pids)}')
    check(snap['scan']['hidden'] == 0 and snap['scan']['dropped_fds'] == 0, snap['scan'])
    # Static fd tables match /proc exactly (fd numbers and link targets).
    for pid in (held, writer, reader, pair, pair_child):
        table = {f['fd']: f for f in procs[pid]['fd_table']}
        real = {int(n): os.readlink(f'/proc/{pid}/fd/{n}') for n in os.listdir(f'/proc/{pid}/fd')}
        check(set(table) == set(real), f'{names[pid]} fds {sorted(table)} != /proc {sorted(real)}')
        for fd, target in real.items():
            shown = table[fd]['target'] + (' (deleted)' if table[fd]['deleted'] else '')
            check(shown == target, f'{names[pid]} fd {fd}: {shown!r} != {target!r}')
    # Known byte rates: per-interval /proc/PID/io and file offsets.
    w = procs[writer]
    check(near(w['write_per_s'], 1 << 20, 0.1) and near(w['advance_per_s'], 1 << 20, 0.1), f'writer {w}')
    r = procs[reader]
    check(near(r['read_per_s'], 1 << 19, 0.1) and near(r['advance_per_s'], 1 << 19, 0.1), f'reader {r}')
    check(near(procs[pair]['write_per_s'], 2 << 18, 0.1), f'pair writer {procs[pair]}')
    check(near(procs[pair_child]['read_per_s'], 2 << 18, 0.15), f'pair reader {procs[pair_child]}')
    check(procs[pair]['kinds']['socket'] == 1 and procs[pair_child]['kinds']['socket'] == 1, 'socketpair ends')
    files = snap['files']
    written = [f for f in files if f['path'].endswith('/written')]
    check(written and near(written[0]['write_per_s'], 1 << 20, 0.1), f'written file {written}')
    source = [f for f in files if f['path'].endswith('/source')]
    check(source and near(source[0]['read_per_s'], 1 << 19, 0.1) and source[0]['size'] == 64 << 20, f'source file {source}')
    # The data pipe is one file held by both sides of the pair.
    pipes = [f for f in files if f['kind'] == 'pipe' and f['holders'] == 2]
    check(any({f['sample_pid']} <= {pair, pair_child} for f in pipes), f'shared pipe {pipes}')
    gone = [f for f in files if f['deleted']]
    check(len(gone) == 1 and gone[0]['size'] == deleted_size and gone[0]['path'].endswith('/held'), f'deleted {gone}')
    check(snap['totals']['deleted_bytes'] == deleted_size, snap['totals'])
    # Churn as polling sees it: the rotating window changes the fd set.
    c = procs[churn]
    check(c['opened'] > 0 and c['closed'] > 0 and c['opened'] <= 8 and abs(c['d_count']) <= 8, f'churn {c}')
    results['json'] = dict(writer_write_per_s=w['write_per_s'], reader_read_per_s=r['read_per_s'],
                           pair_write_per_s=procs[pair]['write_per_s'], churn_opened=c['opened'])

    # lsof agrees on fd numbers, types and the deleted file's size.
    if shutil.which('lsof'):
        kinds = {'REG': 'file', 'DIR': 'dir', 'CHR': 'device', 'BLK': 'device', 'FIFO': 'pipe', 'unix': 'socket',
                 'sock': 'socket', 'IPv4': 'socket', 'IPv6': 'socket', 'a_inode': 'anon'}
        for pid in (held, writer, pair, pair_child):
            out = subprocess.run(['lsof', '-n', '-P', '-w', '-p', str(pid), '-F', 'ftsn'], capture_output=True, text=True, timeout=60).stdout
            seen, fd = {}, None
            for line in out.splitlines():
                tag, value = line[:1], line[1:]
                if tag == 'f':
                    fd = int(value) if value.isdigit() else None
                    if fd is not None:
                        seen[fd] = {}
                elif fd is not None and tag in 'tsn':
                    seen[fd][tag] = value
            table = {f['fd']: f for f in lsof_json([pid], '--fds', samples=1)['processes'][0]['fd_table']}
            check(set(seen) == set(table), f'lsof fds {sorted(seen)} != {sorted(table)}')
            for fd, entry in seen.items():
                check(kinds.get(entry.get('t')) == table[fd]['kind'], f'lsof {pid}:{fd} {entry} vs {table[fd]["kind"]}')
                if pid == held and table[fd]['deleted']:
                    check(int(entry.get('s', -1)) == deleted_size and '(deleted)' in entry.get('n', ''), f'lsof deleted {entry}')
        results['lsof'] = 'agrees'
    else:
        results['lsof'] = 'not installed'

    # Leak watch: steady growth with its kind breakdown.
    snap = lsof_json([leak, churn], samples=9, interval=0.25)
    leaky = {p['pid']: p for p in snap['processes']}
    check(leaky[leak]['leaking'] and leaky[leak]['growth'] >= 8, f'leaker {leaky[leak]}')
    check(set(leaky[leak]['growth_kinds']) <= {'pipe', 'device', 'anon'} and leaky[leak]['growth_kinds'].get('pipe', 0) > 0, leaky[leak])
    check(not leaky[churn]['leaking'], f'churner flagged {leaky[churn]}')

    # D4: a log reopened under the same name onto the same fd number is a
    # close plus an open, reported with the new file's inode.
    rotor = spawn('rotate', work)[0]
    rotated = 0
    for _ in range(3):
        snap = lsof_json([rotor], '--fds', samples=2, interval=1.2)  # longer than the 1 s rotation
        proc = snap['processes'][0]
        logs = [f for f in proc['fd_table'] if f['target'].endswith('/log')]
        if not logs:
            continue
        real = os.stat(f'/proc/{rotor}/fd/{logs[0]["fd"]}').st_ino
        if logs[0]['inode'] == real and proc['opened'] >= 1 and proc['closed'] >= 1:
            rotated = 1
            break
    check(rotated, f'rotation not seen as close+open with the new inode: {proc}')
    # D3: names that are not UTF-8 still give strict JSON.
    weird = work / os.fsdecode(b'bad\xf8\x80\x80name')
    weird.write_bytes(b'x')
    holder = subprocess.Popen([sys.executable, '-c', 'import sys,time; f=open(sys.argv[1],"rb"); print("ready", flush=True); time.sleep(60)', str(weird)],
                              stdout=subprocess.PIPE, text=True)
    started.append(holder)
    holder.stdout.readline()
    raw = subprocess.run([str(xodb), '--lsof-top', '--json', '--fds', '--samples', '1', '--pid', str(holder.pid)], capture_output=True, timeout=60).stdout
    doc = json.loads(raw.decode('utf-8', 'strict'))
    check(any('\ufffd' in f['target'] for f in doc['processes'][0]['fd_table']), 'replacement character expected')
    # Rewritten process titles keep their words out of redacted output.
    titled = spawn('title', 'x' * 64)[0]
    cmd = lsof_json([titled], '--redact', samples=1)['processes'][0]['cmd']
    check(cmd.startswith('fxtitle:') and 'private' not in cmd, f'redacted title {cmd!r}')
    check('private' in lsof_json([titled], samples=1)['processes'][0]['cmd'], 'title fixture')
    # IPv6 addresses in titles and command names are redacted too.
    for text in ('worker@2001:db8::5,fe80::1%eth0', 'fe80::1', '[2001:db8:0:1::42]:443', 'pad 2001:db8:1234::10.0.0.1'):
        six = spawn('title', 'x' * 64, text)[0]
        raw = json.dumps(lsof_json([six], '--redact', samples=1)['processes'][0])
        check('db8' not in raw and 'fe80' not in raw and 'eth0' not in raw and 'x:x::x' in raw, f'IPv6 not redacted: {raw}')
        out = subprocess.run([str(xodb), '--lsof-top', '--once', '--redact', '--pid', str(six), '--size', '120x12'],
                             capture_output=True, text=True, timeout=60).stdout
        check('db8' not in out and 'fe80' not in out, f'IPv6 in redacted frame:\n{out}')
    # Ordinary words with colons are not mistaken for addresses.
    titled = spawn('title', 'x' * 64, 'std::vector-ab:cd')[0]
    check('std::vector' in lsof_json([titled], '--redact', samples=1)['processes'][0]['cmd'], 'over-redacted C++ name')
    # D5/D6: under a tight budget rates stay per process and every listed
    # process is counted somewhere.
    idle = subprocess.Popen([str(fixture), 'idle', '300'], stdout=subprocess.PIPE, stdin=subprocess.DEVNULL, text=True)
    started.append(idle)
    check(idle.stdout.readline().startswith('ready'), 'idle fixture')
    kids = [int(x) for x in Path(f'/proc/{idle.pid}/task/{idle.pid}/children').read_text().split()]
    listed = [1, writer, *kids[:150]]
    seen_rate = 0
    # Each invocation starts a new scan cursor. Sixteen samples may not cover
    # two laps under load, especially when PID wrap puts the writer last.
    # Increase the observation window while retaining the same 1 ms budget.
    for sample_count in (16, 32, 64, 128):
        snap = lsof_json(listed, '--budget-ms', '1', samples=sample_count, interval=0.25)
        sc = snap['scan']
        check(sc['processes'] + sc['hidden'] + sc['kernel_threads'] + sc['unscanned'] + sc['gone'] == len(listed), f'counts {sc}')
        check(sc['stale'] + sc['unscanned'] > 0, f'budget never bit {sc}')
        for f in snap['files']:
            if f['path'].endswith('/written') and f['write_per_s'] > 0:
                check(near(f['write_per_s'], 1 << 20, 0.1), f'budget rate {f}')
                seen_rate += 1
        for p in snap['processes']:
            if p['pid'] == writer and p['write_per_s'] > 0:
                check(near(p['write_per_s'], 1 << 20, 0.1), f'budget process rate {p}')
        if seen_rate:
            break
    check(seen_rate, 'writer rate never shown under the budget')
    if Path('/proc/1').stat().st_uid != os.geteuid():
        check(snap['scan']['hidden'] + sc['unscanned'] >= 1, 'pid 1 counted')
    # D7: an option after "--" belongs to the launched program.
    if xodb.name == 'xodb':  # not the standalone build, which has no debugger to fall back to
        out = subprocess.run([str(xodb), '--help', '--', 'prog', '--lsof-top'], capture_output=True, text=True, timeout=30)
        check('native Linux debugger' in out.stdout + out.stderr, 'argv after -- was taken as --lsof-top')

    # Redacted JSON carries no private strings.
    red = json.dumps(lsof_json(pids, '--fds', '--redact', samples=1))
    check(not private(red), f'redacted JSON leaks {private(red)}')

    # A missing/dumb TERM deliberately selects one snapshot. Other terminal
    # types require a TTY for the interactive view, independent of our runner.
    for term in (None, 'dumb', 'foot', 'xterm-256color'):
        env = dict(os.environ)
        if term is None:
            env.pop('TERM', None)
        else:
            env['TERM'] = term
        out = subprocess.run([str(xodb), '--lsof-top', '--pid', str(os.getpid()), '--redact'],
                             env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30)
        if term in (None, 'dumb'):
            check(out.returncode == 0 and 'lsof-top' in out.stdout and '\x1b' not in out.stdout,
                  f'TERM={term!r}: snapshot fallback: {out.stderr}')
        else:
            check(out.returncode == 2 and 'needs a terminal' in out.stderr,
                  f'TERM={term!r}: interactive refusal: {out.stderr}')
    out = subprocess.run([str(xodb), '--lsof-top', '--interval', 'x'], capture_output=True, text=True, timeout=30)
    check(out.returncode == 2, 'bad interval accepted')

    # ------------------------------------------------------- --once
    plain = ','.join(map(str, pids))
    for view, expect in (('processes', 'CHURN/s'), ('files', 'IO/s'), ('leaks', 'ACCUMULATING'), ('deleted', 'PINNED')):
        out = subprocess.run([str(xodb), '--lsof-top', '--once', '--redact', '--pid', plain, '--view', view, '--size', '120x24'],
                             capture_output=True, text=True, timeout=60)
        check(out.returncode == 0, out.stderr)
        lines = out.stdout.splitlines()
        check(len(lines) == 24 and all(len(line) <= 120 for line in lines), f'{view}: frame shape')
        check('lsof-top' in lines[0] and 'Files' in lines[2] and expect in lines[3], f'{view} frame:\n{out.stdout}')
        check('\x1b' not in out.stdout and not private(out.stdout), f'{view}: escapes or private text')
        save(f'once-{view}', out.stdout.rstrip('\n'))

    # ---------------------------------------------------- interactive
    tui = Tui(['--pid', plain, '--interval', '0.5', '--redact'], 120, 32)
    text = tui.wait(lambda t: 'xodb-fd-fixture' in t and 'CHURN/s' in t, 'processes view')
    check(1049 in tui.screen.modes and 25 not in tui.screen.modes, 'alternate screen, hidden cursor')
    wide = subprocess.run([str(xodb), '--lsof-top', '--once', '--pid', plain, '--size', '160x12', '--samples', '2', '--interval', '0.25'],
                          capture_output=True, text=True, timeout=60).stdout
    check(' pk ' in wide.splitlines()[1], f'peak shown from 140 columns: {wide.splitlines()[1]!r}')
    check(b'\x1b[?2026h' in tui.screen.raw and b'\x1b[?2026l' in tui.screen.raw, 'synchronized output')
    check(b';38;5;' in tui.screen.raw, '256 colours')
    tui.wait(lambda t: re.search(r'read\s+\S+/s', t) and ' pk ' not in t, 'header rates (no peak below 140 columns)')
    tui.pump(1.2)
    save('tui-processes', tui.screen.text())
    tui.keys('1')
    text = tui.wait(lambda t: 'IO/s' in t and '/written' in t and '/source' in t, 'files view')
    check(re.search(r'\d+(\.\d)?[KM]/s w\s+file.*/written', text), f'writer row:\n{text}')
    save('tui-files', text)
    # Idle files of one kind and holder set share a row; Enter expands it.
    check(re.search(r'\d+ pipes \u00b7 both ends in xodb-fd-fixture\[%d\]' % leak, text), f'collapsed pipes:\n{text}')
    check(b'48;5;24' in tui.screen.raw and '\u25b8' in text, 'selection band and marker')
    for _ in range(12):
        if any(line.startswith('\u25b8') and '(Enter)' in line for line in tui.screen.text().splitlines()):
            break
        tui.keys('j')
        tui.pump(0.2)
    tui.keys('\r')
    text = tui.wait(lambda t: 'group' in t.splitlines()[2], 'expanded group')
    save('tui-files-group', text)
    tui.keys('\x1b')
    tui.wait(lambda t: '(Enter)' in t and 'group' not in t.splitlines()[2], 'collapsed again')
    tui.keys('3')
    text = tui.wait(lambda t: 'ACCUMULATING' in t and f'{leak}' in t, 'leaks view')
    save('tui-leaks', tui.screen.text())
    tui.keys('4')
    text = tui.wait(lambda t: 'PINNED' in t and '/held' in t and '3.0M' in t, 'deleted view')
    save('tui-deleted', text)
    # Drill into the deleted file's holders, then that holder's fd table.
    tui.keys('\r')
    text = tui.wait(lambda t: 'holders' in t and str(held) in t, 'holders view')
    save('tui-holders', text)
    tui.keys('\r')
    text = tui.wait(lambda t: f'fds of {held}' in t and '(deleted)' in t, 'holder fd table')
    tui.keys('\x1b')
    tui.wait(lambda t: 'holders' in t and 'fds of' not in t, 'back to holders')
    tui.keys('\x1b')
    tui.wait(lambda t: 'PINNED' in t, 'back to deleted')
    # Filter the processes view to the writer, open its fd table, watch the offset advance.
    tui.keys('2/')
    tui.keys(str(writer))
    tui.keys('\r')
    text = tui.wait(lambda t: f'filter "{writer}"' in t and len(re.findall(r'^[ \u25b8]\s*\d+ user', t, re.M)) == 1, 'filtered processes')
    tui.keys('\r')
    text = tui.wait(lambda t: f'fds of {writer}' in t and '/written' in t, 'writer fd table')

    def offset(t):
        m = re.search(r'^[ \u25b8]\s*\d+ file\s+w\s+\S*\s+(\S+)\s+(\S+/s)\s.*/written', t, re.M)
        return m and m.group(1)
    first = tui.wait(offset, 'writer offset')
    tui.wait(lambda t: offset(t) and offset(t) != offset(first), 'offset advancing')
    save('tui-fd-table', tui.screen.text())
    tui.keys('\x1b')
    tui.wait(lambda t: 'CHURN/s' in t, 'back to processes')
    tui.keys('\x1b')  # clears the filter
    tui.wait(lambda t: 'filter "' not in t and str(leak) in t, 'filter cleared')
    tui.keys('s')
    tui.wait(lambda t: 'sort fds' in t, 'sort cycles')
    tui.keys('r')
    tui.wait(lambda t: 'sort fds \u25b2' in t, 'sort reverses')
    # D8: keys typed ahead across a view switch act on the new view's list.
    tui.keys('j')
    tui.pump(0.2)
    tui.keys('j')
    tui.pump(0.2)
    tui.keys('1')
    tui.wait(lambda t: 'IO/s' in t and '(Enter)' in t, 'files view with groups')
    tui.keys(b'2\r')  # one write: the switch and Enter arrive in one read
    text = tui.wait(lambda t: re.search(r'fds of [1-9]\d* ', t) or tui.proc.poll() is not None, 'fd table after typeahead')
    check(tui.proc.poll() is None and 'fds of 0' not in text, f'typeahead across a view switch:\n{text}')
    tui.keys(b'1\x1b2gj\r')  # a whole burst, ending in the processes view
    text = tui.wait(lambda t: re.search(r'fds of [1-9]\d* ', t) or tui.proc.poll() is not None, 'fd table after burst')
    check(tui.proc.poll() is None and 'fds of 0' not in text, f'burst:\n{text}')
    tui.keys('\x1b')
    tui.wait(lambda t: 'CHURN/s' in t, 'back to processes after typeahead')
    tui.keys('?')
    tui.wait(lambda t: 'Columns' in t and 'CHURN/s   fd-set changes' in t, 'help')
    save('tui-help', tui.screen.text())
    tui.keys('?')
    tui.wait(lambda t: 'Columns' not in t, 'help closed')
    tui.keys('+')
    tui.wait(lambda t: 'sampling every 1s' in t and 'poll 1s' in t, 'slower sampling')
    tui.keys('-')
    tui.wait(lambda t: 'poll 0.5s' in t, 'faster sampling')
    tui.keys(' ')
    text = tui.wait(lambda t: 'FROZEN' in t, 'frozen')
    tui.pump(1.2)
    check('FROZEN' in tui.screen.text(), 'stays frozen')
    tui.keys(' ')
    tui.wait(lambda t: re.search(r'\+00:\d\d:\d\d', t), 'resumed')
    tui.resize(90, 24)
    text = tui.wait(lambda t: 'lsof-top' in t and 'CHURN/s' in t and len(t.splitlines()) <= 24, 'resized')
    tui.pump(0.8)
    lines = tui.screen.text().splitlines()
    check(len(lines) == 24 and all(len(line) <= 90 for line in lines) and lines[-1].strip(), 'resized frame')
    # Rows drawn to the edge keep their last column (no erase after them).
    check(any(len(line) == 90 for line in lines[4:-1]), 'last column kept:\n' + '\n'.join(lines))
    check(b'\x1b[K' not in tui.screen.raw, 'erase-to-end after a full-width row')
    save('tui-narrow', tui.screen.text())
    check(not private(tui.screen.raw.decode('utf-8', 'replace')), 'redacted TUI leaks private text')
    tui.keys('q')
    code, attrs = tui.finish()
    if args.screens:
        (Path(args.screens) / 'tui-session.ansi').write_bytes(tui.screen.raw)
    check(code == 0, f'q exit {code}')
    check(tui.screen.raw.rstrip().endswith(b'\x1b[?1049l') and 1049 not in tui.screen.modes and 25 in tui.screen.modes, 'screen restored')
    check(attrs[3] & termios.ECHO and attrs[3] & termios.ICANON, 'termios restored after q')

    # SIGTERM and a crash both restore the terminal.
    for sig in (signal.SIGTERM, signal.SIGSEGV):
        tui = Tui(['--pid', plain], 100, 24)
        tui.wait(lambda t: 'CHURN/s' in t, 'started')
        os.kill(tui.proc.pid, sig)
        code, attrs = tui.finish()
        check(code == (0 if sig == signal.SIGTERM else -signal.SIGSEGV), f'{sig.name} exit {code}')
        check(b'\x1b[?1049l' in tui.screen.raw and attrs[3] & termios.ECHO and attrs[3] & termios.ICANON, f'{sig.name} restore')
    # Suspend restores the terminal; continuing redraws.
    tui = Tui(['--pid', plain], 100, 24, job_control=True)
    tui.wait(lambda t: 'CHURN/s' in t, 'started')
    mark = len(tui.screen.raw)
    os.kill(tui.proc.pid, signal.SIGTSTP)
    end = time.monotonic() + 10
    while time.monotonic() < end and Path(f'/proc/{tui.proc.pid}/stat').read_text().rsplit(') ', 1)[1][0] != 'T':
        tui.pump(0.05)
    tui.pump(0.2)
    check(b'\x1b[?1049l' in tui.screen.raw[mark:], 'suspend left the alternate screen')
    check(termios.tcgetattr(tui.master)[3] & termios.ECHO, 'suspend restored echo')
    mark = len(tui.screen.raw)
    os.kill(tui.proc.pid, signal.SIGCONT)
    tui.wait(lambda t: b'\x1b[?1049h' in tui.screen.raw[mark:] and 'CHURN/s' in t, 'redrawn after continue')
    check(not termios.tcgetattr(tui.master)[3] & termios.ECHO, 'raw again after continue')
    tui.keys('q')
    code, _ = tui.finish()
    check(code == 0, f'exit after suspend {code}')
    # Ctrl+\\ and the other default-fatal signals restore the terminal too.
    for sig in (signal.SIGQUIT, signal.SIGUSR1, signal.SIGALRM):
        tui = Tui(['--pid', plain], 100, 24, ctty=True)
        tui.wait(lambda t: 'CHURN/s' in t, 'started')
        if sig == signal.SIGQUIT:
            tui.keys(b'\x1c')  # Ctrl+\\ through the line discipline
        else:
            os.kill(tui.proc.pid, sig)
        code, attrs = tui.finish()
        check(code == -sig, f'{sig.name} exit {code}')
        check(b'\x1b[?1049l' in tui.screen.raw and attrs[3] & termios.ECHO and attrs[3] & termios.ICANON, f'{sig.name} restore')
    # TERM=dumb gets one plain frame, not the full-screen interface.
    tui = Tui(['--pid', plain, '--size', '100x20'], 100, 24, {'TERM': 'dumb'})
    code, _ = tui.finish(20)
    check(code == 0 and b'\x1b[?1049h' not in tui.screen.raw and b'lsof-top' in tui.screen.raw, 'TERM=dumb')
    # At 80x24 the footer still says how to get help and quit.
    tui = Tui(['--pid', plain, '--redact'], 80, 24)
    text = tui.wait(lambda t: 'CHURN/s' in t and ' pk ' not in t and re.search(r'read\s+\S+/s', t), 'started')
    check(not private(text), 'redacted 80x24 capture')
    check('? help' in text.splitlines()[-1] and 'q quit' in text.splitlines()[-1], 'footer at 80x24')
    save('tui-80x24', text)
    tui.keys('?')
    tui.wait(lambda t: 'more:' in t, 'help says it scrolls at 24 lines')
    for _ in range(12):
        tui.keys('j')
        tui.pump(0.05)
    tui.wait(lambda t: 'counted as hidden' in t and 'more:' not in t, 'help scrolled to its end')
    tui.keys(' ')  # leaves help and freezes
    text = tui.wait(lambda t: 'frozen' in t.splitlines()[-1], 'frozen message')
    check('? help' in text.splitlines()[-1] and 'q quit' in text.splitlines()[-1], f'frozen footer: {text.splitlines()[-1]!r}')
    tui.keys('?')
    tui.wait(lambda t: 'more:' in t, 'help again')
    tui.keys('q')
    code, _ = tui.finish()
    check(code == 0, 'q quits from help')
    # 16 colours and NO_COLOR.
    for env, want, banned in (({'TERM': 'xterm'}, rb'\x1b\[0;3[1-6]m', b'38;5;'), ({'NO_COLOR': '1'}, rb'\x1b\[0;1m', b'38;5;')):
        tui = Tui(['--pid', plain], 100, 24, env)
        tui.wait(lambda t: 'CHURN/s' in t, 'started')
        tui.keys('q')
        tui.finish()
        check(re.search(want, tui.screen.raw) and banned not in tui.screen.raw, f'colour mode {env}')
        if 'NO_COLOR' in env:
            check(not re.search(rb'\x1b\[[0-9;]*3[0-7]m', tui.screen.raw), 'NO_COLOR still has colours')
    # Nothing to show anywhere: every view and drill-in copes with empty lists.
    tui = Tui(['--pid', str((1 << 22) + 12345)], 100, 24)
    tui.wait(lambda t: 'nothing to show' in t, 'empty processes')
    for k in ('1', '\r', '3', '\r', '4', '\r', 's', 'r', '/', 'x', '\r', '\x1b'):
        tui.keys(k)
        tui.pump(0.1)
    tui.wait(lambda t: 'no deleted files are held open' in t, 'empty deleted view')
    # A terminal that goes away ends the program instead of leaving it spinning.
    os.close(tui.master)
    try:
        code = tui.proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        raise AssertionError('lsof-top kept running after hangup')
    check(code == 0, f'hangup exit {code}')
    tuis.remove(tui)
    results['tui'] = 'views, drill-in, filter, sort, help, freeze, resize, empty lists, q/SIGTERM/SIGSEGV/hangup/suspend, 256/16/no colour'

    # ------------------------------------------------------- overhead
    if args.overhead:
        idle = subprocess.Popen([str(fixture), 'idle', str(args.overhead)], stdout=subprocess.PIPE, stdin=subprocess.DEVNULL, text=True)
        started.append(idle)
        check(idle.stdout.readline().startswith('ready'), 'idle fixture')
        total = len([d for d in os.listdir('/proc') if d.isdigit()])
        measured = {}
        for interval in (1, 0.25):
            tui = Tui(['--interval', str(interval)], 160, 50)
            tui.wait(lambda t: 'CHURN/s' in t, 'started', 30)
            tui.pump(2)

            def cpu(pid):
                fields = Path(f'/proc/{pid}/stat').read_text().rsplit(') ', 1)[1].split()
                return (int(fields[11]) + int(fields[12])) / os.sysconf('SC_CLK_TCK')
            before, t0 = cpu(tui.proc.pid), time.monotonic()
            tui.pump(20)
            used, wall = cpu(tui.proc.pid) - before, time.monotonic() - t0
            m = re.search(r'scan ([\d.]+)ms', tui.screen.text())
            rss = int(Path(f'/proc/{tui.proc.pid}/status').read_text().split('VmRSS:')[1].split()[0])
            tui.keys('q')
            tui.finish()
            measured[str(interval)] = dict(cpu_percent=round(100 * used / wall, 2), last_scan_ms=float(m.group(1)) if m else None, rss_kib=rss)
        snap = json.loads(subprocess.run([str(xodb), '--lsof-top', '--json', '--samples', '2'], capture_output=True, text=True, timeout=120).stdout)
        results['overhead'] = dict(processes_in_proc=total, scanned=snap['scan']['processes'], hidden=snap['scan']['hidden'],
                                   fds=snap['totals']['fds'], json_scan_ms=snap['scan']['ms'], json_scan_cpu_ms=snap['scan']['cpu_ms'], interactive=measured)
    print(json.dumps(results, indent=2))
    print('lsof-top: ok')
finally:
    for tui in tuis:
        if tui.proc.poll() is None:
            tui.proc.kill()
            tui.proc.wait()
    left = stop_all()
    shutil.rmtree(work, ignore_errors=True)
    if left and sys.exc_info()[0] is None:
        raise AssertionError(f'fixture children left behind: {left}')
