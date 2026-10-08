#!/usr/bin/env python3
"""Exercise the private range cache independently of an actual debug image."""
import argparse
import os
from pathlib import Path
import subprocess
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--work',required=True,type=Path);p.add_argument('--sanitize',action='store_true')
a=p.parse_args();os.umask(0o022);root=Path(__file__).resolve().parents[1];os.chdir(root)
w=a.work.resolve();w.mkdir(mode=0o755,parents=True,exist_ok=True)
flags=['-O1','-fsanitize=address,undefined','-fno-omit-frame-pointer'] if a.sanitize else ['-O2']
exe=w/'cache'
subprocess.run(['clang' if a.sanitize else 'cc','-std=c11','-g',*flags,'-Wall','-Wextra','-Werror','tests/object-cache.c','src/binary/object_cache.c','-o',str(exe)],check=True,timeout=60)
r=subprocess.run([str(exe),str(w/'owned.cache')],capture_output=True,text=True,timeout=60)
(w/'results.log').write_text(r.stdout+r.stderr);print(r.stdout,end='');assert r.returncode==0,r.stderr
