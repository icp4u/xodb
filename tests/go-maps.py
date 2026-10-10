#!/usr/bin/env python3
"""Owned optimized Go map storage oracle; no target hash or equality calls."""
import argparse
import ctypes as C
import os
from pathlib import Path
import re
import resource
import signal
import subprocess
import time
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--go',required=True);p.add_argument('--work',type=Path,required=True)
p.add_argument('--strace',action='store_true')
p.add_argument('--experiment',choices=['mapsplitgroup','nomapsplitgroup'],default='mapsplitgroup')
a=p.parse_args();root=Path(__file__).resolve().parents[1];os.chdir(root);os.umask(0o022)
w=a.work.resolve();w.mkdir(parents=True,exist_ok=True);w.chmod(0o755)
resource.setrlimit(resource.RLIMIT_CORE,(0,0))
if C.CDLL(None).prctl(36,1,0,0,0)!=0:raise SystemExit('subreaper unavailable')
env=dict(os.environ,GOCACHE=str(w.parent/'go-maps-cache'),GOPATH=str(w/'gopath'),GOFLAGS='',GOTOOLCHAIN='local',GOMAXPROCS='2',CGO_ENABLED='0',GOEXPERIMENT=a.experiment,XODB_GO_VALUES_WORK=str(w))
start=time.monotonic()
subprocess.run([a.go,'build','-p','2','-o',str(w/'maps'),'tests/fixtures/go/maps.go'],env=env,check=True,timeout=120)
subprocess.run([os.environ.get('CC','cc'),'-std=c11','-O2','-g','-DNDEBUG','-Wall','-Wextra','-Werror','-shared','-fPIC','src/language/go_layout.c','src/language/go_value_layout.c','src/language/go_value.c','src/language/go_map_layout.c','src/language/go_map.c','tests/go-maps-probe.c','tests/go-values-probe.c','-ldw','-lelf','-o',str(w/'maps.so')],check=True,timeout=30)
built=time.monotonic()
command=['gdb','-nx','-q','-batch','-iex','set auto-load off','-iex','set debuginfod enabled off','-ex','set pagination off','-ex','set confirm off','-ex','set may-call-functions off','-ex','set language c','-ex','handle SIGURG nostop noprint pass','-ex','break main.marker','-ex','run','-ex','source tests/go-maps-gdb.py','-ex','kill','--args',str(w/'maps'),str(w/'truth.json')]
if a.strace:
    command=['strace','-s','4096','-qq','-o',str(w/'readonly.strace'),'-e','trace=ptrace,process_vm_readv,process_vm_writev,pread64,pwrite64,pwritev,pwritev2,kill,tgkill,tkill,write',*command]
with (w/'gdb.log').open('w') as log:
    proc=subprocess.Popen(command,env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
    try:rc=proc.wait(timeout=30)
    finally:
        if proc.poll() is None:os.killpg(proc.pid,signal.SIGKILL);proc.wait(timeout=5)
        for task in Path('/proc/self/task').iterdir():
            for raw in (task/'children').read_text().split():
                pid=int(raw)
                try:os.kill(pid,signal.SIGKILL)
                except ProcessLookupError:pass
                try:os.waitpid(pid,0)
                except ChildProcessError:pass
print((w/'gdb.log').read_text(),end='')
if rc:raise SystemExit('GDB oracle failed: '+str(rc))
print(f'go-maps ({a.experiment}): compile {built-start:.2f}s probe {time.monotonic()-built:.2f}s')

if a.strace:
    trace=(w/'readonly.strace').read_text()
    if trace.count('GO_MAPS_READ_BEGIN')!=1 or trace.count('GO_MAPS_READ_END')!=1:raise SystemExit('missing/duplicate audit markers')
    observed=trace.split('GO_MAPS_READ_BEGIN',1)[1].split('GO_MAPS_READ_END',1)[0]
    if not re.search(r'process_vm_readv|pread64|PTRACE_PEEKDATA',observed):raise SystemExit('no audited reads')
    if re.search(r'process_vm_writev\(|pwrite64\(|pwritev2?\(|(?:kill|tgkill|tkill)\(|PTRACE_(?:POKE\w*|SET\w*|CONT|SINGLESTEP|SYSCALL)\b',observed):raise SystemExit('observer mutation')
    print('go-maps: read-only observer interval, target calls disabled')

subprocess.run(['objcopy','--decompress-debug-sections',str(w/'maps'),str(w/'maps-uncompressed')],check=True,timeout=10)
image=(w/'maps-uncompressed').read_bytes();name=b'internal/runtime/maps.ctrlDeleted\0'
if name not in image:raise SystemExit('missing map-only DWARF constant')
(w/'maps-no-control').write_bytes(image.replace(name,b'internal/runtime/maps.ctrlDeleteX\0'))
lib=C.CDLL(str(w/'maps.so'))
lib.probe_map_layout.argtypes=[C.c_char_p,C.c_void_p,C.c_size_t,C.c_void_p];lib.probe_map_layout.restype=C.c_char_p
lib.probe_layout.argtypes=[C.c_char_p,C.c_void_p,C.c_size_t,C.c_void_p];lib.probe_layout.restype=C.c_char_p
buffer=C.create_string_buffer(8192)
reason=lib.probe_map_layout(os.fsencode(w/'maps-no-control'),b'x',1,buffer)
if reason!=b'GoDwarfConstantsUnavailable':raise SystemExit(f'missing map constant: {reason!r}')
reason=lib.probe_layout(os.fsencode(w/'maps-no-control'),b'x',1,buffer)
if reason is not None:raise SystemExit(f'map metadata disabled other profiles: {reason!r}')
print('go-maps: missing map metadata refuses maps, preserves interface/channel/stack profiles')
