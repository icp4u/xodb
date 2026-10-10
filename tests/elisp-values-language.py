#!/usr/bin/env python3
"""Typed Lisp_Object previews through local/agent expression inspection."""
import argparse
import json
import os
from pathlib import Path
import re
import resource
import signal
import subprocess
import time
from client import Client
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--emacs',type=Path,required=True);p.add_argument('--work',type=Path,required=True)
p.add_argument('--agent',type=Path);p.add_argument('--strace',action='store_true');p.add_argument('--wrong-oracle',action='store_true')
a=p.parse_args();os.umask(0o022);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
root=Path(__file__).resolve().parents[1];w=a.work.resolve();w.mkdir(mode=0o755,parents=True,exist_ok=False)
os.environ.update(XODB_ELISP_ORACLE=str(w/'oracle.json'),XODB_ELISP_VALUE_STOPS='1',XDG_CACHE_HOME=str(w/'cache'))
options=['--break','Fdebugger_trap']+(['--runtime-agent',str(a.agent.resolve())] if a.agent else [])
c=Client('control',str(a.emacs.resolve()),args=('-Q','--batch','-l',str(root/'tests/fixtures/elisp/values.el')),options=options)
results=[];audit={}
def usage(pid):
    stat=Path(f'/proc/{pid}/stat').read_text().rsplit(')',1)[1].split()
    return dict(cpu_seconds=(int(stat[11])+int(stat[12]))/os.sysconf('SC_CLK_TCK'),
                rss_kib=int(re.search(r'^VmRSS:\s*(\d+)',Path(f'/proc/{pid}/status').read_text(),re.M)[1]))
try:
    c.continue_initial_stop();stopped=c.stopped('breakpoint',seconds=180)
    oracle=json.loads((w/'oracle.json').read_text())
    if a.wrong_oracle:oracle[0]['printed']='-18'
    for index,expected in enumerate(oracle):
        pid=stopped['pid'];generation=stopped['generation'];regs=c.inspect('get_registers',tid=pid)
        stack=c.inspect('get_language_stack',language='elisp',tid=pid)
        row=next(f for f in stack['segments'][0]['frames'] if f['name']=='xodb-elisp-value-mark')
        assert row['native_binding'],row
        frame=row['native_binding']['frame']
        def read():return c.inspect('evaluate_expression',tid=pid,frame=frame,expression='arg_vector[1]')['value']
        before=usage(c.p.pid);value=read();after=usage(c.p.pid)
        shown=value['visualization'];assert shown and shown['elisp'],value
        detail=shown['elisp'];name=expected['name'];why=shown['diagnostic']
        assert detail['memory_reads']<=8192 and detail['memory_bytes']<=2*1024*1024,detail
        if name in ['fixnum','float','string','multibyte','symbol','nil','list','dotted','vector','record','negative-zero','fraction']:
            assert value['display']==expected['printed'],('prin1 mismatch',name,value,expected)
            assert why is None,value
        elif name in ['cycle','self-vector']:assert why=='ElispValueCycle',value
        elif name in ['long-string','long-vector']:assert why=='ElispPreviewLimit' and shown['truncated'],value
        elif name=='hash':
            assert why is None and shown['count']==2,value
            assert {i['key']:i['display'] for i in detail['items']}=={'alpha':'17','beta':'"two"'},value
        elif name=='buffer':
            assert why is None and detail['type']=='buffer' and 'point=3' in value['display'],value
            assert any('xodb-demo-local' in i['display'] and '29' in i['display'] for i in detail['items']),value
        else:assert why is None and detail['type']==('marker' if 'marker' in name else 'window'),value
        assert c.inspect('evaluate_expression',tid=pid,frame=frame,expression='numargs')['value']['visualization'] is None
        if a.strace and index==0:
            observer=c.collector_pid();trace=w/'readonly.strace'
            state_before={p.name:(p/'schedstat').read_text().split()[0] for p in Path(f'/proc/{pid}/task').iterdir()}
            tracer=subprocess.Popen(['strace','-f','-qq','-o',str(trace),'-e','trace=ptrace,process_vm_readv,process_vm_writev,pread64,pwrite64,pwritev,pwritev2,kill,tgkill,tkill','-p',str(observer)],stderr=subprocess.PIPE)
            try:
                deadline=time.monotonic()+10
                while not re.search(r'^TracerPid:\s*'+str(tracer.pid)+r'\s*$',Path(f'/proc/{observer}/status').read_text(),re.M):
                    assert tracer.poll() is None and time.monotonic()<deadline;time.sleep(.01)
                assert read()==value
            finally:
                if tracer.poll() is None:tracer.send_signal(signal.SIGINT)
                tracer.wait(timeout=10);(w/'strace.stderr').write_bytes(tracer.stderr.read())
            text=trace.read_text();assert re.search(r'process_vm_readv|pread64|PTRACE_PEEKDATA',text),text
            assert not re.search(r'process_vm_writev\(|pwrite64\(|pwritev2?\(|(?:kill|tgkill|tkill)\(|PTRACE_(?:POKE\w*|SET\w*|CONT|SINGLESTEP|SYSCALL)\b',text),text
            assert state_before=={p.name:(p/'schedstat').read_text().split()[0] for p in Path(f'/proc/{pid}/task').iterdir()}
            audit={'target_reads_observed':True,'target_mutations':0,'target_runs':0}
        assert c.session()['generation']==generation and c.inspect('get_registers',tid=pid)==regs
        results.append(dict(name=name,value=value,cpu_rss_before=before,cpu_rss_after=after))
        if index+1<len(oracle):c.action('continue');stopped=c.stopped('breakpoint',seconds=180)
    (w/'results.json').write_text(json.dumps(dict(status='pass',values=results,readonly_audit=audit),indent=2)+'\n')
    print('elisp typed previews: 21 prin1/object cases, integer non-match and retained-stop checks PASS')
finally:
    c.close();(w/'rpc.json').write_text(json.dumps(c.transcript,indent=2)+'\n');(w/'stderr.log').write_bytes(c.p.stderr.read())
