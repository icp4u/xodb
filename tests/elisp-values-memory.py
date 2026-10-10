"""GDB hosts the C value reader; target calls stay disabled."""
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
spec = importlib.util.spec_from_file_location('elisp_abi', root / 'tests/elisp-memory.py')
e = importlib.util.module_from_spec(spec)
spec.loader.exec_module(e)

class Item(C.Structure):
    _fields_ = [('tagged', C.c_uint64), ('key', C.c_char * 128), ('type', C.c_char * 24),
                ('display', C.c_char * 256), ('reason', C.c_char_p)]
class Value(C.Structure):
    _fields_ = [('tagged', C.c_uint64), ('object', C.c_uint64), ('count', C.c_uint64),
                ('type', C.c_char * 24), ('display', C.c_char * 768), ('reason', C.c_char_p),
                ('truncated', C.c_uint32), ('item_count', C.c_size_t), ('items', Item * 24)]

def main():
    e.check(gdb.parameter('may-call-functions') is False, 'target calls disabled')
    lib = C.CDLL(os.environ['XODB_ELISP_READER'])
    lib.probe_size.restype = C.c_size_t
    for name, typ in [('xel_value', Value), ('xel_value_item', Item), ('xel_layout', e.Layout)]:
        e.check(lib.probe_size(name.encode()) == C.sizeof(typ), 'ABI '+name)
    lib.probe_layout.restype = C.c_char_p
    layout = e.Layout()
    why = lib.probe_layout(gdb.current_progspace().filename.encode(), C.byref(layout))
    e.check(why is None, 'layout '+str(why))
    def address(name):
        return int(re.search(r'at address (0x[0-9a-f]+)', gdb.execute('info address '+name,to_string=True))[1],16)
    word = lambda at: int.from_bytes(bytes(gdb.selected_inferior().read_memory(at,8)), 'little')
    context = e.Context(address('lispsym'), (C.c_uint64 * len(e.global_names))(*map(address,e.global_names)))
    overlay = {}
    @e.Read
    def read(_, at, out, n):
        try:
            data = overlay.get((at,n), bytes(gdb.selected_inferior().read_memory(at,n)))
            C.memmove(out,data,n); return 0
        except gdb.error:
            return -1
    r=e.Reader(None,read,0,0,None);stack=e.Stack()
    lib.xel_stack_main(C.byref(layout),C.byref(r),C.byref(context),C.c_uint64(address('current_thread')),
                       C.c_uint64(address('main_thread')),gdb.selected_inferior().pid,gdb.selected_thread().ptid[1],C.byref(stack))
    e.check(stack.reason is None,'stack '+str(stack.reason))
    frame=next(f for f in stack.frames[:stack.count] if f.name==b'xodb-elisp-values-mark')
    e.check(frame.nargs==1,'values argument count')
    vector=word(frame.args)&~7
    vals=gdb.Value(vector).cast(gdb.lookup_type('struct Lisp_Vector').pointer()).dereference()['contents']
    oracle=json.loads(Path(os.environ['XODB_ELISP_ORACLE']).read_text())
    if os.environ.get('XODB_ELISP_WRONG_ORACLE'): oracle[0]['printed']='-18'
    results=[];string=0
    def decoded(tagged):
        r=e.Reader(None,read,0,0,None);v=Value()
        lib.xel_value_read(C.byref(layout),C.byref(r),C.byref(context),C.c_uint64(tagged),C.byref(v))
        e.check(r.reads<=8192 and r.bytes<=2*1024*1024,'budget')
        return dict(type=v.type.decode(),display=v.display.decode(),count=v.count,reason=v.reason.decode() if v.reason else None,
                    truncated=bool(v.truncated),reads=r.reads,bytes=r.bytes,
                    items=[dict(key=i.key.decode(),type=i.type.decode(),display=i.display.decode(),reason=i.reason.decode() if i.reason else None) for i in v.items[:v.item_count]])
    def rss(): return int(Path('/proc/self/statm').read_text().split()[1])*os.sysconf('SC_PAGE_SIZE')
    cpu=time.process_time_ns();before=rss()
    os.write(2,b'ELISP_VALUES_BEGIN\n')
    for i,item in enumerate(oracle):
        pair=int(vals[i].cast(gdb.lookup_type('uintptr_t')))&~7
        cons=gdb.Value(pair).cast(gdb.lookup_type('struct Lisp_Cons').pointer()).dereference()
        tagged=int(cons['u']['s']['u']['cdr'].cast(gdb.lookup_type('uintptr_t')))
        got=decoded(tagged);name=item['name'];results.append(dict(name=name,oracle=item['printed'],**got))
        if name in ['fixnum','float','string','multibyte','symbol','nil','list','dotted','vector','record','negative-zero','fraction']:
            e.check(got['display']==item['printed'],'prin1 mismatch '+repr((name,got,item)))
            e.check(got['reason'] is None,'unexpected diagnostic '+repr(got))
        elif name in ['cycle','self-vector']:
            e.check(got['reason']=='ElispValueCycle','cycle '+repr(got))
        elif name in ['long-string','long-vector']:
            e.check(got['reason']=='ElispPreviewLimit' and got['truncated'],'limit '+repr(got))
        elif name=='hash':
            e.check(got['reason'] is None and got['count']==2,'hash '+repr(got))
            e.check({v['key']:v['display'] for v in got['items']}=={'alpha':'17','beta':'"two"'},'hash entries '+repr(got))
        elif name=='buffer':
            e.check(got['reason'] is None and got['type']=='buffer' and 'point=3' in got['display'],'buffer '+repr(got))
            e.check(any('xodb-demo-local' in v['display'] and '29' in v['display'] for v in got['items']),'buffer locals '+repr(got))
        elif name in ['marker','window','dead-marker']:
            e.check(got['reason'] is None and got['type']==('marker' if 'marker' in name else 'window'),'object '+repr(got))
        if name=='string': string=tagged
    elapsed=time.process_time_ns()-cpu;after=rss()
    fields=re.findall(r'XEL_FIELD\((\w+),',(root/'src/language/elisp_fields.inc').read_text())
    offset=layout.fields[fields.index('STRING_BYTES')].offset
    overlay[( (string&~7)+offset,8)]=(-4).to_bytes(8,'little',signed=True)
    invalid=decoded(string)
    e.check(invalid['reason']=='ElispStringHeaderInvalid','corrupt header '+repr(invalid))
    os.write(2,b'ELISP_VALUES_END\n')
    Path(os.environ['XODB_ELISP_RESULT']).write_text(json.dumps(dict(status='pass',values=results,corrupt_header=invalid,
         observer_cpu_ns=elapsed,observer_rss_before=before,observer_rss_after=after,result_bytes=C.sizeof(Value)),indent=2)+'\n')
    print('elisp values: 21 owned values, prin1 and corrupt header PASS')

if __name__ == '__main__':
    try: main()
    except Exception:
        traceback.print_exc();gdb.execute('quit 1')
