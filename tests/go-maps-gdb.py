"""GDB hosts C map enumeration; compares with the stopped fixture's oracle."""
import ctypes as C
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import resource
import struct
import gdb

root=Path(__file__).resolve().parents[1]
w=Path(os.environ['XODB_GO_VALUES_WORK'])
spec=importlib.util.spec_from_file_location('go_values_types',root/'tests/go-values-gdb.py')
v=importlib.util.module_from_spec(spec);spec.loader.exec_module(v)
check=v.check
names=v.names
types=names('go_map_types.inc','XGM_TYPE')
fields=names('go_map_fields.inc','XGM_FIELD')
constants=names('go_map_constants.inc','XGM_CONSTANT')
class Layout(C.Structure):
    _fields_=[('values',v.Layout),('fields',v.Field*len(fields)),('sizes',C.c_uint32*len(types)),('constants',C.c_uint64*len(constants))]
class Entry(C.Structure):
    _fields_=[('key',C.c_uint64),('value',C.c_uint64)]
class Page(C.Structure):
    _fields_=[('total',C.c_uint64),('start',C.c_uint64),('next',C.c_uint64),('count',C.c_uint32),('groups',C.c_uint32),('tables',C.c_uint32),('deleted',C.c_uint32),('is_nil',C.c_int),('complete',C.c_int),('key_type',v.Type),('element_type',v.Type),('entries',Entry*64),('reason',C.c_char_p)]

def main():
    check(gdb.parameter('may-call-functions') is False,'target calls disabled')
    lib=C.CDLL(str(w/'maps.so'))
    lib.probe_map_size.argtypes=[C.c_uint];lib.probe_map_size.restype=C.c_size_t
    for i,t in enumerate((Layout,Page)):check(lib.probe_map_size(i)==C.sizeof(t),t.__name__)
    lib.probe_map_layout.argtypes=[C.c_char_p,C.c_void_p,C.c_size_t,C.POINTER(Layout)];lib.probe_map_layout.restype=C.c_char_p
    lib.xgv_interface_read.argtypes=[C.POINTER(v.Layout),C.POINTER(v.Reader),C.c_uint64,C.c_uint64,C.c_int,C.POINTER(v.Interface)]
    lib.xgm_map_read.argtypes=[C.POINTER(Layout),C.POINTER(v.Reader),C.c_uint64,C.c_uint64,C.c_uint64,C.c_uint64,C.c_uint,C.POINTER(Page)]
    exe=Path(gdb.current_progspace().filename);identity=hashlib.sha256(exe.read_bytes()).digest();layout=Layout()
    why=lib.probe_map_layout(os.fsencode(exe),identity,len(identity),C.byref(layout))
    check(why is None,why)
    type_rows=re.findall(r'XGM_TYPE\((\w+), "([^"]+)"\)',(root/'src/language/go_map_types.inc').read_text())
    dtypes={k:gdb.lookup_type(n) for k,n in type_rows}
    for i,(key,_) in enumerate(type_rows):check(layout.sizes[i]==dtypes[key].sizeof,key)
    frows=re.findall(r'XGM_FIELD\((\w+), (\w+), "([^"]+)"',(root/'src/language/go_map_fields.inc').read_text())
    for i,(key,owner,path) in enumerate(frows):
        t,offset=dtypes[owner],0
        for part in path.split('.'):
            f=next(f for f in t.strip_typedefs().fields() if f.name==part)
            check(f.bitpos%8==0,key);offset+=f.bitpos//8;t=f.type
        check((offset,t.sizeof)==(layout.fields[i].offset,layout.fields[i].size),key)
    inferior=gdb.selected_inferior();failed=[]
    @v.Read
    def read(_,at,out,n):
        try:C.memmove(out,bytes(inferior.read_memory(at,n)),n);return 0
        except Exception as e:failed.append(str(e));return -1
    def memory(at,n):return bytes(inferior.read_memory(at,n))
    def display(at,type):
        name=type.name.decode()
        if name=='int':return str(int.from_bytes(memory(at,8),'little',signed=True))
        if name=='string':
            ptr,n=struct.unpack('<QQ',memory(at,16));check(n<=4096,'fixture string bound')
            return memory(ptr,n).decode() if n else ''
        if name=='float64':
            x=struct.unpack('<d',memory(at,8))[0];return 'NaN' if math.isnan(x) else str(x)
        if name=='struct {}':return '{}'
        if re.fullmatch(r'\[\d+\]uint8',name):return '['+' '.join(str(x) for x in memory(at,type.size))+']'
        raise RuntimeError('unhandled fixture type '+name)
    module=int(gdb.parse_and_eval("&'runtime.firstmoduledata'").cast(gdb.lookup_type('unsigned long')))
    def usage():
        stat=resource.getrusage(resource.RUSAGE_SELF)
        rss=int(re.search(r'^VmRSS:\s+(\d+)',Path('/proc/self/status').read_text(),re.M)[1])
        return {'cpu_seconds':stat.ru_utime+stat.ru_stime,'rss_kib':rss}
    performance={'before':usage(),'load_average':os.getloadavg(),'cpu_count':os.cpu_count()}
    gdb.flush();gdb.write('GO_MAPS_READ_BEGIN\n');gdb.flush()
    before=gdb.execute('info registers',to_string=True)
    results=[];seen_deleted=False;group_layout=None
    for row in json.loads((w/'truth.json').read_text()):
        r=v.Reader(read=read);iface=v.Interface()
        lib.xgv_interface_read(C.byref(layout.values),C.byref(r),module,int(row['interface'],16),0,C.byref(iface))
        check(iface.reason is None,(row['name'],iface.reason))
        # The typed map DIE links through table/groups to the compiler's
        # concrete group. Corroborate the versioned control-word prefix.
        map_die=gdb.lookup_type(iface.type.name.decode()).strip_typedefs().target().strip_typedefs()
        member=lambda typ,name:next(f for f in typ.strip_typedefs().fields() if f.name==name)
        table_die=member(map_die,'dirPtr').type.target().target().strip_typedefs()
        groups_die=member(table_die,'groups').type
        group_die=member(groups_die,'data').type.target().strip_typedefs()
        first=group_die.fields()[0]
        check(first.bitpos==0 and first.type.sizeof==8,('control prefix',row['name']))
        if row['name']=='small':
            raw=memory(iface.type.address,layout.sizes[types.index('TYPE')])
            def field(key):
                f=layout.fields[fields.index(key)];return int.from_bytes(raw[f.offset:f.offset+f.size],'little')
            group_layout={key:field(key) for key in ('T_KEYS_OFF','T_KEY_STRIDE','T_ELEMS_OFF','T_ELEM_STRIDE')}
            expected=8 if os.environ['GOEXPERIMENT']=='mapsplitgroup' else 24
            check(group_layout['T_KEY_STRIDE']==expected,('experiment layout not observed',group_layout))
        all_rows=[];cursor=0;pages=0;reads=0;byte_count=0;groups=tables=0
        while True:
            r=v.Reader(read=read);page=Page()
            lib.xgm_map_read(C.byref(layout),C.byref(r),module,iface.type.address,iface.data,cursor,64,C.byref(page))
            check(page.reason is None,(row['name'],cursor,page.reason))
            check(page.total==row['len'] and bool(page.is_nil)==row['nil'],(row['name'],'header'))
            check(page.key_type.name.decode()==row['key_type'] and page.element_type.name.decode()==row['element_type'],row['name'])
            all_rows.extend({'key':display(e.key,page.key_type),'value':display(e.value,page.element_type)} for e in page.entries[:page.count])
            pages+=1;reads+=r.reads;byte_count+=r.bytes;groups=page.groups;tables=page.tables;seen_deleted|=page.deleted>0
            check(not failed,(row['name'],failed))
            if page.complete:break
            check(page.next>cursor and pages<=64,'pagination must advance');cursor=page.next
        order=lambda rows:sorted((x['key'],x['value']) for x in rows)
        check(order(all_rows)==order(row['rows']),(row['name'],'enumerated rows differ'))
        if row['name']=='small':
            wrong=[dict(x) for x in row['rows']];wrong[0]['value']='planted wrong value'
            try:check(order(all_rows)==order(wrong),'planted wrong map oracle')
            except RuntimeError:pass
            else:raise RuntimeError('wrong oracle accepted')
        if row['name']=='large':check(tables>1,'multi-table condition not observed')
        results.append({'name':row['name'],'entries':len(all_rows),'pages':pages,'groups':groups,'tables':tables,'reads':reads,'bytes':byte_count})
    check(seen_deleted,'deleted-control condition not observed')
    check(before==gdb.execute('info registers',to_string=True),'registers changed')
    gdb.write('GO_MAPS_READ_END\n');gdb.flush()
    performance['after']=usage()
    performance['status']='not-measurable' if performance['load_average'][0]>performance['cpu_count'] else 'measured'
    (w/'result.json').write_text(json.dumps({'observer_process_cost':performance,'status':'pass','cases':results,'group_layout':group_layout,'deleted_controls_observed':seen_deleted},indent=2)+'\n')
    print('go-maps: %d owned cases match Go iteration, paged and multi-table' % len(results))
try:main()
except Exception:
    import traceback;traceback.print_exc();gdb.execute('quit 1')
