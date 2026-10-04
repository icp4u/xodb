#!/usr/bin/env python3
"""Straight-line stepping speed, a 12k-instruction line, and intervening stops."""
import argparse,json,os,subprocess,time
from pathlib import Path
from client import Client
parser=argparse.ArgumentParser();parser.add_argument('--baseline');options=parser.parse_args()
root=Path(__file__).resolve().parents[1];os.chdir(root)
work=root/'.work'/('source-blocks-'+str(time.time_ns())[-10:]);work.mkdir();(work/'tmp').mkdir()
fixture=work/'fixture';source=root/'tests/fixtures/step-blocks.c';lines=source.read_text().splitlines()
subprocess.run(['cc','-g','-O0','-pthread','-fno-omit-frame-pointer','-Wall','-Wextra','-Werror',str(source),'-o',str(fixture)],check=True,env=dict(os.environ,TMPDIR=str(work/'tmp')))
results=[]
current=os.environ.get('XODB_BIN')
for mode in (['baseline'] if options.baseline else [])+['short','long','middle','watch','trap','threads']:
    if mode=='baseline':os.environ['XODB_BIN']=options.baseline
    elif current:os.environ['XODB_BIN']=current
    else:os.environ.pop('XODB_BIN',None)
    c=Client('control',str(fixture),args=['short' if mode in ('baseline','middle') else mode])
    try:
        marker={'long':'LONG_BLOCK','watch':'WATCH_BLOCK','trap':'TRAP_BLOCK'}.get(mode,'SHORT_BLOCK')
        line=next(i for i,s in enumerate(lines,1) if '// '+marker in s)
        probes=c.action('set_breakpoint',file=str(source),line=line)['ids'];c.action('continue');state=c.stopped('breakpoint');tid=state['pid']
        for probe in probes:c.action('remove_breakpoint',id=probe)
        if mode=='middle':c.action('set_breakpoint',symbol='step_middle')
        if mode=='watch':
            address=c.inspect('evaluate_expression',tid=tid,expression='&step_value')['value']['display']
            c.action('set_watchpoint',address=address,length=4)
        start=time.monotonic();c.action('step_source',tid=tid);stopped=c.stopped();elapsed=time.monotonic()-start
        assert not stopped['source_stepping'] and stopped['step_diagnostic'] is None,stopped
        thread=next(t for t in stopped['threads'] if t['tid']==tid)
        if mode=='watch':assert thread['reason']=='watchpoint',thread
        elif mode=='trap':assert thread['reason']=='signal',thread
        elif mode=='middle':
            assert thread['reason']=='breakpoint',thread
            assert len([b for b in c.inspect('get_breakpoints')['breakpoints'] if not b['internal']])==1
        else:
            regs=c.inspect('get_registers',tid=tid)['registers'];site=c.inspect('get_source_location',address=regs['rip'])['source']
            assert site['line']==line+1,site
            assert not c.inspect('get_breakpoints')['breakpoints']
        if mode not in ('baseline','threads','trap'):
            assert stopped['source_step_planned_instructions']>0,stopped
        if mode=='threads':assert stopped['source_step_planned_instructions']==0 and len(stopped['threads'])==2,stopped
        results.append(dict(mode=mode,seconds=elapsed,resumes=stopped.get('source_step_resumes'),batched=stopped.get('source_step_planned_instructions')))
        print(results[-1],flush=True)
    finally:
        (work/(mode+'.json')).write_text(json.dumps(c.transcript,indent=2)+'\n');c.close()
if options.baseline:
    base=next(r['seconds'] for r in results if r['mode']=='baseline');fast=next(r['seconds'] for r in results if r['mode']=='short')
    assert fast<base/3,(base,fast)
(work/'results.json').write_text(json.dumps(results,indent=2)+'\n');print(work,flush=True)
