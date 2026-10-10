#!/usr/bin/env python3
"""Compare the bounded C value reader with an owned Emacs's prin1 output."""
import argparse
import json
import os
from pathlib import Path
import resource
import subprocess

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--emacs',type=Path,required=True)
p.add_argument('--work',type=Path,required=True)
p.add_argument('--cc',default='cc')
a=p.parse_args();os.umask(0o022);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
w=a.work.resolve();w.mkdir(mode=0o755,parents=True,exist_ok=False)
root=Path(__file__).resolve().parents[1]
env=dict(os.environ,XDG_CACHE_HOME=str(w/'cache'),XODB_ELISP_READER=str(w/'reader.so'))
with (w/'compile.log').open('w') as log:
    subprocess.run([a.cc,'-D_GNU_SOURCE','-std=c11','-O2','-DNDEBUG','-Wall','-Wextra','-Werror','-shared','-fPIC',
                    'src/language/elisp.c','src/language/elisp_layout.c','tests/elisp-layout-probe.c',
                    '-ldw','-lelf','-o',str(w/'reader.so')],cwd=root,stdout=log,stderr=subprocess.STDOUT,check=True,timeout=60)
for label in ['values','wrong-oracle']:
    e=dict(env,XODB_ELISP_ORACLE=str(w/(label+'-oracle.json')),XODB_ELISP_RESULT=str(w/(label+'-result.json')))
    e.pop('XODB_ELISP_WRONG_ORACLE',None)
    if label=='wrong-oracle':e['XODB_ELISP_WRONG_ORACLE']='1'
    command=['gdb','-nx','-q','-batch','-iex','set auto-load off','-iex','set debuginfod enabled off',
             '-ex','set may-call-functions off','-ex','set disable-randomization off','-ex','set startup-with-shell off',
             '-ex','break Fdebugger_trap','-ex','run','-ex','source '+str(root/'tests/elisp-values-memory.py'),'-ex','continue',
             '--args',str(a.emacs.resolve()),'-Q','--batch','-l',str(root/'tests/fixtures/elisp/values.el')]
    with (w/(label+'.log')).open('w') as log:r=subprocess.run(command,cwd=root,env=e,stdout=log,stderr=subprocess.STDOUT,timeout=180)
    text=(w/(label+'.log')).read_text()
    if r.returncode != (1 if label=='wrong-oracle' else 0):raise RuntimeError(label+': see '+str(w/(label+'.log')))
    if label=='wrong-oracle' and 'prin1 mismatch' not in text:raise RuntimeError('wrong oracle unrelated failure: '+text)
print('elisp values: primary prin1 comparisons, bounded/cyclic objects, corrupt header and wrong oracle PASS')
