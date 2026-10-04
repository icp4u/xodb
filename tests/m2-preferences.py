#!/usr/bin/env python3
"""Preferences, explicit capture durations, capacity safety and archive semantics."""
from datetime import datetime
from pathlib import Path
import json, os, subprocess, time
from client import Client
root=Path(__file__).resolve().parents[1]; os.chdir(root)
run=root/'.work'/('preferences-'+datetime.now().strftime('%Y%m%dT%H%M%S%f')); run.mkdir()
fixture='./zig-out/bin/xodb-profile-fixture'
def checkpoint(c):
    bp=c.action('set_breakpoint',symbol='profile_ready')['id']
    c.action('continue'); c.stopped('breakpoint'); c.action('remove_breakpoint',id=bp)
def wait_stop(c, timeout=5):
    deadline=time.monotonic()+timeout
    while True:
        cap=c.inspect('get_profile')['capture']
        if cap['status']!='collecting': return cap
        assert time.monotonic()<deadline,cap
        time.sleep(.01)
def close(c, name):
    c.close()
    (run/(name+'.stderr')).write_bytes(c.p.stderr.read())
    (run/(name+'.rpc.json')).write_text(json.dumps(c.transcript,indent=2)+'\n')

c=Client('control',fixture)
try:
    assert c.inspect('get_profile')['defaults']==dict(frequency_hz=99,duration_ms=60000,context_switch=False,user_stack_bytes=0,user_stack_budget_bytes=33554432,follow_threads=True,ring_budget_bytes=67108864)
    cap=c.action('start_profile')['capture']
    assert cap['duration_ms']==60000
    c.action('stop_profile',capture_id=cap['id'])
    for duration in (300000,4294967295):
        cap=c.action('start_profile',duration_ms=duration)['capture']
        assert cap['duration_ms']==duration
        c.action('stop_profile',capture_id=cap['id'])
finally: close(c,'defaults')

prefs=run/'preferences.json'
prefs.write_text(json.dumps(dict(profile=dict(duration_ms=125,frequency_hz=199,context_switch=True,follow_threads=False,ring_budget_bytes=1048576)))+'\n')
original=prefs.read_bytes()
c=Client('control',fixture,args=['3'],options=['--config',str(prefs)])
try:
    checkpoint(c)
    settings=c.inspect('get_profile')['defaults']; assert settings['duration_ms']==125 and settings['context_switch']
    # Default timed capture stops while the target remains paused.
    cap=c.action('start_profile')['capture']
    assert not cap['follow_threads'] and cap['ring_budget_bytes']==1048576
    assert cap['accepted']['requested_frequency_hz']==199 and cap['accepted']['context_switch']
    stopped=wait_stop(c)
    assert stopped['status']=='duration' and stopped['stored_samples']==0
    # Explicit zero overrides the preference, without mutating it.
    cap=c.action('start_profile',duration_ms=0,context_switch=False,follow_threads=True,ring_budget_bytes=2097152)['capture']
    assert cap['follow_threads'] and cap['ring_budget_bytes']==2097152
    c.action('continue'); time.sleep(.35)
    assert c.inspect('get_profile')['capture']['status']=='collecting'
    stopped=c.action('stop_profile',capture_id=cap['id'])['capture']
    assert stopped['duration_ms']==0 and stopped['stored_samples']>10
    assert c.inspect('get_profile')['defaults']==settings
    c.action('interrupt'); c.stopped()
    cap=c.action('start_profile')['capture']; assert cap['duration_ms']==125
    c.action('stop_profile',capture_id=cap['id'])
finally: close(c,'overrides')
assert prefs.read_bytes()==original

# Disabling the deadline must retain the sample cap.
archive=run/'capacity.xcap'
c=Client('control',fixture,args=['15','threads'],options=['--capture-out',str(archive)])
try:
    checkpoint(c)
    c.action('start_profile',duration_ms=0,frequency_hz=1000)
    c.action('continue')
    cap=wait_stop(c,15)
    assert cap['status']=='capacity' and cap['stored_samples']==cap['sample_limit']==16384,cap
    assert cap['duration_ms']==0
finally: close(c,'capacity')
data=archive.read_bytes()
assert int.from_bytes(data[40:48],'little')==11
copy=run/'copy.xcap'
result=subprocess.run(['./zig-out/bin/xodb','--headless','--mcp','--open-capture',str(archive),'--capture-out',str(copy)],input=b'',capture_output=True,timeout=15)
assert result.returncode==0,result.stderr
assert copy.read_bytes()==data

for name, text, expected in [
    ('typo','{"profile":{"duraton_ms":1}}','UnknownField'),
    ('invalid-rate','{"profile":{"frequency_hz":0}}','InvalidProfileConfig'),
    ('invalid-duration','{"profile":{"duration_ms":4294967296}}','Overflow'),
    ('ring-budget','{"profile":{"ring_budget_bytes":0}}','InvalidProfileConfig'),
    ('follow-type','{"profile":{"follow_threads":1}}','UnexpectedToken'),
    ('wrong-type','{"profile":{"context_switch":0}}','UnexpectedToken'),
]:
    path=run/(name+'.json');path.write_text(text)
    result=subprocess.run(['./zig-out/bin/xodb','--headless','--mcp','--config',str(path)],input=b'',capture_output=True,timeout=5)
    assert result.returncode!=0 and expected.encode() in result.stderr,(name,result)
fifo=run/'fifo';os.mkfifo(fifo)
oversized=run/'oversized'
with oversized.open('xb') as f:f.truncate(65537)
for path,expected in ((fifo,'PreferencesNotRegular'),(oversized,'PreferencesTooLarge'),(run/'absent','PreferencesOpenFailed')):
    result=subprocess.run(['./zig-out/bin/xodb','--headless','--mcp','--config',str(path)],input=b'',capture_output=True,timeout=5)
    assert result.returncode!=0 and expected.encode() in result.stderr,(path,result)
print('PASS: defaults, preference/MCP precedence, paused deadline, manual duration, unchanged prefs, capacity stop, archive copy, invalid/FIFO/oversized config')
print(run)
