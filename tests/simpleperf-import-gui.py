#!/usr/bin/env python3
"""Real import GUI/MCP agreement, using only a private headless Sway session."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('profile', type=Path)
    parser.add_argument('--bin', type=Path, default=ROOT / 'zig-out/bin/xodb')
    args = parser.parse_args()
    os.chdir(ROOT)
    helper = load('timeline_display', ROOT / 'tests/helpers/display.py')
    mcp = load('import_mcp', ROOT / 'tests/simpleperf-import.py')
    display = helper.Display('simpleperf-import')
    app = None
    try:
        directory = Path(display.dir)
        keyboard_xml = '/usr/lib/wayland-debug/resources/protocols/wlroots/protocol/virtual-keyboard-unstable-v1.xml'
        subprocess.run(['wayland-scanner', 'client-header', keyboard_xml, str(directory / 'virtual-keyboard.h')], check=True)
        subprocess.run(['wayland-scanner', 'private-code', keyboard_xml, str(directory / 'virtual-keyboard.c')], check=True)
        source = (ROOT / 'tests/helpers/vinput.c').read_text()
        # Keep the guard tied to the exact private runtime made by Display.
        source = source.replace('!strstr(runtime, "/.work/input-")', 'strcmp(runtime, ' + json.dumps(display.runtime) + ')')
        (directory / 'vinput.c').write_text(source)
        keyboard = directory / 'vinput'
        subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-I', str(directory), str(directory / 'vinput.c'), str(directory / 'virtual-pointer.c'), str(directory / 'virtual-keyboard.c'), '-lwayland-client', '-lxkbcommon', '-lm', '-o', str(keyboard)], check=True)
        app = mcp.Client(args.bin.resolve(), args.profile.resolve(), Path(display.dir), display.env, gui=True)
        status = app.ready()
        identity = status['import_id']

        def key(name):
            code = {'z': 44, 'BackSpace': 14, 'i': 23, 'x': 45, 'Up': 103, 'Down': 108}[name]
            subprocess.run([str(keyboard), *map(str, display.size), 'layout', 'us', 'tap', str(code), 'w', '100'], env=display.env, check=True, timeout=5)

        def ctrl_click(x, y):
            subprocess.run([str(keyboard), *map(str, display.size), 'layout', 'us', 'down', '29',
                            'click', str(x), str(y), 'up', '29', 'w', '100'],
                           env=display.env, check=True, timeout=5)

        def wait(predicate):
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                value = app.tool('get_imported_profile')
                if predicate(value):
                    return value
                time.sleep(.03)
            raise TimeoutError('GUI state')

        wait(lambda s: s['gui']['filter'] is not None)
        time.sleep(.4)
        after_startup = len(app.latencies)
        display.shot('01-flames')
        display.pointer('click', 900, 424)
        picked = wait(lambda s: s['gui']['selected_node'] != 0)
        key('z')
        wait(lambda s: s['gui']['zoom'] == picked['gui']['selected_node'])
        display.shot('02-zoom')
        key('BackSpace')
        key('i')
        inspect = wait(lambda s: s['gui']['sample'] is not None)
        sample = app.tool('get_imported_sample', import_id=identity, ordinal=inspect['gui']['sample'])
        assert sample['frame_total'] > 0
        time.sleep(.2)
        display.shot('03-inspector')
        key('i')
        display.pointer('drag', 450, 574, 850, 574, 20)
        ranged = wait(lambda s: int(s['gui']['filter']['from_ns']) > 0)
        filters = ranged['gui']['filter']
        graph = app.graph(identity, **{k: str(v) if k.endswith('_ns') else v for k, v in filters.items() if v is not None})
        assert graph['samples'] < status['samples']
        display.shot('04-time-range')
        # A distinct MCP selection must not displace the GUI's committed range.
        app.graph(identity, tid=status['threads'][0]['tid'])
        assert app.tool('get_imported_profile')['gui']['filter'] == filters
        key('x')
        wait(lambda s: int(s['gui']['filter']['from_ns']) == 0)
        display.pointer('click', 90, 626)
        threaded = wait(lambda s: s['gui']['filter']['tid'] is not None)
        tid = threaded['gui']['filter']['tid']
        thread_graph = app.graph(identity, tid=tid)
        assert thread_graph['samples'] <= status['samples']
        second_tid = status['threads'][1]['tid']
        chosen = sorted([tid, second_tid])
        ctrl_click(90, 650)
        wait(lambda s: s['gui']['filter']['tids'] == chosen and s['gui']['view_id'] is not None)
        multi = app.graph(identity, tids=chosen)
        assert multi['samples'] == sum(t['samples'] for t in status['threads'] if t['tid'] in chosen)
        assert app.graph(identity, tids=list(reversed(chosen)))['view_id'] == multi['view_id']
        time.sleep(.2)
        display.shot('04b-multi-thread')
        key('i')
        union_sample = wait(lambda s: s['gui']['sample'] is not None)
        assert app.tool('get_imported_sample', import_id=identity, ordinal=union_sample['gui']['sample'])['tid'] in chosen
        key('i')
        ctrl_click(90, 626)
        wait(lambda s: s['gui']['filter']['tid'] == second_tid)
        ctrl_click(90, 650)
        wait(lambda s: s['gui']['filter']['tid'] is None and s['gui']['filter']['tids'] is None)
        display.pointer('click', 90, 626)
        wait(lambda s: s['gui']['filter']['tid'] == tid and s['gui']['view_id'] is not None)
        key('i')
        wait(lambda s: s['gui']['sample'] is not None)
        display.resize(640, 480)
        time.sleep(.4)
        display.shot('05-small-inspector')
        for _ in range(8): key('Down')
        wait(lambda s: s['gui']['stack_start'] >= 8)
        time.sleep(.2)
        display.shot('06-small-scrolled')
        key('i')
        key('x')
        time.sleep(.3)
        display.shot('07-small-flames')
        assert app.tool('get_session')['pid'] == 0
        result = dict(samples=status['samples'], range_samples=graph['samples'], thread_samples=thread_graph['samples'],
                      multi_thread_samples=multi['samples'], selected_tids=chosen, max_rpc_ms=max(app.latencies), max_rpc_after_startup_ms=max(app.latencies[after_startup:]), inspected_sample=inspect['gui']['sample'],
                      checks='private GUI, weighted flames, zoom, sample inspection, range/thread selection, independent MCP view, Ctrl-click union/removal/reset, small window')
        (Path(display.dir) / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
        app.close()
        app = None
        print(json.dumps(result, indent=2))
        print(display.dir)
    finally:
        if app is not None:
            app.close()
        display.close()


if __name__ == '__main__':
    main()
