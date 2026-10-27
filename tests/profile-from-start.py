#!/usr/bin/env python3
"""Profile an owned launch from its exec stop, including constructor CPU."""
from datetime import datetime
import json
import os
from pathlib import Path
import subprocess
import time

from client import Client

root = Path(__file__).resolve().parents[1]
os.chdir(root)
work = root / '.work' / ('profile-from-start-' + datetime.now().strftime('%Y%m%dT%H%M%S%f'))
work.mkdir(parents=True)
fixture = './zig-out/bin/xodb-profile-start-fixture'


def wait_capture(client, predicate, seconds=30):
    deadline = time.monotonic() + seconds
    capture = None
    while time.monotonic() < deadline:
        capture = client.inspect('get_profile')['capture']
        assert capture is not None
        if predicate(capture):
            return capture
        time.sleep(.02)
    raise AssertionError(('capture timeout', capture))


def graph(client, capture):
    rows = []
    start = 0
    view_id = None
    while True:
        page = client.inspect('get_flamegraph', capture_id=capture['id'],
                              revision=capture['revision'], start=start, limit=64,
                              **({'view_id': view_id} if view_id else {}))
        view_id = page['view_id']
        rows += page['nodes']
        if page['next'] is None:
            assert len(rows) == page['total_nodes']
            return rows
        start = page['next']


def launch_case(name, options, expected_hz, expected_duration, evidence=False):
    stop = work / (name + '.stop')
    ready = work / (name + '.ready')
    profile_out = work / (name + '.speedscope.json')
    capture_out = work / (name + '.xoc')
    outputs = ['--profile-out', str(profile_out), '--capture-out', str(capture_out)] if evidence else []
    client = Client('control', fixture, args=[str(stop), str(ready)],
                    options=['--start-profile', *options, *outputs], reply_seconds=15)
    final = None
    try:
        # This is deliberately the first inspection after MCP initialization.
        first = client.inspect('get_profile')
        capture = first['capture']
        assert capture is not None and capture['status'] == 'collecting', first
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

print('PASS: launch profiles constructor and later CPU from exec; defaults, preferences, exports and attach hold')
