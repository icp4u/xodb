#!/usr/bin/env python3
"""Repeated startup breakpoints hit natively, through the agent and shared MCP."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import time
from client import Client

root = Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
work = (Path('.work') / ('repeat-break-' + str(time.time_ns())[-10:])).resolve()
work.mkdir(parents=True)
binary = Path(os.environ.get('XODB_BIN', 'zig-out/bin/xodb')).resolve()
agent = Path(os.environ.get('XODB_RUNTIME_AGENT', 'zig-out/bin/xodb-agent')).resolve()
fixture = Path('zig-out/bin/xodb-m1-fixture').resolve()
checks = []


def options(names):
    return [v for name in names for v in ('--break', name)]


def inspect(c, name, **args):
    return c.inspect(name, **args) if isinstance(c, Client) else c.tool(name, **args)


def run(c, names, hits):
    probes = inspect(c, 'get_breakpoints')
    definitions = probes['definitions']
    assert [r['symbol'] for r in definitions] == list(dict.fromkeys(names)), definitions
    ids = [r['id'] for r in definitions]
    assert ids == sorted(ids) and len(set(ids)) == len(ids), ids
    for expected in hits:
        c.action('continue')
        deadline = time.monotonic() + 8
        while True:
            state = c.session()
            if state['state'] == 'stopped' and any(t['reason'] == 'breakpoint' for t in state['threads']): break
            assert state['state'] != 'exited' and time.monotonic() < deadline, state
            time.sleep(.003)
        frames = inspect(c, 'get_stack', tid=state['pid'])['frames']
        assert frames[0]['symbol'] == expected, (expected, frames)
    return ids


original_agent = os.environ.pop('XODB_RUNTIME_AGENT', None)
try:
    for through_agent in (False, True):
        prefix = ['--runtime-agent', str(agent)] if through_agent else []
        for names in (['main', 'change_value'], ['main', 'absent_owned_symbol', 'change_value', 'main'],
                      ['main'] * 62 + ['absent_owned_symbol', 'change_value']):
            c = Client('control', str(fixture), options=prefix + options(names))
            try:
                run(c, names, ['main', 'change_value', 'change_value'])
                checks.append({'agent': through_agent, 'option_count': len(names)})
            finally:
                (work / f'm1-{through_agent}-{len(names)}.json').write_text(json.dumps(c.transcript, indent=2)); c.close()
        exe, lib = work / 'pending', work / 'late.so'
        if not exe.exists():
            for cmd in (['cc', '-g', '-O0', 'tests/fixtures/pending.c', '-ldl', '-o', str(exe)],
                        ['cc', '-g', '-O0', '-shared', '-fPIC', 'tests/fixtures/pending-lib.c', '-o', str(lib)]):
                subprocess.run(cmd, check=True)
        names = ['before_load', 'late_function', 'after_unload']
        c = Client('control', str(exe.resolve()), args=[str(lib.resolve())], options=prefix + options(names))
        try:
            before = c.inspect('get_breakpoints')
            late = next(r['id'] for r in before['definitions'] if r['symbol'] == 'late_function')
            assert next(b for b in before['breakpoints'] if b['id'] == late)['pending']
            run(c, names, ['before_load', 'late_function', 'after_unload', 'late_function', 'after_unload'])
            checks.append({'agent': through_agent, 'pending_load_reload': True})
        finally: c.close()

    spec = importlib.util.spec_from_file_location('shared_test', root / 'tests/shared-sessions.py')
    shared = importlib.util.module_from_spec(spec); spec.loader.exec_module(shared)
    server = shared.Server(root, work, binary, fixture, 'control', options=options(['main', 'change_value']), fixture_args=())
    try:
        c = shared.Client(server, 'repeated-break-test'); server.remember_target(c.session()); c.claim()
        run(c, ['main', 'change_value'], ['main', 'change_value', 'change_value'])
        checks.append({'shared_session': True})
    finally: server.close()
finally:
    if original_agent is not None: os.environ['XODB_RUNTIME_AGENT'] = original_agent

over = subprocess.run([str(binary), '--headless', *options(['main'] * 65), '--', str(fixture)], capture_output=True, timeout=10)
assert over.returncode != 0 and b'InitialBreakpointLimit' in over.stderr, over.stderr
checks.append({'65th_option': 'refused before launch'})
(work / 'results.json').write_text(json.dumps(checks, indent=2))
print('Repeated --break:', len(checks), 'groups passed;', work)
