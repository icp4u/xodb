#!/usr/bin/env python3
"""Owned task creation/mapping bursts: bounded stops, evidence and fd cleanup."""
from datetime import datetime
from pathlib import Path
import json
import os
import subprocess
import time
from client import Client

root = Path(__file__).resolve().parents[1]
os.chdir(root)
run = root / '.work' / ('m2-robustness-' + datetime.now().strftime('%Y%m%dT%H%M%S%f'))
run.mkdir()
(run / 'tmp').mkdir()
env = dict(os.environ, TMPDIR=str(run / 'tmp'))
subprocess.run(['cc', '-O2', '-g', '-gdwarf-4', '-fno-omit-frame-pointer',
                '-fno-optimize-sibling-calls', '-Wall', '-Wextra', '-Werror',
                '-pthread', 'tests/fixtures/profile-robustness.c', '-o', str(run / 'fixture')],
               env=env, check=True)

def perf_fds(client):
    # The collector holds the event fds. That is this process, or the C agent.
    return [p.name for p in Path(f'/proc/{client.collector_pid()}/fd').iterdir()
            if 'perf_event' in os.readlink(p)]

for mode in ('thread', 'fork', 'burst', 'limit'):
    client = Client('control', str(run / 'fixture'), args=[mode])
    try:
        begin = client.action('set_breakpoint', symbol='profile_ready')['id']
        end = client.action('set_breakpoint', symbol='profile_done')['id']
        client.action('continue')
        stop = client.stopped('breakpoint')
        client.action('remove_breakpoint', id=begin)
        assert sum(t['state'] != 'exited' for t in stop['threads']) == 9, stop
        opened = client.action('start_profile', frequency_hz=199, duration_ms=5000,
                               context_switch=True)['capture']
        assert len(perf_fds(client)) == 9
        client.action('continue')
        deadline = time.monotonic() + 8
        latencies = []
        while True:
            started = time.monotonic()
            capture = client.inspect('get_profile')['capture']
            state = client.session()
            latencies.append(time.monotonic() - started)
            if state['state'] == 'stopped':
                if any(t['reason'] == 'breakpoint' for t in state['threads']): break
                # Following defaults off: the newborn is released without a
                # stop, and its SIGCHLD is delivered without one.
                client.action('continue')
            assert state['state'] != 'exited' and time.monotonic() < deadline, state
            time.sleep(.005)
        if capture['status'] == 'collecting':
            capture = client.action('stop_profile', capture_id=opened['id'])['capture']
        expected = dict(thread='manual', fork='thread_scope_changed',
                        burst='manual', limit='mapping_limit')[mode]
        assert capture['status'] == expected, capture
        assert capture['stored_samples'] > 0 and not perf_fds(client), capture
        assert capture['lost_samples'] == capture['unknown_records'] == 0, capture
        assert capture['scheduling']['invalid_events'] == 0, capture
        if mode == 'fork':
            change = capture['scope_change']
            assert change and change['parent_pid'] == stop['pid'], capture
            assert (change['pid'] == stop['pid']) == (mode == 'thread'), change
            assert capture['stop_reasons'][0] == expected, capture
            assert capture['trusted_before_ns'] is not None
        elif mode == 'thread':
            assert len(capture['threads']) == 10 and capture['follow_threads'], capture
            assert capture['trusted_before_ns'] is None and capture['scope_change'] is None, capture
        elif mode == 'burst':
            assert capture['mapping_history']['recorded_changes'] == 512, capture
            assert capture['trusted_before_ns'] is None and capture['stop_reasons'] == [], capture
        else:
            assert capture['mapping_history']['recorded_changes'] == capture['mapping_history']['change_limit'], capture
            assert capture['stop_reasons'][0] == 'mapping_limit' and capture['trusted_before_ns'] == 0
        graph = client.inspect('get_flamegraph', capture_id=capture['id'], revision=capture['revision'])
        timeline = client.inspect('get_profile_timeline', capture_id=capture['id'], revision=capture['revision'])
        assert graph['samples'] + graph['excluded_by_node_limit'] == timeline['samples'] == capture['stored_samples']
        if mode == 'limit': assert graph['unverified_mapping_samples'] == graph['samples']
        # Replacing completed captures must release all per-thread event fds.
        for _ in range(3):
            again = client.action('start_profile', duration_ms=100)['capture']
            assert again['id'] > capture['id'] and len(perf_fds(client)) == 1, again
            ended = client.action('stop_profile', capture_id=again['id'])['capture']
            assert ended['status'] == 'manual' and not perf_fds(client), ended
        client.action('remove_breakpoint', id=end)
        client.action('continue')
        deadline = time.monotonic() + 5
        while client.session()['state'] != 'exited':
            assert time.monotonic() < deadline
            time.sleep(.005)
        (run / f'{mode}.json').write_text(json.dumps(dict(capture=capture, graph=graph,
            timeline=timeline, max_query_pair_ms=max(latencies)*1000), indent=2) + '\n')
        print(f'{mode}: {expected}, {capture["stored_samples"]} samples, '
              f'{capture["mapping_history"]["recorded_changes"]} mappings; '
              f'max query pair {max(latencies)*1000:.1f} ms; repeat capture/fd cleanup passed', flush=True)
    finally:
        (run / f'{mode}-rpc.json').write_text(json.dumps(client.transcript, indent=2) + '\n')
        client.close()
        (run / f'{mode}-stderr.log').write_bytes(client.p.stderr.read())
print(f'Robustness artifacts: {run}', flush=True)
