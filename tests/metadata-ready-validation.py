#!/usr/bin/env python3
"""Fast component: ready metadata cannot report background transport contention."""
import argparse, json, os, pathlib, subprocess, time
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--work',type=pathlib.Path,default=pathlib.Path('.work/metadata-ready'))
p.add_argument('--metadata-source',type=pathlib.Path)
a=p.parse_args();os.umask(0o022);a.work.mkdir(parents=True,exist_ok=True,mode=0o755)
start=time.monotonic();exe=a.work.resolve()/'check'
subprocess.run(['cc','-std=c11','-O2','-g','-ffunction-sections','-fdata-sections','-Wall','-Wextra','-Werror',
    *(['-DXODB_METADATA_SOURCE="'+str(a.metadata_source.resolve())+'"'] if a.metadata_source else []),
    'tests/metadata-ready-validation.c','-Wl,--gc-sections','-pthread','-o',str(exe)],check=True,timeout=30)
r=subprocess.run([str(exe)],capture_output=True,text=True,timeout=10)
(a.work/'positive.log').write_text(r.stdout+r.stderr)
assert r.returncode==0,(r.returncode,r.stdout,r.stderr)
n=subprocess.run([str(exe),'--wrong-result'],capture_output=True,text=True,timeout=10)
(a.work/'wrong-result.log').write_text(n.stdout+n.stderr)
assert n.returncode!=0 and 'CHECK failed: status ==' in n.stderr,(n.returncode,n.stderr)
result=dict(status='pass',background_contention_observed=True,ready_result='ready',changed_bytes='permanently refused',wrong_result='rejected',seconds=time.monotonic()-start)
(a.work/'results.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
