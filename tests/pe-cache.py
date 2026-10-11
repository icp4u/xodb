#!/usr/bin/env python3
"""Periodic: PE identity turnover and scans larger than the metadata cache."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import time
from client import Client
from helpers.input import load_scale

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--work', type=Path, required=True)
p.add_argument('--only', choices=('identity', 'same', 'midstop', 'scan', 'slots'))
p.add_argument('--rounds', type=int, default=1040)
p.add_argument('--wrong-result', action='store_true')
a = p.parse_args()
root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
w = a.work.resolve()
w.mkdir(parents=True)
spec = importlib.util.spec_from_file_location('cache_image', root/'tests/fixtures/pe/cache-image.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)
exe = w/'fixture'
subprocess.run(['cc', '-std=c11', '-O2', '-g', '-Wall', '-Wextra', '-Werror',
                'tests/pe-cache-fixture.c', '-o', str(exe)], check=True)
checks = []
started = time.monotonic()
scale = load_scale()

def usage(c):
    stat = Path(f'/proc/{c.p.pid}/stat').read_text().rsplit(')', 1)[1].split()
    status = Path(f'/proc/{c.p.pid}/status').read_text()
    return dict(cpu_seconds=(int(stat[11])+int(stat[12]))/os.sysconf('SC_CLK_TCK'),
                rss_bytes=int(re.search(r'VmRSS:\s+(\d+)', status).group(1))*1024)

def find(c, name, seconds=30):
    deadline = time.monotonic() + seconds * scale
    polls = 0
    while time.monotonic() < deadline:
        result = c.tool('find_symbol', name=name)['result']
        polls += 1
        if not result.get('isError'):
            return result['structuredContent'], polls
        error = result['content'][0]['text']
        if error != 'SymbolDiscoveryPending':
            return error, polls
        time.sleep(.002)
    raise AssertionError(f'PE lookup did not settle: {name}, {polls} polls')

def client(args):
    c = Client('control', str(exe), args=args, options=('--break', 'pe_cache_marker'), reply_seconds=60*scale)
    c.continue_initial_stop()
    return c

def close(c):
    try:
        c.close()
    except BaseException:
        if c.p.poll() is None:
            c.p.kill()
            c.p.wait()
        raise

def identity(mode):
    image = w/(mode+'.dll')
    fixture.write(image)
    rounds = a.rounds if mode == 'identity' else 16
    assert 2 <= rounds <= 2048
    c = client([mode, str(rounds), str(image)])
    ids = set()
    rows = []
    try:
        before = usage(c)
        for i in range(rounds):
            c.stopped('breakpoint', seconds=30*scale)
            found, polls = find(c, 'cache_value')
            assert isinstance(found, dict), found
            state = c.session()['pe_metadata']
            assert state['identity_count'] == (2 if a.wrong_result else 1), state
            assert state['mapping_count'] == 1, state
            assert found['module_id'] not in ids, ('reused PE identity', found)
            ids.add(found['module_id'])
            if i in (0, 1, rounds-1):
                rows.append(dict(stop=i, pe=state, symbol=found, polls=polls, **usage(c)))
            if i+1 < rounds:
                c.action('continue')
        checks.append(dict(case=mode, status='pass', rounds=rounds, unique_ids=len(ids),
                           before=before, after=usage(c), samples=rows))
    finally:
        close(c)

def midstop():
    """Another process changes the file while the target is stopped."""
    image = w/'midstop.dll'
    fixture.write(image)
    c = client(['same', '2', str(image)])
    try:
        c.stopped('breakpoint', seconds=30*scale)
        found, _ = find(c, 'cache_value')
        assert isinstance(found, dict), found
        os.utime(image, ns=(1, 2))
        answers = [find(c, name, 10)[0] for name in ('cache_value', 'cache_absent', 'cache_value')]
        # The probe saw the change: nothing parsed before it is served.
        assert all(isinstance(answer, str) for answer in answers), answers
        assert answers[-1] == ('PeImageChanged' if a.wrong_result else 'BinaryChangedDuringRead'), answers
        before = c.session()['pe_metadata']['evictions']
        for _ in range(8):
            assert find(c, 'cache_absent', 10)[0] == answers[-1]
        assert c.session()['pe_metadata']['evictions'] == before, 'refusal reparsed the file'
        c.action('continue')
        c.stopped('breakpoint', seconds=30*scale)
        again, _ = find(c, 'cache_value')
        assert isinstance(again, dict) and again['module_id'] != found['module_id'], (found, again)
        checks.append(dict(case='midstop', status='pass', answers=answers, first=found, next=again))
    finally:
        close(c)

def scan():
    images = []
    for i in range(5):
        image = w/f'large-{i}.dll'
        fixture.write(image, 4*1024*1024, 'cache_tail' if i == 4 else 'cache_value')
        images.append(str(image))
    c = client(['hold', *images])
    try:
        c.stopped('breakpoint', seconds=30*scale)
        before = usage(c)
        absent, polls = find(c, 'cache_absent')
        assert absent == ('NotPe' if a.wrong_result else 'SymbolNotFound'), absent
        tail, tail_polls = find(c, 'cache_tail')
        assert isinstance(tail, dict), tail
        # The fifth file is mapped at the fifth fixed synthetic address.
        expected = 0x1000000000 + 4*0x40000000 + 4096 + 4*1024*1024 + 0x800
        assert int(tail['address'], 0) == expected, tail
        state = c.session()['pe_metadata']
        assert state['evictions'] > 0, ('cache pressure was not exercised', state)
        assert state['retained_bytes'] + state['reserved_bytes'] <= 256*1024*1024, state
        checks.append(dict(case='scan', status='pass', absent=absent, polls=polls,
                           tail=tail, tail_polls=tail_polls, pe=state,
                           before=before, after=usage(c)))
    finally:
        close(c)

def slots():
    spec = importlib.util.spec_from_file_location('shared', root/'tests/shared-sessions.py')
    shared = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(shared)
    shared.TIMEOUT = 60 * scale
    images = []
    for i in range(5):
        image = w/f'slots-{i}.dll'
        fixture.write(image, 4*1024*1024, 'cache_tail' if i == 4 else 'cache_value')
        images.append(str(image))
    work = w/'shared'
    work.mkdir()
    server = shared.Server(root, work, Path(os.environ.get('XODB_BIN', 'zig-out/bin/xodb')).resolve(),
                           exe, 'control', options=['--break', 'pe_cache_marker'], fixture_args=['hold', *images])
    try:
        ctl, obs = shared.Client(server, 'controller'), shared.Client(server, 'observer')
        ctl.claim()
        shared.eventually(lambda: ctl.session()['state'], lambda s: s == 'stopped', 'initial stop', 60*scale)
        ctl.action('continue')
        session = shared.eventually(ctl.session, lambda s: s['state'] == 'stopped' and
            not s['symbol_discovery_pending'] and not s['continue_pending'] and
            any(t['reason'] == 'breakpoint' for t in s['threads']), 'marker stop', 60*scale)
        server.remember_target(session)
        generation = session['generation']
        # Adapt the two existing synchronous clients without altering either.
        class Adapter:
            def __init__(self, client):
                self.client, self.p = client, server.proc
            def tool(self, tool_name, **args):
                return self.client.raw(tool_name, **args)
        observer, controller = Adapter(obs), Adapter(ctl)
        before = usage(controller)
        answers = [observer.tool('find_symbol', name=f'cache_abandoned_{i}')['result'] for i in range(16)]
        # Count only a run that actually filled all slots with unfinished work.
        assert all(r.get('isError') and r['content'][0]['text'] == 'SymbolDiscoveryPending' for r in answers), answers
        obs.close()  # Burst, then silence: abandoned names must not block a new client.
        tail, polls = find(controller, 'cache_tail')
        assert isinstance(tail, dict), tail
        expected = 0x1000000000 + 4*0x40000000 + 4096 + 4*1024*1024 + 0x800
        assert int(tail['address'], 0) == expected + int(a.wrong_result), tail
        absent, resumed = find(controller, 'cache_abandoned_0')
        assert absent == 'SymbolNotFound', absent
        after_session = ctl.session()
        assert after_session['generation'] == generation, 'map refresh hid slot exhaustion'
        state = after_session['pe_metadata']
        assert state['evictions'] > 0 and state['retained_bytes'] + state['reserved_bytes'] <= 256*1024*1024, state
        checks.append(dict(case='slots', status='pass', abandoned=16, tail=tail, polls=polls,
                           restarted=absent, restarted_polls=resumed, pe=state, before=before, after=usage(controller)))
    finally:
        server.close()

try:
    if a.only in (None, 'identity'):
        identity('identity')
    if a.only in (None, 'same'):
        identity('same')
    if a.only in (None, 'midstop'):
        midstop()
    if a.only in (None, 'scan'):
        scan()
    if a.only in (None, 'slots'):
        slots()
finally:
    load = os.getloadavg()
    cpus = len(os.sched_getaffinity(0))
    (w/'results.json').write_text(json.dumps(dict(checks=checks, seconds=time.monotonic()-started,
        load=load, allowed_cpus=cpus, performance='measured' if load[0] <= cpus else 'not measurable'), indent=2)+'\n')
print(json.dumps(dict(status='pass', checks=len(checks), seconds=time.monotonic()-started)))
