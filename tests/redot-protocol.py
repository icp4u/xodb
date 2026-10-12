#!/usr/bin/env python3
"""Fast live lane: cooperative engine scene, properties, signals and retained snapshots."""
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


def wait_object(tool, object_id):
    deadline = time.monotonic() + 10
    while True:
        result = tool('inspect_redot_object', object_id=object_id)
        if result['object'] and not result['pending']:
            return result['object']
        assert time.monotonic() < deadline, result
        time.sleep(.01)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--redot', required=True)
    p.add_argument('--work', type=Path, required=True)
    args = p.parse_args()
    os.chdir(root)
    os.umask(0o022)
    args.work.mkdir(parents=True, exist_ok=True)
    project = args.work.resolve() / 'project'
    shutil.copytree(root / 'tests/fixtures/redot-values', project, dirs_exist_ok=True)
    started = time.monotonic()
    client = Client('control', str(Path(args.redot).resolve()), ('--headless', '--path', str(project)), ('--redot-debugger',))
    def usage():
        fields = Path(f'/proc/{client.p.pid}/stat').read_text().rsplit(')', 1)[1].split()
        return dict(cpu_seconds=(int(fields[11])+int(fields[12]))/os.sysconf('SC_CLK_TCK'), rss_bytes=int(fields[21])*os.sysconf('SC_PAGE_SIZE'))
    before_usage = usage()
    try:
        scene = start_scene(client.inspect)
        assert [(n['name'], n['depth']) for n in scene['nodes']] == [('root', 0), ('Arena', 1), ('Player', 2), ('Hand', 3), ('Dummy', 2)], scene
        assert scene['source'] == 'engine_debugger_protocol'
        page = client.inspect('get_redot_scene_tree', start=2, limit=2)
        assert [n['name'] for n in page['nodes']] == ['Player', 'Hand'] and page['next'] == 4, page
        objects = {}
        for name in ('Player', 'Arena', 'Dummy'):
            node = next(n for n in scene['nodes'] if n['name'] == name)
            objects[name] = wait_object(client.inspect, node['object_id'])
        props = lambda name: {p['name']: p['display'] for p in objects[name]['properties']}
        player = props('Player')
        assert objects['Player']['class_name'] == 'Node2D' and objects['Player']['script_path'] == 'res://player.gd', objects['Player']
        assert player['Members/hp'] == '90' and player['Members/title'] == '"Aria"', player
        assert player['position'] == 'Vector2(12.5, -7.25)', player
        assert '250' in player['Members/inventory'] and 'sharp' in player['Members/inventory'], player
        arena = props('Arena')
        assert arena['Members/v_rid'] == 'RID(77)' and arena['Members/v_path'] == '"/root/Arena/Player:position:x"', arena
        assert objects['Arena']['signals'][0]['property'] == 'Members/v_signal', objects['Arena']['signals']
        assert 'tree_exiting' in objects['Arena']['signals'][0]['display']
        # A deliberately perturbed expected scalar is rejected.
        assert props('Dummy')['Members/armor'] == '3' and props('Dummy')['Members/armor'] != '4'
        client.action('interrupt')
        state = client.stopped()
        cached = client.inspect('get_redot_scene_tree')
        assert cached['nodes'] == scene['nodes'], cached
        client.inspect('get_redot_scene_tree', refresh=True)
        assert client.session()['state'] == 'stopped' and client.session()['generation'] == state['generation']
        client.action('continue')
        deadline = time.monotonic() + 10
        while client.inspect('get_redot_scene_tree')['pending']:
            assert time.monotonic() < deadline
            time.sleep(.01)
        result = dict(before=before_usage, after=usage(), scene=scene, objects=objects)
    finally:
        client.close()
    truth = {line.split(' ', 2)[1]: json.loads(line.split(' ', 2)[2]) for line in client.p.stderr.read().decode().splitlines() if line.startswith('ORACLE ')}
    for name in ('Arena', 'Player', 'Hand', 'Dummy'):
        assert next(n['object_id'] for n in scene['nodes'] if n['name'] == name) == str(truth['ids'][name.lower()])
    assert player['Members/hp'] == str(truth['locals']['hp'])
    spec = importlib.util.spec_from_file_location('shared', root / 'tests/shared-sessions.py')
    shared = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(shared)
    shared_dir = args.work.resolve() / 'shared'
    shared_dir.mkdir(exist_ok=True)
    server = shared.Server(root, shared_dir, Path(os.environ.get('XODB_BIN', root / 'zig-out/bin/xodb')), Path(args.redot).resolve(), 'control', options=('--redot-debugger',), fixture_args=('--headless', '--path', str(project)))
    try:
        owner = shared.Client(server, 'redot-owner')
        observer = shared.Client(server, 'redot-observer')
        server.remember_target(owner.session())
        owner.claim(ttl_ms=60000)
        shared_scene = start_scene(owner.tool)
        assert observer.tool('get_redot_scene_tree')['nodes'] == shared_scene['nodes']
        arena_id = next(n['object_id'] for n in shared_scene['nodes'] if n['name'] == 'Arena')
        observed = wait_object(observer.tool, arena_id)
        assert observed['signals'][0]['property'] == 'Members/v_signal'
        assert observed['script_path'] == 'res://arena.gd'
    finally:
        server.close()
    result.update(status='pass', shared_observer='pass', seconds=round(time.monotonic()-started, 2))
    (args.work / 'results.json').write_text(json.dumps(result, indent=2)+'\n')
    print('Redot protocol: scene hierarchy, script, native properties, members, signals, paging and paused snapshots pass')


if __name__ == '__main__':
    main()
