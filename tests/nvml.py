#!/usr/bin/env python3
"""Optional NVML backend against owned success, denial, missing-ABI and slow libraries."""
import os
from pathlib import Path
import subprocess
import tempfile
root=Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
with tempfile.TemporaryDirectory(prefix='xodb-nvml-', dir=os.environ.get('TMPDIR')) as tmp:
    work=Path(tmp);work.chmod(0o755)
    for name in ('full','absent','legacy'):(work/name).mkdir()
    common=['cc','-std=c11','-Wall','-Wextra','-Werror','-O2']
    subprocess.run([*common,'-shared','-fPIC','tests/nvml-fake.c','-o',str(work/'full/libnvidia-ml.so.1')],check=True)
    subprocess.run([*common,'-DXODB_TEST_NVML_LEGACY','-shared','-fPIC','tests/nvml-fake.c','-o',str(work/'legacy/libnvidia-ml.so.1')],check=True)
    (work/'empty.c').write_text('int empty(void) { return 0; }\n')
    subprocess.run([*common,'-shared','-fPIC',str(work/'empty.c'),'-o',str(work/'absent/libnvidia-ml.so.1')],check=True)
    (work/'no-load.c').write_text('#define _GNU_SOURCE 1\n#include <dlfcn.h>\n#include <string.h>\nvoid *dlopen(const char *n,int f){if(n&&!strcmp(n,"libnvidia-ml.so.1"))return 0;void *(*next)(const char *,int);*(void **)(&next)=dlsym(RTLD_NEXT,"dlopen");return next(n,f);}\n')
    subprocess.run([*common,'-shared','-fPIC',str(work/'no-load.c'),'-ldl','-o',str(work/'no-load.so')],check=True)
    binary=work/'test'
    subprocess.run([*common,'-UNDEBUG','-Isrc/runtime','tests/runtime-nvml.c','src/runtime/sysstat_nvml.c','-pthread','-ldl','-o',str(binary)],check=True)
    for label,library,flag in [('values','full',None),('denied','full','DENY'),('slow','full','SLOW'),('missing ABI','absent','ABSENT'),('missing library','full','LOAD_FAIL'),('init failure','full','INIT_FAIL'),('v1 fallback','legacy','LEGACY')]:
        env=dict(os.environ,LD_LIBRARY_PATH=str(work/library))
        if flag:env['XODB_TEST_NVML_'+flag]='1'
        if flag=='LOAD_FAIL':env.update(XODB_TEST_NVML_ABSENT='1',LD_PRELOAD=str(work/'no-load.so'))
        subprocess.run([str(binary)],env=env,check=True,timeout=5)
        print('PASS NVML '+label,flush=True)
