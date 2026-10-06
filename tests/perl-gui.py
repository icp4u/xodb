#!/usr/bin/env python3
"""Perl Locals/Watch and observer MCP on a private headless compositor.
First run perl-language.py. Pass its output as --fixtures and a NEW SHORT
work path as --work so the private compositor's Unix sockets fit sun_path.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import select
import subprocess
import time

root = Path(__file__).resolve().parent.parent
os.chdir(root)
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--perl', required=True)
p.add_argument('--fixtures', required=True, type=Path)
p.add_argument('--work', required=True, type=Path)
args = p.parse_args()
work=(args.work/".work/input-perl").resolve();work.mkdir(parents=True,mode=0o755)
spec=importlib.util.spec_from_file_location('private_input',root/'tests/helpers/input.py')
h=importlib.util.module_from_spec(spec);spec.loader.exec_module(h)
h.WORK=str(work)
for name in ('tmp','cache/mesa','cache/nvidia'): (work/name).mkdir(parents=True,exist_ok=True)
for xml,stem in ((h.VPTR,'virtual-pointer'),(h.VKBD,'virtual-keyboard')):
    subprocess.run(['wayland-scanner','client-header',xml,str(work/(stem+'.h'))],check=True,timeout=10)
    subprocess.run(['wayland-scanner','private-code',xml,str(work/(stem+'.c'))],check=True,timeout=10)
h.HELPER=str(work/'vinput')
subprocess.run(['cc','-Wall','-Wextra','-Werror','-I',str(work),'tests/helpers/vinput.c',str(work/'virtual-pointer.c'),str(work/'virtual-keyboard.c'),'-lwayland-client','-lxkbcommon','-lm','-o',h.HELPER],check=True,timeout=60)
checks=[]
for mode,expression,keys,expected in [('array','val',[47,30,38],'undef ('),('values','integer',[23,49,20,18,34,18,19],'IV 42 (')]:
    target=subprocess.Popen([args.perl,'tests/fixtures/perl/stopped.pl',mode,str(args.fixtures.resolve()/'values.so'),str(work/(mode+'.jsonl'))],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    d=None
    try:
        assert select.select([target.stdout],[],[],10)[0]
        assert target.stdout.readline()==b'ready\n'
        d=h.Display(str(root),['--agent-scope','control','--attach',str(target.pid),'--source','tests/fixtures/perl/values.c'])
        if mode=='array': d.tool('set_breakpoint',generation=d.session()['generation'],symbol='Perl_av_store')
        else:
            source=Path('tests/fixtures/perl/values.c')
            line=next(i for i,s in enumerate(source.read_text().splitlines(),1) if '__asm__ volatile' in s)
            d.tool('set_breakpoint',generation=d.session()['generation'],file=str(source),line=line)
        d.tool('continue',generation=d.session()['generation']);target.stdin.write(b'go\n');target.stdin.flush()
        snap=d.stopped('breakpoint');assert snap
        regs=d.tool('get_registers',tid=target.pid)
        value=d.tool('evaluate_expression',tid=target.pid,frame=0,expression=expression)['value']
        locals=d.tool('list_locals',tid=target.pid,frame=0)['locals']
        assert value['display'].startswith(expected),value
        assert next(v for v in locals if v['name']==expression)['value']['display']==value['display']
        time.sleep(.3);d.shot(mode+'-locals')
        sequence=['tap',18]
        for key in keys: sequence.extend(['tap',key])
        sequence.extend(['tap',28]);d.keys(*sequence)
        time.sleep(.3);d.shot(mode+'-watch')
        assert d.tool('get_registers',tid=target.pid)==regs and d.session()['generation']==snap['generation']
        d.keys('tap',66)
        assert d.wait(lambda s:s['agent_scope']=='observe')
        observer_generation=d.session()['generation']
        observer_regs=d.tool('get_registers',tid=target.pid)
        logical=d.tool('get_language_stack',tid=target.pid,language='perl')
        assert logical['segments'],logical
        assert d.tool('get_registers',tid=target.pid)==observer_regs and d.session()['generation']==observer_generation
        (work/(mode+'-results.json')).write_text(json.dumps({'value':value,'locals':locals,'language_stack':logical},indent=2)+'\n')
        subprocess.run(['swaymsg','output','HEADLESS-1','mode','1600x1000'],env=d.env,check=True,capture_output=True,timeout=5)
        time.sleep(.3);d.shot(mode+'-watch-large')
        d.app.stdin.close();assert d.app.wait(timeout=10)==0
        checks.append(mode+' locals, expression watch, observer stack, unchanged registers/generation, clean shutdown')
    finally:
        if d:d.close()
        if target.poll() is None:target.terminate()
        try:target.wait(timeout=5)
        except subprocess.TimeoutExpired:target.kill();target.wait()
        (work/(mode+'-stderr.txt')).write_bytes(target.stderr.read())
(work/'results.json').write_text(json.dumps({'pass':checks,'fail':[]},indent=2)+'\n')
print('Perl private GUI checks passed:',work)
