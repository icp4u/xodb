#!/usr/bin/env python3
"""Real configured 65K capture, live snapshot, archive and reopened ceiling."""
from datetime import datetime
from pathlib import Path
import json, os, subprocess, time
from client import Client
root = Path(__file__).resolve().parents[1]
os.chdir(root)
run = root / '.work' / ('capture-limits-' + datetime.now().strftime('%Y%m%dT%H%M%S%f'))
run.mkdir(parents=True)
(run/'prefs.json').write_text('{"profile":{"sample_limit":65536,"duration_ms":0}}\n')

class TestClient(Client):
    def __init__(self, name, args):
        self.id, self.transcript = 0, []
        self.log = (run/(name+'.stderr')).open('x')
        self.p = subprocess.Popen(['./zig-out/bin/xodb','--headless','--mcp','--agent-scope','control',*args],bufsize=0,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=self.log)
        self.call('initialize',{'protocolVersion':'2025-06-18','capabilities':{},'clientInfo':{'name':'capture-limits','version':'1'}})
        self.p.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
        self.name = name
    def close(self):
        try:
            self.p.stdin.close()
            assert self.p.wait(10)==0
        finally:
            if self.p.poll() is None: self.p.kill();self.p.wait()
            self.log.close()
            (run/(self.name+'.json')).write_text(json.dumps(self.transcript,indent=2)+'\n')

def ready(c):
    end=time.monotonic()+15
    while True:
        job=c.inspect('get_archive_status')['job']
        if job['done']:
            assert job['error_name'] is None,job
            return job
        assert time.monotonic()<end,job
        time.sleep(.005)

c=TestClient('live',['--config',str(run/'prefs.json'),'--','./zig-out/bin/xodb-profile-fixture','100','threads'])
latencies=[]
try:
    bp=c.action('set_breakpoint',symbol='profile_ready')['id']
    c.action('continue');c.stopped('breakpoint');c.action('remove_breakpoint',id=bp)
    assert c.inspect('get_profile')['defaults']['sample_limit']==65536
    for value in (0,65537,-1,1.5):
        bad=c.tool('start_profile',generation=c.session()['generation'],sample_limit=value)
        assert bad['error']['code']==-32602,bad
    # MCP override is independent of the loaded default.
    short=c.action('start_profile',sample_limit=1)['capture']
    assert short['sample_limit']==1
    c.action('stop_profile',capture_id=short['id'])
    cap=c.action('start_profile',frequency_hz=997,user_stack_bytes=64,user_stack_budget_bytes=4096)['capture']
    assert cap['sample_limit']==65536
    c.action('continue')
    end=time.monotonic()+95
    saw_legacy=False
    while time.monotonic()<end:
        before=time.monotonic();cap=c.inspect('get_profile')['capture'];latencies.append(time.monotonic()-before)
        if cap['stored_samples']>16384 and not saw_legacy:
            assert cap['status']=='collecting',cap
            view=c.inspect('get_flamegraph',capture_id=cap['id'],start=0,limit=8)
            assert view['snapshot_samples']>16384 and view['view_id'],view
            saw_legacy=True
        if cap['status']!='collecting':break
        time.sleep(.1)
    assert saw_legacy and cap['stored_samples']==65536 and cap['status']=='capacity',cap
    assert cap['sampled_state']['records']==65536 and cap['sampled_state']['skipped_stacks']>0,cap
    artifact=run/'capture.xcap'
    c.action('save_capture_archive',capture_id=cap['id'],revision=cap['revision'],path=str(artifact))
    assert ready(c)['publication']['state']=='published'
finally:c.close()
assert 'sample_limit=65536' in (run/'live.stderr').read_text()
offline=TestClient('offline',['--open-capture',str(artifact)])
try:
    ready(offline)
    opened=offline.inspect('get_profile')['capture']
    assert opened['stored_samples']==65536 and opened['sample_limit']==65536,opened
    assert opened['sampled_state']['records']==65536
finally:offline.close()
result={'samples':cap['stored_samples'],'limit':cap['sample_limit'],'stack_records':cap['sampled_state']['records'],'archive_bytes':artifact.stat().st_size,'get_profile_max_ms':max(latencies)*1000,'polls':len(latencies)}
(run/'results.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result,indent=2),flush=True)
print(run,flush=True)
