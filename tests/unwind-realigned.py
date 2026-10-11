#!/usr/bin/env python3
"""Fast native lane: compiler-aligned CFI preserves exact caller PCs and saved registers."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import time
from client import Client

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--work',type=Path,required=True)
p.add_argument('--binary',type=Path,default=Path('zig-out/bin/xodb'))
p.add_argument('--agent',type=Path)
p.add_argument('--wrong-result',action='store_true',help='plant an incorrect return PC; the oracle must reject it')
a=p.parse_args()
root=Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
w=a.work.resolve();w.mkdir(parents=True,exist_ok=True)
started=time.monotonic()
exe=w/'fixture'
subprocess.run(['cc','-O2','-g','-Wall','-Wextra','-Werror','-fomit-frame-pointer',
                '-fno-optimize-sibling-calls','-mincoming-stack-boundary=3','-Itests',
                '-o',str(exe),'tests/fixtures/unwind-realigned.c'],check=True,timeout=30)
frames=subprocess.check_output(['readelf','--debug-dump=frames',str(exe)],text=True,timeout=30)
(w/'compiler-frames.txt').write_text(frames)
# Prove the compiler emitted the condition this regression needs. The usual
# PLT expression alone does not count; the saved-register rules must exist too.
assert 'DW_CFA_def_cfa_expression' in frames, frames
for name in ('rbp','rbx','r14'):
    assert re.search(r'DW_CFA_expression: r\d+ \('+name+r'\)',frames), name
os.environ['XODB_BIN']=str(a.binary.resolve())
client=Client('control',str(exe),args=[str(w/'oracle')],
              options=['--runtime-agent',str(a.agent.resolve())] if a.agent else [],reply_seconds=15)
report=dict(status='failed',transport='agent' if a.agent else 'host')
try:
    client.stopped()
    client.action('set_breakpoint',symbol='unwind_realign_stop')
    client.continue_initial_stop()
    stopped=client.stopped('breakpoint')
    expected=[int(v,16) for v in (w/'oracle').read_text().splitlines()]
    assert len(expected)==6,expected
    if a.wrong_result:
        expected[0]+=1
    deadline=time.monotonic()+20
    while True:
        stack=client.inspect('get_stack',tid=stopped['pid'])
        if not any(f.get('diagnostic')=='DebugMetadataPending' for f in stack['frames']):
            break
        assert time.monotonic()<deadline,'metadata did not finish'
        time.sleep(.005)
    rows=stack['frames']
    (w/'stack.json').write_text(json.dumps(stack,indent=2)+'\n')
    diagnostics=[dict(symbol=f.get('symbol'),diagnostic=f.get('diagnostic')) for f in rows if f.get('diagnostic')]
    assert not diagnostics,diagnostics
    actual=[f['pc'] for f in rows[2:5]]
    assert actual==expected[:3],dict(expected=expected[:3],actual=actual)
    saved=[rows[3]['registers'][i] for i in (6,3,14)]
    assert saved==expected[3:],dict(expected=expected[3:],actual=saved)
    assert all(f['unwind_method']=='eh_frame' for f in rows[:5]),rows[:5]
    report.update(status='passed',callers=3,saved_registers=['rbp','rbx','r14'],frames=len(rows))
    print('PASS compiler-realigned CFA, exact caller PCs and rbp/rbx/r14 through '+report['transport'],flush=True)
finally:
    (w/'transcript.json').write_text(json.dumps(client.transcript,indent=2)+'\n')
    client.close()
    report['seconds']=time.monotonic()-started
    (w/'results.json').write_text(json.dumps(report,indent=2)+'\n')
    print(w,flush=True)
