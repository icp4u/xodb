#!/usr/bin/env python3
"""Import real T04 frame timings into a completed capture; preserve CPU evidence."""
from datetime import datetime
from pathlib import Path
import json,os,subprocess,sys,time
from client import Client
root=Path(__file__).resolve().parents[1];os.chdir(root)
run=root/'.work'/('m2-intervals-'+datetime.now().strftime('%Y%m%dT%H%M%S%f'));run.mkdir()
binary=run/'frames'
subprocess.run(['cc','-O2','-g','-fno-omit-frame-pointer','-mno-omit-leaf-frame-pointer','-fno-optimize-sibling-calls','-pthread','tests/workloads/frameloop.c','-o',str(binary)],check=True,env=dict(os.environ,TMPDIR=str(root/'.work/tmp')))
c=Client('control',str(binary),args=['--frames','50','--stall','lock','--stall-first','20','--csv',str(run/'frames.csv')])
try:
 bp=c.action('set_breakpoint',symbol='frame_begin')['id'];c.action('continue');snap=c.stopped('breakpoint');c.action('remove_breakpoint',id=bp)
 tid=snap['threads'][0]['tid']
 cap=c.action('start_profile',context_switch=True)['capture'];c.action('continue')
 live=c.tool('add_profile_intervals',generation=c.session()['generation'],capture_id=cap['id'],revision=c.inspect('get_profile')['capture']['revision'],source='live',intervals=[dict(from_ns=0,to_ns=1,label='no')])
 assert live['result']['isError']
 deadline=time.monotonic()+8
 while c.session()['state']!='exited':
  assert time.monotonic()<deadline
  time.sleep(.03)
 cap=c.inspect('get_profile')['capture'];generation=c.session()['generation']
 graph=c.inspect('get_flamegraph',capture_id=cap['id'],revision=cap['revision'])
 schedule=c.inspect('get_profile_schedule',capture_id=cap['id'],revision=cap['revision'],tid=tid)
 (run/'capture.json').write_text(json.dumps(cap)+'\n')
 converted=subprocess.check_output([sys.executable,'scripts/frame-intervals.py',str(run/'frames.csv'),'--capture',str(run/'capture.json'),'--generation',str(generation),'--tid',str(tid)],text=True)
 (run/'converted.json').write_text(converted); converted=json.loads(converted)
 assert converted['included']>=40 and converted['skipped_boundary_or_outside']>=1,converted
 for call in converted['tool_calls']:
  result=c.inspect(call['name'],**call['arguments'])
 revision=result['revision']
 assert revision>cap['revision'] and c.session()['generation']==generation+len(converted['tool_calls'])
 generation=c.session()['generation']
 rows=[];start=0
 while True:
  page=c.inspect('get_profile_intervals',capture_id=cap['id'],revision=revision,start=start,limit=7)
  rows+=page['intervals']
  if page['next'] is None:break
  start=page['next']
 assert len(rows)==converted['included'] and page['total']==len(rows)
 stall=next(r for r in rows if r['correlation_id']==20)
 assert stall['kind']=='frame' and 'injected' in stall['label'] and 'CLOCK_MONOTONIC' in stall['source']
 assert stall['to_ns']-stall['from_ns']>20_000_000,stall
 selected=c.inspect('get_profile_intervals',capture_id=cap['id'],revision=revision,tid=tid,from_ns=stall['from_ns'],to_ns=stall['to_ns'])
 assert selected['total']==1 and selected['intervals'][0]==stall
 after=c.inspect('get_flamegraph',capture_id=cap['id'],revision=revision)
 assert after['nodes']==graph['nodes'] and after['samples']==graph['samples']
 assert c.inspect('get_profile_schedule',capture_id=cap['id'],revision=revision,tid=tid)['spans']==schedule['spans']
 # Invalid batch must not append its valid prefix or change the revision.
 bad=c.action('add_profile_intervals',capture_id=cap['id'],revision=revision,source='test',intervals=[dict(from_ns=1,to_ns=2,label='global')])
 revision=bad['revision'];generation=c.session()['generation']
 response=c.tool('add_profile_intervals',generation=generation,capture_id=cap['id'],revision=revision,source='test',intervals=[dict(from_ns=1,to_ns=2,label='valid'),dict(from_ns=3,to_ns=2,label='bad')])
 assert response['result']['isError']
 assert c.inspect('get_profile')['capture']['revision']==revision
 stale=c.tool('get_profile_intervals',capture_id=cap['id'],revision=revision-1)
 assert stale['result']['isError'] and stale['result']['content'][0]['text']=='StaleProfile'
 other=cap['threads'][1]['perf']['tid']
 assert c.inspect('get_profile_intervals',capture_id=cap['id'],revision=revision,tid=other)['total']==1
 assert c.session()['generation']==generation
 print('application intervals:',len(rows),'real frames; known stall',round((stall['to_ns']-stall['from_ns'])/1e6,2),'ms; provenance, pages, filters, atomic rejection and CPU/scheduling preservation passed')
finally:
 (run/'rpc.json').write_text(json.dumps(c.transcript,indent=2)+'\n');c.close()
c=Client('observe')
try:
 response=c.tool('add_profile_intervals',generation=c.session()['generation'],capture_id=1,revision=1,source='denied',intervals=[dict(from_ns=1,to_ns=2,label='denied')])
 assert response['result']['isError'] and response['result']['content'][0]['text']=='AgentScopeDenied'
finally:c.close()
print(run)
