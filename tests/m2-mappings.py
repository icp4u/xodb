#!/usr/bin/env python3
"""Live mapping identities, replacement, historical source, and thread coverage."""
from datetime import datetime
from pathlib import Path
import json
import os
import subprocess
import time
from client import Client

root = Path(__file__).resolve().parents[1]
os.chdir(root)
run = root / '.work' / ('m2-mappings-' + datetime.now().strftime('%Y%m%dT%H%M%S%f'))
run.mkdir()
(run / 'tmp').mkdir()
env = dict(os.environ, TMPDIR=str(run / 'tmp'))
flags = ['-O2', '-g', '-gdwarf-4', '-fno-omit-frame-pointer', '-mno-omit-leaf-frame-pointer', '-fno-optimize-sibling-calls', '-Wall', '-Wextra', '-Werror']
for letter in ('a', 'b'):
    subprocess.run(['cc', *flags, '-shared', '-fPIC', '-DMAPPED_NAME=mapped_hot_' + letter,
                    'tests/fixtures/profile-mapping-library.c', '-o', str(run / ('lib' + letter + '.so'))],
                   env=env, check=True)
subprocess.run(['cc', *flags, '-pthread', 'tests/fixtures/profile-mappings.c', '-ldl', '-o', str(run / 'fixture')], env=env, check=True)

def pages(client, tool, field, capture):
    rows, start, view_id = [], 0, None
    while True:
        data = client.inspect(tool, capture_id=capture['id'], revision=capture['revision'], start=start, limit=64, **({"view_id":view_id} if view_id else {}))
        view_id = data.get('view_id')
        rows.extend(data[field])
        if data['next'] is None: return rows, data
        start = data['next']

for mode in ('main', 'worker', 'subset'):
    client = Client('control', str(run / 'fixture'), args=[str(run / 'liba.so'), str(run / 'libb.so'), 'worker' if mode != 'main' else 'main'])
    try:
        begin = client.action('set_breakpoint', symbol='profile_ready')['id']
        end = client.action('set_breakpoint', symbol='profile_done')['id']
        client.action('continue'); client.stopped('breakpoint')
        client.action('remove_breakpoint', id=begin)
        initial = client.session()
        tids = [t['tid'] for t in initial['threads'] if t['state'] != 'exited']
        assert len(tids) == (1 if mode == 'main' else 2)
        args = {'tids': [t for t in tids if t != initial['pid']]} if mode == 'subset' else {}
        opened = client.action('start_profile', duration_ms=5000, frequency_hz=199, **args)['capture']
        assert opened['accepted']['mmap_data']
        client.action('continue'); client.stopped('breakpoint')
        capture = client.action('stop_profile', capture_id=opened['id'])['capture']
        assert capture['status'] == 'manual', capture
        assert capture['stored_samples'] > 30 and capture['mapping_history']['recorded_changes'] > 5, capture
        graph, metadata = pages(client, 'get_flamegraph', 'nodes', capture)
        maps, _ = pages(client, 'get_profile_mappings', 'mappings', capture)
        assert 'munmap/mremap' in metadata['mapping_coverage']
        assert sum(n['self'] for n in graph) == metadata['samples'] == capture['stored_samples']
        assert len(maps) == capture['mapping_history']['opening_regions'] + capture['mapping_history']['recorded_changes']
        assert len({m['id'] for m in maps}) == len(maps)
        if mode == 'subset':
            assert metadata['unverified_mapping_samples'] == metadata['samples']
            assert not any(n['kind'] == 'code' for n in graph)
        else:
            a = [n for n in graph if n['name'] == 'mapped_hot_a']
            b = [n for n in graph if n['name'] == 'mapped_hot_b']
            assert a and len(b) >= 2, (a, b, maps)
            assert {n['address'] for n in a} == {n['address'] for n in b}, (a, b)
            assert {n['mapping_id'] for n in a}.isdisjoint({n['mapping_id'] for n in b})
            assert {n['module_id'] for n in a}.isdisjoint({n['module_id'] for n in b})
            assert any(n['mapping_note'] == 'anonymous' and n['self'] > 0 for n in graph)
            details = {n['id']: client.inspect('get_profile_frame', capture_id=capture['id'], revision=capture['revision'], node=n['id'], view_id=metadata['view_id']) for n in a + b}
            assert all(d['source'] and d['instructions'] for d in details.values()), details
            # Permission changes give B another mapping lifetime, preserving A's
            # earlier image and source even though the address was overwritten.
            assert any(not m['executable'] and m['offset_ns'] is not None for m in maps)
            stop = client.session()
            regs = {tid: client.inspect('get_registers', tid=tid) for tid in [t['tid'] for t in stop['threads'] if t['state'] == 'stopped']}
            pages(client, 'get_profile_mappings', 'mappings', capture)
            assert client.session()['generation'] == stop['generation']
            assert all(client.inspect('get_registers', tid=tid) == value for tid, value in regs.items())
            client.action('remove_breakpoint', id=end)
            client.action('continue')
            deadline = time.monotonic() + 5
            while client.session()['state'] != 'exited':
                assert time.monotonic() < deadline
                time.sleep(.01)
            assert pages(client, 'get_flamegraph', 'nodes', capture)[0] == graph
            for node_id, before in details.items():
                after = client.inspect('get_profile_frame', capture_id=capture['id'], revision=capture['revision'], node=node_id, view_id=metadata['view_id'])
                assert after['source'] == before['source'] and after['instructions'] == before['instructions']
        assert not any('perf_event' in os.readlink(p) for p in Path(f'/proc/{client.p.pid}/fd').iterdir())
        for name, data in (('capture', capture), ('graph', graph), ('mappings', maps)):
            (run / f'{mode}-{name}.json').write_text(json.dumps(data, indent=2) + '\n')
        print(f'{mode}: {capture["stored_samples"]} samples across {capture["mapping_history"]["recorded_changes"]} changes; identities, coverage and cleanup passed', flush=True)
    finally:
        (run / f'{mode}-rpc.json').write_text(json.dumps(client.transcript, indent=2) + '\n')
        client.close()
print(f'Mapping artifacts: {run}', flush=True)
