#!/usr/bin/env python3
"""Periodic PE workers: pinned source, publication, cancellation and mutation.

The barrier case holds an actual file read while testing nonblocking poll,
cancel and join. --sanitize instruments the PE reader and worker.
"""
import argparse, json, os, shutil, subprocess, time
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--work',type=Path,required=True)
p.add_argument('--image',type=Path)
p.add_argument('--library',type=Path)
p.add_argument('--sanitize',action='store_true')
a=p.parse_args()
root=Path(__file__).resolve().parents[1];os.chdir(root);os.umask(0o022)
w=a.work.resolve();w.mkdir(parents=True)
start=time.monotonic();rows=[]
def run(name,command,expected=0,timeout=120):
 begin=time.monotonic();result=subprocess.run(command,capture_output=True,text=True,timeout=timeout)
 (w/(name+'.log')).write_text(result.stdout+result.stderr)
 rows.append(dict(name=name,exit=result.returncode,expected=expected,seconds=time.monotonic()-begin,status='pass' if result.returncode==expected else 'fail'))
 (w/'results.json').write_text(json.dumps(dict(checks=rows,elapsed_seconds=time.monotonic()-start),indent=2)+'\n')
 assert result.returncode==expected,rows[-1]
if a.image is None:
 run('fixture',['python3','-B','tests/pe-image.py','--work',str(w/'fixture')])
 a.image=w/'fixture/owned-pe.dll'
if a.library is None:
 a.library=w/'runtime/libxrt.a'
 run('runtime',['make','-C','src/runtime','BUILD='+str(a.library.parent),'-j2',str(a.library)])
exe=w/'check'
flags=['-O1','-fsanitize=address,undefined','-fno-omit-frame-pointer'] if a.sanitize else ['-O2']
run('compile',['clang' if a.sanitize else 'cc','-std=c11','-g','-DNDEBUG','-Wall','-Wextra','-Werror','-Wswitch-enum',*flags,
 'tests/pe-job.c','src/binary/pe_job.c','src/binary/pe.c',str(a.library.resolve()),'-Wl,--wrap=xrt_file_view_read','-pthread','-latomic','-ldl','-o',str(exe)])
for mode in ('plain','cancel','barrier','mutation','wrong-result'):
 image=w/(mode+'.dll');shutil.copyfile(a.image,image)
 run(mode,[str(exe),str(image),mode],expected=-6 if mode=='wrong-result' else 0,timeout=60)
print(json.dumps(dict(status='pass',checks=len(rows),elapsed_seconds=time.monotonic()-start)))
