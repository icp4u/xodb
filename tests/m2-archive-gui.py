#!/usr/bin/env python3
"""Offline archive interaction and worker responsiveness on private headless Sway.
Usage: python3 -B tests/m2-archive-gui.py CAPTURE [BUDGET_CAPTURE]
"""
import importlib.util, json, os, subprocess, sys, time
from pathlib import Path
root = Path(__file__).resolve().parents[1]; os.chdir(root)
spec = importlib.util.spec_from_file_location('timeline_repro', root/'tests/helpers/display.py')
h = importlib.util.module_from_spec(spec); spec.loader.exec_module(h)
d = h.Display('archive'); apps = []; results = []
class Offline(h.Mcp):
    def __init__(self, path, name):
        self.log = open(Path(d.dir)/(name+'.log'), 'wb')
        self.proc = subprocess.Popen(['./zig-out/bin/xodb', '--mcp', '--agent-scope', 'control', '--open-capture', str(path)], env=d.env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log, bufsize=0)
        apps.append(self)
        self.serial = 0; self.pending = b''
        self.call('initialize', {'protocolVersion':'2025-06-18','capabilities':{},'clientInfo':{'name':'archive-gui','version':'1'}})
        self.proc.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
    def ready(self):
        delays = []; phases = []; start = time.monotonic()
        while True:
            begin = time.monotonic(); status = self.tool('get_archive_status'); delays.append(time.monotonic()-begin)
            phases.append(status['job']['phase'])
            if status['job']['done']:
                assert status['job']['error_name'] is None, status
                break
            assert time.monotonic()-start < 20
            time.sleep(.002)
        results.append(dict(artifact=status['artifact_sha256'], max_rpc_ms=max(delays)*1000, phases=sorted(set(phases)), elapsed_ms=(time.monotonic()-start)*1000))
        return status
    def close(self):
        self.proc.stdin.close(); assert self.proc.wait(15) == 0
        self.log.close()
try:
    app = Offline(sys.argv[1], 'offline'); app.ready(); time.sleep(.5)
    cap = app.tool('get_profile')['capture']; snap = app.session()
    assert snap['pid'] == 0
    d.shot('recorded-profile')
    # The overview exists even when this capture has only one thread lane.
    d.pointer('drag', 450, 565, 850, 565, 20); time.sleep(.4)
    displayed = app.tool('get_profile')['displayed_view']
    assert displayed and displayed['filter']['from_ns'] > 0 and displayed['filter']['to_ns'] is not None, displayed
    filters = {k:v for k,v in displayed['filter'].items() if v is not None}
    deadline = time.monotonic()+10
    while True:
        response = app.call('tools/call', {'name':'get_flamegraph','arguments':dict(capture_id=cap['id'], revision=cap['revision'], **filters)})
        if not response['isError']: break
        assert response['content'][0]['text'] == 'ArchiveViewPending', response
        assert time.monotonic()<deadline
        time.sleep(.01)
    graph = response['structuredContent']
    timeline = app.tool('get_profile_timeline',capture_id=cap['id'],revision=cap['revision'],**filters)
    assert graph['samples'] == timeline['samples']
    assert app.session()['generation'] == snap['generation'] and app.session()['pid'] == 0
    d.shot('filtered-profile')
    d.resize(1600,1000); time.sleep(.4); d.shot('resized-profile')
    app.close()
    if len(sys.argv)>2:
        app = Offline(sys.argv[2], 'budget')
        app.ready(); time.sleep(.4); d.shot('budget-profile')
        assert results[-1]['max_rpc_ms'] < 250, results[-1]
        cap = app.tool('get_profile')['capture']
        before = time.monotonic()
        response = app.call('tools/call', {'name':'get_flamegraph','arguments':dict(capture_id=cap['id'],revision=cap['revision'],tid=4100)})
        assert time.monotonic()-before < .25
        if response['isError']:
            assert response['content'][0]['text']=='ArchiveViewPending'
            app.ready()
        app.close()
    (Path(d.dir)/'results.json').write_text(json.dumps(results,indent=2)+'\n')
    print('PASS: private offline GUI, range/MCP agreement, resize, target isolation and archive worker responsiveness')
    print(json.dumps(results)); print(d.dir)
finally:
    for app in apps:
        if app.proc.poll() is None:
            app.proc.terminate()
            try: app.proc.wait(10)
            except subprocess.TimeoutExpired: app.proc.kill(); app.proc.wait()
        if not app.log.closed: app.log.close()
    d.close()
