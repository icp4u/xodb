"""GDB hosts the C binding reader; no inferior calls or state rewinding."""
import ctypes as C
import importlib.util
import json
import os
from pathlib import Path
import re
import time
import traceback
import gdb

root = Path(__file__).resolve().parents[1]
def module(name, path):
    spec = importlib.util.spec_from_file_location(name, root / path)
    result = importlib.util.module_from_spec(spec); spec.loader.exec_module(result); return result
e = module('elisp_abi', 'tests/elisp-memory.py')
v = module('elisp_values', 'tests/elisp-values-memory.py')
class Binding(C.Structure):
    _fields_ = [(n, C.c_uint64) for n in ('symbol','value','slot','record','environment')] + [
        ('name',C.c_char*192),('scope',C.c_uint32),('has_value',C.c_uint32),('reason',C.c_char_p)]
class Bindings(C.Structure):
    _fields_ = [('count',C.c_size_t),('truncated',C.c_uint32),('reason',C.c_char_p),('rows',Binding*128)]

def main():
    e.check(gdb.parameter('may-call-functions') is False, 'target calls disabled')
    lib=C.CDLL(os.environ['XODB_ELISP_READER']);lib.probe_size.restype=C.c_size_t
    for name,typ in [('xel_binding',Binding),('xel_bindings',Bindings),('xel_layout',e.Layout),('xel_stack',e.Stack)]:
        e.check(lib.probe_size(name.encode())==C.sizeof(typ),'ABI '+name)
    layout=e.Layout();lib.probe_layout.restype=C.c_char_p
    e.check(lib.probe_layout(gdb.current_progspace().filename.encode(),C.byref(layout)) is None,'layout')
    def address(name):
        return int(re.search(r'at address (0x[0-9a-f]+)',gdb.execute('info address '+name,to_string=True))[1],16)
    context=e.Context(address('lispsym'),(C.c_uint64*len(e.global_names))(*map(address,e.global_names)))
    counts=[0,0]
    @e.Read
    def read(_,at,out,n):
        try:
            counts[0]+=1;counts[1]+=n
            C.memmove(out,bytes(gdb.selected_inferior().read_memory(at,n)),n);return 0
        except gdb.error:return -1
    pid=gdb.selected_inferior().pid
    before_regs=gdb.execute('info all-registers',to_string=True)
    def target_ticks():
        return {p.name:(p/'schedstat').read_text().split()[0] for p in Path(f'/proc/{pid}/task').iterdir()}
    before_ticks=target_ticks()
    r=e.Reader(None,read,0,0,None);stack=e.Stack()
    lib.xel_stack_main(C.byref(layout),C.byref(r),C.byref(context),C.c_uint64(address('current_thread')),
                       C.c_uint64(address('main_thread')),pid,pid,C.byref(stack))
    e.check(not stack.reason,'stack '+str(stack.reason))
    start=next(i for i,f in enumerate(stack.frames[:stack.count]) if f.name==b'xodb-binding-mark')
    expected=json.loads(Path(os.environ['XODB_ELISP_ORACLE']).read_text())
    if os.environ.get('XODB_ELISP_WRONG_ORACLE'):expected[0]['bindings'][0][1]='24'
    def rss():return int(re.search(r'^VmRSS:\s*(\d+)',Path('/proc/self/status').read_text(),re.M)[1])
    rss_before=rss();cpu_start=time.process_time_ns();actual=[]
    for item in expected:
        index=start+item['level'];e.check(stack.frames[index].name.decode()==item['name'],'frame index/name')
        r=e.Reader(None,read,0,0,None);out=Bindings()
        lib.xel_bindings_read(C.byref(layout),C.byref(r),C.byref(context),C.byref(stack),C.c_size_t(index),
                              C.c_uint64(address('Qinternal_interpreter_environment')),C.byref(out))
        e.check(not out.reason,'bindings '+str(out.reason))
        pairs=[];rows=[]
        for row in out.rows[:out.count]:
            name=row.name.decode()
            if not name.startswith('xodb-'):continue
            e.check(row.has_value and not row.reason, 'unproved owned binding '+name+': '+str(row.reason))
            preview=v.Value()
            lib.xel_value_read(C.byref(layout),C.byref(r),C.byref(context),C.c_uint64(row.value),C.byref(preview))
            e.check(not preview.reason,'preview '+str(preview.reason))
            pairs.append([name,preview.display.decode()])
            rows.append(dict(name=name,value=preview.display.decode(),scope='lexical' if row.scope else 'dynamic',slot=row.slot,record=row.record,environment=row.environment))
        e.check(sorted(pairs)==sorted(item['bindings']),f'bindings oracle mismatch: {item}: {pairs}')
        e.check(r.reads<=8192 and r.bytes<=2*1024*1024,'reader budget')
        actual.append(dict(level=item['level'],name=item['name'],rows=rows,reads=r.reads,bytes=r.bytes))
    result=dict(status='pass',frames=actual,cpu_ns=time.process_time_ns()-cpu_start,rss_before_kib=rss_before,
                rss_after_kib=rss(),result_capacity_bytes=C.sizeof(Bindings),callbacks=counts[0],bytes=counts[1])
    e.check(before_regs==gdb.execute('info all-registers',to_string=True),'target registers changed')
    e.check(before_ticks==target_ticks(),'target ran during reader')
    e.check(any(row['scope']=='dynamic' and row['value']=='11' for f in actual for row in f['rows']),'outer old-frame value observed')
    e.check(any(row['scope']=='dynamic' and row['value']=='23' for f in actual for row in f['rows']),'inner changed value observed')
    e.check(any(row['scope']=='lexical' for f in actual for row in f['rows']),'lexical environment observed')
    Path(os.environ['XODB_ELISP_RESULT']).write_text(json.dumps(result,indent=2)+'\n')
    print('elisp bindings: exact per-frame backtrace--locals, shadowing and lexical values PASS')
if __name__=='__main__':
    try:main()
    except Exception:traceback.print_exc();gdb.execute('quit 1')
