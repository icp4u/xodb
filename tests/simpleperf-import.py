#!/usr/bin/env python3
"""Verify an imported profile through the real headless MCP endpoint."""
import argparse
from datetime import datetime
import json
from pathlib import Path
import select
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]


class Client:
    def __init__(self, binary, profile, output, env=None, gui=False):
        self.log = (output / 'xodb.log').open('xb')
        self.p = subprocess.Popen([str(binary), *([] if gui else ['--headless']), '--mcp', '--open-profile', str(profile)],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log,
                                  text=True, bufsize=1, env=env)
        self.sequence = 0
        self.latencies = []
        self.request('initialize', dict(protocolVersion='2025-06-18', capabilities={}, clientInfo=dict(name='import-test', version='1')))
        self.p.stdin.write('{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
        self.p.stdin.flush()

    def request(self, method, params=None, allow_error=False):
        self.sequence += 1
        begin = time.monotonic()
        self.p.stdin.write(json.dumps(dict(jsonrpc='2.0', id=self.sequence, method=method, params=params or {})) + '\n')
        self.p.stdin.flush()
        if not select.select([self.p.stdout], [], [], 10)[0]:
            raise TimeoutError(method)
        result = json.loads(self.p.stdout.readline())
        self.latencies.append((time.monotonic() - begin) * 1000)
        assert result['id'] == self.sequence, result
        if 'error' in result and allow_error:
            return result
        assert 'error' not in result, result
        return result['result']

    def tool(self, name, **args):
        result = self.request('tools/call', dict(name=name, arguments=args))
        assert not result.get('isError'), result
        return result['structuredContent']

    def error(self, name, expected, **args):
        result = self.request('tools/call', dict(name=name, arguments=args), allow_error=True)
        assert (result.get('isError') or result.get('error')) and expected in str(result), result

    def ready(self):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            status = self.tool('get_imported_profile')
            if status['status'] != 'pending':
                assert status['status'] == 'ready', status
                return status
            time.sleep(.01)
        raise TimeoutError('import')

    def graph(self, identity, **filters):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            first = self.tool('get_imported_flamegraph', import_id=identity, **filters)
            if first['status'] == 'ready':
                break
            time.sleep(.01)
        else:
            raise TimeoutError('filtered graph')
        nodes = first['nodes'][:]
        page = first
        while page['next'] is not None:
            page = self.tool('get_imported_flamegraph', import_id=identity, view_id=first['view_id'], start=page['next'], **filters)
            assert page['view_id'] == first['view_id'] and page['status'] == 'ready'
            nodes.extend(page['nodes'])
        assert len(nodes) == first['node_total']
        first['nodes'] = nodes
        return first

    def close(self):
        if self.p.poll() is None:
            self.p.stdin.close()
            try:
                self.p.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.p.kill()
                self.p.wait()
                raise
        self.log.close()
        assert self.p.returncode == 0, self.p.returncode


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('profile', type=Path)
    parser.add_argument('--bin', type=Path, default=ROOT / 'zig-out/bin/xodb')
    args = parser.parse_args()
    run = ROOT / '.work' / ('import-check-' + datetime.now().strftime('%Y%m%dT%H%M%S%f'))
    run.mkdir()
    wire = json.loads(args.profile.read_text())
    samples = wire['samples']
    origin = min(int(s['time_ns']) for s in samples)
    period = sum(int(s['period']) for s in samples)
    client = Client(args.bin.resolve(), args.profile.resolve(), run)
    try:
        status = client.ready()
        assert status['samples'] == len(samples) and int(status['total_period']) == period
        assert status['architecture'] == wire['architecture']
        assert client.tool('get_session')['architecture'] == wire['architecture']
        identity = status['import_id']
        assert {t['name'] for t in client.request('tools/list')['tools']} == {
            'get_session', 'get_imported_profile', 'get_imported_flamegraph', 'get_imported_sample'}
        graph = client.graph(identity)
        assert graph['samples'] == len(samples)
        assert int(graph['nodes'][0]['inclusive_period']) + int(graph['excluded_period']) == period
        assert sum(int(n['self_period']) for n in graph['nodes']) == int(graph['nodes'][0]['inclusive_period'])
        children = [0] * len(graph['nodes'])
        for node in graph['nodes'][1:]:
            children[node['parent']] += int(node['inclusive_period'])
        for node in graph['nodes']:
            assert int(node['inclusive_period']) == int(node['self_period']) + children[node['id']]
            example = node['example_sample']
            if example is not None and node['frame_index'] is not None:
                assert node['frame_index'] in [s['frame'] for s in samples[example]['stack']]
        tids = sorted({s['tid'] for s in samples})
        thread_sum = 0
        for tid in tids:
            view = client.graph(identity, tid=tid)
            expected = [s for s in samples if s['tid'] == tid]
            assert view['samples'] == len(expected)
            assert int(view['total_period']) == sum(int(s['period']) for s in expected)
            thread_sum += int(view['total_period'])
        assert thread_sum == period
        chosen = sorted(tids)[:2]
        if len(chosen) == 2:
            multiple = client.graph(identity, tids=chosen)
            expected = [s for s in samples if s['tid'] in chosen]
            assert multiple['samples'] == len(expected)
            assert int(multiple['total_period']) == sum(int(s['period']) for s in expected)
            assert client.graph(identity, tids=list(reversed(chosen)))['view_id'] == multiple['view_id']
            assert client.graph(identity, tids=[chosen[0]])['view_id'] == client.graph(identity, tid=chosen[0])['view_id']
            client.error('get_imported_flamegraph', 'StaleProfileView', import_id=identity, tids=chosen, view_id=graph['view_id'])
            client.error('get_imported_flamegraph', 'InvalidArguments', import_id=identity, tid=chosen[0], tids=chosen)
            client.error('get_imported_flamegraph', 'InvalidArguments', import_id=identity, tids=[chosen[0], chosen[0]])
            client.error('get_imported_flamegraph', 'InvalidProfileThread', import_id=identity, tids=[chosen[0], 2147483647])
        assert client.graph(identity, tids=[])['view_id'] == graph['view_id']
        middle = int(status['extent_ns']) // 2
        if middle:
            left = client.graph(identity, to_ns=str(middle))
            right = client.graph(identity, from_ns=str(middle))
            assert left['samples'] + right['samples'] == len(samples)
            assert int(left['total_period']) + int(right['total_period']) == period
        empty = client.graph(identity, from_ns=str(int(status['extent_ns']) + 1))
        assert empty['samples'] == 0 and empty['nodes'][0]['example_sample'] is None
        for ordinal in sorted({0, len(samples) // 2, len(samples) - 1}):
            raw = samples[ordinal]
            start = 0
            rows = []
            while True:
                page = client.tool('get_imported_sample', import_id=identity, ordinal=ordinal, start=start)
                assert page['time_ns'] == raw['time_ns'] and page['period'] == raw['period']
                assert page['unwind_status'] == 'not_exported'
                rows.extend(page['frames'])
                if page['next'] is None:
                    break
                start = page['next']
            assert len(rows) == len(raw['stack'])
            for imported, original in zip(rows, raw['stack']):
                assert imported['frame_index'] == original['frame']
                assert imported['ip'] == original['ip'] and imported['vaddr'] == original['vaddr']
                assert imported['build_id'] == wire['modules'][wire['frames'][original['frame']]['module']]['build_id']
        client.error('continue', 'OfflineImportedProfile')
        client.error('get_imported_flamegraph', 'StaleImport', import_id='wrong')
        client.error('get_imported_flamegraph', 'StaleProfileView', import_id=identity, view_id='wrong')
        client.error('get_imported_sample', 'InvalidSample', import_id=identity, ordinal=len(samples))
        client.error('get_imported_flamegraph', 'InvalidArguments', import_id=identity, limit=1000)
        result = dict(samples=len(samples), total_period=str(period), nodes=len(graph['nodes']), threads=len(tids),
                      max_request_ms=max(client.latencies), metadata=status, checks='weights, partitions, multi-thread unions/canonical IDs, citations, raw addresses, paging, stale IDs, read-only scope')
        (run / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps({k: v for k, v in result.items() if k != 'metadata'}, indent=2))
        print(run)
    finally:
        client.close()


if __name__ == '__main__':
    main()
