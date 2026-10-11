#!/usr/bin/env python3
"""Live end-to-end test: xodb on this host debugs an owned process on an
Apple-silicon Mac through Apple's debugserver.

Explicit and periodic only; it needs a Mac reachable with `ssh HOST` (keys,
no prompt), Xcode selected there and Developer mode enabled. debugserver has
no authentication: it is bound to the Mac's loopback and reached through an
SSH local forward, never over the network. Everything on the Mac lives in
--remote-dir; only processes started here are signalled, by PID.

--record FILE also writes the scrubbed packet transcript that
tests/gdb-debugserver.py replays without a Mac.
"""
import argparse
import json
import os
from pathlib import Path
import random
import re
import shlex
import socket
import subprocess
import sys
import threading
import time

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from client import Client
from helpers import debugserver_scenario, rsp

ROOT = Path(__file__).resolve().parents[1]
GUARD = '[ "$(uname -s)" = Darwin ] || exit 9; '
# Never a prompt; and no client notices, which would put the Mac's address into the evidence log.
SSH = ('-o', 'BatchMode=yes', '-o', 'LogLevel=ERROR')
SYMBOLS = ('marker', 'halves', 'want_signal', 'want_watch', 'got_signal', 'tick', 'inner', 'middle', 'outer', 'main')
FIND = ('DS=$(xcrun --find debugserver 2>/dev/null); '
        '[ -x "$DS" ] || DS="$(xcode-select -p)/../SharedFrameworks/LLDB.framework/Resources/debugserver"; '
        '[ -x "$DS" ] || DS=/Library/Developer/CommandLineTools/Library/PrivateFrameworks/LLDB.framework/Resources/debugserver; '
        '[ -x "$DS" ] || { echo "no debugserver: select Xcode or install the command line tools" >&2; exit 7; }; ')


class Mac:
    def __init__(self, host, directory, log):
        self.host, self.directory, self.log = host, directory, log

    def run(self, script, stdin=None, check=True, timeout=60):
        """Every command checks for Darwin first and runs inside the test directory."""
        command = GUARD + f'mkdir -p {self.directory} && cd {self.directory} || exit 8; ' + script
        done = subprocess.run(['ssh', *SSH, '-o', 'ConnectTimeout=10', self.host, command],
                              input=stdin, capture_output=True, timeout=timeout)
        self.log.write(f'$ {script}\n[{done.returncode}] {done.stdout.decode(errors="replace")}{done.stderr.decode(errors="replace")}\n'); self.log.flush()
        if done.returncode == 9: raise SystemExit('remote host is not running Darwin; nothing was started')
        if check and done.returncode: raise AssertionError(f'remote command failed ({done.returncode}): {script}\n{done.stderr.decode(errors="replace")}')
        return done.stdout.decode(errors='replace')


def listening(process, port):
    """True once this ssh process holds the local forward; connecting would use up the stub's one accept."""
    assert process.poll() is None, 'ssh tunnel exited: ' + (process.stderr.read().decode(errors='replace') if process.stderr else '')
    inodes = set()
    for fd in Path(f'/proc/{process.pid}/fd').iterdir():
        try:
            link = os.readlink(fd)
            if link.startswith('socket:['): inodes.add(link[8:-1])
        except FileNotFoundError: pass
    for line in Path(f'/proc/{process.pid}/net/tcp').read_text().splitlines()[1:]:
        fields = line.split()
        if fields[3] == '0A' and fields[9] in inodes and int(fields[1].split(':')[1], 16) == port:
            assert fields[1].split(':')[0] == '0100007F', 'tunnel must listen on loopback only'
            return True
    return False


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0)); return sock.getsockname()[1]


class Recorder(threading.Thread):
    """Loopback relay between xodb and the tunnel that keeps both byte streams in arrival order."""
    def __init__(self, target):
        super().__init__(daemon=True)
        self.listener = socket.socket(); self.listener.bind(('127.0.0.1', 0)); self.listener.listen(1)
        self.port, self.target, self.chunks = self.listener.getsockname()[1], target, []

    def run(self):
        import select
        self.listener.settimeout(60)
        try: near, _ = self.listener.accept()
        except OSError: return
        far = socket.create_connection(('127.0.0.1', self.target), timeout=10)
        for end in (near, far): end.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        try:
            while True:
                for ready in select.select([near, far], [], [], 120)[0]:
                    data = ready.recv(65536)
                    if not data: return
                    (far if ready is near else near).sendall(data)
                    self.chunks.append(('c' if ready is near else 's', data))
        except OSError: pass
        finally: near.close(); far.close(); self.listener.close()

    def exchanges(self):
        """[request, [replies]] in order. Acks are link state, not content, and are dropped."""
        buffers, result = {'c': bytearray(), 's': bytearray()}, []
        for side, data in self.chunks:
            buffers[side] += data
            for kind, payload in rsp.split(buffers[side]):
                if kind in ('ack', 'nak'): continue
                text = '\x03' if kind == 'interrupt' else payload.decode('latin-1')
                if side == 'c': result.append([text, []])
                else: result[-1][1].append(text)
        return result


def scrub(exchanges, replace, forbidden):
    """Synthetic process and thread identities, neutral paths; then prove nothing private is left."""
    threads = {}
    for request, replies in exchanges:
        if request in ('qfThreadInfo', 'qsThreadInfo'):
            for reply in replies:
                for tid in filter(None, reply[1:].split(',')) if reply.startswith('m') else ():
                    threads.setdefault(tid, f'{0x1001 + len(threads):x}')
        for reply in replies:
            for tid in re.findall(r'(?:^T[0-9a-f]{2}|;)thread:([0-9a-f]+);', reply): threads.setdefault(tid, f'{0x1001 + len(threads):x}')
    ids = '|'.join(sorted(threads, key=len, reverse=True)) or 'none'
    def fix(text, request=None):
        for old, new in replace: text = text.replace(old, new)
        text = re.sub(rf'(thread:|QC|Hg|Hc|qThreadStopInfo|vCont;[sS][0-9a-f]*:|vCont;C[0-9a-f]+:)({ids})(?![0-9a-f])', lambda m: m.group(1) + threads[m.group(2)], text)
        text = re.sub(r'(?<![a-z_])threads:([0-9a-f,]+);', lambda m: 'threads:' + ','.join(threads.get(t, t) for t in m.group(1).split(',')) + ';', text)
        if request in ('qfThreadInfo', 'qsThreadInfo') and text.startswith('m'):
            text = 'm' + ','.join(threads.get(t, t) for t in text[1:].split(','))
        if request == 'qProcessInfo':
            for key, value in (('pid', '4d2'), ('parent-pid', '4d1'), ('real-uid', '3e8'), ('real-gid', '3e8'), ('effective-uid', '3e8'), ('effective-gid', '3e8')):
                text = re.sub(rf'\b{key}:[0-9a-f]+;', f'{key}:{value};', text)
        return text
    cleaned = [[fix(request), [fix(reply, request) for reply in replies]] for request, replies in exchanges]
    blob = json.dumps(cleaned).lower()
    for word in forbidden:
        assert word.lower() not in blob, f'transcript still contains {word!r}; not written'
    assert '/users/' not in blob and '/home/' not in blob, 'transcript still contains a home path; not written'
    for tid in threads: assert not re.search(rf'(thread:|QC|Hg)({tid})(?![0-9a-f])', blob), 'transcript still contains a real thread id'
    return cleaned


def case(args, mac, mode, work, record):
    directory = work / mode; directory.mkdir(mode=0o755)
    remote = mac.run('pwd -P').strip()
    static = {'symbols': {}, 'sigusr1': 30, 'sigstop': 17}
    for line in mac.run('nm -n fixture').splitlines():
        parts = line.split()
        if len(parts) == 3 and parts[2][1:] in SYMBOLS: static['symbols'][parts[2][1:]] = int(parts[0], 16)
    assert set(static['symbols']) == set(SYMBOLS), static
    tunnel = client = None
    pids = {}
    try:
        for _ in range(5):
            port = random.randrange(49152, 65000)
            # Ask about this port only: a full listing would copy the Mac's other listeners into the evidence log.
            if f':{port} ' not in mac.run(f'lsof -nP -iTCP:{port} -sTCP:LISTEN 2>/dev/null || true'): break
        else: raise AssertionError('no free port found on the Mac')
        mac.run('rm -f out.txt ds.log ds.pid fx.pid')
        if mode == 'attach':
            mac.run('nohup ./fixture > out.txt 2>&1 < /dev/null & echo $! > fx.pid')
            mac.run('for i in 1 2 3 4 5 6 7 8 9 10; do grep -q ^ready out.txt && exit 0; sleep 0.2; done; exit 1')
            start = f'--attach=$(cat fx.pid)'
        else:
            start = f'--stdout-path {shlex.quote(remote + "/out.txt")} ./fixture'
        mac.run(FIND + f'nohup "$DS" 127.0.0.1:{port} {start} > ds.out 2> ds.log < /dev/null & echo $! > ds.pid')
        deadline = time.monotonic() + 15
        while True:
            sockets = [line for line in mac.run('lsof -nP -a -p $(cat ds.pid) -iTCP -sTCP:LISTEN 2>/dev/null || true').splitlines() if 'LISTEN' in line]
            if sockets: break
            assert time.monotonic() < deadline, 'debugserver did not listen: ' + mac.run('cat ds.log ds.out', check=False)
            time.sleep(.2)
        assert all(f'127.0.0.1:{port} ' in line for line in sockets), f'debugserver must listen on loopback only: {sockets}'
        pids['debugserver'] = int(mac.run('cat ds.pid'))
        children = mac.run(f'cat fx.pid 2>/dev/null || ps -axo pid=,ppid= | awk \'$2 == {pids["debugserver"]} {{print $1}}\'').split()
        assert len(children) == 1, children
        pids['fixture'] = int(children[0])
        local = free_port()
        tunnel = subprocess.Popen(['ssh', *SSH, '-o', 'ExitOnForwardFailure=yes', '-N',
                                   '-L', f'127.0.0.1:{local}:127.0.0.1:{port}', args.ssh], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        deadline = time.monotonic() + 15
        while not listening(tunnel, local):
            assert time.monotonic() < deadline, 'ssh tunnel did not come up'
            time.sleep(.05)
        recorder = None
        if record:
            recorder = Recorder(local); recorder.start(); local = recorder.port
        lines = []
        def log(text): lines.append(text); print(f'  {mode}: {text}', flush=True)
        def printed():
            told = {}
            for line in mac.run('cat out.txt').splitlines():
                name, _, value = line.partition('=')
                if value: told[name] = int(value, 0)
            assert told['pid'] == pids['fixture'], (told, pids)
            return told
        client = Client('mutate', executable=None, options=('--gdb-remote', f'127.0.0.1:{local}'), reply_seconds=30)
        try: debugserver_scenario.run(client, static, printed, log, launched=mode == 'launch')
        finally:
            (directory / 'mcp.json').write_text(json.dumps(client.transcript, indent=1) + '\n')
            (directory / 'scenario.log').write_text('\n'.join(lines) + '\n')
            closing, client = client, None
            closing.close()
        # Detach leaves the process running: xodb never kills a stub's target.
        alive = mac.run(f'ps -p {pids["fixture"]} -o comm= || true').strip()
        assert alive.endswith('fixture'), f'fixture should survive detach: {alive!r}'
        log('fixture still running after detach')
        if recorder:
            recorder.join(timeout=5)
            account = mac.run('id -un').strip()
            cleaned = scrub(recorder.exchanges(), [(remote, '/tmp/xodb-fixture')],
                            [account, args.ssh, os.environ.get('USER', '\0'), remote, socket.gethostname()])
            Path(record).write_text(json.dumps({'comment': 'Packets recorded from Apple debugserver with tests/macos-debugserver.py --record; process and thread identities are synthetic.',
                                                 'static': static, 'exchanges': cleaned}, indent=0) + '\n')
            log(f'transcript: {len(cleaned)} exchanges')
        return dict(case=mode, status='pass')
    finally:
        if client:
            try: client.close()
            except Exception: pass
        if tunnel:
            tunnel.terminate()
            try: tunnel.wait(timeout=5)
            except subprocess.TimeoutExpired: tunnel.kill(); tunnel.wait()
        # Only the two PIDs started above, and only while they still are those programs.
        for name, pid in pids.items():
            mac.run(f'ps -p {pid} -o comm= | grep -q {name} && kill -9 {pid}; true', check=False)
        if pids:
            left = mac.run('sleep 0.3; ps -p ' + ','.join(map(str, pids.values())) + ' -o pid=,comm= || true', check=False).strip()
            assert not left, f'processes left on the Mac: {left}'


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--ssh', required=True, metavar='HOST', help='ssh destination of the Mac; there is no default')
    parser.add_argument('--work', required=True, help='Fresh local evidence directory')
    parser.add_argument('--remote-dir', default='xodb-debugserver-test', help='Directory on the Mac, relative to its home (default %(default)s)')
    parser.add_argument('--xodb', default='zig-out/bin/xodb')
    parser.add_argument('--cases', nargs='+', default=['launch', 'attach'], choices=['launch', 'attach'])
    parser.add_argument('--record', metavar='FILE', help='Write the scrubbed launch transcript for tests/gdb-debugserver.py')
    args = parser.parse_args(); os.umask(0o022)
    assert re.fullmatch(r'[A-Za-z0-9._/-]+', args.remote_dir) and not args.remote_dir.startswith(('/', '-')) and '..' not in args.remote_dir, 'remote directory must be a plain relative path'
    work = Path(args.work).resolve(); work.mkdir(mode=0o755, parents=True, exist_ok=False)
    os.environ['XODB_BIN'] = str(Path(args.xodb).resolve())
    results = []
    with (work / 'remote.log').open('w') as log:
        mac = Mac(args.ssh, args.remote_dir, log)
        mac.run('cat > fixture.c && cc -g -O1 -o fixture fixture.c', stdin=(ROOT / 'tests/fixtures/darwin-debugserver.c').read_bytes(), timeout=120)
        for mode in args.cases:
            started = time.monotonic()
            try: result = case(args, mac, mode, work, args.record if mode == 'launch' else None)
            except Exception as error:
                result = dict(case=mode, status='fail', reason=f'{type(error).__name__}: {error}')
            result['seconds'] = round(time.monotonic() - started, 2)
            results.append(result); print(json.dumps(result), flush=True)
            (work / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        # Leave nothing behind: the files made here, then the directory if that emptied it.
        mac.run(f'rm -f fixture fixture.c out.txt ds.out ds.log ds.pid fx.pid; rm -rf fixture.dSYM; cd && rmdir {args.remote_dir} 2>/dev/null; true', check=False)
    return int(any(result['status'] != 'pass' for result in results))


if __name__ == '__main__': raise SystemExit(main())
