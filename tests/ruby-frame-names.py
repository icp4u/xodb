#!/usr/bin/env python3
"""Qualified Ruby and native boundary labels across stops and GC, locally and through the agent."""
import argparse,json,os,re,time
from pathlib import Path
from client import Client
from helpers.readonly import audit

p=argparse.ArgumentParser(description=__doc__);p.add_argument('--ruby',required=True);p.add_argument('--work',required=True,type=Path)
p.add_argument('--agent',type=Path);p.add_argument('--strace',action='store_true');a=p.parse_args()
root=Path(__file__).resolve().parents[1];os.chdir(root);os.umask(0o022)
w=a.work.resolve();w.mkdir(mode=0o755,parents=True);os.environ['XDG_CACHE_HOME']=str(w/'cache')

def usage(pid):
    stat=Path(f'/proc/{pid}/stat').read_text().rsplit(')',1)[1].split()
    rss=int(re.search(r'^VmRSS:\s*(\d+)',Path(f'/proc/{pid}/status').read_text(),re.M)[1])
    return dict(cpu_seconds=(int(stat[11])+int(stat[12]))/os.sysconf('SC_CLK_TCK'),rss_kib=rss)

expected=['ObserveParent#instance_call','ObserveParent#renamed (alias of instance_call)','ObserveMixin#mixed',
          'ObserveParent.class_call','block in ObserveParent#closure',
          'ObserveParent#dynamic (define_method)','ObserveParent#dynamic_alias (alias of dynamic) (define_method)',
          'block in ObserveParent#dynamic_block (define_method)','<main>']
client=None;result=dict(status='running',stops=[],resources=[])
try:
    options=['--break','rb_int_digits',*(['--runtime-agent',str(a.agent.resolve())] if a.agent else [])]
    client=Client('control',a.ruby,args=[str(root/'tests/fixtures/ruby/frame-observe.rb')],options=options)
    client.continue_initial_stop();previous=None
    for index,wanted in enumerate(expected):
        state=client.stopped('breakpoint',seconds=30);pid=state['pid']
        processes=dict(frontend=client.p.pid)
        if a.agent:processes['agent']=client.collector_pid()
        before={k:usage(v) for k,v in processes.items()};started=time.monotonic()
        stack=client.inspect('get_language_stack',language='ruby',tid=pid)
        labels=[f['qualified_name'] for s in stack['segments'] for f in s['frames'] if f['qualified_name']]
        assert 'Integer#digits' in labels and wanted in labels,(wanted,stack)
        assert all(f['name_reason'] is None for s in stack['segments'] for f in s['frames'] if f['qualified_name']),stack
        native=[f for s in stack['segments'] for f in s['frames'] if f['qualified_name']=='Integer#digits']
        assert native and all(f['kind']=='cfunc' and f['reason']=='RubyNativeBoundary' for f in native),native
        result['resources'].append(dict(before=before,after={k:usage(v) for k,v in processes.items()},seconds=time.monotonic()-started,load=os.getloadavg(),cpus=len(os.sched_getaffinity(0))))
        generation=client.session()['generation'];regs=client.inspect('get_registers',tid=pid)
        again=client.inspect('get_language_stack',language='ruby',tid=pid)
        # Background symbol work may improve native_stack_incomplete without
        # executing the target. The Ruby segments and retained stop must agree.
        assert all(again[key]==stack[key] for key in ('session_id','generation','tid','segments')),(stack,again)
        assert client.inspect('get_registers',tid=pid)==regs and client.session()['generation']==generation
        if index==0 and a.strace:
            result['readonly']=audit(client,pid,w/'readonly.strace',lambda:client.inspect('get_language_stack',language='ruby',tid=pid))
        if previous is not None:
            stale=client.tool('get_language_locals',generation=previous,language='ruby',tid=pid,segment=0,frame=0)['result']
            assert stale.get('isError') and stale['content'][0]['text']=='StaleSnapshot',stale
        result['stops'].append(dict(expected=wanted,stack=stack));previous=generation
        client.action('continue')
    deadline=time.monotonic()+30
    while client.session()['state']!='exited':
        assert time.monotonic()<deadline,'owned Ruby did not exit'
        time.sleep(.01)
    result['status']='pass'
finally:
    if client:
        (w/'transcript.json').write_text(json.dumps(client.transcript,indent=2)+'\n');client.close()
    (w/'results.json').write_text(json.dumps(result,indent=2)+'\n')
print('Ruby qualified frames: nine stops, native Integer#digits, owner/alias/block labels, GC and stale/read-only checks passed')
