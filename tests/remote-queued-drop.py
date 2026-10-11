#!/usr/bin/env python3
"""Fast live lane: admitted mutation, client disposal, dispatch, unchanged data.

The barrier runs after queue admission. Socket writes alone never count as
admission evidence. A second real client verifies the sentinel and exercises
the same mutation handler after acquiring a fresh controller lease.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import time


def run(args):
    root = Path(__file__).resolve().parents[1]
    work = Path(args.work).resolve()
    work.mkdir(mode=0o755, parents=True, exist_ok=False)
    probes = work / 'probes'
    probes.mkdir(mode=0o755)
    os.environ.update(XODB_RUNTIME_AGENT=str(root/'zig-out/bin/xodb-agent'),
                      XODB_TEST_PRIVATE_DISPLAY='1', XODB_TEST_REMOTE_DIR=str(probes))
    spec = importlib.util.spec_from_file_location('shared_sessions', root/'tests/shared-sessions.py')
    shared = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(shared)
    scale = max(1, os.getloadavg()[0] / len(os.sched_getaffinity(0)))
    shared.TIMEOUT = 10 * scale
    server = None
    report = {'passed': False, 'load': os.getloadavg(), 'cpus': len(os.sched_getaffinity(0))}
    started = time.monotonic()

    def marker(name):
        path = probes / (name+'.json')
        deadline = time.monotonic() + 10 * scale
        while not path.exists():
            assert server.proc.poll() is None, (server.work/'server.log').read_text()
            assert time.monotonic() < deadline, (name, (server.work/'server.log').read_text())
            time.sleep(.002)
        return json.loads(path.read_text())

    try:
        server = shared.Server(root, work, Path(args.binary).resolve(), root/'zig-out/bin/xodb-m1-fixture', 'mutate')
        dropped = shared.Client(server, 'queued-writer')
        survivor = shared.Client(server, 'surviving-reader')
        snapshot = survivor.session()
        assert snapshot['state'] == 'stopped', snapshot
        server.remember_target(snapshot)
        dropped.claim()
        identity = dropped.info()
        lookup = survivor.raw('find_symbol', name='state')
        assert not lookup['result']['isError'], lookup
        address = lookup['result']['structuredContent']['address']
        before = survivor.tool('read_memory', address=address, length=8)['hex']
        mutation = (99).to_bytes(8, 'little').hex()
        assert before != mutation, before
        generation = survivor.session()['generation']
        (probes/'arm').touch()
        dropped.serial += 1
        dropped.send({'jsonrpc': '2.0', 'id': dropped.serial, 'method': 'tools/call',
                      'params': {'name': 'write_memory', 'arguments': {
                          'generation': generation, 'address': address, 'hex': mutation}}})
        admitted = marker('admitted')
        assert admitted['sequence'] > 0 and admitted['client'] == identity['client_id'], admitted
        assert admitted['lease'] is not None and admitted['stamp']['pid'] == snapshot['pid'], admitted
        assert not (probes/'dispatch.json').exists()
        report['admitted'] = admitted
        dropped.close()
        disconnected = marker('disconnected')
        assert disconnected['sequence'] == admitted['sequence'] and disconnected['client'] == admitted['client'], disconnected
        assert not (probes/'dispatch.json').exists()
        report['disconnect_observed_before_dispatch'] = True
        (probes/'release').touch()
        dispatched = marker('dispatch')
        finished = marker('finished')
        assert dispatched == {'sequence': admitted['sequence'], 'disconnected': True}, dispatched
        assert finished == {'sequence': admitted['sequence'], 'disposed': True, 'dispatched': True}, finished
        report['disposed'] = finished
        after = survivor.tool('read_memory', address=address, length=8)['hex']
        report['sentinel'] = {'before': before, 'after': after, 'requested': mutation}
        assert after == (mutation if args.wrong_result else before), report['sentinel']
        info = survivor.info()
        assert info['controller_id'] is None and len(info['clients']) == 1, info
        survivor.claim()
        # Acquiring another lease cannot revive the disposed command.
        assert survivor.tool('read_memory', address=address, length=8)['hex'] == before
        survivor.action('write_memory', address=address, hex=mutation)
        assert survivor.tool('read_memory', address=address, length=8)['hex'] == mutation
        report['surviving_client_mutation_confirmed'] = True
        report['passed'] = True
    finally:
        (probes/'release').touch()
        if server:
            server.close()
        report['seconds'] = time.monotonic() - started
        (work/'result.json').write_text(json.dumps(report, indent=2)+'\n')
        print(json.dumps(report), flush=True)
    if not args.wrong_result:
        wrong = subprocess.run([sys.executable, '-B', __file__, '--binary', args.binary,
                                '--work', str(work/'wrong'), '--wrong-result'],
                               capture_output=True, text=True, timeout=60*scale)
        (work/'wrong-result.log').write_text(wrong.stdout+wrong.stderr)
        rows = [json.loads(line) for line in wrong.stdout.splitlines() if line.startswith('{')]
        assert wrong.returncode != 0 and rows and rows[-1].get('disconnect_observed_before_dispatch') and rows[-1].get('sentinel'), wrong.stdout+wrong.stderr


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', default='zig-out/bin/xodb')
    parser.add_argument('--work', required=True)
    parser.add_argument('--wrong-result', action='store_true')
    run(parser.parse_args())
