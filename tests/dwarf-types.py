#!/usr/bin/env python3
"""Struct layouts by qualified name across compilation units: compiler
oracles (offsetof printed by the fixture itself), declarations that are not
definitions, definitions that disagree, and the work bound.
Run: python3 tests/dwarf-types.py --work out/dwarf-types   (component, about 3 s)"""
import argparse, json, os, re, subprocess
from pathlib import Path

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--work', required=True, type=Path)
p.add_argument('--sanitize', action='store_true')
a = p.parse_args(); os.umask(0o022)
root = Path(__file__).resolve().parents[1]; os.chdir(root)
w = a.work.resolve(); w.mkdir(mode=0o755, parents=True, exist_ok=True)
exe = w / 'types'
flags = ['-O1', '-fsanitize=address,undefined', '-fno-omit-frame-pointer'] if a.sanitize else ['-O2']
subprocess.run(['clang' if a.sanitize else 'cc', '-std=c11', '-g', *flags, '-Wall', '-Wextra', '-Werror', 'tests/dwarf-types.c', 'src/debug/dwarf_types.c', '-ldw', '-lelf', '-o', str(exe)], check=True, timeout=120)

# A class with a virtual method is defined in full only in its key
# function's unit (engine.cc); user.cc sees the header but emits a declaration
# for Engine there when it only holds a pointer. Level is nested in Engine.
(w / 'engine.h').write_text('''#include <cstddef>
#include <cstdint>
typedef unsigned int Count;
struct Text { char32_t *data; };
struct Name { struct Data { int refs; Text name; }; Data *data; };
class Engine {
public:
    struct Level { void *stack; Name *function; int *line; Level *prev; };
    virtual ~Engine();
    static Engine *singleton;
    static thread_local Level *top;
    Count limit;
    bool tracking;
    const volatile Name name = {};
    unsigned flags : 3;
    char pad[5];
    enum Kind { NONE, FIRST, SEVENTH = 7 };
};
struct Holder { int tag; Name::Data inner; Engine *engine; struct { char skip[3]; short at; } pair; };
namespace outer { namespace inner { struct Deep { short a; long long b; }; } }
int use(Engine *);
''')
(w / 'engine.cc').write_text('''#include "engine.h"
#include <cstdio>
Engine::~Engine() {}
Engine *Engine::singleton;
thread_local Engine::Level *Engine::top;
int main() {
    Engine engine; Engine::Level level = {}; outer::inner::Deep deep = {}; Engine::top = &level;
    Holder holder = {}; Engine::Kind kind = Engine::SEVENTH;
    std::printf("NESTED %zu %zu %zu %d %zu\\n", offsetof(Holder, inner) + offsetof(Name::Data, name) + offsetof(Text, data), offsetof(Holder, pair) + 4, sizeof(Engine::Kind), (int)kind + holder.tag, sizeof(Holder));
    std::printf("ORACLE %zu %zu %zu %zu %zu %zu %zu %zu %zu %zu %zu\\n", sizeof(Engine), offsetof(Engine, limit), offsetof(Engine, tracking), offsetof(Engine, name),
        sizeof(Engine::Level), offsetof(Engine::Level, function), offsetof(Engine::Level, line), offsetof(Engine::Level, prev),
        sizeof(Name::Data), offsetof(Name::Data, name), offsetof(outer::inner::Deep, b));
    return use(&engine) + (int)deep.a;
}
''')
(w / 'user.cc').write_text('#include "engine.h"\nint use(Engine *engine) { Engine::Level level = {}; Name::Data data = {1, {nullptr}}; Name name = {&data}; return engine != nullptr && level.prev == nullptr && name.data->refs == 1 ? 0 : 1; }\n')
# The same qualified name with another layout, in a third unit.
(w / 'clash.cc').write_text('struct Name { struct Data { long long big[2]; long long name; }; Data *data; };\nint clash() { Name::Data d = {{1, 2}, 3}; Name n = {&d}; return (int)n.data->name; }\n')
(w / 'main2.cc').write_text('int clash();\nint use2() { return clash(); }\n')

TYPES = ['Engine', 'Engine::Level', 'Name::Data', 'outer::inner::Deep', 'Name', 'Text']
FIELDS = ['0:limit:unsigned:4', '0:tracking:boolean:1', '0:name:any:8', '1:function:pointer:8', '1:line:pointer:8', '1:prev:pointer:8',
          '2:name:any:8', '3:b:signed:8', '4:data:pointer:8', '5:data:pointer:8', '0:missing:any:0:optional']
rows = []
def run(label, image, types=TYPES, fields=FIELDS, work=1 << 24, reason=None):
    r = subprocess.run([str(exe), str(image), str(work), *types, '--', *fields], capture_output=True, text=True, timeout=60)
    (w / (label + '.log')).write_text(r.stdout + r.stderr)
    assert r.returncode == (2 if reason else 0), (label, r.returncode, r.stdout, r.stderr)
    if reason: assert r.stdout.startswith('error ' + reason + ' '), (label, r.stdout)
    rows.append({'name': label, 'status': 'pass', 'stdout': r.stdout})
    return r.stdout
def offsets(text):
    return {m[1]: (int(m[2]), int(m[3]), int(m[4])) for m in re.finditer(r'^field (\S+) offset=(\d+) size=(\d+) present=(\d+)$', text, re.M)}
def sizes(text):
    return {m[1]: (int(m[2]), int(m[3])) for m in re.finditer(r'^type (\S+) size=(\d+) definitions=(\d+)$', text, re.M)}

for compiler in ('g++', 'clang++'):
    for version in (4, 5):
        tag = f'{compiler}-{version}'
        image = w / tag
        subprocess.run([compiler, '-O1', '-Wno-invalid-offsetof', f'-gdwarf-{version}', str(w / 'engine.cc'), str(w / 'user.cc'), '-o', str(image)], check=True, timeout=120)
        printed = subprocess.run([str(image)], capture_output=True, text=True, timeout=30, check=True).stdout.splitlines()
        nested, oracle = [int(n) for n in printed[0].split()[1:]], [int(n) for n in printed[1].split()[1:]]
        text = run(tag, image)
        got, size = offsets(text), sizes(text)
        assert [size['Engine'][0], got['Engine.limit'][0], got['Engine.tracking'][0], got['Engine.name'][0], size['Engine::Level'][0], got['Engine::Level.function'][0],
                got['Engine::Level.line'][0], got['Engine::Level.prev'][0], size['Name::Data'][0], got['Name::Data.name'][0], got['outer::inner::Deep.b'][0]] == oracle, (tag, text, oracle)
        # Two units define Level and Name; only the key function's defines Engine.
        assert size['Engine'][1] == 1 and size['Engine::Level'][1] >= 1 and size['Name'][1] == 2 and size['Text'][0] == 8, (tag, text)
        assert got['Engine.missing'] == (0, 0, 0) and got['Engine.limit'][1:] == (4, 1), (tag, text)
        # A path through members held by value adds the offsets up; an
        # enumerator answers with its value; a type marked "?" may be absent.
        text2 = run(tag + '-nested', image, types=['Holder', 'Engine::Kind', '?Nowhere', '?Engine::Level'],
                    fields=['0:inner.name.data:pointer:8', '0:pair.at:signed:2', '1:NONE:any:0', '1:FIRST:any:0', '1:SEVENTH:any:0', '2:x:any:0', '0:inner.gone:any:0:optional', '1:EIGHTH:any:0:optional', '3:prev:pointer:8'])
        got2, size2 = offsets(text2), sizes(text2)
        assert [got2['Holder.inner.name.data'][0], got2['Holder.pair.at'][0], size2['Engine::Kind'][0], got2['Engine::Kind.SEVENTH'][0], size2['Holder'][0]] == nested, (tag, text2, nested)
        assert got2['Engine::Kind.NONE'] == (0, 0, 1) and got2['Engine::Kind.FIRST'] == (1, 0, 1) and got2['Nowhere.x'] == (0, 0, 0) and size2['Nowhere'] == (0, 0), (tag, text2)
        assert got2['Holder.inner.gone'] == (0, 0, 0) and got2['Engine::Kind.EIGHTH'] == (0, 0, 0) and got2['Engine::Level.prev'][2] == 1, (tag, text2)
        # An optional type that is not what was asked is left out, alone.
        text3 = run(tag + '-dropped', image, types=['?Holder', 'Text', '?Engine::Kind', '?Name'], fields=['0:inner.gone:any:0', '0:tag:signed:4', '1:data:pointer:8', '2:EIGHTH:any:0', '3:data:signed:8'])
        got3, size3 = offsets(text3), sizes(text3)
        assert size3['Holder'] == (0, 0) and size3['Engine::Kind'] == (0, 0) and size3['Name'] == (0, 0) and size3['Text'][0] == 8, (tag, text3)
        assert got3['Holder.tag'] == (0, 0, 0) and got3['Text.data'] == (0, 8, 1) and got3['Name.data'] == (0, 0, 0), (tag, text3)
        run(tag + '-nested-absent', image, types=['Holder'], fields=['0:inner.gone:any:0'], reason='DwarfFieldNotFound')
        run(tag + '-nested-scalar', image, types=['Holder'], fields=['0:tag.x:any:0'], reason='DwarfFieldMismatch')
        # A path may not cross a pointer: Engine is only pointed at.
        run(tag + '-nested-pointer', image, types=['Holder'], fields=['0:engine.limit:any:0'], reason='DwarfFieldMismatch')
        run(tag + '-enumerator-absent', image, types=['Engine::Kind'], fields=['0:EIGHTH:any:0'], reason='DwarfFieldNotFound')
        run(tag + '-type-absent', image, types=['Nowhere'], fields=[], reason='DwarfTypeNotFound')
        # A static member, a bit-field and a member of the wrong kind or width are not accepted.
        run(tag + '-static', image, fields=['0:singleton:pointer:8'], reason='DwarfFieldNotFound')
        run(tag + '-tls', image, fields=['0:top:pointer:8'], reason='DwarfFieldNotFound')
        run(tag + '-bitfield', image, fields=['0:flags:unsigned:0'], reason='DwarfFieldMismatch')
        run(tag + '-kind', image, fields=['0:limit:pointer:0'], reason='DwarfFieldMismatch')
        run(tag + '-signed', image, fields=['0:limit:signed:4'], reason='DwarfFieldMismatch')
        run(tag + '-width', image, fields=['0:limit:unsigned:8'], reason='DwarfFieldMismatch')
        run(tag + '-absent', image, fields=['0:nothing:any:0'], reason='DwarfFieldNotFound')
        # Names that are prefixes, suffixes or unqualified nested types find nothing.
        for name in ('Engin', 'Engine::Leve', 'Level', 'Data', 'inner::Deep', 'Engine::Level::prev', 'Engine::', '::Engine', ''):
            run(tag + '-name', image, types=[name], fields=[], reason='DwarfTypeNotFound')
        # The walk is counted: too little work is a refusal, never a partial answer.
        work = int(re.search(r'^ok units=\d+ work=(\d+)$', text, re.M)[1])
        assert work > 100, text
        run(tag + '-work', image, work=work - 1, reason='DwarfTypesWorkLimit')
        run(tag + '-work0', image, work=0, reason='DwarfTypesWorkLimit')
        run(tag + '-exact', image, work=work)
        # Definitions that disagree across units.
        clash = w / (tag + '-clash')
        subprocess.run([compiler, '-O1', f'-gdwarf-{version}', '-shared', '-fPIC', str(w / 'clash.cc'), str(w / 'main2.cc'), str(w / 'user.cc'), '-o', str(clash)], check=True, timeout=120)
        run(tag + '-ambiguous', clash, types=['Name::Data'], fields=['0:name:any:8'], reason='DwarfTypeAmbiguous')
        text4 = run(tag + '-ambiguous-optional', clash, types=['?Name::Data', 'Name'], fields=['0:name:any:8', '1:data:pointer:8'])
        assert sizes(text4)['Name::Data'] == (0, 0) and offsets(text4)['Name::Data.name'] == (0, 0, 0) and offsets(text4)['Name.data'] == (0, 8, 1), (tag, text4)
        # An image without DWARF.
        stripped = w / (tag + '-stripped')
        subprocess.run(['objcopy', '--strip-debug', str(image), str(stripped)], check=True, timeout=60)
        run(tag + '-stripped', stripped, reason='DwarfTypesUnavailable')
run('no-dwarf', 'none', reason='DwarfTypesUnavailable')
run('too-many-types', w / 'g++-5', types=['T'] * 49, fields=[], reason='DwarfTypesSchemaLimit')
run('too-many-fields', w / 'g++-5', types=['Engine'], fields=['0:limit:any:0'] * 161, reason='DwarfTypesSchemaLimit')
run('bad-owner', w / 'g++-5', types=['Engine'], fields=['3:limit:any:0'], reason='DwarfTypesSchemaLimit')
run('no-types', w / 'g++-5', types=[], fields=[], reason='DwarfTypesSchemaLimit')
# Damaged debug sections: garbled DIEs and a unit that claims to be 2 GiB long.
data = bytearray((w / 'g++-5').read_bytes())
header = subprocess.run(['readelf', '-SW', str(w / 'g++-5')], capture_output=True, text=True, check=True).stdout
m = re.search(r'\.debug_info\s+PROGBITS\s+\S+\s+([0-9a-f]+)\s+([0-9a-f]+)', header); start, length = int(m[1], 16), int(m[2], 16)
for label, edit in (('garbled-info', lambda d: d.__setitem__(slice(start + 11, start + length), bytes((b * 37 + 11) & 255 for b in d[start + 11:start + length]))),
                    ('huge-unit', lambda d: d.__setitem__(slice(start, start + 4), b'\xf0\xff\xff\x7f'))):
    bad = bytearray(data); edit(bad); (w / label).write_bytes(bad)
    r = subprocess.run([str(exe), str(w / label), str(1 << 22), *TYPES, '--', *FIELDS], capture_output=True, text=True, timeout=60)
    # Either a named refusal or whatever libdw still reads within the work
    # bound; never a crash, a hang or an unbounded walk.
    assert r.returncode in (0, 2) and re.search(r'^(ok|error Dwarf\w+) units=\d+ work=\d+$', r.stdout, re.M), (label, r.returncode, r.stdout, r.stderr)
    assert int(re.search(r'work=(\d+)$', r.stdout, re.M)[1]) <= (1 << 22) + 1, r.stdout
    rows.append({'name': label, 'status': 'pass', 'stdout': r.stdout})
(w / 'result.json').write_text(json.dumps({'status': 'passed', 'sanitize': a.sanitize, 'rows': rows}, indent=1) + '\n')
print(f'dwarf-types: {len(rows)} checks passed')
