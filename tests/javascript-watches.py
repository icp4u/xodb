#!/usr/bin/env python3
"""Owned stopped context-storage watches against JavaScript scalar bytes."""
import argparse, importlib.util, json, os, queue, select, signal, subprocess, threading, time
from pathlib import Path
from types import SimpleNamespace
from client import Client
from helpers.readonly import audit

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--node',default='node');p.add_argument('--include',default='/usr/include/node')
p.add_argument('--work',required=True,type=Path);p.add_argument('--agent',type=Path)
p.add_argument('--strace',action='store_true');a=p.parse_args()
root=Path(__file__).resolve().parents[1];os.chdir(root);os.umask(0o022)
w=a.work.resolve();w.mkdir(parents=True,mode=0o755)
os.environ['XDG_CACHE_HOME']=str(w/'cache')
if a.agent:os.environ['XODB_RUNTIME_AGENT']=str(a.agent.resolve())
else:os.environ.pop('XODB_RUNTIME_AGENT',None)
addon=w/'probe.node'
subprocess.run(['c++','-std=c++20','-g','-O0','-fno-omit-frame-pointer','-fPIC','-shared',
    '-I'+a.include,'-DNODE_GYP_MODULE_NAME=xodb_probe','-DXODB_PROBE_HEAP_IDENTITY','tests/fixtures/javascript/probe.cc','-o',str(addon)],check=True,timeout=60)
def fixture():
    return subprocess.Popen([a.node,'--no-opt','--no-sparkplug','--no-maglev','--expose-gc','--compact-on-every-full-gc',
        'tests/fixtures/javascript/watches.js'],env=dict(os.environ,XODB_NODE_PROBE=str(addon)),
        stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
def drain(target, output):
    for line in target.stdout:output.put(line)
def pick(stack, name):
    return next((s,f,row) for s,part in enumerate(stack['segments']) for f,row in enumerate(part['frames']) if row['name']==name)
def refusal(reply, why):
    assert reply['result'].get('isError') and reply['result']['content'][0]['text']==why,reply
def resources(client, label):
    pids={'frontend':client.p.pid}
    if client.runtime_agent:pids['agent']=client.collector_pid()
    row=dict(label=label,load=os.getloadavg(),allowed_cpus=len(os.sched_getaffinity(0)),processes={})
    for name,pid in pids.items():
        fields=Path(f'/proc/{pid}/stat').read_text().rsplit(') ',1)[1].split()
        rss=next(line.split()[1] for line in Path(f'/proc/{pid}/status').read_text().splitlines() if line.startswith('VmRSS:'))
        row['processes'][name]=dict(cpu_seconds=(int(fields[11])+int(fields[12]))/os.sysconf('SC_CLK_TCK'),rss_kib=int(rss))
    return row

target=fixture();c=None;thread=None;report={'status':'running','stops':[],'resources':[]}
try:
    assert select.select([target.stdout],[],[],15)[0] and target.stdout.readline()==b'ready\n'
    lines=queue.Queue();thread=threading.Thread(target=drain,args=(target,lines),daemon=True);thread.start()
    c=Client('control',None,options=[*(['--runtime-agent',str(a.agent.resolve())] if a.agent else []),'--attach',str(target.pid)])
    c.action('set_breakpoint',symbol='xodb_node_stop');c.continue_initial_stop();target.stdin.write(b'go\n');target.stdin.flush()
    ids={};previous={};extra={};retired=False
    labels=['initial','gc-equal','changed','equal','typed','cap','limit','recovered','inner-scope','outer-scope',
            'recursive-0','recursive-1','recursive-2','unwound','gone','initial']
    for index,label in enumerate(labels):
        state=c.stopped('breakpoint',seconds=45);generation=state['generation']
        oracle=json.loads(lines.get(timeout=30));site=json.loads(lines.get(timeout=30))
        assert oracle['label']==site['label']==label,(label,oracle,site)
        stack=c.inspect('get_language_stack',language='javascript',tid=target.pid)
        if index==0:
            segment,frame,initial_frame=pick(stack,'watched')
            args=dict(language='javascript',tid=target.pid,segment=segment,frame=frame)
            bindings=c.action('get_language_locals',**args)['rows']
            initial_word=next(v for v in bindings if v['name']=='word')
            assert initial_word['address']==int(site['watch_heap_tagged'],16)-1,(initial_word,site)
            initial_word_address=initial_word['address']
            report['resources'].append(resources(c,'before watch creation after metadata/stack'))
            for name in oracle['values']:
                row=next(v['ordinal'] for v in bindings if v['name']==name)
                ids[name]=c.action('add_language_watch',**args,row=row)['added']
            refusal(c.tool('add_language_watch',generation=generation,**args,expression='x'),'JavaScriptLexicalUnproved')
            refusal(c.tool('evaluate_language_expression',generation=generation,**args,expression='x'),'JavaScriptLexicalUnproved')
        deadline=time.monotonic()+45
        while True:
            rows=c.inspect('get_language_watches')['watches']
            if all(v['state'] in ('gone','context_changed') or (v['observed_generation']==generation and not (v['diagnostic'] or '').endswith('Pending')) for v in rows):break
            assert time.monotonic()<deadline,rows;time.sleep(.01)
        byid={v['id']:v for v in rows}
        if label=='gone':retired=True
        if retired:
            assert all(byid[ident]['state']=='gone' for ident in ids.values()),rows
        elif not label.startswith('recursive-'):
            for name,ident in ids.items():
                row=byid[ident];want=oracle['values'][name]
                assert row['language']=='javascript' and row['selector']=='context_storage',row
                assert row['expression']=='' and row['row_name']==name,row
                assert 'lexical visibility unproved' in row['semantics'] and 'activation lifetime between stops unproved' in row['identity'],row
                if not want['complete']:
                    assert row['state']=='unavailable' and row['diagnostic'],row
                    if name=='large':assert row['diagnostic']=='JavaScriptWatchStringLimit',row
                    continue
                assert row['state']=='value',row
                assert row['current']['kind']==want['kind'] and row['current']['comparison_bytes']==len(want['hex'])//2,(name,want,row)
                old=previous.get(name);changed=old is not None and (old['kind'],old['hex'])!=(want['kind'],want['hex'])
                assert row['changed']==changed,(label,name,changed,row)
                assert row['comparison']==('not_compared' if old is None else 'same_slot_different' if changed else 'same_slot_equal'),row
                previous[name]=want
            if label=='gc-equal':
                segment,frame,current=pick(stack,'watched')
                bindings=c.action('get_language_locals',language='javascript',tid=target.pid,segment=segment,frame=frame)['rows']
                current_word=next(v for v in bindings if v['name']=='word')
                native_address=int(site['watch_heap_tagged'],16)-1
                assert current_word['address']==native_address and native_address!=initial_word_address,(initial_word_address,current_word,site)
                assert current['context']!=initial_frame['context'] and current['frame_pointer']==initial_frame['frame_pointer']
                word=byid[ids['word']]
                assert not word['changed'] and word['comparison']=='same_slot_equal' and word['current']['display']==word['previous']['display'],word
                assert oracle['values']['word']==report['stops'][0]['oracle']['values']['word']
                report['gc_equal_relocation']={'status':'pass','native_old':initial_word_address,'native_new':native_address,'reader_matches_native':True,'same_value':True,'context_moved':True}
            if label=='changed':
                current=pick(stack,'watched')[2]
                assert current['context']!=initial_frame['context'],('GC relocation not observed',initial_frame,current)
                assert current['frame_pointer']==initial_frame['frame_pointer']
                report['context_relocation_observed']=True
                word=byid[ids['word']];assert word['changed'] and word['current']['display']==word['previous']['display'],word
            if label=='inner-scope':
                segment,frame,_=pick(stack,'watched');args=dict(language='javascript',tid=target.pid,segment=segment,frame=frame)
                bindings=c.action('get_language_locals',**args)['rows'];positions=[v['ordinal'] for v in bindings if v['name']=='x']
                assert len(positions)==2,bindings
                extra['inner']=c.action('add_language_watch',**args,row=positions[0])['added']
                inner=next(v for v in c.inspect('get_language_watches')['watches'] if v['id']==extra['inner'])
                assert inner['current']['display']=='smi 999' and byid[ids['x']]['current']['display']=='smi 8',rows
            if label=='outer-scope':assert byid[extra['inner']]['state']=='gone',rows
            if label=='unwound' and a.strace:
                segment,frame,_=pick(stack,'watched');args=dict(language='javascript',tid=target.pid,segment=segment,frame=frame)
                bindings=c.action('get_language_locals',**args)['rows'];row=next(v['ordinal'] for v in bindings if v['name']=='x')
                def observe():
                    added=c.action('add_language_watch',**args,row=row)['added'];c.action('remove_language_watch',id=added)
                report['readonly']=audit(c,target.pid,w/'watches.strace',observe)
        if label=='recursive-0':
            segment,frame,_=pick(stack,'recursive');args=dict(language='javascript',tid=target.pid,segment=segment,frame=frame)
            bindings=c.action('get_language_locals',**args)['rows'];row=next(v['ordinal'] for v in bindings if v['name']=='own')
            extra['recursive']=c.action('add_language_watch',**args,row=row)['added']
            added=next(v for v in c.inspect('get_language_watches')['watches'] if v['id']==extra['recursive'])
            assert added['current']['display']=='smi 0',added
        if label in ('recursive-1','recursive-2','unwound'):assert byid[extra['recursive']]['state']=='gone',rows
        assert c.session()['generation']==generation
        report['resources'].append(resources(c,label));report['stops'].append(dict(label=label,oracle=oracle,site=site,stack=stack,watches=rows))
        if index+1<len(labels):c.action('continue')
    assert report.get('context_relocation_observed') and report.get('gc_equal_relocation',{}).get('status')=='pass'
    c.action('detach');report['status']='pass'
    report['measurement_status']='not-measurable' if any(max(v['load'])>v['allowed_cpus'] for v in report['resources']) else 'measured'
    report['measurement_phase']='metadata/stack through watch creation and cooperating stops; includes run control and optional tracing'
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
    spec=importlib.util.spec_from_file_location('js_shared',root/'tests/shared-sessions.py')
    shared=importlib.util.module_from_spec(spec);spec.loader.exec_module(shared)
    part=w/'shared';part.mkdir();(part/'run').mkdir(mode=0o700)
    server=SimpleNamespace(path=part/'run/s',clients=[],proc=None)
    assert len(os.fsencode(server.path))<108,'Use a shorter --work path for the shared socket'
    fixture_process=fixture();log=(part/'server.log').open('wb');reader=None;result={'status':'running'}
    try:
        assert select.select([fixture_process.stdout],[],[],15)[0] and fixture_process.stdout.readline()==b'ready\n'
        output=queue.Queue();reader=threading.Thread(target=drain,args=(fixture_process,output),daemon=True);reader.start()
        command=[os.environ.get('XODB_BIN',str(root/'zig-out/bin/xodb')),'--headless','--session-socket',str(server.path),
            '--agent-scope','control',*(['--runtime-agent',str(a.agent.resolve())] if a.agent else []),'--attach',str(fixture_process.pid)]
        server.proc=subprocess.Popen(command,stdin=subprocess.DEVNULL,stdout=log,stderr=subprocess.STDOUT)
        owner=shared.Client(server,'js-owner');observer=shared.Client(server,'js-observer');owner.claim(ttl_ms=60000)
        owner.action('set_breakpoint',symbol='xodb_node_stop');owner.action('continue')
        fixture_process.stdin.write(b'go\n');fixture_process.stdin.flush()
        shared.eventually(owner.session,lambda v:v['state']=='stopped' and not v['continue_pending'] and
            not v['symbol_discovery_pending'] and any(t['reason']=='breakpoint' for t in v['threads']),'shared Node watch stop')
        assert json.loads(output.get(timeout=30))['label']=='initial';assert json.loads(output.get(timeout=30))['label']=='initial'
        deadline=time.monotonic()+45
        while True:
            reply=owner.raw('get_language_stack',tid=fixture_process.pid,language='javascript')
            if not reply['result'].get('isError'):break
            refusal(reply,'DebugMetadataPending');assert time.monotonic()<deadline,reply;time.sleep(.01)
        segment,frame,_=pick(reply['result']['structuredContent'],'watched')
        generation=owner.session()['generation'];args=dict(generation=generation,language='javascript',tid=fixture_process.pid,segment=segment,frame=frame)
        bindings=owner.tool('get_language_locals',**args)['rows'];args['row']=next(v['ordinal'] for v in bindings if v['name']=='x')
        listed=shared.listed_tools(observer);assert 'add_language_watch' not in listed and 'remove_language_watch' not in listed
        registers=owner.tool('get_registers',tid=fixture_process.pid)
        refusal(observer.raw('add_language_watch',**args),'ControlLeaseRequired');assert observer.tool('get_language_watches')['watches']==[]
        added=owner.tool('add_language_watch',**args)['added'];watches=observer.tool('get_language_watches')['watches']
        assert watches==owner.tool('get_language_watches')['watches'] and len(watches)==1,watches
        assert watches[0]['id']==added and watches[0]['current']['display']=='smi 7',watches
        refusal(observer.raw('remove_language_watch',generation=generation,id=added),'ControlLeaseRequired')
        assert observer.tool('get_language_watches')['watches']==watches
        owner.tool('release_session_control');assert observer.info()['controller_id'] is None
        assert observer.tool('get_language_watches')['watches']==watches
        assert owner.session()['generation']==generation and owner.tool('get_registers',tid=fixture_process.pid)==registers
        owner.claim(ttl_ms=60000);owner.tool('remove_language_watch',generation=generation,id=added)
        assert observer.tool('get_language_watches')['watches']==[];owner.action('detach')
        result.update(status='pass',add_error='ControlLeaseRequired',remove_error='ControlLeaseRequired',
            owner_observer_equal=True,reads_without_controller=True,generation_registers_unchanged=True)
        return result
    finally:
        for client in server.clients:client.close()
        status=0
        if server.proc:
            if server.proc.poll() is None:
                server.proc.send_signal(signal.SIGINT)
                try:server.proc.wait(timeout=10)
                except subprocess.TimeoutExpired:server.proc.kill();server.proc.wait()
            status=server.proc.returncode
        if fixture_process.poll() is None:fixture_process.kill()
        fixture_process.wait(timeout=10)
        if reader:reader.join(timeout=5)
        log.close();(part/'target.stderr').write_bytes(fixture_process.stderr.read())
        result['transcripts']=[client.transcript for client in server.clients]
        if result['status']!='pass' or status:result['status']='failed'
        (part/'results.json').write_text(json.dumps(result,indent=2)+'\n')
        assert status==0,('shared server exit',status)
def inspector_oracle():
    # A separate cooperating producer invokes its own inspector. xodb never
    # requests evaluation or executes this code in the stopped target.
    command=[a.node,'--no-opt','--no-sparkplug','--no-maglev','--expose-gc','--compact-on-every-full-gc',
        'tests/fixtures/javascript/watches.js','inspector']
    run=subprocess.run(command,input=b'go\n',env=dict(os.environ,XODB_NODE_PROBE=str(addon)),capture_output=True,timeout=45)
    (w/'inspector.stdout').write_bytes(run.stdout);(w/'inspector.stderr').write_bytes(run.stderr)
    assert run.returncode==0,run.stderr.decode()
    lines=run.stdout.splitlines();assert lines[0]==b'ready' and (len(lines)-1)%3==0
    stops=[]
    for i in range(1,len(lines),3):
        values,inspector,site=map(json.loads,lines[i:i+3]);label=values['label']
        assert label==inspector['label']==site['label']
        frames=inspector['inspector']
        if label=='gone':assert not frames
        else:
            wanted='recursive' if label.startswith('recursive-') else 'watched'
            frame=next(v for v in frames if v['name']==wanted)
            expected=dict(values['values']);expected.pop('inner',None)
            assert frame['values']==expected,(label,frame,expected)
            if label=='inner-scope':
                assert frame['bare_x']==values['values']['inner'] and frame['bare_x']!=frame['values']['x'],frame
        stops.append(dict(label=label,oracle=values,inspector=inspector))
    assert len(stops)>=len(report['stops'])
    for live,independent in zip(report['stops'],stops):
        assert live['label']==independent['label'] and live['oracle']==independent['oracle']
    return dict(status='pass',stops=stops,lexical_shadow_mismatch_observed=True)

try:
    report['shared_observer']=shared_observer()
    report['inspector_oracle']=inspector_oracle()
except BaseException:
    report['status']='failed';raise
finally:(w/'results.json').write_text(json.dumps(report,indent=2)+'\n')
print('JavaScript watches: complete scalar/GC/scope oracle, frame retirement and shared-observer checks passed')
