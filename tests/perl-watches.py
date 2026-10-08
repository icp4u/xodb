#!/usr/bin/env python3
"""Stopped Perl scalar watches against a cooperating PadWalker/public-macro oracle."""
import argparse, json, os, queue, select, shlex, subprocess, threading, time
from pathlib import Path
from client import Client
from helpers.readonly import audit
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--perl',required=True);p.add_argument('--padwalker',required=True,type=Path)
p.add_argument('--work',required=True,type=Path);p.add_argument('--agent',type=Path);p.add_argument('--strace',action='store_true');a=p.parse_args()
root=Path(__file__).resolve().parents[1];os.chdir(root);os.umask(0o022)
w=a.work.resolve();w.mkdir(parents=True,mode=0o755)
cfg=json.loads(subprocess.check_output([a.perl,'-MConfig','-MJSON::PP','-e','print JSON::PP::encode_json({map {$_=>$Config{$_}} qw(archlib cc ccflags)})'],timeout=30))
source=root/'tests/fixtures/perl/watches.c';shared=w/'watches.so'
subprocess.run([*shlex.split(cfg['cc']),*shlex.split(cfg['ccflags']),'-U_FORTIFY_SOURCE','-shared','-fPIC','-g3','-O0','-fno-omit-frame-pointer','-I'+cfg['archlib']+'/CORE',str(source),'-o',str(shared)],check=True,timeout=90)
env=dict(os.environ,PERL5LIB=str(a.padwalker.resolve()/'blib/lib')+':'+str(a.padwalker.resolve()/'blib/arch'))
if a.agent:os.environ['XODB_RUNTIME_AGENT']=str(a.agent.resolve())
else:os.environ.pop('XODB_RUNTIME_AGENT',None)
target=subprocess.Popen([a.perl,str(root/'tests/fixtures/perl/watches.pl'),str(shared)],env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
c=None;report={'status':'running','stops':[],'resources':[]};thread=None

def resources(label):
    pids={'frontend':c.p.pid}
    if c.runtime_agent:pids['agent']=c.collector_pid()
    row=dict(label=label,load=os.getloadavg(),allowed_cpus=len(os.sched_getaffinity(0)),processes={})
    for name,pid in pids.items():
        fields=Path(f'/proc/{pid}/stat').read_text().rsplit(') ',1)[1].split()
        rss=next(line.split()[1] for line in Path(f'/proc/{pid}/status').read_text().splitlines() if line.startswith('VmRSS:'))
        row['processes'][name]=dict(cpu_seconds=(int(fields[11])+int(fields[12]))/os.sysconf('SC_CLK_TCK'),rss_kib=int(rss))
    report['resources'].append(row)

try:
    assert select.select([target.stdout],[],[],10)[0] and target.stdout.readline()==b'ready\n'
    lines=queue.Queue()
    def drain():
        for line in target.stdout:lines.put(line)
    thread=threading.Thread(target=drain,daemon=True);thread.start()
    c=Client('control',executable=None,options=[*(['--runtime-agent',str(a.agent.resolve())] if a.agent else []),'--attach',str(target.pid)])
    line=next(i for i,text in enumerate(source.read_text().splitlines(),1) if 'WATCH_STOP' in text)
    c.action('set_breakpoint',file=str(source),line=line);c.continue_initial_stop();target.stdin.write(b'go\n');target.stdin.flush()
    ids={};previous={};initial_context=None;shadow=None;gone=False
    labels=['initial','changed','equal','shadow','outer','typed','bytes','unicode','limit','deep','unwound','gone','initial']
    for index,label in enumerate(labels):
        state=c.stopped('breakpoint',seconds=30);oracle=json.loads(lines.get(timeout=30));assert oracle['label']==label,(label,oracle)
        generation=state['generation'];stack=c.inspect('get_language_stack',language='perl',tid=target.pid)
        frames=stack['segments'][0]['frames'];selected=next((i for i,f in enumerate(frames) if f['name']=='main::watched'),None)
        if not index:
            assert selected==0,stack
            initial_context=oracle['context_array']
            resources('before watch creation after initial metadata/stack')
            args=dict(language='perl',tid=target.pid,segment=0,frame=selected)
            bindings=c.inspect('get_language_locals',generation=generation,**args)['rows']
            row=next(i for i,v in enumerate(bindings) if v['name']=='$x')
            ids['binding_x']=c.action('add_language_watch',**args,row=row)['added']
            unicode_row=next(i for i,v in enumerate(bindings) if v['name']=='$élan')
            ids['binding_unicode']=c.action('add_language_watch',**args,row=unicode_row)['added']
            for name in ('$x','$dual','$word','$number','$empty','$reference','$tied'):
                ids[name]=c.action('add_language_watch',**args,expression=name)['added']
        end=time.monotonic()+45
        while True:
            rows=c.inspect('get_language_watches')['watches']
            if all(v['observed_generation']==generation or v['state'] in ('gone','context_changed') for v in rows):break
            assert time.monotonic()<end,rows;time.sleep(.01)
        byid={v['id']:v for v in rows}
        if label=='gone':gone=True
        if gone:
            assert all(byid[ident]['state']=='gone' for ident in ids.values()),rows
        else:
            expected={v['name']:v for v in oracle['frames'][selected]}
            for name,ident in ids.items():
                row=byid[ident];want=expected[{'binding_x':'$x','binding_unicode':'$élan'}.get(name,name)]
                if name=='binding_x' and label=='shadow':
                    # W remains the outer declaration; the name expression sees 900.
                    want=previous[name]
                if not want['complete']:
                    assert row['state']=='unavailable' and row['diagnostic'],row
                    continue
                assert row['state']=='value',row
                assert row['current']['kind']==want['kind'] and row['current']['comparison_bytes']==len(want['hex'])//2,(name,want,row)
                old=previous.get(name);changed=old is not None and (old['kind'],old['hex'])!=(want['kind'],want['hex'])
                assert row['changed']==changed,(label,name,changed,row)
                assert row['comparison']==('not_compared' if old is None else 'same_slot_different' if changed else 'same_slot_equal'),row
                previous[name]=want
            if label=='deep':
                assert selected>1 and oracle['context_array']!=initial_context,('relocation was not observed',selected,initial_context,oracle['context_array'])
                report['relocated_context_array']=True
            if label=='shadow':
                assert byid[ids['binding_x']]['current']['display']=='IV 8' and byid[ids['$x']]['current']['display']=='IV 900'
                bindings=c.inspect('get_language_locals',generation=generation,language='perl',tid=target.pid,segment=0,frame=selected)['rows']
                position=next(i for i,v in enumerate(bindings) if v['name']=='$x')
                shadow=c.action('add_language_watch',language='perl',tid=target.pid,segment=0,frame=selected,row=position)['added']
            elif label=='outer':
                assert byid[shadow]['state']=='unavailable' and byid[shadow]['diagnostic']=='PerlWatchBindingUnavailable',byid[shadow]
            if a.strace and label=='unwound':
                report['readonly']=audit(c,target.pid,w/'watches.strace',lambda:c.action('add_language_watch',language='perl',tid=target.pid,segment=0,frame=selected,expression='$x'))
        assert c.session()['generation']==generation
        resources(label)
        report['stops'].append(dict(label=label,oracle=oracle,watches=rows,frames=frames))
        if index+1<len(labels):c.action('continue')
    assert report.get('relocated_context_array')
    c.action('detach');report['status']='pass'
    report['measurement_status']='not-measurable' if any(max(row['load'])>row['allowed_cpus'] for row in report['resources']) else 'measured'
    report['measurement_phase']='initial metadata/stack through watch creation and 13 cooperating stops; includes run control/oracle and optional tracing, not isolated observer overhead'
finally:
    if c:
        c.close();(w/'rpc.json').write_text(json.dumps(c.transcript,indent=2)+'\n');(w/'stderr.log').write_bytes(c.p.stderr.read())
    if target.poll() is None:target.kill()
    target.wait(timeout=10)
    if thread:thread.join(timeout=5)
    (w/'target.stderr').write_bytes(target.stderr.read())
    if report['status']!='pass':report['status']='failed'
    (w/'results.json').write_text(json.dumps(report,indent=2)+'\n')
print('Perl watches: public-macro/PadWalker oracle, dualvars, full strings, Unicode, shadow binding, relocation, retirement and no resurrection passed')
