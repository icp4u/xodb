"""Audit an owned stopped fixture's debugger during observer operations."""
import re
import signal
import subprocess
import time
from pathlib import Path


def audit(client, pid, log, operation):
    def scheduled():
        return {p.name:(p/'schedstat').read_text().split()[0] for p in Path(f'/proc/{pid}/task').iterdir()}
    registers=client.inspect('get_registers',tid=pid)
    generation=client.session()['generation']
    before=scheduled()
    observers={client.p.pid}
    # Shared-session adapters already supply the collector as p.pid.
    if getattr(client,'runtime_agent',False):observers.add(client.collector_pid())
    tracer=subprocess.Popen(['strace','-f','-qq','-o',str(log),'-e',
        'trace=ptrace,process_vm_readv,process_vm_writev,pread64,pwrite64,pwritev,pwritev2,kill,tgkill,tkill',
        *[part for pid in sorted(observers) for part in ('-p',str(pid))]],stderr=subprocess.PIPE)
    try:
        deadline = time.monotonic() + 5
        while True:
            assert tracer.poll() is None,tracer.stderr.read().decode()
            attached=[]
            for observer_pid in observers:
                status=Path(f'/proc/{observer_pid}/status').read_text()
                attached.append(next(int(line.split()[1]) for line in status.splitlines() if line.startswith('TracerPid:')))
            if all(pid==tracer.pid for pid in attached):break
            assert time.monotonic() < deadline, 'strace did not attach before the audit deadline'
            time.sleep(.01)
        for _ in range(2):operation()
    finally:
        if tracer.poll() is None:tracer.send_signal(signal.SIGINT)
        try:tracer.wait(timeout=10)
        except subprocess.TimeoutExpired:tracer.kill();tracer.wait(timeout=5)
        tracer.stderr.close()
    calls={}
    for line in Path(log).read_text().splitlines():
        match=re.search(r'\b(ptrace|process_vm_readv|process_vm_writev|pread64|pwrite64|pwritev|pwritev2|kill|tgkill|tkill)\(([^,)]*)',line)
        if not match:continue
        call=match[1]+(':'+match[2] if match[1]=='ptrace' else '')
        calls[call]=calls.get(call,0)+1
    forbidden=[k for k in calls if k in ('process_vm_writev','pwrite64','pwritev','pwritev2','kill','tgkill','tkill') or
        k.startswith(('ptrace:PTRACE_POKE','ptrace:PTRACE_SET')) or k in ('ptrace:PTRACE_CONT','ptrace:PTRACE_SINGLESTEP','ptrace:PTRACE_SYSCALL')]
    assert not forbidden,calls
    assert any(k in calls for k in ('process_vm_readv','pread64','ptrace:PTRACE_PEEKDATA')),calls
    assert scheduled()==before
    assert client.inspect('get_registers',tid=pid)==registers and client.session()['generation']==generation
    return {'syscalls':calls,'registers_generation_schedstat_unchanged':True}
