"""GDB hosts the C observer; the inferior runs only the owned Go fixture."""
import ctypes as C
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import gdb

root = Path(__file__).resolve().parents[1]
w = Path(os.environ['XODB_GO_VALUES_WORK'])

def check(ok, message):
    if not ok:
        raise RuntimeError(str(message))

def names(file, macro):
    return re.findall(r'^' + macro + r'\((\w+),', (root/'src/language'/file).read_text(), re.M)

types = names('go_value_types.inc', 'XGV_TYPE')
fields = names('go_value_fields.inc', 'XGV_FIELD')
constants = names('go_value_constants.inc', 'XGV_CONSTANT')
class Field(C.Structure):
    _fields_ = [('offset', C.c_uint32), ('size', C.c_uint32)]
class Layout(C.Structure):
    _fields_ = [('fields', Field*len(fields)), ('sizes', C.c_uint32*len(types)), ('constants', C.c_uint64*len(constants)), ('build_id', C.c_uint8*64), ('build_id_len', C.c_uint8)]
Read = C.CFUNCTYPE(C.c_int, C.c_void_p, C.c_uint64, C.c_void_p, C.c_size_t)
class Reader(C.Structure):
    _fields_ = [('context', C.c_void_p), ('read', Read), ('reads', C.c_size_t), ('bytes', C.c_size_t), ('error', C.c_char_p)]
class Type(C.Structure):
    _fields_ = [('address', C.c_uint64), ('size', C.c_uint64), ('pointer_bytes', C.c_uint64), ('section_start', C.c_uint64), ('section_end', C.c_uint64), ('hash', C.c_uint32), ('kind', C.c_uint8), ('direct', C.c_uint8), ('name', C.c_char*160), ('reason', C.c_char_p)]
class Interface(C.Structure):
    _fields_ = [('is_nil', C.c_int), ('data', C.c_uint64), ('value_address', C.c_uint64), ('type', Type), ('reason', C.c_char_p)]
class Channel(C.Structure):
    _fields_ = [('is_nil', C.c_int), ('closed', C.c_int), ('header_valid', C.c_int), ('waits_complete', C.c_int), ('length', C.c_uint64), ('capacity', C.c_uint64), ('buffer', C.c_uint64), ('send_index', C.c_uint64), ('receive_index', C.c_uint64), ('send_entries', C.c_uint32), ('receive_entries', C.c_uint32), ('select_entries', C.c_uint32), ('element', Type), ('reason', C.c_char_p)]

def main():
    check(gdb.parameter('may-call-functions') is False, 'target calls disabled')
    lib = C.CDLL(str(w/'values.so'))
    lib.probe_size.argtypes = [C.c_uint]; lib.probe_size.restype = C.c_size_t
    for i, ty in enumerate((Layout, Reader, Type, Interface, Channel)):
        check(lib.probe_size(i) == C.sizeof(ty), 'ABI size: '+ty.__name__)
    lib.probe_layout.argtypes = [C.c_char_p, C.c_void_p, C.c_size_t, C.POINTER(Layout)]
    lib.probe_layout.restype = C.c_char_p
    lib.xgv_interface_read.argtypes = [C.POINTER(Layout), C.POINTER(Reader), C.c_uint64, C.c_uint64, C.c_int, C.POINTER(Interface)]
    lib.xgv_channel_read.argtypes = [C.POINTER(Layout), C.POINTER(Reader), C.c_uint64, C.c_uint64, C.POINTER(Channel)]
    exe = Path(gdb.current_progspace().filename)
    identity = hashlib.sha256(exe.read_bytes()).digest()
    layout = Layout()
    reason = lib.probe_layout(os.fsencode(exe), identity, len(identity), C.byref(layout))
    check(reason is None, 'layout: '+str(reason))
    check(bytes(layout.build_id[:layout.build_id_len]) == identity, 'image identity')
    # Independently query GDB's type reader for every field and aggregate.
    type_rows = re.findall(r'XGV_TYPE\((\w+), "([^"]+)"\)', (root/'src/language/go_value_types.inc').read_text())
    dwarf_types = {key: gdb.lookup_type(name) for key, name in type_rows}
    for i, (key, name) in enumerate(type_rows):
        check(dwarf_types[key].sizeof == layout.sizes[i], (key, 'size'))
    field_rows = re.findall(r'XGV_FIELD\((\w+), (\w+), "([^"]+)"', (root/'src/language/go_value_fields.inc').read_text())
    for i, (key, owner, path) in enumerate(field_rows):
        t, offset = dwarf_types[owner], 0
        for part in path.split('.'):
            f = next(f for f in t.strip_typedefs().fields() if f.name == part)
            check(f.bitpos % 8 == 0, key)
            offset += f.bitpos//8; t = f.type
        check((offset, t.sizeof) == (layout.fields[i].offset, layout.fields[i].size), key)
    inferior = gdb.selected_inferior()
    failures = []
    @Read
    def read(_, address, output, count):
        try:
            C.memmove(output, bytes(inferior.read_memory(address, count)), count)
            return 0
        except Exception as e:
            failures.append(str(e)); return -1
    module = int(gdb.parse_and_eval("&'runtime.firstmoduledata'").cast(gdb.lookup_type('unsigned long')))
    def usage():
        stat = resource.getrusage(resource.RUSAGE_SELF)
        rss = int(re.search(r'^VmRSS:\s+(\d+)', Path('/proc/self/status').read_text(), re.M)[1])
        return {'cpu_seconds':stat.ru_utime+stat.ru_stime, 'rss_kib':rss}
    performance = {'before':usage(), 'load_average':os.getloadavg(), 'cpu_count':os.cpu_count()}
    gdb.flush()
    gdb.write('GO_VALUES_READ_BEGIN\n'); gdb.flush()
    before = gdb.execute('info registers', to_string=True)
    oracle = json.loads((w/'truth.json').read_text())
    actual = []
    for row in oracle:
        r = Reader(read=read)
        at = int(row['address'], 16)
        if row['kind'] == 'interface':
            result = Interface()
            lib.xgv_interface_read(C.byref(layout), C.byref(r), module, at, row['nonempty'], C.byref(result))
            if row['reason']:
                check(result.reason and result.reason.decode() == row['reason'], (row, result.reason))
                actual.append({'name':row['name'],'kind':row['kind'],'refusal':row['reason'],'reads':r.reads,'bytes':r.bytes})
                continue
            check(result.reason is None, (row['name'], result.reason))
            got = {'name':row['name'], 'kind':'interface', 'nil':bool(result.is_nil), 'type':result.type.name.decode()}
            check(got['nil'] == row['nil'] and got['type'] == row['type'], (got, row))
            if row['name'] == 'int':
                check(int.from_bytes(inferior.read_memory(result.value_address,8), 'little') == 73 and not result.type.direct, 'indirect int')
            if row['name'] == 'pair':
                check(bytes(inferior.read_memory(result.value_address,16)) == (11).to_bytes(8,'little')+(29).to_bytes(8,'little'), 'pair')
            if row['name'] in ('pointer','typed-nil'):
                check(result.type.direct and result.value_address == at + layout.fields[fields.index('EF_DATA')].offset, 'direct word')
                if row['name'] == 'typed-nil': check(result.data == 0 and not result.is_nil, 'typed nil is nonnil interface')
                else: check(int.from_bytes(inferior.read_memory(result.data,8),'little') == 37, 'pointer referent')
        else:
            result = Channel()
            lib.xgv_channel_read(C.byref(layout), C.byref(r), module, at, C.byref(result))
            if row['reason']:
                check(result.reason and result.reason.decode() == row['reason'] and not result.header_valid, (row, result.reason))
                actual.append({'name':row['name'],'kind':row['kind'],'refusal':row['reason'],'reads':r.reads,'bytes':r.bytes})
                continue
            check(result.reason is None and result.header_valid and result.waits_complete, (row['name'], result.reason))
            got = {'name':row['name'], 'kind':'channel', 'nil':bool(result.is_nil), 'len':result.length, 'cap':result.capacity, 'closed':bool(result.closed), 'send':result.send_entries, 'receive':result.receive_entries, 'select':result.select_entries}
            check(all(got[k] == row[k] for k in got), (got, row))
            if not result.is_nil: check(result.element.name.decode() == row['type'], (row, result.element.name))
        check(r.error is None and not failures, (r.error, failures))
        got.update(reads=r.reads, bytes=r.bytes)
        actual.append(got)
    # Same comparison, deliberately wrong target-oracle count, must fail.
    chosen = next(x for x in actual if x['kind']=='channel' and x['name']=='senders')
    wrong = next(x for x in oracle if x['kind']=='channel' and x['name']=='senders').copy()
    wrong['send'] += 1
    try:
        check(all(chosen[k] == wrong[k] for k in ('nil','len','cap','closed','send','receive','select')), 'planted wrong sender count')
    except RuntimeError:
        pass
    else:
        raise RuntimeError('wrong oracle accepted')
    check(before == gdb.execute('info registers', to_string=True), 'observer changed registers')
    gdb.write('GO_VALUES_READ_END\n'); gdb.flush()
    performance['after'] = usage()
    performance['status'] = 'not-measurable' if performance['load_average'][0] > performance['cpu_count'] else 'measured'
    (w/'result.json').write_text(json.dumps({'status':'pass','cases':actual,'wrong_oracle':'refused','may_call_functions':False,'observer_process_cost':performance}, indent=2)+'\n')
    print('go-values: %d owned interface/channel cases, DWARF cross-check and wrong oracle pass' % len(actual))

if __name__ == '__main__':
    try:
        main()
    except Exception:
        import traceback
        traceback.print_exc()
        gdb.execute('quit 1')
