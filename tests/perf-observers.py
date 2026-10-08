#!/usr/bin/env python3
"""Measurements of cached observer RPCs on owned, stopped fixtures; no speed gate."""
import argparse
import json
import os
from pathlib import Path
import statistics
import time
from client import Client


def resources(pid):
    fields = Path(f'/proc/{pid}/stat').read_text().rsplit(') ', 1)[1].split()
    rss = next(line.split()[1] for line in Path(f'/proc/{pid}/status').read_text().splitlines()
               if line.startswith('VmRSS:'))
    return dict(cpu_seconds=(int(fields[11]) + int(fields[12])) / os.sysconf('SC_CLK_TCK'),
                rss_kib=int(rss))


def validate(before, after):
    # Timing evidence cannot turn a resumed or replaced target into a success.
    for key in ('session_id', 'generation', 'pid', 'state'):
        assert after[key] == before[key], (key, before, after)
    assert after['state'] == 'stopped', after


def measure(root, work, remote, requests):
    name = 'agent' if remote else 'local'
    options = ['--runtime-agent', str(root/'zig-out/bin/xodb-agent')] if remote else []
    client = Client('control', str(root/'zig-out/bin/xodb-m1-fixture'), options=options)
    part = work/name
    part.mkdir(mode=0o755)
    try:
        client.action('set_breakpoint', symbol='main')
        client.continue_initial_stop()
        client.stopped('breakpoint')
        deadline = time.monotonic() + 30
        while True:
            before = client.session()
            if not before['symbol_discovery_pending'] and not before['continue_pending']:
                break
            assert time.monotonic() < deadline, before
            time.sleep(.01)
        registers = client.inspect('get_registers', tid=before['pid'])
        # Warm the transport and metadata before either CPU or RSS baseline.
        for _ in range(16):
            validate(before, client.session())
        pids = {'frontend': client.p.pid}
        if remote:
            pids['agent'] = client.collector_pid()
        samples = []
        def sample():
            row = dict(load=os.getloadavg(), allowed_cpus=len(os.sched_getaffinity(0)),
                       processes={name: resources(pid) for name,pid in pids.items()})
            samples.append(row)
        sample()
        latencies = []
        start = time.monotonic()
        for index in range(requests):
            begin = time.monotonic()
            observed = client.session()
            latencies.append(time.monotonic() - begin)
            validate(before, observed)
            if (index + 1) % 16 == 0:
                sample()
        elapsed = time.monotonic() - start
        sample()
        assert client.inspect('get_registers', tid=before['pid']) == registers
        validate(before, client.session())
        overloaded = any(max(row['load']) > row['allowed_cpus'] for row in samples)
        row = dict(name=name, status='not-measurable' if overloaded else 'measured',
                   reason='host load exceeds allowed CPU count' if overloaded else None,
                   phase='after transport warm-up to completed cached get_session requests; includes RPC and harness overhead',
                   requests=requests, elapsed_seconds=elapsed, rpc_seconds=latencies,
                   median_rpc_seconds=statistics.median(latencies),
                   samples=samples, correctness='stopped session, generation, pid and registers unchanged')
        row['resources'] = {name: dict(before=samples[0]['processes'][name],
            after=samples[-1]['processes'][name],
            cpu_seconds=samples[-1]['processes'][name]['cpu_seconds']-samples[0]['processes'][name]['cpu_seconds'],
            peak_rss_delta_kib=max(s['processes'][name]['rss_kib'] for s in samples)-samples[0]['processes'][name]['rss_kib'])
            for name in pids}
        return row
    finally:
        client.close()
        (part/'stderr.log').write_bytes(client.p.stderr.read())
        (part/'rpc.json').write_text(json.dumps(client.transcript,indent=2)+'\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work', type=Path, required=True)
    parser.add_argument('--requests', type=int, default=128, help='fixed benchmark workload, not a minimum throughput requirement')
    args = parser.parse_args()
    if not 1 <= args.requests <= 4096:
        parser.error('--requests must be between 1 and 4096')
    os.umask(0o022)
    root = Path(__file__).resolve().parents[1]
    os.chdir(root)
    # Prevent an inherited agent selection from silently replacing the local case.
    os.environ.pop('XODB_RUNTIME_AGENT', None)
    work = args.work.resolve()
    work.mkdir(parents=True, mode=0o755)
    report = dict(status='failed', cases=[], cpu_clock_ticks_per_second=os.sysconf('SC_CLK_TCK'),
                  cpu_resolution_note='A zero CPU delta is below /proc accounting resolution, not zero overhead.')
    try:
        for remote in (False, True):
            report['cases'].append(measure(root, work, remote, args.requests))
        report['status'] = ('not-measurable' if any(row['status']=='not-measurable' for row in report['cases'])
                            else 'measured')
        print(json.dumps({k:v for k,v in report.items() if k!='cases'}))
    finally:
        (work/'results.json').write_text(json.dumps(report,indent=2)+'\n')


if __name__ == '__main__':
    main()
