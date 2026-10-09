#!/usr/bin/env python3
"""Bulk memory search and capture on an owned large mapping (fast lane).

Plants needles across read-chunk boundaries and next to unmapped pages, then
checks exact hits, unreadable accounting, multi-range capture and the
retained-capture budget. Throughput is reported as evidence, not asserted.
"""
from datetime import datetime
import argparse, json, os, subprocess, time
from pathlib import Path
parser = argparse.ArgumentParser()
parser.add_argument('--mib', type=int, default=256)
parser.add_argument('--agent')
parser.add_argument('--search-only', action='store_true', help='skip capture checks (old-build throughput)')
opts = parser.parse_args()
root = Path(__file__).resolve().parents[1]; os.chdir(root)
if opts.agent: os.environ['XODB_RUNTIME_AGENT'] = opts.agent
from client import Client
run = root/'.work'/('memory-search-speed-'+datetime.now().strftime('%Y%m%dT%H%M%S%f')); run.mkdir(parents=True)
exe = run/'fixture'
subprocess.run(['gcc', '-g', '-O1', 'tests/fixtures/memory-speed.c', '-o', str(exe)], check=True, env=dict(os.environ, TMPDIR=str(root/'.work/tmp')))
needle = 'xodb:planted-needle:5Q'
n = len(needle)
c = Client('control', str(exe), args=[str(opts.mib)])
def rss(): return int(next(l.split()[1] for l in open(f'/proc/{c.p.pid}/status') if l.startswith('VmRSS:'))) // 1024
rss_mib = {}
try:
    ready = c.inspect('find_symbol', name='speed_ready')['address']
    c.action('set_breakpoint', address=ready); c.action('continue'); c.stopped('breakpoint')
    def word(name):
        cap = c.action('capture_memory', address=c.inspect('find_symbol', name=name)['address'], length=8)
        return int.from_bytes(bytes.fromhex(c.inspect('read_memory_snapshot', id=cap['id'])['hex']), 'little')
    base, size, hole, hole2 = word('base'), word('size'), word('hole'), word('hole2')
    assert size == opts.mib << 20, size
    expected = [0, (1 << 20) - 7, (4 << 20) - 3, (16 << 20) - 10, hole - n, hole + 4096, size - n]
    load = os.getloadavg()[0]; rss_mib['before'] = rss()
    job = c.action('search_memory', address=hex(base), length=size, pattern=needle, encoding='utf8')
    started = time.monotonic(); latencies = []
    while True:
        before = time.monotonic(); result = c.inspect('get_memory_search', id=job['id']); latencies.append(time.monotonic() - before)
        if result['state'] != 'running': break
        assert time.monotonic() - started < 120, result
        time.sleep(.002)
    elapsed = time.monotonic() - started
    hits = [int(h, 16) - base for h in result['hits']]
    assert result['state'] == 'complete' and result['scanned'] == size, result
    assert hits == expected, (hits, expected)
    assert result['unreadable'] == 8192, result
    rate = size / elapsed / 1e6; rss_mib['search'] = rss()
    if not opts.search_only:
        # One call, several ranges: a large readable span, a span across the
        # unmapped page and a span ending at the mapping's last byte.
        big = 16 << 20
        multi = c.action('capture_memory', ranges=[{'address': hex(base), 'length': big},
                                                   {'address': hex(base + hole - 4096), 'length': 12288},
                                                   {'address': hex(base + size - 64), 'length': 64}])
        snaps = multi['snapshots']
        assert [s['length'] for s in snaps] == [big, 12288, 64], multi
        assert [s['readable'] for s in snaps] == [big, 8192, 64], multi
        assert len({s['generation'] for s in snaps}) == 1, multi
        page = c.inspect('read_memory_snapshot', id=snaps[1]['id'], start=4096 - n, limit=4096)
        assert bytes.fromhex(page['hex'][:2 * n]) == needle.encode() and page['hex'][2 * n:2 * n + 2] == '??', page
        tail = c.inspect('read_memory_snapshot', id=snaps[0]['id'], start=big - 4096, limit=4096)
        assert tail['next'] is None and all(tail['valid']), tail['next']
        assert bytes.fromhex(c.inspect('read_memory_snapshot', id=snaps[2]['id'])['hex'])[-n:] == needle.encode()
        gen = c.session()['generation']
        def refused(r): return 'error' in r or r['result']['isError']
        too_big = c.tool('capture_memory', address=hex(base), length=big + 1, generation=gen)
        assert refused(too_big), too_big
        too_many = c.tool('capture_memory', ranges=[{'address': hex(base), 'length': 4096}] * 17, generation=gen)
        assert refused(too_many), too_many
        too_much = c.tool('capture_memory', ranges=[{'address': hex(base), 'length': big}] * 2 + [{'address': hex(base), 'length': 1}], generation=gen)
        assert refused(too_much), too_much
        both = c.tool('capture_memory', address=hex(base), length=64, ranges=[{'address': hex(base), 'length': 64}], generation=gen)
        assert refused(both), both
        # The retained budget (64 MiB of captured bytes) evicts oldest first.
        ids = [c.action('capture_memory', address=hex(base + i * big), length=big)['id'] for i in range(4)]
        old = c.tool('read_memory_snapshot', id=snaps[0]['id'])
        assert old['result']['isError'] and old['result']['content'][0]['text'] == 'MemorySnapshotExpired', old
        for i in ids: c.inspect('read_memory_snapshot', id=i, limit=1)
        rss_mib['budget'] = rss()
        assert rss_mib['budget'] < rss_mib['before'] + 2 * 64 + 64, rss_mib
finally:
    (run/'transcript.json').write_text(json.dumps(c.transcript)[:1 << 20]); c.close()
print(f'Memory search {opts.mib} MiB{" via agent" if opts.agent else ""}: {elapsed*1000:.0f} ms, {rate:.0f} MB/s, '
      f'max status {max(latencies)*1000:.1f} ms, load {load:.2f}, xodb RSS MiB {rss_mib}; exact hits/unreadable passed', '' if opts.search_only else '; multi-range capture/budget passed')
