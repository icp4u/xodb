#!/usr/bin/env python3
"""Fast live lane: frame timings and explicit frame/owner/native joins."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys
import time
from client import Client

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'scripts/helpers'))
from redot_scene import start_scene
from redot_time import sample_time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--redot', required=True)
    parser.add_argument('--work', type=Path, required=True)
    args = parser.parse_args()
    os.chdir(root)
    os.umask(0o022)
    args.work.mkdir(parents=True, exist_ok=True)
    project = args.work.resolve() / 'project'
    shutil.copytree(root / 'tests/fixtures/redot-time', project)
    start = time.monotonic()
    client = Client('control', str(Path(args.redot).resolve()), ('--headless', '--path', str(project)), ('--redot-debugger', '--image-limit', '1600M', '--image-total-limit', '2G'), reply_seconds=30)
    def usage():
        fields = Path(f'/proc/{client.p.pid}/stat').read_text().rsplit(')', 1)[1].split()
        return dict(cpu_seconds=(int(fields[11])+int(fields[12]))/os.sysconf('SC_CLK_TCK'), rss_bytes=int(fields[21])*os.sysconf('SC_PAGE_SIZE'))
    before = usage()
    try:
        scene = start_scene(client.inspect)
        samples = sample_time(client.inspect, 12)
        all_frames = client.inspect('get_redot_profile', limit=256)
        assert all_frames['enabled'] is False and len(all_frames['frames']) > 1, all_frames
        joined = []
        for sample in samples:
            detail = client.inspect('get_redot_profile', frame_number=sample['frame_number'])
            frame = detail['selected']
            if not frame:
                continue
            burn = next((s for s in sample['script'] if s['name'] == 'burn' and s['native_frame'] is not None and s['reason'] is None), None)
            if not burn:
                continue
            function = next(f for f in frame['functions'] if f['signature'].endswith('::burn'))
            assert function['calls'] > 0 and function['total_ms'] >= function['self_ms'] > 0, function
            slow = next(n for n in scene['nodes'] if n['name'] == 'Slow')
            assert burn['owner_id'] == slow['object_id'] and burn['file'] == 'res://slow.gd', burn
            native = sample['native'][burn['native_frame']]
            assert 'GDScriptFunction' in native['display'], native
            assert len(detail['native_samples']) > 0 and sample['frame_number'] == frame['number']
            assert frame['frame_ms'] >= frame['script_ms'] > 0
            shared = [n for n in detail['node_costs'] if n['name'].startswith('Light')]
            assert len(shared) == 2 and all(n['script_instances'] == 2 and n['attribution'] == 'shared_script_cost_not_per_instance' for n in shared), shared
            assert next(n for n in detail['node_costs'] if n['name'] == 'Slow')['script_self_ms'] > max(n['script_self_ms'] for n in shared)
            joined.append(detail)
        assert joined, samples
        assert any(s['native_frame'] is not None and s['native_frame'] > 0 for sample in samples for s in sample['script'] if s['name'] == 'burn' and s['reason'] is None), samples
        result = dict(status='pass', frames=all_frames['frames'], samples=samples, joined=joined, before=before, after=usage())
    finally:
        client.close()
    truth = [json.loads(line.split(' ', 2)[2]) for line in client.p.stderr.read().decode().splitlines() if line.startswith('ORACLE frame ')]
    assert truth
    oracle = {f['process']: f for f in truth}
    for detail in joined:
        number = detail['selected']['number']
        assert number in oracle
        assert any(s['owner_id'] == str(oracle[number]['owner']) for sample in detail['native_samples'] for s in sample['script'] if s['name'] == 'burn')
    observer = Client('observe', executable=None)
    try:
        refusal = observer.tool('set_redot_profiling', enabled=True, generation=0)
        assert 'AgentScopeDenied' in str(refusal), refusal
    finally:
        observer.close()
    spec = importlib.util.spec_from_file_location('shared', root / 'tests/shared-sessions.py')
    shared = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(shared)
    server = shared.Server(root, args.work.resolve(), Path(os.environ.get('XODB_BIN', root / 'zig-out/bin/xodb')), Path(args.redot).resolve(), 'control', options=('--redot-debugger',), fixture_args=('--headless', '--path', str(project)))
    try:
        owner = shared.Client(server, 'owner')
        observer = shared.Client(server, 'observer')
        server.remember_target(owner.session())
        owner.claim(ttl_ms=60000)
        start_scene(owner.tool)
        refusal = observer.call('tools/call', dict(name='set_redot_profiling', arguments=dict(enabled=True, generation=owner.session()['generation'])))
        assert 'ControlLeaseRequired' in str(refusal), refusal
        owner.tool('set_redot_profiling', enabled=True, generation=owner.session()['generation'])
        deadline = time.monotonic() + 10
        while observer.tool('get_redot_profile')['total'] == 0:
            assert time.monotonic() < deadline
            time.sleep(.01)
        owner.tool('set_redot_profiling', enabled=False, generation=owner.session()['generation'])
    finally:
        server.close()
    result.update(seconds=round(time.monotonic()-start, 2), shared_observer='pass', controller_refusals='pass')
    (args.work / 'results.json').write_text(json.dumps(result, indent=2)+'\n')
    print('Redot time: frame units, slow script, owner/native join, shared-script ambiguity and observer/controller access pass')


if __name__ == '__main__':
    main()
