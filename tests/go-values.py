#!/usr/bin/env python3
"""Owned Go interfaces/channels through the C reader; fast host lane after
compiler-cache warmup. Cold Go compilation is bounded separately."""
import argparse
import ctypes as C
import re
import resource
import signal
import os
from pathlib import Path
import subprocess
import time

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--go',required=True)
p.add_argument('--work',type=Path,required=True)
p.add_argument('--strace',action='store_true')
a=p.parse_args()
root=Path(__file__).resolve().parents[1]
os.chdir(root); os.umask(0o022)
w=a.work.resolve(); w.mkdir(parents=True,exist_ok=True); w.chmod(0o755)
env=dict(os.environ,GOCACHE=str(w.parent/'go-values-cache'),GOPATH=str(w/'gopath'),GOFLAGS='',GOTOOLCHAIN='local',GOMAXPROCS='2',CGO_ENABLED='0',XODB_GO_VALUES_WORK=str(w))
resource.setrlimit(resource.RLIMIT_CORE,(0,0))
# Adopt only this runner's owned children if a debugger dies at its deadline.
if C.CDLL(None).prctl(36,1,0,0,0) != 0: raise SystemExit('subreaper unavailable')
start=time.monotonic()
subprocess.run([a.go,'build','-p','2','-o',str(w/'values'),'tests/fixtures/go/values.go'],env=env,check=True,timeout=120)
subprocess.run([os.environ.get('CC','cc'),'-std=c11','-O2','-g','-DNDEBUG','-Wall','-Wextra','-Werror','-shared','-fPIC','src/language/go_layout.c','src/language/go_value_layout.c','src/language/go_value.c','tests/go-values-probe.c','-ldw','-lelf','-o',str(w/'values.so')],check=True,timeout=30)
built=time.monotonic()
command=['gdb','-nx','-q','-batch','-iex','set auto-load off','-iex','set debuginfod enabled off','-ex','set pagination off','-ex','set confirm off','-ex','set may-call-functions off','-ex','set language c','-ex','handle SIGURG nostop noprint pass','-ex','break main.marker','-ex','run','-ex','source tests/go-values-gdb.py','-ex','kill','--args',str(w/'values'),str(w/'truth.json')]
if a.strace:
    command=['strace','-s','4096','-qq','-o',str(w/'readonly.strace'),'-e','trace=ptrace,process_vm_readv,process_vm_writev,pread64,pwrite64,pwritev,pwritev2,kill,tgkill,tkill,write',*command]
with (w/'gdb.log').open('w') as log:
    proc=subprocess.Popen(command,env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
    try:
        rc=proc.wait(timeout=30)
    finally:
        if proc.poll() is None:
            os.killpg(proc.pid,signal.SIGKILL); proc.wait(timeout=5)
        # GDB normally kills its inferior. Catch any child orphaned at timeout.
        for task in Path('/proc/self/task').iterdir():
            for raw in (task/'children').read_text().split():
                pid=int(raw)
                try: os.kill(pid,signal.SIGKILL)
                except ProcessLookupError: pass
                try: os.waitpid(pid,0)
                except ChildProcessError: pass
print((w/'gdb.log').read_text(),end='')
if rc: raise SystemExit(f'gdb failed: {rc}')
if a.strace:
    trace=(w/'readonly.strace').read_text()
    if trace.count('GO_VALUES_READ_BEGIN') != 1 or trace.count('GO_VALUES_READ_END') != 1:
        raise SystemExit('read audit markers missing/duplicated')
    observed=trace.split('GO_VALUES_READ_BEGIN',1)[1].split('GO_VALUES_READ_END',1)[0]
    if not re.search(r'process_vm_readv|pread64|PTRACE_PEEKDATA',observed):
        raise SystemExit('read audit did not observe reads')
    if re.search(r'process_vm_writev\(|pwrite64\(|pwritev2?\(|(?:kill|tgkill|tkill)\(|PTRACE_(?:POKE\w*|SET\w*|CONT|SINGLESTEP|SYSCALL)\b',observed):
        raise SystemExit('read audit saw mutation')
    print('go-values: strace confirms read-only observer interval')
print(f'go-values: compile {built-start:.2f}s, probe {time.monotonic()-built:.2f}s')

# A missing value constant must disable only that profile; stripped metadata
# must refuse, never fall back to guessed runtime offsets.
subprocess.run(['objcopy','--decompress-debug-sections',str(w/'values'),str(w/'values-uncompressed')],check=True,timeout=10)
image=(w/'values-uncompressed').read_bytes()
name=b'internal/abi.TFlagDirectIface\0'
if name not in image: raise SystemExit('missing fixture DWARF constant')
(w/'values-no-direct').write_bytes(image.replace(name,b'internal/abi.TFlagDirectIfacX\0'))
subprocess.run(['objcopy','--strip-debug',str(w/'values'),str(w/'values-stripped')],check=True,timeout=10)
lib=C.CDLL(str(w/'values.so'))
lib.probe_layout.argtypes=[C.c_char_p,C.c_void_p,C.c_size_t,C.c_void_p]; lib.probe_layout.restype=C.c_char_p
lib.probe_stack.argtypes=[C.c_char_p]; lib.probe_stack.restype=C.c_char_p
for name,expected in (('values-no-direct',b'GoDwarfConstantsUnavailable'),('values-stripped',b'GoDwarfUnavailable')):
    out=C.create_string_buffer(8192)
    reason=lib.probe_layout(os.fsencode(w/name),b'x',1,out)
    if reason != expected: raise SystemExit(f'{name}: {reason!r} != {expected!r}')
if lib.probe_stack(os.fsencode(w/'values-no-direct')) is not None:
    raise SystemExit('value metadata must not disable existing stack profile')
print('go-values: missing-value-constant and stripped-image refusals pass; stack profile stays independent')
