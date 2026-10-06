#!/usr/bin/env python3
"""Shared-client attribution survives process routing and family detach.

Launches only the owned vfork fixture. XODB_BIN, XODB_RUNTIME_AGENT and
XODB_TEST_TMPDIR have the same meanings as in shared-sessions.py.
"""
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time


root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('shared_sessions', root / 'tests/shared-sessions.py')
shared = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shared)


def snapshot(client, process):
    return client.tool('get_session', process_id=process)


def action(client, process, name, **args):
    return client.tool(name, process_id=process, generation=snapshot(client, process)['generation'], **args)


def alive(pid, identity):
    current = shared.process_identity(pid)
    return current is not None and current[0] == identity[0] and current[1] != 'Z'


def detached_family(server, process):
    owner = shared.Client(server, 'family-controller')
    observer = shared.Client(server, 'family-observer')
    owned = {}
    report = {'detach_via_process': process}
    try:
        initial = shared.eventually(owner.session, lambda value: value['state'] == 'stopped', 'initial fixture stop')
        server.remember_target(initial)
        owned[initial['pid']] = server.target_identity
        owner_id = owner.info()['client_id']
        assert owner_id != observer.info()['client_id']
        owner.claim()
        owner.action('continue')
        shared.eventually(owner.session,
                          lambda value: value['state'] == 'stopped' and any(t['reason'] == 'breakpoint' for t in value['threads']),
                          'tree_ready breakpoint')
        owner.action('continue')
        tree = shared.eventually(lambda: observer.tool('get_processes'),
                                 lambda value: value['total'] == 2, 'vfork child admission')
        rows = tree['processes']
        assert [row['process_id'] for row in rows] == [1, 2], rows
        assert rows[1]['parent_process_id'] == 1 and rows[1]['kind'] == 'vfork', rows
        assert all(row['shared_vm'] for row in rows), rows
        before = {}
        for row in rows:
            ident = row['process_id']
            state = snapshot(observer, ident)
            assert state['state'] == 'stopped' and state['pid'] == row['pid'], state
            birth = shared.process_identity(state['pid'])
            assert birth is not None and birth[1] != 'Z', state
            owned[state['pid']] = birth
            before[ident] = state
            shared.expect_error(observer.raw('detach_process_family', process_id=ident,
                                            generation=state['generation']), 'ControlLeaseRequired')
            assert snapshot(observer, ident) == state, 'denied observer detach changed target state'
        assert owner.info()['controller_id'] == owner_id
        action(owner, process, 'detach_process_family')
        audit = {}
        for ident in (1, 2):
            state = snapshot(observer, ident)
            assert state['state'] == 'idle', state
            assert state['session_id'] == before[ident]['session_id'], (before[ident], state)
            actions = observer.tool('get_audit', process_id=ident)
            assert actions['process_id'] == ident and actions['process_session_id'] == state['session_id'], actions
            last = actions['actions'][-1]
            assert last['action'] == 'detach_process_family' and last['actor'] == 'agent', last
            assert last['client_id'] == owner_id, (ident, owner_id, last)
            assert state['last_action'] == last, (state, last)
            assert owner.tool('get_audit', process_id=ident)['actions'][-1] == last
            audit[ident] = last
        after = observer.tool('get_processes')
        assert after['total'] == 2 and all(row['state'] == 'idle' for row in after['processes']), after
        assert observer.session()['process_id'] == 1, 'routing changed the default process'
        shared.eventually(lambda: [pid for pid, birth in owned.items() if alive(pid, birth)],
                          lambda pids: not pids, 'detached fixture completion')
        report.update(client_id=owner_id, audits=audit, pids=list(owned), retained_sessions=2)
        server.stop_and_check()
        # The fixture parent normally reaps its fork child; the server reaps
        # its own child during shutdown. Neither owned process may remain.
        shared.eventually(lambda: [pid for pid in owned if shared.process_identity(pid) is not None],
                          lambda pids: not pids, 'detached fixture reaping')
        report['passed'] = True
        return report
    finally:
        server.close()
        # Failure cleanup cannot target a reused PID. Kill a remaining owned
        # child before its parent, allowing waitpid to reap it when possible.
        for pid, birth in reversed(list(owned.items())):
            if alive(pid, birth):
                os.kill(pid, signal.SIGKILL)
                time.sleep(.02)
        (server.work / 'family-result.json').write_text(json.dumps(report, indent=2) + '\n')


def main():
    os.umask(0o022)
    os.chdir(root)
    work = Path(tempfile.mkdtemp(prefix='xodb-shared-tree-', dir=os.environ.get('XODB_TEST_TMPDIR')))
    work.chmod(0o755)
    binary = Path(os.environ.get('XODB_BIN', 'zig-out/bin/xodb')).resolve()
    fixture = work / 'fixture'
    subprocess.run(['cc', '-g', '-O0', '-fno-omit-frame-pointer', '-Wall', '-Wextra', '-Werror',
                    str(root / 'tests/fixtures/process-tree.c'), '-o', str(fixture)], check=True,
                   env=dict(os.environ, TMPDIR=str(work)))
    report = {'artifact': str(work), 'runtime_agent': bool(os.environ.get('XODB_RUNTIME_AGENT')), 'cases': []}
    try:
        for process in (1, 2):
            case = work / f'via-{process}'
            case.mkdir(mode=0o755)
            server = shared.Server(root, case, binary, fixture, 'control',
                                   options=('--follow-forks', '--break', 'tree_ready'), fixture_args=('vfork-detach',))
            report['cases'].append(detached_family(server, process))
        report['passed'] = True
        print(json.dumps(report))
    finally:
        (work / 'result.json').write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
