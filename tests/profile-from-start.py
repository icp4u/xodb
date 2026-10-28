#!/usr/bin/env python3
"""Profile an owned launch from its exec stop, including constructor CPU."""
from datetime import datetime
import json
import os
from pathlib import Path
import shlex
import subprocess
import time

from client import Client

root = Path(__file__).resolve().parents[1]
os.chdir(root)
work = root / '.work' / ('profile-from-start-' + datetime.now().strftime('%Y%m%dT%H%M%S%f'))
work.mkdir(parents=True)
fixture = './zig-out/bin/xodb-profile-start-fixture'


def wait_capture(client, predicate, seconds=30, process_id=None):
    deadline = time.monotonic() + seconds
    capture = None
    while time.monotonic() < deadline:
        capture = client.inspect('get_profile', **({'process_id': process_id} if process_id else {}))['capture']
        assert capture is not None
        if predicate(capture):
            return capture
        time.sleep(.02)
    raise AssertionError(('capture timeout', capture))


def graph(client, capture, process_id=None):
    rows = []
    start = 0
    view_id = None
    while True:
        page = client.inspect('get_flamegraph', capture_id=capture['id'],
                              revision=capture['revision'], start=start, limit=64,
                              **({'view_id': view_id} if view_id else {}),
                              **({'process_id': process_id} if process_id else {}))
        view_id = page['view_id']
        rows += page['nodes']
        if page['next'] is None:
            assert len(rows) == page['total_nodes']
            return rows
        start = page['next']


def launch_case(name, options, expected_hz, expected_duration, evidence=False,
                exec_wrapper=False):
    stop = work / (name + '.stop')
    ready = work / (name + '.ready')
    profile_out = work / (name + '.speedscope.json')
    capture_out = work / (name + '.xoc')
    outputs = ['--profile-out', str(profile_out), '--capture-out', str(capture_out)] if evidence else []
    executable = '/bin/sh' if exec_wrapper else fixture
    args = (['-c', 'exec ' + shlex.join([fixture, str(stop), str(ready)])]
            if exec_wrapper else [str(stop), str(ready)])
    client = Client('control', executable, args=args,
                    options=['--start-profile', *options, *outputs], reply_seconds=15)
    final = None
    try:
        # This is deliberately the first inspection after MCP initialization.
        first = client.inspect('get_profile')
        capture = first['capture']
        assert capture is not None and capture['status'] == 'collecting', first
        if exec_wrapper:
            capture = wait_capture(client, lambda value: value['id'] >= 2 and
                                    value['status'] == 'collecting')
        assert capture['accepted']['requested_frequency_hz'] == expected_hz, capture
        assert capture['duration_ms'] == expected_duration, capture
        assert capture['follow_threads'] and capture['opening_threads'] == 1, capture
        deadline = time.monotonic() + 15
        while not ready.exists():
            assert client.session()['state'] == 'running'
            assert time.monotonic() < deadline
            time.sleep(.01)
        # Ordering, independent of sampling luck: the capture opened before the
        # constructor (user code) began. Both clocks are this host's CLOCK_MONOTONIC.
        constructor_ns = int(ready.read_text())
        assert constructor_ns and capture['started_ns'] < constructor_ns, (capture['started_ns'], constructor_ns)
        if evidence:
            baseline = client.inspect('get_profile')['capture']['stored_samples']
            wait_capture(client, lambda value: value['stored_samples'] >= baseline + 150)
        stop.write_text('stop\n')
        final = wait_capture(client, lambda value: value['status'] != 'collecting')
        deadline = time.monotonic() + 15
        while client.session()['state'] != 'exited':
            assert time.monotonic() < deadline
            time.sleep(.02)
        if evidence:
            assert final['status'] == 'target_ended', final
            nodes = graph(client, final)
            hot = {node['name']: node for node in nodes
                   if node['name'] in ('profile_startup_hot', 'profile_late_hot')}
            assert hot.keys() == {'profile_startup_hot', 'profile_late_hot'}, nodes
            assert all(node['self'] > 0 for node in hot.values()), hot
    finally:
        client.close()
    if evidence:
        exported = profile_out.read_text()
        assert 'profile_startup_hot' in exported and 'profile_late_hot' in exported
        assert capture_out.stat().st_size > 0
    return final


# CLI values override the already-existing profile preference keys.
config = work / 'configured.json'
config.write_text(json.dumps({'profile': {'frequency_hz': 113, 'duration_ms': 5000}}) + '\n')
launch_case('cli', ['--config', str(config), '--profile-hz', '997', '--profile-duration', '0'], 997, 0, evidence=True)

# A launch without either source profiles until it exits; explicit preferences
# remain usable for the same startup capture.
launch_case('default', [], 99, 0)
empty_config = work / 'empty.json'
empty_config.write_text('{}\n')
launch_case('empty-config', ['--config', str(empty_config)], 99, 0)
configured = work / 'profile.json'
configured.write_text(json.dumps({'profile': {'frequency_hz': 321, 'duration_ms': 60000}}) + '\n')
launch_case('preferences', ['--config', str(configured)], 321, 60000)

# The shell is the first image captured. Its exec closes that image's evidence,
# then xodb arms the same request against the fixture before constructor code.
launch_case('exec-wrapper', ['--profile-hz', '997', '--profile-duration', '0'],
            997, 0, evidence=True, exec_wrapper=True)

# A followed process is held at birth. It gets an independent startup capture,
# restarts that capture across its exec, and resumes without an MCP continue.
stop = work / 'follow.stop'
ready = work / 'follow.ready'
command = shlex.join([fixture, str(stop), str(ready)]) + ' & wait'
followed = Client('control', '/bin/sh', args=['-c', command],
                  options=['--follow-forks', '--start-profile', '--profile-hz', '997',
                           '--profile-duration', '0'], reply_seconds=15)
try:
    deadline = time.monotonic() + 20
    tree = None
    while time.monotonic() < deadline:
        tree = followed.inspect('get_processes')
        if tree['total'] == 2:
            break
        time.sleep(.02)
    assert tree is not None and tree['total'] == 2, tree
    child = next(row for row in tree['processes'] if row['process_id'] != 1)
    assert child['parent_process_id'] == 1 and child['following'], tree
    child_id = child['process_id']
    root_capture = wait_capture(followed, lambda value: value['status'] == 'collecting',
                                process_id=1)
    child_capture = wait_capture(followed, lambda value: value['id'] >= 2 and
                                 value['status'] == 'collecting', process_id=child_id)
    for capture in (root_capture, child_capture):
        assert capture['accepted']['requested_frequency_hz'] == 997, capture
        assert capture['duration_ms'] == 0, capture
        assert capture['follow_threads'] and capture['opening_threads'] == 1, capture
    deadline = time.monotonic() + 15
    while not ready.exists():
        state = followed.inspect('get_session', process_id=child_id)
        assert state['state'] == 'running', state
        assert time.monotonic() < deadline
        time.sleep(.01)
    constructor_ns = int(ready.read_text())
    assert constructor_ns and child_capture['started_ns'] < constructor_ns, (child_capture, constructor_ns)
    baseline = child_capture['stored_samples']
    child_capture = wait_capture(followed, lambda value: value['stored_samples'] >= baseline + 150,
                                 process_id=child_id)
    stop.write_text('stop\n')
    child_capture = wait_capture(followed, lambda value: value['status'] != 'collecting',
                                 process_id=child_id)
    root_capture = wait_capture(followed, lambda value: value['status'] != 'collecting',
                                process_id=1)
    assert child_capture['status'] == 'target_ended', child_capture
    assert root_capture['status'] == 'target_ended', root_capture
    nodes = graph(followed, child_capture, process_id=child_id)
    hot = {node['name']: node for node in nodes
           if node['name'] in ('profile_startup_hot', 'profile_late_hot')}
    assert hot.keys() == {'profile_startup_hot', 'profile_late_hot'}, nodes
    assert all(node['self'] > 0 for node in hot.values()), hot
finally:
    followed.close()

# A program that runs a child during startup keeps one capture of its own
# process, constructor included, with or without following the child.
for follow in ([], ['--follow-forks']):
    stop = work / ('system%d.stop' % len(follow))
    ready = work / ('system%d.ready' % len(follow))
    spawning = Client('control', fixture, args=[str(stop), str(ready), 'system'],
                      options=[*follow, '--start-profile', '--profile-hz', '997'], reply_seconds=15)
    try:
        deadline = time.monotonic() + 15
        while not ready.exists():
            assert time.monotonic() < deadline
            time.sleep(.01)
        capture = spawning.inspect('get_profile', process_id=1)['capture']
        assert capture['id'] == 1 and capture['status'] == 'collecting', capture
        assert capture['started_ns'] < int(ready.read_text()), capture
        baseline = capture['stored_samples']
        wait_capture(spawning, lambda value: value['stored_samples'] >= baseline + 150, process_id=1)
        stop.write_text('stop\n')
        final = wait_capture(spawning, lambda value: value['status'] != 'collecting', process_id=1)
        assert final['id'] == 1 and final['status'] == 'target_ended', final
        hot = {node['name']: node for node in graph(spawning, final, process_id=1)
               if node['name'] in ('profile_startup_hot', 'profile_late_hot')}
        assert hot.keys() == {'profile_startup_hot', 'profile_late_hot'}, hot
    finally:
        spawning.close()

# Keep the established attach contract. The runtime-agent lane exercises launch;
# start-profile attach intentionally remains local-only as it was before.
if not (os.environ.get('XODB_TEST_RUNTIME_AGENT') or os.environ.get('XODB_RUNTIME_AGENT')):
    stop = work / 'attach.stop'
    ready = work / 'attach.ready'
    target = subprocess.Popen([fixture, str(stop), str(ready)], stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL)
    attached = None
    try:
        deadline = time.monotonic() + 10
        while not ready.exists():
            assert target.poll() is None
            assert time.monotonic() < deadline
            time.sleep(.01)
        attached = Client('control', executable=None,
                          options=['--attach', str(target.pid), '--start-profile'], reply_seconds=15)
        capture = attached.inspect('get_profile')['capture']
        assert capture['accepted']['requested_frequency_hz'] == 99 and capture['duration_ms'] == 10000, capture
        assert attached.session()['state'] == 'running'
        stop.write_text('stop\n')
        target.wait(timeout=15)
        wait_capture(attached, lambda value: value['status'] != 'collecting')
    finally:
        if attached is not None:
            attached.close()
        if target.poll() is None:
            target.terminate()
            target.wait(timeout=5)

print('PASS: startup profiles begin before constructors, continue across exec/followed forks, and preserve defaults, exports and attach')
