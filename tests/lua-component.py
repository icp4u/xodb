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
p.add_argument('--sanitize', action='store_true')
a=p.parse_args()
root=Path(__file__).resolve().parents[1];os.chdir(root);os.umask(0o022)
work=a.work.resolve();work.mkdir(parents=True,mode=0o755)
def run(source, name):
    exe=work/name
    flags=['-fsanitize=address,undefined', '-fno-omit-frame-pointer'] if a.sanitize else []
    subprocess.run([os.environ.get('CC','cc'),'-std=c11','-g','-O2','-Wall','-Wextra','-Werror',
        *flags, '-I'+a.source,source,'src/language/lua.c','src/language/lua_layout.c',
        a.library,'-ldw','-lelf','-lm','-ldl','-o',str(exe)],check=True,timeout=90)
    result=subprocess.run([str(exe)],capture_output=True,text=True,timeout=30)
    (work/(name+'.log')).write_text(result.stdout+result.stderr)
    assert result.returncode==0,result.stdout+result.stderr
    return result
r=run('tests/lua-reader.c','reader')
assert '22 values, 9 stacks, 32 exact frame positions passed' in r.stdout,r.stdout
named=run('tests/lua-locals.c','locals')
assert 'named locals:' in named.stdout and 'callbacks passed' in named.stdout,named.stdout
inputs={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(Path(a.source).glob('*.h'))}
inputs[str(Path(a.library))]=hashlib.sha256(Path(a.library).read_bytes()).hexdigest()
(work/'inputs.json').write_text(json.dumps(inputs,indent=2)+'\n')
print(r.stdout.splitlines()[-1])
print(named.stdout.splitlines()[-1])
