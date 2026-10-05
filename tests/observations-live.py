#!/usr/bin/env python3
"""Real function invocations, exact ABI words, immutable pages and cohorts."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
from client import Client
from inspections import pipeline

os.umask(0o022)
parser = argparse.ArgumentParser()
parser.add_argument('--helper')
parser.add_argument('--modes', default='balanced,recursive,limit,exit,exec,cancel,stale')
options = parser.parse_args()
if options.helper:
    options.helper = str(Path(options.helper).resolve())
work = Path(tempfile.mkdtemp(prefix='xodb-observations-', dir=os.environ.get('XODB_TEST_TMPDIR')))
work.chmod(0o755)
fixture = work / 'fixture'
subprocess.run(['cc', '-g', '-O0', '-fno-omit-frame-pointer', '-fno-optimize-sibling-calls',
                '-Wall', '-Wextra', '-Werror', 'tests/fixtures/observations.c', '-o', str(fixture)], check=True)


def wait(client, predicate):
    deadline = time.monotonic() + 15
    while True:
        value = client.inspect('get_observation')
        if predicate(value):
            return value
        assert time.monotonic() < deadline, value
        time.sleep(.003)


def rows(client, kind, key):
    result = []
    start = 0
    while True:
        page = client.inspect('get_observation_' + kind, **key, start=start, limit=64)
        result.extend(page[kind])
        if page['next'] is None:
            return result
        start = page['next']


for mode in options.modes.split(','):
    client = Client('control', str(fixture), [mode], options=['--allocation-helper', options.helper] if options.helper else [])
    try:
        ready = client.action('set_breakpoint', symbol='observation_ready')['id']
        client.action('set_breakpoint', symbol='observation_done')
        client.action('continue')
        state = client.stopped('breakpoint')
        client.action('remove_breakpoint', id=ready)
        pc = client.inspect('get_registers', tid=state['pid'])['registers']['rip']
        start_args = dict(tids=[state['pid']], mapping_address=pc,
                          functions=['observed_recursive' if mode == 'recursive' else 'observed_work'],
                          duration_ms=10000, record_limit=10 if mode == 'limit' else 32768)
        if mode in ('cancel', 'stale'):
            generation = client.session()['generation']
            action = ('stop_observation', dict(generation=generation + 1, session_id=state['session_id'], capture_id=1)) if mode == 'cancel' else ('step_instruction', dict(generation=generation + 1, tid=state['pid']))
            responses = pipeline(client, [('start_observation', dict(start_args, generation=generation)), action])
            assert all('result' in r and not r['result']['isError'] for r in responses), responses
            pending = responses[0]['result']['structuredContent']
        else:
            pending = client.action('start_observation', **start_args)
        identity = pending['preparation']
        key = {k: identity[k] for k in ('session_id', 'capture_id')}
        status = wait(client, lambda s: s['state'] != 'preparing')
        if mode in ('cancel', 'stale'):
            assert status['state'] == 'empty' and status['error_name'], status
            print(mode, status['error_name'], flush=True)
            continue
        assert status['state'] == 'collecting' and status['error_name'] is None, status
        client.action('continue')
        deadline = time.monotonic() + 15
        while True:
            state = client.session()
            if state['state'] in ('stopped', 'exited'):
                break
            assert time.monotonic() < deadline, state
            time.sleep(.002)
        if client.inspect('get_observation')['state'] == 'collecting':
            client.action('stop_observation', **key)
        status = wait(client, lambda s: s['state'] == 'completed' and not s['cleanup_pending'])
        records = rows(client, 'records', key)
        calls = rows(client, 'calls', key)
        complete = [v for v in calls if v['call']['reason'] == 'complete']
        if mode == 'limit':
            assert len(records) == 10 and status['unread_possible'], status
        elif mode == 'recursive':
            assert len(complete) == 5 and sorted(int(v['args'][0], 16) for v in complete) == list(range(5)), calls
            assert int(complete[0]['result'], 16) == 10, calls
            assert sum(v['call']['parent_call'] is not None for v in complete) == 4
        else:
            assert len(complete) == 16, (status, calls, records)
            for call in complete:
                args = [int(v, 16) for v in call['args']]
                assert args[1:] == [0xf000000000000002, 3, 4, 5, 6], call
                assert int(call['result'], 16) == args[0] ^ args[1] ^ args[2] ^ args[3] ^ args[4] ^ args[5], call
                entry = records[call['call']['entry_record']]
                assert entry['event']['data']['sample']['raw_registers']['di'] == call['args'][0]
                assert call['duration_ns'] == call['end_ns'] - call['start_ns']
            comparison = client.inspect('compare_observation', **key, threshold_ns=4_000_000)
            deadline = time.monotonic() + 5
            while True:
                view = client.inspect('get_observation_comparison', id=comparison['id'])
                if view['state'] != 'running':
                    break
                assert time.monotonic() < deadline, view
                time.sleep(.002)
            assert view['state'] == 'completed', view
            assert view['result']['summary']['complete_calls'] == 16, view
            assert view['result']['slow']['count'] == 8, view
            assert view['result']['fast']['count'] == 8, view
            assert view['result']['slow']['arguments'][0]['values'][0]['value'] == '0x1', view
            assert view['result']['fast']['arguments'][0]['values'][0]['value'] == '0x0', view
            assert isinstance(view['result']['slow']['duration']['total_ns'], str), view
            (work / f'{mode}-comparison.json').write_text(json.dumps(view, indent=2) + '\n')
        assert client.tool('get_observation_calls', session_id=key['session_id'], capture_id=key['capture_id'] + 1)['result']['isError']
        (work / f'{mode}.json').write_text(json.dumps({'status': status, 'calls': calls, 'records': records}, indent=2) + '\n')
        if mode == 'balanced':
            previous_selection = client.inspect('get_observation')['comparison_selection']
            rejected = client.tool('compare_observation', **key, threshold_ns=1, start_ns=10, end_ns=1)
            assert rejected.get('error', {}).get('code') == -32602, rejected
            assert client.inspect('get_observation')['comparison_selection'] == previous_selection
            saved = client.action('save_observation', **key, path=str(work / 'after-invalid-selection.xoi'))
            deadline = time.monotonic() + 5
            while True:
                publication = client.inspect('get_observation_archive', id=saved['id'])
                if publication['state'] != 'running':
                    break
                assert time.monotonic() < deadline, publication
            assert publication['state'] == 'completed', publication
            generation = client.session()['generation']
            replies = pipeline(client, [
                ('start_observation', dict(start_args, generation=generation)),
                ('compare_observation', dict(key, threshold_ns=4_000_000)),
                ('associate_observation', dict(key, threshold_ns=4_000_000)),
            ])
            assert not replies[0]['result']['isError'], replies[0]
            for rejected in replies[1:]:
                assert rejected['result']['isError'] and rejected['result']['content'][0]['text'] == 'ObservationStillCollecting', rejected
            new_identity = replies[0]['result']['structuredContent']['preparation']
            ready = wait(client, lambda value: value['state'] != 'preparing')
            assert ready['identity']['capture_id'] == new_identity['capture_id'], ready
            client.action('stop_observation', **{k: new_identity[k] for k in ('session_id', 'capture_id')})
            wait(client, lambda value: value['state'] == 'completed' and not value['cleanup_pending'])
            assert client.tool('get_observation_comparison', id=comparison['id'])['result']['isError']
            print('replacement: old capture cannot gain worker borrowers during preparation; invalid selector preserves saved metadata', flush=True)
        print(mode, len(records), len(complete), status['stop_reason'], flush=True)
    finally:
        client.close()
print('evidence:', work)
