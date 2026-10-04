#!/usr/bin/env python3
"""Workstation private GUI -> real SSH -> staged native ARM64 fixture."""
from datetime import datetime
from pathlib import Path
import argparse,os,re,subprocess,time,json
root=Path(__file__).resolve().parents[1];os.chdir(root)
p=argparse.ArgumentParser();p.add_argument('--host',default='jetty');p.add_argument('--remote-root',required=True);p.add_argument('--bin',default='.work/remote-build/bin/xodb');args=p.parse_args()
assert args.remote_root.startswith('/') and not args.host.startswith('-')
run=root/'.work'/('gui-remote-ssh-'+datetime.now().strftime('%Y%m%dT%H%M%S%f'));run.mkdir()
for d in ('runtime','tmp','cache','cache/nvidia','cache/mesa'):(run/d).mkdir(mode=0o700,parents=True,exist_ok=True)
env=dict(os.environ)
for key in ('DISPLAY','WAYLAND_DISPLAY','SWAYSOCK','DBUS_SESSION_BUS_ADDRESS'):env.pop(key,None)
env.update(TMPDIR=str(run/'tmp'),XDG_CACHE_HOME=str(run/'cache'),MESA_SHADER_CACHE_DIR=str(run/'cache/mesa'),__GL_SHADER_DISK_CACHE_PATH=str(run/'cache/nvidia'),XDG_RUNTIME_DIR=str(run/'runtime'),WLR_BACKENDS='headless',WLR_HEADLESS_OUTPUTS='1',WLR_LIBINPUT_NO_DEVICES='1',XODB_TEST_PRIVATE_DISPLAY='1')
(run/'sway.conf').write_text('xwayland disable\noutput HEADLESS-1 mode 1280x800\noutput * bg #0b0f16 solid_color\ndefault_border none\nfocus_follows_mouse no\nseat seat0 hide_cursor 100\n')
processes=[]
def wait_for(fn,timeout=20):
    end=time.monotonic()+timeout
    while time.monotonic()<end:
        result=fn()
        if result:return result
        time.sleep(.03)
    raise AssertionError('Timeout; logs in '+str(run))
def states():
    if not (run/'gui.log').exists():return []
    fields=re.findall(r'remote (\S+) pid=(\d+) state=(\S+) generation=(\d+) tid=(\d+) frame=(\d+) symbol=(\S+) line=(\d+)',(run/'gui.log').read_text())
    return [dict(architecture=f[0],pid=int(f[1]),state=f[2],generation=int(f[3]),tid=int(f[4]),frame=int(f[5]),symbol=f[6],line=int(f[7])) for f in fields]
def latest(predicate=lambda s:True):
    rows=states();return rows[-1] if rows and predicate(rows[-1]) else None
def screenshot(name):subprocess.run(['grim',str(run/name)],env=env,check=True,timeout=5)
try:
    with (run/'sway.log').open('wb') as log:sway=subprocess.Popen(['sway','--unsupported-gpu','--config',str(run/'sway.conf')],env=env,stdout=log,stderr=subprocess.STDOUT)
    processes.append(sway);wait_for(lambda:list((run/'runtime').glob('sway-ipc*.sock')))
    env['SWAYSOCK']=str(next((run/'runtime').glob('sway-ipc*.sock')))
    env['WAYLAND_DISPLAY']=next(p.name for p in (run/'runtime').glob('wayland-*') if not p.name.endswith('.lock'))
    protocol='/usr/share/wlr-protocols/unstable/wlr-virtual-pointer-unstable-v1.xml'
    subprocess.run(['wayland-scanner','client-header',protocol,str(run/'virtual-pointer.h')],check=True)
    subprocess.run(['wayland-scanner','private-code',protocol,str(run/'virtual-pointer.c')],check=True)
    pointer=run/'pointer';subprocess.run(['cc','-Wall','-Wextra','-Werror','-I',str(run),'tests/private-pointer.c',str(run/'virtual-pointer.c'),'-lwayland-client','-lm','-o',str(pointer)],check=True)
    def click(x,y):subprocess.run([str(pointer),str(x),str(y),'1280','800'],env=env,check=True,timeout=5)
    command=[str((root/args.bin).resolve()),'--ssh',args.host,'--remote-xodb',args.remote_root+'/zig-out/bin/xodb','--source',args.remote_root+'/tests/fixtures/m1.c','--break','change_value','--',args.remote_root+'/zig-out/bin/xodb-m1-fixture','w']
    (run/'command.json').write_text(json.dumps(command,indent=2)+'\n')
    with (run/'gui.log').open('wb') as log:app=subprocess.Popen(command,env=env,stdout=log,stderr=log)
    processes.append(app)
    initial=wait_for(lambda:latest());assert initial['architecture']=='aarch64',initial
    pid=initial['pid'];time.sleep(.4);click(250,64)
    stepped=wait_for(lambda:latest(lambda s:s['generation']>initial['generation'] and s['state']=='stopped'))
    time.sleep(.2);click(365,64)
    wait_for(lambda:latest(lambda s:s['generation']>stepped['generation'] and s['state']=='stopped'))
    time.sleep(.2);screenshot('00-loader-stepped.png');click(90,64)
    first=wait_for(lambda:latest(lambda s:s['symbol']=='change_value'));time.sleep(.3);screenshot('01-arm-breakpoint.png')
    scroll=max(0,first['line']-6);click(20,132+(10-1-scroll)*23+8)
    wait_for(lambda:latest(lambda s:s['generation']>first['generation']));time.sleep(.2);click(90,64)
    wait_for(lambda:latest(lambda s:s['symbol']=='change_value' and s['line']==10));time.sleep(.3);screenshot('02-arm-locals.png')
    click(700,560+38+23+7);wait_for(lambda:latest(lambda s:s['frame']==1 and s['symbol']=='main'));time.sleep(.2);screenshot('03-arm-caller.png')
    # Inspecting a caller must not hide the next execution stop.
    click(250,64)
    wait_for(lambda:latest(lambda s:s['symbol']=='change_value' and s['line']==11 and s['frame']==0));time.sleep(.3)
    click(845,64);time.sleep(.3);screenshot('04-arm-registers.png')
    app.terminate();assert app.wait(timeout=5)==0
    # Only inspect the owned PID after closing, never signal arbitrary host PIDs.
    time.sleep(.4)
    check=subprocess.run(['ssh','-T','-o','BatchMode=yes','-o','ConnectTimeout=8','-o','StrictHostKeyChecking=yes','-o','ForwardAgent=no',args.host,'test ! -e /proc/'+str(pid)],capture_output=True,timeout=10)
    assert check.returncode==0,'Owned remote fixture survived closing the GUI'
    print('Native ARM64 SSH GUI passed: launch, loader Step/Over, breakpoint, source gutter, locals display, caller selection, source step back to frame 0, ARM registers, GUI close and owned cleanup')
    print(run)
finally:
    (run/'states.json').write_text(json.dumps(states(),indent=2)+'\n')
    for p in reversed(processes):
        if p.poll() is None:
            p.terminate()
            try:p.wait(timeout=5)
            except subprocess.TimeoutExpired:p.kill();p.wait()
