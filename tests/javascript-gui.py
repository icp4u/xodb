#!/usr/bin/env python3
"""Node Locals/Watch and observer MCP, exclusively on a private compositor."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import time

root=Path(__file__).resolve().parent.parent
os.chdir(root)
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--node',required=True)
p.add_argument('--include',default='/usr/include/node')
p.add_argument('--work',required=True,type=Path)
args=p.parse_args()
work=(args.work/'.work/input-node').resolve();work.mkdir(parents=True,mode=0o755)
spec=importlib.util.spec_from_file_location('private_input',root/'tests/helpers/input.py')
h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)
h.WORK=str(work)
for name in ('tmp','cache/mesa','cache/nvidia'):(work/name).mkdir(parents=True,exist_ok=True)
for xml,stem in ((h.VPTR,'virtual-pointer'),(h.VKBD,'virtual-keyboard')):
    subprocess.run(['wayland-scanner','client-header',xml,str(work/(stem+'.h'))],check=True,timeout=10)
    subprocess.run(['wayland-scanner','private-code',xml,str(work/(stem+'.c'))],check=True,timeout=10)
h.HELPER=str(work/'vinput')
subprocess.run(['cc','-Wall','-Wextra','-Werror','-I',str(work),'tests/helpers/vinput.c',str(work/'virtual-pointer.c'),str(work/'virtual-keyboard.c'),'-lwayland-client','-lxkbcommon','-lm','-o',h.HELPER],check=True,timeout=60)
addon=work/'probe.node'
subprocess.run([os.environ.get('CXX','c++'),'-std=c++20','-g','-O0','-fno-omit-frame-pointer','-fPIC','-shared','-I'+args.include,'-DNODE_GYP_MODULE_NAME=xodb_probe','examples/node-probe.cc','-o',str(addon)],check=True,timeout=90)
target=subprocess.Popen([args.node,'tests/fixtures/javascript/stopped.js'],env=dict(os.environ,XODB_NODE_PROBE=str(addon)),stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
d=None
try:
    assert select.select([target.stdout],[],[],10)[0] and target.stdout.readline()==b'ready\n'
    d=h.Display(str(root),['--agent-scope','control','--attach',str(target.pid),'--source','examples/node-probe.cc'])
    d.tool('set_breakpoint',generation=d.session()['generation'],symbol='xodb_node_stop')
    d.tool('continue',generation=d.session()['generation']);target.stdin.write(b'go\n');target.stdin.flush()
    for i in range(12):
        assert d.stopped('breakpoint')
        if i!=11:d.tool('continue',generation=d.session()['generation'])
    value=d.tool('evaluate_expression',tid=target.pid,frame=0,expression='value')['value']
    assert value['display']=='Array(3) [smi 1, string "two", true]',value
    time.sleep(.3);d.shot('node-array-locals')
    # E, value, Return.
    d.keys('tap',18,'tap',47,'tap',30,'tap',38,'tap',22,'tap',18,'tap',28)
    time.sleep(.3);d.shot('node-array-watch')
    d.keys('tap',66)
    assert d.wait(lambda s:s['agent_scope']=='observe')
    generation=d.session()['generation'];regs=d.tool('get_registers',tid=target.pid)
    logical=d.tool('get_language_stack',tid=target.pid,language='javascript')
    assert logical['segments'][0]['frames'][0]['name']=='inner',logical
    assert d.tool('get_registers',tid=target.pid)==regs and d.session()['generation']==generation
    (work/'results.json').write_text(json.dumps({'status':'pass','value':value,'language_stack':logical},indent=2)+'\n')
    d.app.stdin.close();assert d.app.wait(timeout=10)==0
    if target.poll() is None: target.kill(); target.wait()
    # Reuse only this private compositor to exercise the user-facing script.
    env=dict(d.env,NODE=args.node,NODE_INCLUDE=args.include,XODB=str(root/'zig-out/bin/xodb'))
    with (work/'demo.log').open('wb') as log:
        demo=subprocess.Popen(['scripts/demo-node'],env=env,stdin=subprocess.DEVNULL,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
        try:
            socket=Path(d.runtime)/f'xodb-demo-node-{os.getuid()}'/'session.sock'
            deadline=time.monotonic()+20
            while not socket.exists() and time.monotonic()<deadline:
                assert demo.poll() is None,(work/'demo.log').read_text()
                time.sleep(.1)
            assert socket.exists(),(work/'demo.log').read_text()
            time.sleep(.5)
            outputs=[]
            for iteration in range(2):
                d.keys('tap',57)  # Space: reach the next native probe.
                deadline=time.monotonic()+10
                while time.monotonic()<deadline:
                    result=subprocess.run(['scripts/demo-node','stack'],env=env,capture_output=True,text=True,timeout=10)
                    if result.returncode==0 and '  inspect ' in result.stdout and 'value = ' in result.stdout and result.stdout not in outputs:break
                    time.sleep(.1)
                assert result.returncode==0 and '  inspect ' in result.stdout,result.stdout+result.stderr
                assert result.stdout not in outputs,result.stdout
                outputs.append(result.stdout)
                if not iteration:
                    d.keys('tap',18,'tap',47,'tap',30,'tap',38,'tap',22,'tap',18,'tap',28)
                    time.sleep(.3);d.shot('node-demo-watch')
            (work/'demo-stack.txt').write_text('\n'.join(outputs))
        finally:
            if demo.poll() is None: os.killpg(demo.pid,signal.SIGTERM)
            try:demo.wait(timeout=10)
            except subprocess.TimeoutExpired:os.killpg(demo.pid,signal.SIGKILL);demo.wait()
finally:
    if d:d.close()
    if target.poll() is None:target.kill()
    target.wait(timeout=5)
    (work/'target-stderr.txt').write_bytes(target.stderr.read())
print('Node private GUI checks passed:',work)
