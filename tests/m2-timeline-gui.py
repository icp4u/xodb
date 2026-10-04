#!/usr/bin/env python3
"""Integrated timeline/scheduling on owned targets in private headless Sway."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import time

root = Path(__file__).resolve().parents[1]
os.chdir(root)
spec = importlib.util.spec_from_file_location('timeline_repro', root/'tests/helpers/display.py')
h = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h)

class App(h.Mcp):
    def __init__(self, display):
        self.log = open(Path(display.dir)/'xodb.log', 'wb')
        self.proc = subprocess.Popen(['./zig-out/bin/xodb', '--mcp', '--agent-scope', 'control', '--break', 'profile_ready', '--source', 'tests/fixtures/profile.c', '--', './zig-out/bin/xodb-profile-fixture', '20', 'threads'], env=display.env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log, bufsize=0)
        self.serial, self.pending, self.transcript = 0, b'', []
        self.call('initialize', {'protocolVersion':'2025-06-18','capabilities':{},'clientInfo':{'name':'integrated-timeline','version':'1'}})
        self.proc.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
    def call(self, method, params=None, timeout=10):
        result = super().call(method, params, timeout)
        self.transcript.append(dict(method=method, params=params, result=result))
        return result
    def action(self, name, **args):
        return self.tool(name, generation=self.session()['generation'], **args)
    def view(self):
        deadline = time.monotonic() + 5
        while True:
            time.sleep(.05)
            profile = self.tool('get_profile')
            view, capture = profile['displayed_view'], profile['capture']
            if view and view['capture_id'] == capture['id'] and view['sample_count'] == capture['stored_samples']:
                break
            assert time.monotonic() < deadline, profile
        args = dict(capture_id=view['capture_id'], **{k:v for k,v in view['filter'].items() if v is not None})
        graph = self.tool('get_flamegraph', revision=view['revision'], view_id=view['view_id'], **args)
        assert not graph.get('pending'), graph
        density = self.tool('get_profile_timeline', revision=capture['revision'], **args)
        assert graph['samples'] + graph['excluded_by_node_limit'] == density['samples']
        return view, density

display = h.Display('live')
app = None
try:
    app = App(display)
    app.await_state('stopped')
    app.action('continue')
    stopped = app.await_state('stopped', 'breakpoint')
    assert len(stopped['threads']) == 2
    for bp in app.tool('get_breakpoints')['breakpoints']:
        app.action('remove_breakpoint', id=bp['id'])
    display.pointer('click',450,22)
    time.sleep(.4)
    display.pointer('click',1080,110)  # Next sched: on
    display.pointer('click',280,110)  # New capture (GUI preference)
    time.sleep(.3)
    capture = app.tool('get_profile')['capture']
    assert capture['accepted']['context_switch'] is True
    app.action('continue')
    time.sleep(.8)
    display.pointer('drag',400,618,700,618,20)
    display.shot('01-live')
    capture = app.tool('get_profile')['capture']
    app.action('stop_profile',capture_id=capture['id'])
    app.action('interrupt')
    stopped = app.await_state('stopped')
    capture = app.tool('get_profile')['capture']
    assert capture['scheduling']['status'] == 'available'
    assert capture['scheduling']['recorded_events'] > 1
    tid = stopped['threads'][0]['tid']
    registers = app.tool('get_registers',tid=tid)
    generation = stopped['generation']
    view, density = app.view()
    assert view['visible'] and view['filter']['to_ns'] is not None
    assert view['filter']['from_ns'] < view['filter']['to_ns']
    # Select the real second thread and preserve the committed range.
    display.pointer('click',100,642)
    second, second_density = app.view()
    assert second['filter']['tid'] == capture['threads'][1]['perf']['tid'], second
    assert second['filter']['from_ns'] == view['filter']['from_ns']
    assert second['filter']['to_ns'] == view['filter']['to_ns']
    assert 0 < second_density['samples'] < density['samples']
    schedule = app.tool('get_profile_schedule',capture_id=capture['id'],revision=capture['revision'], **second['filter'])
    assert sum(schedule['totals'].values()) == schedule['range']['to_ns'] - schedule['range']['from_ns']
    display.shot('02-thread-range')
    display.pointer('click',1116,529)  # Fit range
    assert app.view()[0]['filter'] == second['filter']
    display.pointer('wheel',640,560,15)
    assert app.view()[0]['filter'] == second['filter']
    display.pointer('click',1222,529)  # Reset
    reset, full = app.view()
    assert reset['filter'] == dict(tid=None,from_ns=0,to_ns=None), reset
    assert full['samples'] == capture['stored_samples']
    display.shot('03-reset')
    display.pointer('click',450,22)  # Return to source with original panes
    assert not app.view()[0]['visible']
    display.shot('04-source')
    display.pointer('click',450,22)
    assert app.view()[0]['visible']
    assert app.session()['generation'] == generation
    assert app.tool('get_registers',tid=tid) == registers
    # Replacing a capture clears selection and the next-capture toggle can be off.
    display.pointer('click',100,642)
    assert app.view()[0]['filter']['tid'] is not None
    display.pointer('click',1080,110,'click',280,110)
    time.sleep(.3)
    new = app.tool('get_profile')['capture']
    assert new['id'] != capture['id'] and not new['accepted']['context_switch']
    app.action('stop_profile',capture_id=new['id'])
    assert app.view()[0]['filter'] == dict(tid=None,from_ns=0,to_ns=None)
    display.resize(900,600)
    time.sleep(.4)
    display.shot('05-narrow')
    app.proc.stdin.close()
    assert app.proc.wait(10) == 0
    app.log.close()
    log = (Path(display.dir)/'xodb.log').read_text()
    assert 'slow' not in log, log
    print('PASS: real two-thread lane selection, live range drag, matching MCP/flames, scheduling toggle, fit/zoom/reset, source view, unchanged target, replacement and resize', flush=True)
    print(display.dir, flush=True)
finally:
    if app:
        if app.proc.poll() is None:
            app.proc.stdin.close()
            try: app.proc.wait(10)
            except subprocess.TimeoutExpired: app.proc.kill();app.proc.wait()
        (Path(display.dir)/'rpc.json').write_text(json.dumps(app.transcript,indent=2)+'\n')
        if not app.log.closed: app.log.close()
    display.close()
