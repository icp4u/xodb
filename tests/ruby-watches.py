#!/usr/bin/env python3
"""Stopped CRuby scalar watches against a cooperating public-macro oracle."""
import argparse,importlib.util,json,os,queue,re,select,signal,subprocess,threading,time
from types import SimpleNamespace
from pathlib import Path
from client import Client
from helpers.readonly import audit
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--ruby',required=True);p.add_argument('--work',required=True,type=Path)
p.add_argument('--agent',type=Path);p.add_argument('--strace',action='store_true');a=p.parse_args()
root=Path(__file__).resolve().parents[1];os.chdir(root);os.umask(0o022)
w=a.work.resolve();w.mkdir(parents=True,mode=0o755)
headers=json.loads(subprocess.check_output([a.ruby,'-rjson','-rrbconfig','-e','puts JSON.generate(RbConfig::CONFIG.values_at("rubyhdrdir","rubyarchhdrdir","DLEXT"))'],text=True,timeout=30))
source=root/'tests/fixtures/ruby/watches.c';addon=w/('xodb_watches.'+headers[2])
subprocess.run(['cc','-g','-O0','-fno-omit-frame-pointer','-fPIC','-shared','-I'+headers[0],'-I'+headers[1],str(source),'-o',str(addon)],check=True,timeout=60)
if a.agent:os.environ['XODB_RUNTIME_AGENT']=str(a.agent.resolve())
else:os.environ.pop('XODB_RUNTIME_AGENT',None)
target=subprocess.Popen([a.ruby,'tests/fixtures/ruby/watches.rb'],env=dict(os.environ,XODB_RUBY_WATCHES=str(addon)),stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
c=None;thread=None;report={'status':'running','stops':[],'resources':[]}
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
    assert select.select([target.stdout],[],[],15)[0] and target.stdout.readline()==b'ready\n'
    lines=queue.Queue()
    def drain():
        for line in target.stdout:lines.put(line)
    thread=threading.Thread(target=drain,daemon=True);thread.start()
    c=Client('control',None,options=[*(['--runtime-agent',str(a.agent.resolve())] if a.agent else []),'--attach',str(target.pid)])
    line=next(i for i,text in enumerate(source.read_text().splitlines(),1) if 'WATCH_STOP' in text)
    c.action('set_breakpoint',file=str(source),line=line);c.continue_initial_stop();target.stdin.write(b'go\n');target.stdin.flush()
    ids={};previous={};gone=False;initial_frame=None;closure_ids={}
    labels=['initial','changed','equal','encoding','typed','cap','limit','bytes','shadow','outer','other-fiber','fiber-return','deep','unwound','gone','initial']
    for index,label in enumerate(labels):
        state=c.stopped('breakpoint',seconds=45);oracle=json.loads(lines.get(timeout=30));assert oracle['label']==label,(label,oracle)
        generation=state['generation'];stack=c.inspect('get_language_stack',language='ruby',tid=target.pid)
        selected=next(((s,f,row) for s,part in enumerate(stack['segments']) for f,row in enumerate(part['frames']) if row['name']=='watched'),None)
        if not index:
            assert selected is not None,stack
            segment,frame,initial_frame=selected
            report['initial_runtime']=stack['segments'][segment]['runtime_instance']['address']
            resources('before watch creation after metadata/stack')
            args=dict(language='ruby',tid=target.pid,segment=segment,frame=frame)
            bindings=c.inspect('get_language_locals',generation=generation,**args)['rows']
            row=next(i for i,v in enumerate(bindings) if v['name']=='x')
            ids['binding_x']=c.action('add_language_watch',**args,row=row)['added']
            for name in ('x','word','fraction','truth','empty','object','large'):
                ids[name]=c.action('add_language_watch',**args,expression=name)['added']
        end=time.monotonic()+45
        while True:
            rows=c.inspect('get_language_watches')['watches']
            if all(v['observed_generation']==generation or v['state'] in ('gone','context_changed') for v in rows):break
            assert time.monotonic()<end,rows;time.sleep(.01)
        byid={v['id']:v for v in rows}
        if label=='gone':gone=True
        if gone:assert all(byid[ident]['state']=='gone' for ident in ids.values()),rows
        elif label=='other-fiber':
            assert all(byid[i]['state']=='unavailable' for i in ids.values()),rows
            assert any(part['runtime_instance']['address']!=report['initial_runtime'] for part in stack['segments']),stack
            report['different_fiber_observed']=True
        else:
            for name,ident in ids.items():
                row=byid[ident];want=oracle['values']['x' if name=='binding_x' else name]
                if label=='shadow' and name in ('x','binding_x'):want=previous[name]
                assert row['language']=='ruby' and 'unproved' in row['identity'],row
                if not want['complete']:
                    assert row['state']=='unavailable' and row['diagnostic'],row
                    if name=='word':assert row['diagnostic']=='RubyWatchSampleLimit',row
                    continue
                assert row['state']=='value',row
                assert row['current']['kind']==want['kind'] and row['current']['comparison_bytes']==len(want['hex'])//2,(name,want,row)
                old=previous.get(name);changed=old is not None and (old['kind'],old['hex'])!=(want['kind'],want['hex'])
                assert row['changed']==changed,(label,name,changed,row)
                assert row['comparison']==('not_compared' if old is None else 'same_slot_different' if changed else 'same_slot_equal'),row
                previous[name]=want
            if label=='changed':
                assert selected[2]['environment']!=initial_frame['environment'],('environment move not observed',initial_frame,selected)
                report['escaped_environment_move']=True
                assert byid[ids['word']]['changed'] and byid[ids['word']]['current']['display']==byid[ids['word']]['previous']['display'],byid[ids['word']]
            if label=='shadow':
                segment,frame,_=next((s,f,v) for s,part in enumerate(stack['segments']) for f,v in enumerate(part['frames']) if v['name']=='block in watched')
                args=dict(language='ruby',tid=target.pid,segment=segment,frame=frame)
                bindings=c.inspect('get_language_locals',generation=generation,**args)['rows']
                positions=[i for i,v in enumerate(bindings) if v['name']=='x'];assert len(positions)==2,bindings
                closure_ids['inner']=c.action('add_language_watch',**args,expression='x')['added']
                closure_ids['outer']=c.action('add_language_watch',**args,row=positions[1])['added']
                added={v['id']:v for v in c.inspect('get_language_watches')['watches']}
                assert added[closure_ids['inner']]['current']['display']=='999',added
                assert added[closure_ids['outer']]['current']['display']=='8',added
                assert added[closure_ids['outer']]['current']['kind']==2,added
            if label=='outer':assert all(byid[i]['state']=='gone' for i in closure_ids.values()),rows
            if label=='encoding':assert byid[ids['word']]['changed'],rows
            if label=='equal':assert all(not byid[i]['changed'] for i in ids.values()),rows
            if a.strace and label=='unwound':
                segment,frame,_=selected
                report['readonly']=audit(c,target.pid,w/'watches.strace',lambda:c.action('add_language_watch',language='ruby',tid=target.pid,segment=segment,frame=frame,expression='x'))
        assert c.session()['generation']==generation
        resources(label);report['stops'].append(dict(label=label,oracle=oracle,watches=rows,stack=stack))
        if index+1<len(labels):c.action('continue')
    assert report.get('escaped_environment_move') and report.get('different_fiber_observed')
    c.action('detach');report['status']='pass'
    report['measurement_status']='not-measurable' if any(max(v['load'])>v['allowed_cpus'] for v in report['resources']) else 'measured'
    report['measurement_phase']='metadata/stack through watch creation and cooperating stops; includes run control and optional tracing, not isolated watch overhead'
finally:
    if c:
        c.close();(w/'rpc.json').write_text(json.dumps(c.transcript,indent=2)+'\n');(w/'stderr.log').write_bytes(c.p.stderr.read())
    if target.poll() is None:target.kill()
    target.wait(timeout=10)
    if thread:thread.join(timeout=5)
    (w/'target.stderr').write_bytes(target.stderr.read())
    if report['status']!='pass':report['status']='failed'
    (w/'results.json').write_text(json.dumps(report,indent=2)+'\n')
def shared_observer():
    spec=importlib.util.spec_from_file_location('ruby_shared',root/'tests/shared-sessions.py')
    shared=importlib.util.module_from_spec(spec);spec.loader.exec_module(shared)
    part=w/'shared';part.mkdir();(part/'run').mkdir(mode=0o700)
    server=SimpleNamespace(path=part/'run/s',clients=[],proc=None)
    assert len(os.fsencode(server.path))<108,'Use a shorter --work path for the shared socket'
    fixture=subprocess.Popen([a.ruby,'tests/fixtures/ruby/watches.rb'],env=dict(os.environ,XODB_RUBY_WATCHES=str(addon)),
        stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    log=(part/'server.log').open('wb');reader=None;result={'status':'running'}
    try:
        assert select.select([fixture.stdout],[],[],15)[0] and fixture.stdout.readline()==b'ready\n'
        output=queue.Queue()
        def drain_shared():
            for line in fixture.stdout:output.put(line)
        reader=threading.Thread(target=drain_shared,daemon=True);reader.start()
        command=[os.environ.get('XODB_BIN',str(root/'zig-out/bin/xodb')),'--headless','--session-socket',str(server.path),
            '--agent-scope','control',*(['--runtime-agent',str(a.agent.resolve())] if a.agent else []),'--attach',str(fixture.pid)]
        server.proc=subprocess.Popen(command,stdin=subprocess.DEVNULL,stdout=log,stderr=subprocess.STDOUT)
        owner=shared.Client(server,'ruby-owner');observer=shared.Client(server,'ruby-observer');owner.claim(ttl_ms=60000)
        line=next(i for i,text in enumerate(source.read_text().splitlines(),1) if 'WATCH_STOP' in text)
        owner.action('set_breakpoint',file=str(source),line=line);owner.action('continue')
        fixture.stdin.write(b'go\n');fixture.stdin.flush()
        state=shared.eventually(owner.session,lambda value:value['state']=='stopped' and
            not value['continue_pending'] and not value['symbol_discovery_pending'] and
            any(t['reason']=='breakpoint' for t in value['threads']),'shared Ruby watch stop')
        oracle=json.loads(output.get(timeout=30));assert oracle['label']=='initial',oracle
        deadline=time.monotonic()+45
        while True:
            reply=owner.raw('get_language_stack',tid=fixture.pid,language='ruby')
            if not reply['result'].get('isError'):break
            assert reply['result']['content'][0]['text']=='DebugMetadataPending' and time.monotonic()<deadline,reply
            time.sleep(.01)
        stack=reply['result']['structuredContent']
        segment,frame=next((s,f) for s,part in enumerate(stack['segments']) for f,row in enumerate(part['frames']) if row['name']=='watched')
        generation=owner.session()['generation'];args=dict(generation=generation,language='ruby',tid=fixture.pid,segment=segment,frame=frame,expression='x')
        listed=shared.listed_tools(observer)
        assert 'add_language_watch' not in listed and 'remove_language_watch' not in listed
        registers=owner.tool('get_registers',tid=fixture.pid)
        shared.expect_error(observer.raw('add_language_watch',**args),'ControlLeaseRequired')
        assert observer.tool('get_language_watches')['watches']==[]
        added=owner.tool('add_language_watch',**args)['added']
        watches=observer.tool('get_language_watches')['watches']
        assert watches==owner.tool('get_language_watches')['watches'] and len(watches)==1,watches
        assert watches[0]['id']==added and watches[0]['language']=='ruby' and watches[0]['current']['display']=='7',watches
        shared.expect_error(observer.raw('remove_language_watch',generation=generation,id=added),'ControlLeaseRequired')
        assert observer.tool('get_language_watches')['watches']==watches
        owner.tool('release_session_control');assert observer.info()['controller_id'] is None
        assert observer.tool('get_language_watches')['watches']==watches
        assert owner.session()['generation']==generation and owner.tool('get_registers',tid=fixture.pid)==registers
        owner.claim(ttl_ms=60000);owner.tool('remove_language_watch',generation=generation,id=added)
        assert observer.tool('get_language_watches')['watches']==[]
        owner.action('detach')
        result.update(status='pass',add_error='ControlLeaseRequired',remove_error='ControlLeaseRequired',
            owner_observer_equal=True,reads_without_controller=True,generation_registers_unchanged=True)
        return result
    finally:
        for client in server.clients:client.close()
        cleanup_status=0
        if server.proc:
            if server.proc.poll() is None:
                server.proc.send_signal(signal.SIGINT)
                try:server.proc.wait(timeout=10)
                except subprocess.TimeoutExpired:server.proc.kill();server.proc.wait()
            cleanup_status=server.proc.returncode
        if fixture.poll() is None:fixture.kill()
        fixture.wait(timeout=10)
        if reader:reader.join(timeout=5)
        log.close();(part/'target.stderr').write_bytes(fixture.stderr.read())
        result['transcripts']=[client.transcript for client in server.clients]
        if result['status']!='pass' or cleanup_status:result['status']='failed'
        (part/'results.json').write_text(json.dumps(result,indent=2)+'\n')
        assert cleanup_status==0,('shared server exit',cleanup_status)

try:report['shared_observer']=shared_observer()
except BaseException:
    report['status']='failed'
    raise
finally:(w/'results.json').write_text(json.dumps(report,indent=2)+'\n')
print('Ruby watches: complete scalar/GC/frame oracle and shared-observer watch lease checks passed')
