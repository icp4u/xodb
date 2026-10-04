#!/usr/bin/env python3
"""Portable CPU evidence: stack conservation, filters, schema and file safety.

Optional --schema PATH validates every output with the upstream Speedscope
JSON schema; requires test-only jsonschema in the invoking Python environment.
"""
from collections import Counter
from datetime import datetime
from pathlib import Path
import argparse,json,os,stat,time
from client import Client
parser=argparse.ArgumentParser();parser.add_argument('--schema',type=Path);args=parser.parse_args()
schema=json.loads(args.schema.read_text()) if args.schema else None
if schema:
 import jsonschema
root=Path(__file__).resolve().parents[1];os.chdir(root)
run=root/'.work'/('m2-export-'+datetime.now().strftime('%Y%m%dT%H%M%S%f'));run.mkdir()
fixture='./zig-out/bin/xodb-profile-fixture'

def error(response,name):
 assert response['result']['isError'] and response['result']['content'][0]['text']==name,response

def checkpoint(c):
 bp=c.action('set_breakpoint',symbol='profile_ready')['id'];c.action('continue');snap=c.stopped('breakpoint');c.action('remove_breakpoint',id=bp)
 return snap

def read(path):
 data=json.loads(path.read_text())
 if schema:jsonschema.validate(data,schema)
 p=data['profiles'][0];e=data['xodb']
 assert p['type']=='sampled' and p['unit']=='none' and p['startValue']==0
 assert sum(p['weights'])==p['endValue']==e['samples']
 assert len(p['samples'])==len(p['weights'])
 assert all(w>0 for w in p['weights'])
 assert all(0<=i<len(data['shared']['frames']) for stack in p['samples'] for i in stack)
 assert len(e['frame_identities'])==len(data['shared']['frames'])
 assert sum(b['samples'] for b in e['cpu_bins'])==sum(t['samples'] for t in e['cpu_threads'])==e['samples']+e['excluded_by_node_limit']
 assert 'synthetic' in e['ordering'] and 'not a timeline' in e['ordering']
 assert 'munmap/mremap' in e['mapping_coverage']
 for row in e['scheduling_totals']:assert sum(row['totals'].values())==e['range']['to_ns']-e['range']['from_ns']
 assert stat.S_IMODE(path.stat().st_mode)==0o600
 return data

def identity(f):return (f['kind'],f['module_id'],f['mapping_id'],int(f['address'],16) if isinstance(f['address'],str) else f['address'])

def verify(c,cap,path,filters):
 generation=c.session()['generation'];rev=cap['revision']
 result=c.action('export_profile',capture_id=cap['id'],revision=rev,path=str(path),**filters)
 assert result['generation']==generation+1 and result['revision']==rev
 assert result['result']['bytes']==path.stat().st_size
 data=read(path);e=data['xodb'];p=data['profiles'][0]
 assert e['capture']['revision']==rev and c.inspect('get_profile')['capture']['revision']==rev
 nodes=[];start=0
 while True:
  graph=c.inspect('get_flamegraph',capture_id=cap['id'],revision=rev,start=start,limit=64,**({"view_id":graph["view_id"]} if start else {}),**filters);nodes+=graph['nodes']
  if graph['next'] is None:break
  start=graph['next']
 expected=Counter()
 for node in nodes:
  if not node['self']:continue
  stack=[];cur=node
  while cur['parent'] is not None:
   stack.append(identity(cur));cur=nodes[cur['parent']]
  expected[tuple(reversed(stack))]+=node['self']
 actual=Counter()
 for stack,weight in zip(p['samples'],p['weights']):actual[tuple(identity(e['frame_identities'][i]) for i in stack)]+=weight
 assert actual==expected,(actual,expected)
 assert e['samples']==graph['samples'] and e['excluded_by_node_limit']==graph['excluded_by_node_limit']
 timeline=c.inspect('get_profile_timeline',capture_id=cap['id'],revision=rev,bins=128,**filters)
 assert e['cpu_bins']==timeline['bins'] and e['cpu_threads']==timeline['threads'] and e['range']==timeline['range']
 for row in e['scheduling_totals']:
  schedule=c.inspect('get_profile_schedule',capture_id=cap['id'],revision=rev,**dict(filters,tid=row['tid']))
  assert row['totals']==schedule['totals']
 assert e['application_intervals']==c.inspect('get_profile_intervals',capture_id=cap['id'],revision=rev,**filters)['intervals']
 return data

shutdown=run/'shutdown.speedscope.json'
c=Client('control',fixture,args=['2','threads'],options=['--profile-out',str(shutdown)])
try:
 snap=checkpoint(c);tids=[t['tid'] for t in snap['threads'] if t['state']!='exited']
 cap=c.action('start_profile',frequency_hz=199,context_switch=True)['capture']
 error(c.tool('export_profile',generation=c.session()['generation'],capture_id=cap['id'],revision=cap['revision'],path=str(run/'live.json')),'ProfileStillCollecting')
 c.action('continue');time.sleep(.5)
 cap=c.action('stop_profile',capture_id=cap['id'])['capture'];c.action('interrupt');c.stopped()
 regs=c.inspect('get_registers',tid=tids[0])['registers']
 c.action('add_profile_intervals',capture_id=cap['id'],revision=cap['revision'],source='export test fixture',intervals=[dict(from_ns=10_000_000,to_ns=30_000_000,tid=tids[0],kind='request',label='quote" and \\ slash',correlation_id=7)])
 cap=c.inspect('get_profile')['capture']
 full=verify(c,cap,run/'full.speedscope.json',{})
 assert full['xodb']['samples']>20 and len(full['xodb']['application_intervals'])==1
 assert any(len(set(stack))<len(stack) for stack in full['profiles'][0]['samples']),'recursion lost'
 filtered=verify(c,cap,run/'selected.speedscope.json',dict(tid=tids[0],from_ns=10_000_000,to_ns=200_000_000))
 assert 0<filtered['xodb']['samples']<full['xodb']['samples'] and len(filtered['xodb']['cpu_threads'])==1
 empty=verify(c,cap,run/'empty.speedscope.json',dict(from_ns=10_000_000_000))
 assert empty['profiles'][0]['samples']==[] and empty['profiles'][0]['endValue']==0
 before=(run/'full.speedscope.json').read_bytes();generation=c.session()['generation']
 common=dict(generation=generation,capture_id=cap['id'],revision=cap['revision'])
 c.inspect('get_flamegraph',capture_id=cap['id'],revision=cap['revision']) # prepare the full view before testing publication failures
 error(c.tool('export_profile',path=str(run/'full.speedscope.json'),**common),'ProfileExportExists')
 assert (run/'full.speedscope.json').read_bytes()==before
 link=run/'symlink.json';link.symlink_to(run/'full.speedscope.json')
 error(c.tool('export_profile',path=str(link),**common),'ProfileExportExists')
 assert link.is_symlink() and link.read_bytes()==before
 error(c.tool('export_profile',path=str(run/'missing'/'bad.json'),**common),'ProfileExportOpenFailed')
 error(c.tool('export_profile',path=str(run/'stale.json'),**dict(common,revision=cap['revision']-1)),'StaleProfile')
 for path in ('','embedded\0nul'):
  assert c.tool('export_profile',path=path,**common)['error']['code']==-32602
 assert c.session()['generation']==generation
 assert c.inspect('get_registers',tid=tids[0])['registers']==regs and c.session()['state']=='stopped'
 assert not list(run.glob('*.tmp')) and not (run/'stale.json').exists() and not (run/'live.json').exists()
 c.action('continue');deadline=time.monotonic()+5
 while c.session()['state']!='exited':
  assert time.monotonic()<deadline
  time.sleep(.02)
 assert verify(c,cap,run/'after-exit.speedscope.json',{})['profiles']==full['profiles']
finally:
 (run/'rpc.json').write_text(json.dumps(c.transcript,indent=2)+'\n');c.close()
 (run/'stderr.log').write_bytes(c.p.stderr.read())
assert read(shutdown)['profiles']==full['profiles']
# Closing with an active, stopped (zero-sample) capture must drain and export.
c=Client('control',fixture,args=['3'],options=['--profile-out',str(run/'active-close.json')])
try:
 checkpoint(c);c.action('start_profile')
finally:c.close()
assert read(run/'active-close.json')['profiles'][0]['endValue']==0
c=Client('observe')
try:
 error(c.tool('export_profile',generation=c.session()['generation'],capture_id=1,revision=1,path=str(run/'denied.json')),'AgentScopeDenied')
 assert not (run/'denied.json').exists()
finally:c.close()
print('export: full/filtered/empty stack and count conservation, scheduling, imported intervals, recursion, audit/scope/stale guards, atomic no-overwrite/symlink protection, post-exit and active-close CLI output passed')
print('schema validation:',bool(schema));print(run)
