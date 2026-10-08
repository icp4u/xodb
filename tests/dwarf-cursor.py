#!/usr/bin/env python3
"""Small exact libdw oracles plus bounded malformed DWARF cursor inputs."""
import argparse
import json
import os
from pathlib import Path
import struct
import subprocess

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--work',required=True,type=Path)
p.add_argument('--sanitize',action='store_true')
a=p.parse_args();os.umask(0o022)
root=Path(__file__).resolve().parents[1];os.chdir(root)
w=a.work.resolve();w.mkdir(parents=True,exist_ok=True,mode=0o755)
exe=w/'cursor'
flags=['-O1','-fsanitize=address,undefined','-fno-omit-frame-pointer'] if a.sanitize else ['-O2']
subprocess.run(['clang' if a.sanitize else 'cc','-std=c11','-g',*flags,'-Wall','-Wextra','-Werror','tests/dwarf-cursor.c','src/debug/dwarf_cursor.c','src/binary/object.c','-ldw','-lelf','-o',str(exe)],check=True,timeout=60)
source='''namespace demo {
struct Record { int value; static constexpr unsigned constant = 42; };
template<class T> struct Box { T item; Box<T> *next; };
__attribute__((noinline)) int value(Box<Record> *box) { return box->item.value + Record::constant; }
}
extern int auxiliary();
int main() { demo::Box<demo::Record> box = {{7},nullptr}; return demo::value(&box)+auxiliary(); }
'''
(w/'fixture.cc').write_text(source)
(w/'second.cc').write_text('struct Other { double item; }; int auxiliary() { Other x={1.5}; return (int)x.item; }\n')
rows=[]
def run(name,path,mode=None,reason=None):
 cmd=[str(exe),str(path)]+([mode] if mode else [])
 r=subprocess.run(cmd,capture_output=True,text=True,timeout=45)
 (w/(name+'.log')).write_text(r.stdout+r.stderr)
 assert r.returncode==(2 if reason else 0),(name,r.returncode,r.stdout,r.stderr)
 if reason:assert 'refused ' in r.stderr and reason in r.stderr,(name,r.stderr)
 rows.append({'name':name,'status':'pass','stdout':r.stdout,'stderr':r.stderr})
for compiler in ('g++','clang++'):
 for version in (2,3,4,5):
  name=compiler+str(version);out=w/name
  subprocess.run([compiler,'-O1','-gdwarf-'+str(version),str(w/'fixture.cc'),str(w/'second.cc'),'-o',str(out)],check=True,timeout=30)
  run(name,out);run(name+'-skip',out,'skip');run(name+'-unit',out,'unit')
# Valid ELF containers for hand-built DWARF; mutations are in the sections.
def elf(path,body,abbrev):
 names=b'\0.shstrtab\0.debug_info\0.debug_abbrev\0.debug_str\0'
 sections=[(1,3,names),(11,1,body),(23,1,abbrev),(37,1,b'\0unit\0leaf\0')]
 data=bytearray(64);headers=[bytes(64)]
 for name,kind,payload in sections:
  offset=len(data);data+=payload
  headers.append(struct.pack('<IIQQQQIIQQ',name,kind,0,0,offset,len(payload),0,0,1,0))
 table=len(data);data+=b''.join(headers)
 data[:64]=struct.pack('<16sHHIQQQIHHHHHH',b'\x7fELF\x02\x01\x01'+bytes(9),2,62,1,0,0,table,0,64,0,0,64,len(headers),1)
 path.write_bytes(data)
def unit(body):
 content=struct.pack('<HIB',4,0,8)+body
 return struct.pack('<I',len(content))+content
abbrev=bytes([1,0x11,1,3,0xe,0,0,2,0x34,0,3,0xe,0x1c,0xb,0,0,0])
body=b'\x01'+struct.pack('<I',1)+b'\x02'+struct.pack('<I',6)+b'\x2a\0'
valid=unit(body)
cases=[('trailing-byte',valid+b'\0',abbrev,'DwarfTruncated'),
       ('unit-overrun',struct.pack('<I',999999)+valid[4:],abbrev,'DwarfUnitExtent'),
       ('unterminated',unit(body[:-1]),abbrev,'DwarfUnterminatedChildren'),
       ('second-root',unit(body+body),abbrev,'DwarfUnitTrailingBytes'),
       ('missing-code',unit(b'\x03'),abbrev,'DwarfAbbreviationMissing'),
       ('invalid-children',valid,abbrev[:2]+b'\x02'+abbrev[3:],'DwarfAbbreviationMalformed'),
       ('duplicate-abbrev',valid,abbrev[:-1]+abbrev,'DwarfDuplicateAbbreviation'),
       ('leb-overflow',valid,b'\xff'*10,'DwarfLebOverflow'),
       ('unsupported-form',valid,bytes([1,0x11,1,3,0x70,0,0,0]),'DwarfFormUnsupported'),
       ('null-root',unit(b'\0'),abbrev,'DwarfChildMalformed'),
       ('reserved-length',struct.pack('<I',0xfffffff0)+valid[4:],abbrev,'DwarfReservedLength')]
for name,info,ab,reason in cases:
 out=w/(name+'.elf');elf(out,info,ab);run(name,out,'raw',reason)
# Two attributes exceed the page cache together. Tiny slices must resume
# inside the DIE instead of replaying evicted pages indefinitely.
ab=bytes([1,0x11,1,0x25,8,0x1b,8,3,0xe,0,0,2,0x34,0,3,0xe,0x1c,0xb,0,0,0])
info=unit(b'\x01'+b'p'*700000+b'\0'+b'd'*700000+b'\0'+body[1:])
out=w/'long-inline.elf';elf(out,info,ab);run('long-inline',out)
(w/'results.json').write_text(json.dumps({'status':'pass','checks':rows},indent=2)+'\n')
print('DWARF cursor checks passed:',len(rows))
