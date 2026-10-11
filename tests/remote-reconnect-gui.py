#!/usr/bin/env python3
"""Fast GUI lane: fresh incarnations, lost mutation reply, or held startup."""
import argparse
import ctypes
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time
from types import SimpleNamespace


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


def run(args):
    root = Path(__file__).resolve().parents[1]
    owner = module('owner_test', root/'tests/remote-owner-gui.py')
    shared = module('shared_test', root/'tests/shared-sessions.py')
    h, work = owner.setup(root)
    scale = h.load_scale()
    # Adopt only descendants of our owned agent so detached fixtures are reaped.
    assert ctypes.CDLL(None).prctl(36, 1, 0, 0, 0) == 0
    wrapper = work/'agent-proxy'
    wrapper.write_text('#!/usr/bin/env python3\nimport os, sys\nos.execv(sys.executable, '+repr([
        sys.executable, str(root/'tests/remote-owner-gui.py'), '--proxy', str(work), str(root/'zig-out/bin/xodb-agent')])+')\n')
    wrapper.chmod(0o755)
    # Derive the operation ID from the protocol declaration, not a copied guess.
    enum = (root/'src/runtime/rpc.h').read_text().split('enum xrt_rpc_op {', 1)[1].split('};', 1)[0]
    operations = re.findall(r'XRT_RPC_[A-Z_]+', enum)
    held_op = 1 if args.startup else operations.index('XRT_RPC_WRITE')+1
    (work/'hold-op').write_text(str(held_op))
    if args.startup:
        (work/'arm').touch()
    display = None
    registry = SimpleNamespace(path=str(work/'session.sock'), clients=[])
    target = None
    started = time.monotonic()
    report = {'passed': False, 'startup': args.startup, 'load': os.getloadavg(), 'cpus': len(os.sched_getaffinity(0))}

    def wait(check, message):
        return owner.wait(check, message, timeout=15*scale)

    def held():
        path = work/'held.json'
        return json.loads(path.read_text()) if path.exists() else None

    def reconnect(incarnation):
        display.keys('down', 29, 'down', 42, 'tap', 19, 'up', 42, 'up', 29)
        wait(lambda: f'remote incarnation={incarnation} retired;' in Path(display.log).read_text(), 'old incarnation did not retire')
        assert display.alive(), display.tail()

    try:
        display = h.Display(str(root), ['--runtime-agent', str(wrapper), '--agent-scope', 'mutate',
            '--session-socket', registry.path, '--source', 'tests/fixtures/m1.c',
            '--', str(root/'zig-out/bin/xodb-m1-fixture'), 'w'], stdio=False, binary=args.binary)
        registry.proc = display.app
        if args.startup:
            reply = wait(held, 'startup reply was not held')
            assert reply['op'] == 1 and not (work/'release').exists(), reply
            # The window was mapped/focused by Display while startup was held.
            report['window_mapped_during_held_startup'] = True
            report['before'] = owner.usage(display.app.pid)
            display.keys('tap', 18)
            wait(lambda: 'editor=open' in Path(display.log).read_text(), 'editor did not paint during startup')
            subprocess.run(['swaymsg', '-s', display.env['SWAYSOCK'], '[app_id="xodb"] kill'], env=display.env,
                           capture_output=True, check=True, timeout=10*scale)
            display.app.wait(timeout=15*scale)
            assert display.app.returncode == 0, Path(display.log).read_text()
            assert not (work/'release').exists() and (work/'cancelled-before-release').exists()
            report['owner_done_before_release'] = True
        else:
            first = shared.Client(registry, 'first-incarnation')
            state = first.session()
            assert state['state'] == 'stopped', state
            target = state['pid'], shared.process_identity(state['pid'])
            (work/'owned-target.json').write_text(json.dumps({'pid': target[0], 'identity': target[1]}))
            first.claim()
            old_lease = first.info()
            lookup = first.raw('find_symbol', name='state')
            assert not lookup['result']['isError'], lookup
            address = lookup['result']['structuredContent']['address']
            report['before'] = owner.usage(display.app.pid)
            (work/'arm').touch()
            first.serial += 1
            pending_id = first.serial
            first.send({'jsonrpc': '2.0', 'id': pending_id, 'method': 'tools/call', 'params': {
                'name': 'write_memory', 'arguments': {'generation': state['generation'], 'address': address, 'hex': '6300000000000000'}}})
            reply = wait(held, 'the actual mutation reply was not held')
            assert reply['op'] == held_op and reply['status'] == 0, reply
            report['peer_confirmed_mutation_before_reply_loss'] = reply
            reconnect(1)
            response = first.receive(pending_id)
            report['lost_reply_result'] = response
            assert response['result']['isError'] and 'RemoteOutcomeUnknown' in json.dumps(response), response
            assert (work/'cancelled-before-release').exists() and not (work/'release').exists()
            # The old channel is closed, even though a new listener uses its path.
            assert first.sock.recv(1) == b''
            first.close()
            fresh = shared.Client(registry, 'fresh-incarnation')
            snapshot = fresh.session()
            assert snapshot['state'] == 'idle' and snapshot['pid'] == 0 and snapshot['agent_scope'] == 'observe', snapshot
            assert snapshot['session_id'] != state['session_id'], (state, snapshot)
            info = fresh.info()
            assert info['controller_id'] is None, (old_lease, info)
            refused = fresh.raw('write_memory', generation=state['generation'], address=address, hex='6400000000000000')
            assert refused['result']['isError'] and 'AgentScopeDenied' in json.dumps(refused), refused
            report['fresh_session'] = snapshot
            report['old_control_refused'] = refused
            for incarnation in (2, 3):
                reconnect(incarnation)
                assert fresh.sock.recv(1) == b''
                fresh.close()
                fresh = shared.Client(registry, 'another-incarnation')
                state = fresh.session()
                assert state['state'] == 'idle' and state['session_id'] != snapshot['session_id'], state
                snapshot = state
            requests = [json.loads(line) for line in (work/'requests.jsonl').read_text().splitlines()]
            assert len({row['transport'] for row in requests}) == 4, requests
            assert sum(row['op'] == 5 for row in requests) == 1, 'launch replayed'
            assert sum(row['op'] == held_op for row in requests) == 1, 'mutation replayed'
            report['connections'] = 4
            report['no_launch_or_mutation_replay'] = True
            report['after'] = owner.usage(display.app.pid)
        report['passed'] = True
    finally:
        (work/'release').touch()
        for client in registry.clients:
            client.close()
        if display:
            display.close()
        if target:
            pid, identity = target
            current = shared.process_identity(pid)
            if current and identity and current[0] == identity[0]:
                os.kill(pid, signal.SIGKILL)
                try:
                    os.waitpid(pid, 0)
                except ChildProcessError:
                    pass
        report['seconds'] = time.monotonic()-started
        report['performance_measurable'] = os.getloadavg()[0] <= report['cpus']
        (work/'result.json').write_text(json.dumps(report, indent=2)+'\n')
        print(json.dumps({**report, 'work': str(work)}), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary')
    parser.add_argument('--startup', action='store_true')
    run(parser.parse_args())
