#!/usr/bin/env python3
"""Owned new-thread sampling, mapping coverage, fixed scopes, bounds and archives."""
from datetime import datetime
from pathlib import Path
import json, os, subprocess, time
from client import Client

root = Path(__file__).resolve().parents[1]
os.chdir(root)
run = root / '.work' / ('m2-dynamic-' + datetime.now().strftime('%Y%m%dT%H%M%S%f'))
(run / 'tmp').mkdir(parents=True)
subprocess.run(['cc', '-O2', '-g', '-gdwarf-4', '-fno-omit-frame-pointer',
                '-fno-optimize-sibling-calls', '-Wall', '-Wextra', '-Werror',
                '-pthread', 'tests/fixtures/profile-dynamic.c', '-o', str(run / 'fixture')],
               env=dict(os.environ, TMPDIR=str(run / 'tmp')), check=True)

def perf_fds(c):
    return [p.name for p in Path(f'/proc/{c.collector_pid()}/fd').iterdir() if 'perf_event' in os.readlink(p)]

def archive_ready(c):
    deadline = time.monotonic() + 20
    while True:
        state = c.inspect('get_archive_status')
        if state['job'] and state['job']['done']:
            assert state['job']['error_name'] is None, state
            return state
        assert time.monotonic() < deadline, state
        time.sleep(.005)

def graph(c, cap, **filters):
    args = dict(capture_id=cap['id'], revision=cap['revision'], **filters)
    deadline = time.monotonic() + 20
    while True:
        result = c.tool('get_flamegraph', **args)
        assert 'error' not in result, result
        if result['result']['isError']:
            assert result['result']['content'][0]['text'] == 'ArchiveViewPending', result
        else:
            data = result['result']['structuredContent']
            if not data.get('pending'): return data
            args['view_id'] = data['view_id']
        assert time.monotonic() < deadline, result
        time.sleep(.005)

class Offline(Client):
    def __init__(self, path):
        self.transcript, self.id = [], 0
        self.p = subprocess.Popen(['./zig-out/bin/xodb', '--headless', '--mcp', '--open-capture', str(path)],
                                  bufsize=0, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.call('initialize', {'protocolVersion':'2025-06-18','capabilities':{},'clientInfo':{'name':'dynamic-test','version':'1'}})
        self.p.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
        archive_ready(self)

cases = [
    ('follow', 'churn', 16, {}, 'manual'),
    ('churn', 'churn', 192, {'ring_budget_bytes':1048576}, 'manual'),
    ('pool', 'pool', 24, {}, 'manual'),
    ('fixed', 'churn', 8, {'follow_threads':False}, 'thread_scope_changed'),
    ('subset', 'churn', 8, {}, 'thread_scope_changed'),
    ('budget', 'churn', 8, {'ring_budget_bytes':262144}, 'collector_error'),
    ('fork', 'fork', 1, {}, 'thread_scope_changed'),
    ('vfork', 'vfork', 1, {}, 'thread_scope_changed'),
    ('limit', 'churn', 1028, {}, 'collector_error'),
]
if os.environ.get('XODB_DYNAMIC_CASES'):
    cases = [row for row in cases if row[0] in os.environ['XODB_DYNAMIC_CASES'].split(',')]
for name, mode, count, options, expected in cases:
    c = Client('control', str(run / 'fixture'), args=[mode, str(count)],
               options=('--follow-forks',) if mode in ('fork', 'vfork') else ())
    try:
        begin = c.action('set_breakpoint', symbol='profile_ready')['id']
        c.action('set_breakpoint', symbol='profile_done')
        c.action('continue'); state = c.stopped('breakpoint')
        c.action('remove_breakpoint', id=begin)
        if name == 'subset': options = dict(options, tids=[state['pid']], follow_threads=True)
        opened = c.action('start_profile', frequency_hz=499, duration_ms=20000, context_switch=True,
                          user_stack_bytes=128 if name == 'follow' else 0, **options)['capture']
        assert opened['follow_threads'] == (name not in ('subset', 'fixed')), opened
        assert opened['opening_threads'] == 1 and len(opened['threads']) == 1, opened
        c.action('continue')
        deadline = time.monotonic() + 25
        max_rings, latencies = 0, []
        while True:
            started = time.monotonic()
            cap = c.inspect('get_profile')['capture']
            state = c.session()
            latencies.append(time.monotonic() - started)
            max_rings = max(max_rings, cap['ring_allocated_bytes'])
            assert cap['ring_allocated_bytes'] <= cap['ring_budget_bytes'], cap
            if state['state'] == 'stopped':
                if any(t['reason'] == 'breakpoint' for t in state['threads']): break
                if mode in ('fork', 'vfork'):
                    tree = c.inspect('get_processes')
                    for child in tree['processes'][1:]:
                        if child['state'] == 'stopped':
                            c.inspect('continue', process_id=child['process_id'], generation=child['generation'])
                    parent = tree['processes'][0]
                    if not parent['pending_count'] and not parent['shared_vm']:
                        c.action('continue')
                else:
                    c.action('continue')
            assert state['state'] != 'exited' and time.monotonic() < deadline, state
            time.sleep(.002)
        # get_session may drain the automatic stop after the earlier profile
        # snapshot. Do not race that stop with a manual stop request.
        cap = c.inspect('get_profile')['capture']
        if expected == 'manual':
            if cap['status'] == 'collecting': cap = c.action('stop_profile', capture_id=cap['id'])['capture']
        else:
            while cap['status'] == 'collecting':
                assert time.monotonic() < deadline, cap
                time.sleep(.002)
                cap = c.inspect('get_profile')['capture']
        assert cap['status'] == expected and not perf_fds(c), cap
        assert cap['lost_samples'] == cap['unknown_records'] == 0, cap
        assert cap['scheduling']['invalid_events'] == 0, cap
        assert cap['accepted']['threads'] == len(cap['threads']), cap
        if expected == 'manual':
            expected_threads = count + (1 if mode == 'pool' else 2)
            assert len(cap['threads']) == expected_threads, cap
            assert cap['trusted_before_ns'] is None and cap['scope_change'] is None, cap
            assert cap['mapping_history']['recorded_changes'] >= count, cap
            assert all(t['enrolled_ns'] >= cap['started_ns'] for t in cap['threads'][1:]), cap
            whole = graph(c, cap)
            timeline = c.inspect('get_profile_timeline', capture_id=cap['id'], revision=cap['revision'])
            assert whole['samples'] == timeline['samples'] == cap['stored_samples'] > 0, (whole, timeline, cap)
            assert whole['unverified_mapping_samples'] == 0, whole
            sampled = [lane for lane in timeline['threads'] if lane['samples'] and lane['enrolled_ns'] is not None]
            assert sampled, timeline
            lane = max(sampled, key=lambda item: item['samples'])
            part = graph(c, cap, tid=lane['tid'])
            assert part['samples'] == lane['samples'], (part, lane)
            assert any(n['name'] == 'late_hot' for n in part['nodes']), part
            if name == 'follow':
                path = run / 'dynamic.xcap'
                c.action('save_capture_archive', capture_id=cap['id'], revision=cap['revision'], path=str(path))
                archive_ready(c)
                offline = Offline(path)
                try:
                    saved = offline.inspect('get_profile')['capture']
                    assert saved['follow_threads'] and saved['threads'] == cap['threads'], saved
                    assert saved['ring_budget_bytes'] == cap['ring_budget_bytes'], saved
                    reopened = graph(offline, saved, tid=lane['tid'])
                    assert reopened['samples'] == part['samples'], reopened
                    assert [(n['name'], n['inclusive']) for n in reopened['nodes']] == [(n['name'], n['inclusive']) for n in part['nodes']]
                finally: offline.close()
        elif expected == 'thread_scope_changed':
            assert len(cap['threads']) == 1 and cap['trusted_before_ns'] is not None, cap
        else:
            assert ('budget exhausted' if name == 'budget' else '1024 distinct') in cap['diagnostic'], cap
        (run / (name + '.json')).write_text(json.dumps(dict(capture=cap, max_ring_data_bytes=max_rings,
            max_query_pair_ms=max(latencies)*1000), indent=2) + '\n')
        print(f'{name}: {cap["status"]}, {len(cap["threads"])} threads, {cap["stored_samples"]} samples, '
              f'{cap["mapping_history"]["recorded_changes"]} mappings; max query pair {max(latencies)*1000:.1f} ms', flush=True)
    finally:
        (run / (name + '-rpc.json')).write_text(json.dumps(c.transcript, indent=2) + '\n')
        c.close()
        (run / (name + '-stderr.log')).write_bytes(c.p.stderr.read())
print(f'Dynamic thread artifacts: {run}', flush=True)
