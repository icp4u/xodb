#!/usr/bin/env python3
"""Compile the Lua reader oracle against an explicitly selected debug SDK."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--source',required=True)
p.add_argument('--library',required=True)
p.add_argument('--work',required=True,type=Path)
a=p.parse_args()
root=Path(__file__).resolve().parents[1];os.chdir(root);os.umask(0o022)
work=a.work.resolve();work.mkdir(parents=True,mode=0o755)
exe=work/'reader'
subprocess.run([os.environ.get('CC','cc'),'-std=c11','-g','-O2','-Wall','-Wextra','-Werror',
    '-I'+a.source,'tests/lua-reader.c','src/language/lua.c','src/language/lua_layout.c',
    a.library,'-ldw','-lelf','-lm','-ldl','-o',str(exe)],check=True,timeout=90)
r=subprocess.run([str(exe)],capture_output=True,text=True,timeout=30)
(work/'reader.log').write_text(r.stdout+r.stderr)
assert r.returncode==0,r.stdout+r.stderr
assert '22 values, 9 stacks, 32 exact frame positions passed' in r.stdout,r.stdout
inputs={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(Path(a.source).glob('*.h'))}
inputs[str(Path(a.library))]=hashlib.sha256(Path(a.library).read_bytes()).hexdigest()
(work/'inputs.json').write_text(json.dumps(inputs,indent=2)+'\n')
print(r.stdout.splitlines()[-1])
