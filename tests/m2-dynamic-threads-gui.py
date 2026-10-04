#!/usr/bin/env python3
"""Real newborn-thread flame capture and lane selection on private headless Sway."""
import importlib.util, json, os, subprocess, time
from pathlib import Path
root = Path(__file__).resolve().parents[1]
os.chdir(root)
spec = importlib.util.spec_from_file_location('timeline_repro', root/'tests/helpers/display.py')
h = importlib.util.module_from_spec(spec); spec.loader.exec_module(h)
d = h.Display('dynamic-threads'); app = None
class App(h.Mcp):
    def __init__(self):
        self.log = open(Path(d.dir)/'xodb.log', 'wb')
        self.proc = subprocess.Popen(['./zig-out/bin/xodb', '--mcp', '--agent-scope', 'control',
            '--break', 'profile_ready', '--source', 'tests/fixtures/profile-dynamic.c', '--',
            str(Path(d.dir)/'fixture'), 'churn', '16'], env=d.env,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log, bufsize=0)
        self.serial, self.pending = 0, b''
        self.call('initialize', {'protocolVersion':'2025-06-18','capabilities':{},'clientInfo':{'name':'dynamic-gui','version':'1'}})
        self.proc.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
    def action(self, name, **args):
        return self.tool(name, generation=self.session()['generation'], **args)
    def view(self, cap, tid=None):
        deadline = time.monotonic() + 10
        while True:
            data = self.tool('get_profile'); view = data['displayed_view']
            if view and view['visible'] and view['capture_id'] == cap['id'] and view['sample_count'] == cap['stored_samples'] and view['filter']['tid'] == tid:
                return view
            assert time.monotonic() < deadline, data
            time.sleep(.05)
try:
    subprocess.run(['cc', '-g', '-O2', '-gdwarf-4', '-fno-omit-frame-pointer', '-fno-optimize-sibling-calls',
                    '-pthread', 'tests/fixtures/profile-dynamic.c', '-o', str(Path(d.dir)/'fixture')], env=d.env, check=True)
    app = App(); app.await_state('stopped'); app.action('continue'); app.await_state('stopped', 'breakpoint')
    for bp in app.tool('get_breakpoints')['breakpoints']: app.action('remove_breakpoint', id=bp['id'])
    app.action('set_breakpoint', symbol='profile_done')
    d.pointer('click', 450, 22); time.sleep(.3)  # Flame view.
    d.pointer('click', 290, 110); time.sleep(.15)  # Start via GUI defaults.
    opened = app.tool('get_profile')['capture']
    assert opened and opened['follow_threads'] and opened['opening_threads'] == 1, opened
    app.action('continue'); app.await_state('stopped', 'breakpoint')
    capture = app.tool('get_profile')['capture']; assert capture['status'] == 'collecting', capture
    capture = app.action('stop_profile', capture_id=capture['id'])['capture']
    assert len(capture['threads']) == 18 and capture['trusted_before_ns'] is None, capture
    view = app.view(capture); d.shot('01-followed-threads')
    tid = capture['threads'][1]['perf']['tid']
    d.pointer('click', 100, 642); selected = app.view(capture, tid)
    graph = app.tool('get_flamegraph', capture_id=capture['id'], revision=selected['revision'],
                     view_id=selected['view_id'], tid=tid)
    density = app.tool('get_profile_timeline', capture_id=capture['id'], revision=capture['revision'], tid=tid)
    assert not graph.get('pending') and graph['samples'] == density['samples'] > 0, (graph, density)
    d.shot('02-new-thread-selected')
    d.pointer('click', 1080, 110); time.sleep(.3); d.shot('03-following-setup')
    (Path(d.dir)/'evidence.json').write_text(json.dumps(dict(capture=capture, view=view,
        selected=selected, graph=graph, density=density), indent=2)+'\n')
    app.proc.stdin.close(); assert app.proc.wait(10) == 0
    print('PASS: GUI capture follows new threads; completed worker lane filters flame counts; setup displays effective scope')
    print(d.dir)
finally:
    if app:
        if app.proc.poll() is None: app.proc.terminate(); app.proc.wait(10)
        app.log.close()
    d.close()
