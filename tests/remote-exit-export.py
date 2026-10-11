#!/usr/bin/env python3
"""Fast host lane: voluntary remote exit drains busy-target tail samples."""
import argparse
import ctypes
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import shlex
import signal
import struct
import sys
import time
from types import SimpleNamespace, MethodType

from helpers.agent_proxy import relay


def cpu(pid):
    fields = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
    return int(fields[11])+int(fields[12]), fields[19]


def samples(body):
    """Decode the documented perf-wire envelope and native perf record headers."""
    size = struct.unpack_from('>I', body, 8)[0]
    data = body[12:12+size]
    assert len(data) == size and data[0] == 1, 'collector request failed'
    # perf_info: two u32 counts, three u64 sizes, u32 version, two bools.
    assert data[38] == 0, 'collector reports failure'
    if data[39] == 0:
        assert len(data) == 40
        return 0
    assert data[39] == 1
    events = struct.unpack_from('>I', data, 44)[0]
    # perf_thread: tid/count, event IDs, three u64 identities, two bools.
    at = 40+8+8*events+24+2
    at += 8+1  # tail and more
    length = struct.unpack_from('>I', data, at)[0]
    records = data[at+4:]
    assert len(records) == length
    at, count = 0, 0
    while at < length:
        kind, _, size = struct.unpack_from('<IHH', records, at)
        assert size >= 8 and size % 8 == 0 and at+size <= length
        count += kind == 9  # PERF_RECORD_SAMPLE
        at += size
    return count


def proxy(directory, agent):
    directory = Path(directory)
    config = json.loads((directory/'proxy.json').read_text())
    stopped = False
    def record(row):
        with (directory/'events.jsonl').open('a') as f:
            f.write(json.dumps(row)+'\n')
    def request(row):
        if row['op'] == config['stop'] and (directory/'armed.json').exists():
            armed = json.loads((directory/'armed.json').read_text())
            before, identity = cpu(armed['pid'])
            assert identity == armed['identity']
            # Calibrate work to the CPU time that produced the initial samples.
            # The target keeps running while the final stop request is held.
            deadline = time.monotonic()+10
            while True:
                after, identity = cpu(armed['pid'])
                assert identity == armed['identity']
                if after-before >= armed['ticks']:
                    break
                assert time.monotonic() < deadline, 'owned busy target made no progress'
                time.sleep(.001)
            record(dict(phase='stop', cpu_ticks=after-before))
        return True
    def reply(row):
        nonlocal stopped
        if row['op'] == config['stop']:
            assert row['status'] == 0
            stopped = True
            record(dict(phase='stopped'))
        elif row['op'] == config['ring'] and stopped:
            assert row['status'] == 0
            record(dict(phase='tail', samples=samples(row['body'])))
        return row['header']+row['body']
    relay(agent, request, reply)


def run(args):
    root = Path(__file__).resolve().parents[1]
    os.chdir(root)
    os.umask(0o022)
    work = args.work.resolve()
    work.mkdir(parents=True)
    binary = (args.binary or root/'zig-out/bin/xodb').resolve()
    spec = importlib.util.spec_from_file_location('shared', root/'tests/shared-sessions.py')
    shared = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(shared)
    shared.TIMEOUT = 10
    class StdioServer(shared.Server):
        def __init__(self, case, flag, output):
            from client import Client
            assert ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0) == 0
            self.work = case/'mutate'
            self.work.mkdir()
            self.log = (self.work/'server.log').open('w')
            self.target_pid = self.target_identity = None
            old = os.environ.get('XODB_BIN')
            os.environ['XODB_BIN'] = str(binary)
            try:
                primary = Client('mutate', executable=str(binary.with_name('xodb-profile-fixture')),
                                 args=['30'], options=[flag, str(output)], reply_seconds=10)
            finally:
                if old is None:
                    os.environ.pop('XODB_BIN', None)
                else:
                    os.environ['XODB_BIN'] = old
            primary.label = 'stdio-export'
            self.clients = [primary]
            self.proc = primary.p
            self.client = SimpleNamespace(tool=primary.inspect, raw=primary.tool,
                                          session=primary.session, claim=lambda: None)
            self.client.action = MethodType(shared.Client.action, self.client)
        def collect_log(self):
            self.log.write(self.proc.stderr.read().decode(errors='replace'))
            self.log.flush()
        def close(self):
            super().close()
            self.proc.stdout.close()
            self.proc.stderr.close()
    enum = (root/'src/runtime/rpc.h').read_text().split('enum xrt_rpc_op {', 1)[1].split('};', 1)[0]
    ops = {name: index+1 for index, name in enumerate(re.findall(r'XRT_RPC_[A-Z_]+', enum))}
    started = time.monotonic()
    rows = []
    for index, flag in enumerate(('--profile-out', '--capture-out')):
        case = work/str(index)
        case.mkdir()
        output = case/'capture'
        (case/'proxy.json').write_text(json.dumps(dict(stop=ops['XRT_RPC_PERF_STOP'], ring=ops['XRT_RPC_PERF_RING'])))
        wrapper = case/'agent'
        wrapper.write_text('#!/bin/sh\nexec '+shlex.join([sys.executable, '-B', str(Path(__file__).resolve()), '--proxy', str(case), str(binary.with_name('xodb-agent'))])+'\n')
        wrapper.chmod(0o755)
        os.environ['XODB_RUNTIME_AGENT'] = str(wrapper)
        server = None
        try:
            if args.stdio:
                server = StdioServer(case, flag, output)
                client = server.client
            else:
                server = shared.Server(root, case, binary, binary.with_name('xodb-profile-fixture'), 'mutate',
                                       options=(flag, str(output)), fixture_args=('30',))
                client = shared.Client(server, 'exit-export')
            snapshot = client.session()
            server.remember_target(snapshot)
            client.claim()
            client.action('start_profile', frequency_hz=997, duration_ms=0)
            ticks, identity = cpu(snapshot['pid'])
            client.action('continue')
            before = shared.eventually(lambda: client.tool('get_profile')['capture'],
                                       lambda c: c['stored_samples'] > 0, 'busy target produced samples', timeout=10)
            elapsed_ticks = max(1, cpu(snapshot['pid'])[0]-ticks)
            hold_ticks = max(2, 2*math.ceil(elapsed_ticks/before['stored_samples']))
            (case/'armed.json').write_text(json.dumps(dict(pid=snapshot['pid'], identity=identity, ticks=hold_ticks)))
            if args.stdio:
                server.proc.stdin.close()
            else:
                server.proc.send_signal(signal.SIGINT)
            code = server.proc.wait(timeout=15)
            if args.stdio:
                server.collect_log()
            assert code == 0, (server.work/'server.log').read_text()
            log = (server.work/'server.log').read_text()
            assert 'RemoteCancelled' not in log and 'collector_error' not in log, log
            events = [json.loads(line) for line in (case/'events.jsonl').read_text().splitlines()]
            tail = sum(row['samples'] for row in events if row['phase'] == 'tail')
            assert any(row['phase'] == 'stop' for row in events) and tail > 0, ('final tail not observed', events)
            assert output.is_file(), log
            if flag == '--profile-out':
                data = json.loads(output.read_text())
                capture = data['xodb']['capture']
                assert data['xodb']['samples'] > 0, data['xodb']
            else:
                from client import Client
                old_binary = os.environ.get('XODB_BIN')
                os.environ['XODB_BIN'] = str(binary)
                offline = Client('observe', executable=None, options=['--open-capture', str(output)], reply_seconds=10)
                try:
                    shared.eventually(lambda: offline.inspect('get_archive_status')['job'],
                                      lambda job: job['done'], 'saved capture reopened', timeout=10)
                    capture = offline.inspect('get_profile')['capture']
                finally:
                    offline.close()
                    if old_binary is None:
                        os.environ.pop('XODB_BIN', None)
                    else:
                        os.environ['XODB_BIN'] = old_binary
            assert capture['status'] == ('collector_error' if args.wrong_result else 'manual'), capture
            assert capture['stored_samples'] >= before['stored_samples']+tail, (before, tail, capture)
            rows.append(dict(flag=flag, before=before['stored_samples'], tail_samples=tail,
                             stored=capture['stored_samples'], status=capture['status'], events=events))
            print(json.dumps(rows[-1]), flush=True)
        finally:
            if server:
                if server.proc.stdin and not server.proc.stdin.closed:
                    server.proc.stdin.close()
                server.close()
    result = dict(status='pass', exit='stdio EOF' if args.stdio else 'SIGINT', cases=rows, seconds=time.monotonic()-started, load=os.getloadavg())
    (work/'results.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps(result))


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--proxy':
        proxy(sys.argv[2], sys.argv[3])
    else:
        p = argparse.ArgumentParser(description=__doc__)
        p.add_argument('--work', type=Path, required=True)
        p.add_argument('--binary', type=Path)
        p.add_argument('--wrong-result', action='store_true')
        p.add_argument('--stdio', action='store_true')
        run(p.parse_args())
