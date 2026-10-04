#!/usr/bin/env python3
"""Idle stopped debugger on a hidden private workspace, plus readiness faults."""
import argparse,importlib.util,json,os,select,signal,subprocess,sys,time
from pathlib import Path
root=Path(__file__).resolve().parents[1];os.chdir(root)
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('mode',choices=['trace','acquire','fence'],nargs='?',default='trace')
parser.add_argument('binary',nargs='?',default='zig-out/bin/xodb')
parser.add_argument('--expect-stall',action='store_true')
parser.add_argument('--keep-hidden',action='store_true')
parser.add_argument('--attach-fixture',action='store_true')
parser.add_argument('--quit',choices=['mcp','signal','close'],default='mcp')
args=parser.parse_args()
mode=args.mode;binary=str(Path(args.binary).resolve());expect_stall=args.expect_stall
spec=importlib.util.spec_from_file_location('display',root/'tests/helpers/display.py')
h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)
h.WORK=str(root/'.work'/('timeline-vk-'+str(time.time_ns())[-8:]))
d=h.Display('idle');app=target=None;gate=Path(d.dir)/'gate';log=Path(d.dir)/'xodb.log'
results={'mode':mode,'binary':binary,'expect_stall':expect_stall}
try:
    fault=Path(d.dir)/'stall.so'
    subprocess.run(['cc','-shared','-fPIC','-Wall','-Wextra','-Werror','tests/vulkan-stall.c','-ldl','-o',str(fault)],check=True)
    appenv=dict(d.env,LD_PRELOAD=str(fault),XODB_TEST_VULKAN_MODE=mode,XODB_TEST_VULKAN_GATE=str(gate))
    launch=['--','./zig-out/bin/xodb-m1-fixture']
    if args.attach_fixture:
        with (Path(d.dir)/'target.log').open('xb') as stream:
            target=subprocess.Popen(['./zig-out/bin/xodb-profile-fixture','100','threads'],stdout=stream,stderr=stream,env=d.env)
        end=time.monotonic()+5
        while len(list(Path(f'/proc/{target.pid}/task').iterdir()))<2:
            assert target.poll() is None and time.monotonic()<end
            time.sleep(.01)
        time.sleep(.05)
        launch=['--attach',str(target.pid)]
    with log.open('xb') as stream:
        app=subprocess.Popen([binary,'--mcp','--agent-scope','control',*launch],env=appenv,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=stream,bufsize=0)
    serial=0;pending=b'';transcript=[]
    def request(method,params=None,timeout=2):
        global serial,pending
        serial+=1;identity=serial
        app.stdin.write((json.dumps(dict(jsonrpc='2.0',id=identity,method=method,params=params or {}))+'\n').encode())
        end=time.monotonic()+timeout
        while time.monotonic()<end:
            while b'\n' in pending:
                line,pending=pending.split(b'\n',1);obj=json.loads(line);transcript.append(obj)
                if obj.get('id')==identity:return obj
            if not select.select([app.stdout],[],[],max(0,end-time.monotonic()))[0]:return None
            data=os.read(app.stdout.fileno(),65536)
            assert data,log.read_text();pending+=data
        return None
    def tool(name,**args):
        result=request('tools/call',{'name':name,'arguments':args})
        assert result and not result.get('error') and not result['result'].get('isError'),result
        return result['result']['structuredContent']
    assert request('initialize',{'protocolVersion':'2025-06-18','capabilities':{},'clientInfo':{'name':'vulkan-stall','version':'1'}})
    app.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
    stopped=tool('get_session');assert stopped['state']=='stopped'
    pid=stopped['pid'];tid=stopped['threads'][0]['tid']
    for expression in ('$rip','$rsp','$rdi'):
        assert tool('evaluate_expression',tid=tid,expression=expression)['availability']=='available'
    time.sleep(.5);d.shot('visible-before')
    gate.touch()
    if mode=='trace':
        subprocess.run(['swaymsg','workspace','number','2'],env=d.env,check=True,capture_output=True)
    deadline=time.monotonic()+8;latencies=[];stalled=False
    while time.monotonic()<deadline:
        before=time.monotonic();reply=request('ping',timeout=2);latencies.append(time.monotonic()-before)
        if reply is None:stalled=True;break
        assert reply['result']=={},reply
        time.sleep(.1)
    results.update(stalled=stalled,max_ping_ms=max(latencies)*1000,pings=len(latencies),last_phase=log.read_text().splitlines()[-6:],wchan=Path(f'/proc/{app.pid}/wchan').read_text(),responses=transcript[-4:])
    print(json.dumps(results),flush=True)
    if expect_stall:assert stalled,log.read_text()
    else:assert not stalled,log.read_text()
    if not args.keep_hidden:
        gate.unlink()
        if mode=='trace':subprocess.run(['swaymsg','workspace','number','1'],env=d.env,check=True,capture_output=True)
        # A timed-out reply can still arrive; request() discards old request IDs.
        end=time.monotonic()+5
        while not request('ping',timeout=.5):assert time.monotonic()<end
        resumed=tool('get_session');assert resumed['state']=='stopped' and resumed['generation']==stopped['generation'],resumed
        time.sleep(.4);d.shot('visible-after')
        d.resize(1040,720);time.sleep(.3);assert request('ping');d.shot('resized-after')
    before=time.monotonic()
    if args.quit=='signal':app.send_signal(signal.SIGINT)
    elif args.quit=='close':subprocess.run(['swaymsg','[app_id="xodb"]','kill'],env=d.env,check=True,capture_output=True)
    else:app.stdin.close()
    assert app.wait(timeout=5)==0,log.read_text()
    results.update(exit_ms=(time.monotonic()-before)*1000,quit=args.quit,kept_hidden=args.keep_hidden,attached=bool(target))
    if target:
        assert target.poll() is None,'Attached fixture was killed'
        assert 'TracerPid:\t0' in Path(f'/proc/{target.pid}/status').read_text()
        assert not Path(f'/proc/{target.pid}/stat').read_text().split(') ')[1].startswith(('t','T'))
    else:assert not Path(f'/proc/{pid}').exists(),'Owned target survived shutdown'
    (Path(d.dir)/'results.json').write_text(json.dumps(results,indent=2)+'\n')
finally:
    if gate.exists():gate.unlink()
    if app and app.poll() is None:app.kill();app.wait()
    if target and target.poll() is None:target.terminate();target.wait(timeout=5)
    d.close()
    print(d.dir,flush=True)
