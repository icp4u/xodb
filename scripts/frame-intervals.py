#!/usr/bin/env python3
"""Convert T04 frameloop CSV to guarded add_profile_intervals MCP tool calls.

Reads files, writes JSON to stdout. Does not connect to xodb or execute tools.
Only complete work intervals inside the completed capture are included.
"""
import argparse, csv, json
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('csv',type=Path)
p.add_argument('--capture',required=True,type=Path,help='JSON capture summary, get_profile result, or MCP response')
p.add_argument('--generation',required=True,type=int,help='current get_session generation')
p.add_argument('--tid',type=int,help='opening TID for the frame thread; omit for global intervals')
a=p.parse_args()
if a.generation<0 or (a.tid is not None and a.tid<=0):p.error('generation/TID out of range')
c=json.loads(a.capture.read_text())
for key in ['result','structuredContent','capture']:
 if key in c:c=c[key]
if c.get('ended_ns') is None or c.get('status')=='collecting':p.error('capture must be completed')
start,end=c['started_ns'],c['ended_ns']
if a.tid is not None and a.tid not in [t['perf']['tid'] for t in c['threads']]:p.error('TID is outside this capture')
rows=[];skipped=0
with a.csv.open(newline='') as f:
 for row in csv.DictReader(f):
  frame=int(row['frame']);begin=int(row['start_us'])*1000;duration=int(row['work_us'])*1000
  if min(frame,begin,duration)<0:p.error('CSV contains a negative frame/time')
  finish=begin+duration
  if begin<start or begin>=end or finish>end:
   skipped+=1;continue
  item=dict(from_ns=begin-start,to_ns=finish-start,label=f'frame {frame}'+(' (injected)' if row.get('injected')=='1' else ''),kind='frame',correlation_id=frame)
  if a.tid is not None:item['tid']=a.tid
  rows.append(item)
  if len(rows)>4096:p.error('more than 4096 matching intervals; select a shorter input')
source='frameloop CSV; CLOCK_MONOTONIC microseconds; complete work intervals'
calls=[]
for offset in range(0,len(rows),128):
 calls.append(dict(name='add_profile_intervals',arguments=dict(generation=a.generation+len(calls),capture_id=c['id'],revision=c['revision']+len(calls),source=source,intervals=rows[offset:offset+128])))
print(json.dumps(dict(input_file=str(a.csv.resolve()),included=len(rows),skipped_boundary_or_outside=skipped,clock='CSV microseconds converted to capture-relative nanoseconds; caller must verify same process/run and CLOCK_MONOTONIC origin',tool_calls=calls),indent=2))
