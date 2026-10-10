#!/usr/bin/env python3
"""Multi-range and region-selector memory search on many small owned mappings
(fast lane, about 5 s locally).

Checks exact hits and per-range accounting for explicit ranges and for each
region selector (clipped to the fixture's area), that hits never span a
PROT_NONE page or two ranges, refusals, and one unclipped whole-process
search. Timing of N single-range calls against one multi-range call is
reported as evidence, not asserted.
"""
from datetime import datetime
import argparse, json, os, subprocess, time
from pathlib import Path
parser = argparse.ArgumentParser()
parser.add_argument('--agent')
opts = parser.parse_args()
root = Path(__file__).resolve().parents[1]; os.chdir(root)
if opts.agent: os.environ['XODB_RUNTIME_AGENT'] = opts.agent
from client import Client
run = root/'.work'/('memory-search-ranges-'+datetime.now().strftime('%Y%m%dT%H%M%S%f')); run.mkdir(parents=True)
exe = run/'fixture'; truth_path = run/'truth.json'
subprocess.run(['gcc', '-g', '-O1', 'tests/fixtures/memory-ranges.c', '-o', str(exe)], check=True, env=dict(os.environ, TMPDIR=str(root/'.work/tmp')))
needle = 'xodb-range-needle:R3'
c = Client('control', str(exe), args=[str(truth_path)])
report = {}
def refused(r, text):
    if text == 'InvalidArguments': assert r.get('error') == {'code': -32602, 'message': text}, (r, text)
    else: assert r.get('result', {}).get('isError') and r['result']['content'][0]['text'] == text, (r, text)
try:
    c.action('set_breakpoint', address=c.inspect('find_symbol', name='ranges_ready')['address']); c.action('continue'); c.stopped('breakpoint')
    t = json.loads(truth_path.read_text()); page = t['page']
    gen = c.session()['generation']
    def search(**args):
        return c.inspect('search_memory', generation=gen, pattern=needle, encoding='utf8', **args)
    def finish(job, **args):
        while True:
            r = c.inspect('get_memory_search', id=job['id'], limit=128, **args)
            if r['state'] != 'running': return r
            time.sleep(.001)
    def all_hits(job):
        hits, start = [], 0
        while True:
            r = c.inspect('get_memory_search', id=job['id'], start=start, limit=128)
            hits += [int(h, 16) for h in r['hits']]
            if r['next'] is None: return hits
            start = r['next']
    def all_ranges(job):
        rows, start = [], 0
        while True:
            r = c.inspect('get_memory_search', id=job['id'], range_start=start, range_limit=256)
            rows += r['ranges']
            if r['range_next'] is None: return rows
            start = r['range_next']
    window = dict(address=hex(t['area']), length=t['area_size'])
    anon = sorted(t['anon']); assert len(anon) == 48
    # Region selectors over the fixture's area: exact hits and range counts.
    cases = {'writable': (dict(), anon + [t['file']], 603),
             'anon-writable': (dict(), anon, 602),
             'all-readable': (dict(), anon + [t['ro'], t['file']], 604),
             'writable+shared': (dict(include_shared=True), anon + [t['shared'], t['file']], 604)}
    for name, (extra, expected, count) in cases.items():
        job = search(regions=name.split('+')[0], **window, **extra)
        done = finish(job)
        assert job['range_count'] == count and done['range_count'] == count, (name, job, done['range_count'])
        assert done['state'] == 'complete' and done['unreadable'] == 0 and done['scanned'] == done['length'] == job['length'], (name, done)
        assert all_hits(job) == sorted(expected), (name, all_hits(job), sorted(expected))
        report[name] = {'ranges': count, 'bytes': done['length'], 'hits': done['total_hits']}
    # Explicit ranges: every small mapping, one extended onto its PROT_NONE
    # neighbour, plus a range over the needle broken by a PROT_NONE page.
    end_plant = next(a for a, l in t['small'] if a + l - 20 in anon)
    ranges = [{'address': hex(a), 'length': l + (page if a == end_plant else 0)} for a, l in t['small']]
    ranges.append({'address': hex(t['split']), 'length': 3 * page})
    job = search(ranges=ranges)
    done = finish(job)
    assert done['state'] == 'complete' and done['range_count'] == 601 and done['ranges_done'] == 601, done
    assert done['unreadable'] == 2 * page and done['ranges_with_unreadable'] == 2 and done['ranges_unreadable'] == 0, done
    assert done['scanned'] == done['length'] == sum(r['length'] for r in ranges), done
    multi_hits = all_hits(job); assert multi_hits == anon, multi_hits
    rows = all_ranges(job)
    assert [r['address'] for r in rows] == [r['address'] for r in ranges] and all(r['scanned'] == r['length'] for r in rows), rows[:4]
    assert [r['unreadable'] for r in rows] == [page if int(r['address'], 16) in (end_plant, t['split']) else 0 for r in ranges]
    assert sum(r['hits'] for r in rows) == 48 and rows[-1]['hits'] == 0, rows[-1]
    # The hit cap ends a multi-range search inside its first range: mapping 0
    # is one page of 0x80 filler.
    assert page == 4096
    capped = finish(c.inspect('search_memory', generation=gen, pattern='80', ranges=ranges))
    assert capped['state'] == 'match_limit' and capped['total_hits'] == 4096 and capped['ranges_done'] == 0, capped
    # Timing evidence: N single-range calls against the one call above.
    load = os.getloadavg()[0]
    started = time.monotonic(); single_hits = []
    for r in ranges[:-1]:
        j = search(address=r['address'], length=r['length'])
        single_hits += [int(h, 16) for h in finish(j)['hits']]
    singles = time.monotonic() - started
    assert single_hits == anon, single_hits
    started = time.monotonic(); finish(search(ranges=ranges)); multi = time.monotonic() - started
    report['timing'] = {'singles_ms': round(singles * 1000), 'multi_ms': round(multi * 1000), 'calls': len(ranges) - 1, 'load': round(load, 2)}
    # Whole-process writable search: every planted writable needle is found.
    whole = finish(search(regions='writable'))
    whole_hits = all_hits({'id': whole['id']})
    assert whole['state'] == 'complete' and whole_hits == sorted(anon + [t['file']]) and t['shared'] not in whole_hits and t['ro'] not in whole_hits, whole
    report['whole_writable'] = {k: whole[k] for k in ('range_count', 'length', 'unreadable', 'total_hits')}
    # Refusals.
    def tool(**args): return c.tool('search_memory', generation=gen, pattern=needle, encoding='utf8', **args)
    refused(tool(ranges=ranges[:2], address=hex(t['area']), length=64), 'InvalidArguments')
    refused(tool(ranges=[{'address': hex(t['area'] + i * 2 * page), 'length': 16} for i in range(1025)]), 'InvalidArguments')
    refused(tool(ranges=[ranges[1], ranges[0]]), 'InvalidMemoryRange')
    refused(tool(ranges=[ranges[0], ranges[0]]), 'InvalidMemoryRange')
    refused(tool(address=hex(t['area']), length=64, include_shared=True), 'InvalidArguments')
    refused(tool(regions='everything'), 'InvalidArguments')
    refused(tool(regions='writable', address=hex(int(ranges[0]['address'], 16) + 2 * page), length=page), 'NoMatchingRegions')
    refused(tool(address=hex(t['area']), length=(1 << 30) + 1), 'InvalidArguments')
finally:
    (run/'transcript.json').write_text(json.dumps(c.transcript)[:1 << 20]); c.close()
print(f'Memory search ranges{" via agent" if opts.agent else ""}: {json.dumps(report)}; exact hits/accounting passed')
