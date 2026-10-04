#!/usr/bin/env python3
"""Finish through recursion and run-to probe ownership on an owned fixture."""
from datetime import datetime
import os
from pathlib import Path
import subprocess
from client import Client
root=Path(__file__).resolve().parents[1]
os.chdir(root)
run=root/'.work'/('run-control-'+datetime.now().strftime('%Y%m%dT%H%M%S%f'))
run.mkdir(parents=True)
source=root/'tests/fixtures/run-control.c'
binary=run/'fixture'
subprocess.run(['gcc','-g','-O0','-fno-omit-frame-pointer',str(source),'-o',str(binary)],check=True,env=dict(os.environ,TMPDIR=str(root/'.work/tmp')))
line=next(i for i,s in enumerate(source.read_text().splitlines(),1) if 'LEAF_STOP' in s)
c=Client('control',str(binary))
try:
    ids=c.action('set_breakpoint',file=str(source),line=line)['ids']
    c.action('continue')
    tid=c.stopped('breakpoint')['threads'][0]['tid']
    assert c.inspect('evaluate_expression',tid=tid,expression='depth')['value']['display']=='0'
    for b in ids: c.action('remove_breakpoint',id=b)
    c.action('finish',tid=tid,frame=1)
    snap=c.stopped()
    assert snap['running_to'] is None,snap
    assert c.inspect('evaluate_expression',tid=tid,expression='depth')['value']['display']=='2'
    assert not c.inspect('get_breakpoints')['breakpoints']
    end=c.inspect('find_symbol',name='finished')['address']
    shared=c.action('set_breakpoint',address=end)['id']
    c.action('run_to',tid=tid,address=end)
    assert c.stopped()['running_to'] is None
    regs=c.inspect('get_registers',tid=tid)['registers']
    assert regs['rip']==end,(regs,end)
    assert c.inspect('get_breakpoints')['breakpoints'][0]['id']==shared
    assert c.inspect('evaluate_expression',tid=tid,expression='answer')['value']['display']=='15'
finally:c.close()
print('Finish through recursive return sites, run-to and shared probe ownership passed:',run)
