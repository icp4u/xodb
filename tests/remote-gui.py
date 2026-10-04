#!/usr/bin/env python3
"""Private Sway GUI exercise through a recording TCP proxy. Never uses desktop."""
from datetime import datetime
import argparse,json,os,select,socket,subprocess,threading,time,shlex,runpy
from pathlib import Path
root=Path(__file__).resolve().parents[1];os.chdir(root)
parser=argparse.ArgumentParser();parser.add_argument('--bin',default='.work/remote-build/bin')
parser.add_argument('--running-panes',action='store_true',help='Verify retained stopped panes and live Interrupt while the owned host fixture runs')
parser.add_argument('--idle-workspace',action='store_true',help='Exercise hidden-window pacing and shutdown instead of the stepping walkthrough')
parser.add_argument('--server-host');parser.add_argument('--server-root');parser.add_argument('--server-address',default='127.0.0.1')
parser.add_argument('--android-bundle',type=Path,help='Deploy the owned Android demo over USB (device writes; see docs/ANDROID.md)')
args=parser.parse_args()
if args.android_bundle and args.server_host:parser.error('Choose Android USB or SSH')
if args.running_panes and (args.android_bundle or args.server_host or args.idle_workspace):parser.error('--running-panes uses only the owned host fixture')
binary=(root/args.bin/'xodb').resolve()
run=root/'.work'/('gui-remote-'+datetime.now().strftime('%Y%m%dT%H%M%S%f'));run.mkdir()
for directory in ('runtime','tmp','cache','cache/nvidia','cache/mesa'): (run/directory).mkdir(mode=0o700,parents=True,exist_ok=True)
env=dict(os.environ)
for key in ('DISPLAY','WAYLAND_DISPLAY','SWAYSOCK','DBUS_SESSION_BUS_ADDRESS'):env.pop(key,None)
env.update(TMPDIR=str(run/'tmp'),XDG_CACHE_HOME=str(run/'cache'),MESA_SHADER_CACHE_DIR=str(run/'cache/mesa'),__GL_SHADER_DISK_CACHE_PATH=str(run/'cache/nvidia'),XDG_RUNTIME_DIR=str(run/'runtime'),WLR_BACKENDS='headless',WLR_HEADLESS_OUTPUTS='1',WLR_LIBINPUT_NO_DEVICES='1')
(run/'sway.conf').write_text('xwayland disable\noutput HEADLESS-1 mode 1280x800\noutput * bg #0b0f16 solid_color\ndefault_border none\nfocus_follows_mouse no\nseat seat0 hide_cursor 100\n')
processes=[];sockets=[];transcript=[];view_lock=threading.Lock();latest=None;failure=[];device=None
def wait_for(fn,timeout=15):
    end=time.monotonic()+timeout
    while time.monotonic()<end:
        value=fn()
        if value:return value
        if failure:raise AssertionError(failure)
        time.sleep(.03)
    raise AssertionError('Timeout; logs in '+str(run))
def get_view(predicate=lambda v:True):
    with view_lock:return latest if latest and predicate(latest) else None
def screenshot(name):
    subprocess.run(['grim',str(run/name)],env=env,check=True,timeout=5)
def free_port():
    with socket.socket() as s:s.bind(('127.0.0.1',0));return s.getsockname()[1]
try:
    with (run/'sway.log').open('wb') as log: sway=subprocess.Popen(['sway','--unsupported-gpu','--config',str(run/'sway.conf')],env=env,stdout=log,stderr=subprocess.STDOUT)
    processes.append(sway)
    wait_for(lambda:list((run/'runtime').glob('sway-ipc*.sock')))
    env['SWAYSOCK']=str(next((run/'runtime').glob('sway-ipc*.sock')))
    env['XODB_TEST_PRIVATE_DISPLAY']='1'
    env['WAYLAND_DISPLAY']=next(p.name for p in (run/'runtime').glob('wayland-*') if not p.name.endswith('.lock'))
    protocol='/usr/share/wlr-protocols/unstable/wlr-virtual-pointer-unstable-v1.xml'
    subprocess.run(['wayland-scanner','client-header',protocol,str(run/'virtual-pointer.h')],check=True)
    subprocess.run(['wayland-scanner','private-code',protocol,str(run/'virtual-pointer.c')],check=True)
    pointer=run/'pointer'
    subprocess.run(['cc','-Wall','-Wextra','-Werror','-I',str(run),'tests/private-pointer.c',str(run/'virtual-pointer.c'),'-lwayland-client','-lm','-o',str(pointer)],check=True)
    def click(x,y):subprocess.run([str(pointer),str(x),str(y),'1280','800'],env=env,check=True,timeout=5)
    if args.android_bundle:
        DeviceDemo=runpy.run_path(str(root/'scripts/demo-android'))['DeviceDemo']
        device=DeviceDemo(args.android_bundle,90)
        device.start()
        port=device.port
        args.server_address='127.0.0.1'
        server=device.server
        write_line=next(i for i,s in enumerate((args.android_bundle/'demo.c').read_text().splitlines(),1) if 'WATCH_WRITE' in s)
    else:
        port=free_port()
        server_log=(run/'server.log').open('wb')
        target_binary=str(binary) if not args.server_host else args.server_root+'/zig-out/bin/xodb'
        target_fixture=str(binary.parent/'xodb-m1-fixture') if not args.server_host else args.server_root+'/zig-out/bin/xodb-m1-fixture'
        target_source='tests/fixtures/m1.c' if not args.server_host else args.server_root+'/tests/fixtures/m1.c'
        command=[target_binary,'--headless','--mcp','--listen',f'{args.server_address}:{port}','--agent-scope','control','--source',target_source,'--break','change_value','--',target_fixture,'w']
        if args.server_host: command=['ssh','-T','-o','BatchMode=yes','-o','ForwardAgent=no','-o','StrictHostKeyChecking=yes','-o','ConnectTimeout=8',args.server_host,'exec '+shlex.join(command)]
        server=subprocess.Popen(command,stdout=server_log,stderr=server_log)
        processes.append(server)
        wait_for(lambda:'listening on' in (run/'server.log').read_text())
        write_line=10
    listener=socket.socket();listener.bind(('127.0.0.1',0));listener.listen(1);sockets.append(listener)
    proxy_port=listener.getsockname()[1]
    requests={}
    def relay(src,dst,direction):
        global latest
        buf=b''
        try:
            while True:
                data=src.recv(65536)
                if not data:break
                dst.sendall(data);buf+=data
                while b'\n' in buf:
                    line,buf=buf.split(b'\n',1);msg=json.loads(line)
                    with view_lock:
                        transcript.append({'direction':direction,'message':msg})
                        if direction=='request' and 'id' in msg:requests[msg['id']]=msg
                        if direction=='response' and msg.get('id') in requests:
                            req=requests[msg['id']]
                            if req.get('params',{}).get('name')=='get_debug_view' and not req.get('params',{}).get('arguments',{}).get('summary_only'):
                                result=msg.get('result',{}).get('structuredContent')
                                if result:latest=result
        except OSError:pass
        except Exception as exc:failure.append(str(exc))
        finally:
            try:dst.shutdown(socket.SHUT_WR)
            except OSError:pass
    def proxy():
        client,_=listener.accept();upstream=socket.create_connection((args.server_address,port));sockets.extend([client,upstream])
        t=threading.Thread(target=relay,args=(client,upstream,'request'),daemon=True);t.start()
        relay(upstream,client,'response');t.join(2)
    proxy_thread=threading.Thread(target=proxy,daemon=True);proxy_thread.start()
    with (run/'gui.log').open('wb') as log:app=subprocess.Popen([str(binary),'--connect',f'127.0.0.1:{proxy_port}'],env=env,stdout=log,stderr=log)
    processes.append(app)
    initial=wait_for(lambda:get_view());pid=initial['pid']
    if args.idle_workspace:
        time.sleep(.5);screenshot('idle-before.png')
        subprocess.run(['swaymsg','workspace','number','2'],env=env,check=True,capture_output=True)
        time.sleep(8)
        assert app.poll() is None,(run/'gui.log').read_text()
        assert 'frame deferred, event loop remains active' in (run/'gui.log').read_text()
        subprocess.run(['swaymsg','workspace','number','1'],env=env,check=True,capture_output=True)
        wait_for(lambda:'compositor frame callback ready after' in (run/'gui.log').read_text())
        time.sleep(.2);screenshot('idle-restored.png')
        # A real GUI action after restoration proves that input still reaches
        # the remote target. This variant deliberately skips loader stepping.
        click(90,64)
        first=wait_for(lambda:get_view(lambda v:v['frames'] and v['frames'][0]['symbol']=='change_value'))
        time.sleep(.2);screenshot('idle-breakpoint.png')
        subprocess.run(['swaymsg','workspace','number','2'],env=env,check=True,capture_output=True)
        time.sleep(2)
        before=time.monotonic();app.terminate();assert app.wait(timeout=5)==0
        elapsed=(time.monotonic()-before)*1000
        if device:device.close()
        else:assert server.wait(timeout=10)==0,(run/'server.log').read_text()
        if device:
            assert device.adb('shell','sh','-c',shlex.quote(f'test ! -e /proc/{pid} && echo gone'))=='gone'
        elif args.server_host:
            check=subprocess.run(['ssh','-T','-o','BatchMode=yes','-o','ForwardAgent=no','-o','StrictHostKeyChecking=yes','-o','ConnectTimeout=8',args.server_host,'test ! -e /proc/'+str(pid)],capture_output=True,timeout=10)
            assert check.returncode==0,'Owned remote target survived EOF'
        else:assert not Path(f'/proc/{pid}').exists(),'Owned target survived EOF'
        print('Private remote idle GUI passed: hidden workspace, restore, GUI continue to breakpoint, signal shutdown while hidden and owned-target cleanup')
        print(json.dumps({'exit_ms':elapsed,'generation':first['generation']}))
        print(run)
        raise SystemExit(0)
    # Start in the loader, which has assembly/registers but no source line.
    assert not initial['frames'] or initial['frames'][0]['source'] is None,initial
    def pc(v): return next(r['value'] for r in v['registers'] if r['name'] in ('pc','rip'))
    time.sleep(.5);click(250,64)
    stepped=wait_for(lambda:get_view(lambda v:v['state']=='stopped' and v['registers'] and v['generation']>initial['generation'] and pc(v)!=pc(initial)))
    time.sleep(.2);click(365,64)
    wait_for(lambda:get_view(lambda v:v['state']=='stopped' and v['registers'] and v['generation']>stepped['generation'] and pc(v)!=pc(stepped)))
    time.sleep(.2);screenshot('00-loader-stepped.png')
    # The shared source must accept gutter breakpoints before any frame maps to
    # that source (including a relocated ./demo.c on the Android service).
    def has_source_probe(v):
        return any(p.get('source',{}).get('line')==write_line for p in v['breakpoints'] if p.get('source'))
    source_y=132+(write_line-1)*23+8
    click(20,source_y)
    armed_source=wait_for(lambda:get_view(has_source_probe))
    assert not armed_source['frames'] or armed_source['frames'][0]['source'] is None
    time.sleep(.2);screenshot('00a-loader-source-breakpoint.png')
    click(20,source_y)
    wait_for(lambda:get_view(lambda v:v['generation']>armed_source['generation'] and not has_source_probe(v)))
    time.sleep(.2);click(20,source_y)
    wait_for(lambda:get_view(has_source_probe));time.sleep(.2)
    click(90,64)
    first=wait_for(lambda:get_view(lambda v:v['frames'] and v['frames'][0]['symbol']=='change_value'))
    time.sleep(.3);screenshot('01-breakpoint.png')
    entry_line=first['frames'][0]['source']['line']
    # The breakpoint set in the loader survives entry and actually catches the store.
    assert has_source_probe(first)
    time.sleep(.2);click(90,64)
    at_line=wait_for(lambda:get_view(lambda v:v['frames'] and v['frames'][0].get('source',{}).get('line')==write_line))
    assert {v['name']:v['display'] for v in at_line['locals']}['next']=='12',at_line
    time.sleep(.2);screenshot('02-locals.png')
    if args.running_panes:
        from PIL import Image, ImageChops
        # Keep the initialized source locals, then let both calls complete and
        # leave the owned fixture sleeping. No device or remote-host access.
        scroll=max(0,write_line-6)
        click(20,132+(entry_line-1-scroll)*23+8)
        # The loader rendezvous can coexist with the remaining source probe.
        wait_for(lambda:get_view(lambda v:has_source_probe(v) and not any(
            p['source'] and p['source']['line']==entry_line for p in v['breakpoints'])));time.sleep(.2)
        click(20,132+(write_line-1-scroll)*23+8)
        saved=wait_for(lambda:get_view(lambda v:not v['breakpoints']));time.sleep(.3)
        screenshot('running-00-stopped.png')
        click(845,64);time.sleep(.3);screenshot('running-00-registers.png')
        click(845,64);time.sleep(.2);click(90,64)
        running=wait_for(lambda:get_view(lambda v:v['state']=='running'))
        assert not running['frames'] and not running['locals'] and running['source'] is None,running
        crops={'source':(10,128,582,550),'assembly':(590,128,951,550),
               'locals':(962,128,1269,550),'stack':(590,594,1269,760)}
        comparison={}
        with Image.open(run/'running-00-stopped.png') as before:
            for index in range(3):
                time.sleep(.4);name=f'running-0{index+1}.png';screenshot(name)
                with Image.open(run/name) as after:
                    comparison[name]={key:ImageChops.difference(before.crop(box),after.crop(box)).getbbox() is None for key,box in crops.items()}
                assert all(comparison[name].values()),comparison
        # Stale values/frames must not send target mutations or selections.
        marker=len(transcript)
        click(1010,150);click(999,64);click(250,64);click(700,607);time.sleep(.25)
        requests_after=[t['message'].get('params',{}).get('name') for t in transcript[marker:] if t['direction']=='request' and t['message'].get('method')=='tools/call']
        assert all(name=='get_debug_view' for name in requests_after),requests_after
        click(845,64);time.sleep(.25);screenshot('running-04-registers.png')
        with Image.open(run/'running-00-registers.png') as before, Image.open(run/'running-04-registers.png') as after:
            assert ImageChops.difference(before.crop(crops['locals']),after.crop(crops['locals'])).getbbox() is None
        # Interrupt must use the running generation and produce fresh inspection.
        click(90,64)
        resumed=wait_for(lambda:get_view(lambda v:v['state']=='stopped' and v['generation']>running['generation']))
        assert resumed['registers'] and resumed['frames']
        assert resumed['frames'][0]['pc']!=saved['frames'][0]['pc']
        time.sleep(.3);screenshot('running-05-interrupted.png')
        result={'checks':'three running frames preserve source/assembly/locals/stack; register toggle; stale actions blocked; live interrupt refreshes inspection',
                'body_comparisons':comparison,'stopped_generation':saved['generation'],'running_generation':running['generation'],'interrupted_generation':resumed['generation']}
        (run/'running-results.json').write_text(json.dumps(result,indent=2)+'\n')
        app.terminate();assert app.wait(timeout=5)==0
        assert server.wait(timeout=10)==0
        assert not Path(f'/proc/{pid}').exists(),'Owned target survived EOF'
        print(json.dumps(result,indent=2));print(run)
        raise SystemExit(0)
    # Arm a watch through the real GUI, catch the next call's new local value,
    # inspect the watch list, then remove it. The stack slot stays at one address.
    local_index=next(i for i,v in enumerate(at_line['locals']) if v['name']=='next')
    assert at_line['locals'][local_index]['address'] is not None,at_line
    click(1010,132+46*local_index+8);click(999,64)
    armed=wait_for(lambda:get_view(lambda v:len(v.get('watchpoints',[]))==1));time.sleep(.2)
    click(90,64)
    wait_for(lambda:get_view(lambda v:v['generation']>armed['generation'] and v['state']=='stopped' and v['frames'] and v['frames'][0].get('source',{}).get('line')==entry_line));time.sleep(.2)
    click(90,64)
    hit=wait_for(lambda:get_view(lambda v:any(h['after']==21 for h in v.get('watch_hits',[]))))
    assert hit['watch_hits'][0]['before']==12,hit
    if hit['architecture']=='aarch64':
        assert hit['watch_hits'][0]['phase']=='completed' and hit['watch_hits'][0]['trap_pc']+4==hit['watch_hits'][0]['pc'],hit
    time.sleep(.2);screenshot('02a-watch-hit.png');click(1130,64);time.sleep(.2);screenshot('02b-watches.png')
    click(1020,140);click(999,64)
    wait_for(lambda:get_view(lambda v:v['generation']>hit['generation'] and not v.get('watchpoints')));time.sleep(.2);click(1130,64)
    click(700,560+38+23+7)
    wait_for(lambda:get_view(lambda v:v['frame']==1));time.sleep(.2);screenshot('03-caller.png')
    # Stepping while inspecting the caller must return inspection to frame 0.
    click(250,64)
    wait_for(lambda:get_view(lambda v:v['frames'] and v['frames'][0].get('source',{}).get('line')==write_line+1 and v['frame']==0));time.sleep(.2)
    click(845,64);time.sleep(.2);screenshot('04-registers.png')
    # Break the transport deliberately while the GUI remains open.
    with view_lock: last_generation=latest['generation']
    sockets[-1].shutdown(socket.SHUT_RDWR);sockets[-1].close()
    wait_for(lambda:'remote connection ended' in (run/'gui.log').read_text());time.sleep(.4)
    screenshot('05-disconnected.png')
    assert app.poll() is None,'GUI exited on network loss'
    if device:device.close()
    else:assert server.wait(timeout=10)==0,(run/'server.log').read_text()
    if device:
        assert device.adb('shell','sh','-c',shlex.quote(f'test ! -e /proc/{pid} && echo gone'))=='gone'
    elif args.server_host:
        check=subprocess.run(['ssh','-T','-o','BatchMode=yes','-o','ForwardAgent=no','-o','StrictHostKeyChecking=yes','-o','ConnectTimeout=8',args.server_host,'test ! -e /proc/'+str(pid)],capture_output=True,timeout=10)
        assert check.returncode==0,'Owned remote target survived EOF'
    else: assert not Path(f'/proc/{pid}').exists(),'Owned target survived EOF'
    before=sum(1 for t in transcript if t['direction']=='request' and t['message'].get('params',{}).get('name')=='continue')
    click(90,64);time.sleep(.2)
    after=sum(1 for t in transcript if t['direction']=='request' and t['message'].get('params',{}).get('name')=='continue')
    assert before==after,'Disconnected GUI sent another action'
    app.terminate();assert app.wait(timeout=5)==0
    print('Private remote GUI passed: TCP handshake, loader Step/Over, source gutter add/remove/re-add before entry, continue, source breakpoint hit, locals, GUI hardware watch/create/hit/remove, caller selection, source step back to frame 0, registers, disconnect responsiveness and cleanup')
    print(run)
finally:
    (run/'transcript.json').write_text(json.dumps(transcript,indent=2)+'\n')
    for s in sockets:
        try:s.close()
        except OSError:pass
    for p in reversed(processes):
        if p.poll() is None:
            p.terminate()
            try:p.wait(timeout=5)
            except subprocess.TimeoutExpired:p.kill();p.wait()

    if device:device.close()
