#!/usr/bin/env python3
"""Measure observer CPU and RSS for one or four owned base-page processes.

Run under the shared heavy-gate wrapper. These are measurements, not fixed
performance assertions; adaptive refresh and incomplete page scans stay visible.
"""
import argparse
import json
import os
from pathlib import Path
import select
import statistics
import subprocess
import time
from client import Client

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--scopes', type=int, choices=(1, 4), default=1)
parser.add_argument('--mib', type=int, default=1024, help='MiB per owned process')
parser.add_argument('--seconds', type=int, default=45)
parser.add_argument('--idle-seconds', type=int, default=15)
args = parser.parse_args()
if not 4 <= args.mib <= 1024 or args.mib % 2 or not 1 <= args.seconds <= 300 or not 1 <= args.idle_seconds <= 60:
    parser.error('use even 4..1024 MiB, 1..300 sample seconds and 1..60 idle seconds')
root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
work = root / '.work' / ('memory-cost-' + str(time.time_ns()))
work.mkdir(parents=True, mode=0o755)
fixture_source = work / 'fixture.c'
fixture_source.write_text((root / 'tests/memory-map-fixture.c').read_text().replace(
    'madvise(base, bytes, MADV_HUGEPAGE)', 'madvise(base, bytes, MADV_NOHUGEPAGE)'))
subprocess.run(['cc', '-O2', '-std=c11', '-Wall', '-Wextra', '-Werror', str(fixture_source), '-o', str(work / 'fixture')], check=True, timeout=30)
page_size = os.sysconf('SC_PAGESIZE')
clock_ticks = os.sysconf('SC_CLK_TCK')
cpus = len(os.sched_getaffinity(0))
fixtures, selection, measurements = [], [], []
client = None


def birth(pid):
    return int(Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()[19])


def server_stats():
    fields = Path(f'/proc/{client.p.pid}/stat').read_text().rsplit(')', 1)[1].split()
    return (int(fields[11]) + int(fields[12])) / clock_ticks, int(fields[21]) * page_size


def measure(name, seconds, requests):
    started = time.monotonic()
    cpu_start, rss_start = server_stats()
    samples, loads, rss_values = [], [], [rss_start]
    sequences = [set() for _ in requests]
    while time.monotonic() - started < seconds:
        at = time.monotonic()
        loads.append(os.getloadavg()[0])
        for i, request in enumerate(requests):
            response = client.tool('get_memory_map', **request)
            client.transcript.clear()
            result = response.get('result', {})
            if response.get('error') or result.get('isError'):
                assert 'MemoryCacheBusy' in json.dumps(response), response
                samples.append(dict(scope=i, cache_busy=True))
                continue
            data = result['structuredContent']
            process = data.get('process')
            if process is None:
                samples.append(dict(scope=i, pending=True))
                continue
            assert process['start_ticks'] == request['start_ticks']
            sequences[i].add(data['cache']['sequence'])
            samples.append(dict(scope=i, sequence=data['cache']['sequence'],
                state=process['pages_status']['state'], reason=process['pages_status']['reason'],
                scanned_bytes=process['scanned_bytes'], cpu_ns=process['cpu_ns'],
                age_ms=data['cache']['age_ms'], refresh_ms=data['refresh_ms'],
                cost_limited=data['cost_limited'], delta_interval_ns=data['delta_interval_ns']))
        rss_values.append(server_stats()[1])
        time.sleep(max(0, at + 1 - time.monotonic()))
    wall = time.monotonic() - started
    cpu_end, rss_end = server_stats()
    published = [s for s in samples if 'sequence' in s]
    result = dict(name=name, scopes=len(requests), mib_per_process=args.mib,
        wall_seconds=wall, cpu_percent_one_core=(cpu_end - cpu_start) / wall * 100,
        rss_start_bytes=rss_start, rss_end_bytes=rss_end, rss_sampled_peak_bytes=max(rss_values),
        load_min=min(loads), load_max=max(loads), available_cpus=cpus,
        measurable=max(loads) <= cpus, publications=[len(s) for s in sequences],
        all_scopes_retained_previous=bool(requests) and all(any(s.get('scope') == i and s.get('delta_interval_ns', 0) > 0 for s in published) for i in range(len(requests))),
        page_states=sorted({s['state'] for s in published}),
        every_published_scan_complete=bool(published) and all(s['state'] == 'ok' and s['scanned_bytes'] == args.mib << 20 for s in published),
        median_sample_cpu_ms=statistics.median(s['cpu_ns'] for s in published) / 1e6 if published else None,
        samples=samples)
    measurements.append(result)
    (work / 'results.json').write_text(json.dumps(measurements, indent=2) + '\n')
    print(json.dumps({k:v for k,v in result.items() if k != 'samples'}), flush=True)


try:
    for _ in range(args.scopes):
        fixture = subprocess.Popen([str(work / 'fixture'), str(args.mib)], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        fixtures.append(fixture)
        assert select.select([fixture.stdout], [], [], 30)[0], 'fixture startup watchdog'
        ready = json.loads(fixture.stdout.readline())
        selection.append(dict(pid=fixture.pid, start_ticks=birth(fixture.pid),
            range_start=ready['start'], range_end=ready['end'], view='cells', limit=256))
    client = Client('observe', executable=None)
    measure('idle stdio server', args.idle_seconds, [])
    measure('base-page maps requested at 1 Hz', args.seconds, selection)
finally:
    try:
        if client:
            client.close()
    finally:
        for fixture in fixtures:
            fixture.stdin.close()
            try:
                fixture.wait(timeout=5)
            except subprocess.TimeoutExpired:
                fixture.terminate()
                fixture.wait(timeout=5)
print('Private evidence:', work, flush=True)
