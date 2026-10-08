#!/usr/bin/env python3
"""Persistent fallback name index against libdw across compilers and DWARF versions."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import struct
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--work',required=True,type=Path);p.add_argument('--sanitize',action='store_true')
a=p.parse_args();os.umask(0o022);root=Path(__file__).resolve().parents[1];os.chdir(root)
w=a.work.resolve();w.mkdir(mode=0o755,parents=True,exist_ok=True)
flags=['-O1','-fsanitize=address,undefined','-fno-omit-frame-pointer'] if a.sanitize else ['-O2']
exe=w/'index'
subprocess.run(['clang' if a.sanitize else 'cc','-std=c11','-g',*flags,'-Wall','-Wextra','-Werror','tests/dwarf-index.c','src/debug/dwarf_index.c','src/debug/dwarf_cursor.c','src/binary/object.c','-ldw','-lelf','-o',str(exe)],check=True,timeout=60)
(w/'one.cc').write_text('namespace demo {struct Record {int value;}; __attribute__((noinline)) int calculate(Record *r){return r->value;}} extern int other(); int main(){demo::Record r={42};return demo::calculate(&r)+other();}\n')
(w/'two.cc').write_text('namespace second {struct Record {double value;};} int other(){second::Record r={1.0};return (int)r.value;}\n')
rows=[]
for compiler in ('g++','clang++'):
 for version in (2,3,4,5):
  name=compiler+str(version);binary=w/name
  subprocess.run([compiler,'-O0',f'-gdwarf-{version}',str(w/'one.cc'),str(w/'two.cc'),'-o',str(binary)],check=True,timeout=30)
  r=subprocess.run([str(exe),str(binary),str(w/(name+'.index'))],capture_output=True,text=True,timeout=60)
  (w/(name+'.log')).write_text(r.stdout+r.stderr)
  assert r.returncode==0,(name,r.stdout,r.stderr)
  rows.append({'name':name,'status':'pass','stdout':r.stdout})
# Owned ELF images with genuine small DWARF units located past 5 GiB.
def sparse(path,endian,width,version):
 pack=lambda fmt,*v:struct.pack(endian+fmt,*v)
 off=lambda v:pack('I' if width==4 else 'Q',v)
 abbrev=bytes([1,0x11,1,3,0xe,0,0,2,0x13,0,3,0xe,0xb,0xb,0,0,3,0x2e,0,3,0xe,0,0,0])
 def unit(function):
  header=pack('HBB',version,1,8)+off(0) if version==5 else pack('H',version)+off(0)+bytes([8])
  body=header+bytes([1])+off(1)+bytes([2])+off(6)+bytes([4])
  if function:body+=bytes([3])+off(13)
  body+=bytes([0])
  return (pack('I',len(body)) if width==4 else pack('IQ',0xffffffff,len(body)))+body
 names=b'\0.shstrtab\0.debug_info\0.debug_abbrev\0.debug_str\0'
 parts=[('.shstrtab',3,names),('.debug_info',1,unit(True)+unit(False)),('.debug_abbrev',1,abbrev),('.debug_str',1,b'\0unit\0Record\0calculate\0')]
 with path.open('wb') as f:
  f.write(bytes(64));headers=[bytes(64)]
  for name,kind,data in parts:
   if name=='.debug_info':f.seek(5*1024**3+17)
   offset=f.tell();f.write(data)
   headers.append(pack('IIQQQQIIQQ',names.index(name.encode()),kind,0,0,offset,len(data),0,0,1,0))
  table=f.tell();f.write(b''.join(headers));f.seek(0)
  f.write(pack('16sHHIQQQIHHHHHH',b'\x7fELF\x02'+(b'\x01' if endian=='<' else b'\x02')+b'\x01'+bytes(9),2,62,1,0,0,table,0,64,0,0,64,len(headers),1))
for endian in ('<','>'):
 for width in (4,8):
  for version in (4,5):
   name=f'sparse-{endian=="<"}-{width}-{version}';binary=w/(name+'.elf');sparse(binary,endian,width,version)
   r=subprocess.run([str(exe),str(binary),str(w/(name+'.index'))],capture_output=True,text=True,timeout=60)
   (w/(name+'.log')).write_text(r.stdout+r.stderr);assert r.returncode==0,(name,r.stdout,r.stderr)
   assert binary.stat().st_size>5*1024**3 and binary.stat().st_blocks*512<32768
   rows.append({'name':name,'status':'pass','stdout':r.stdout})
(w/'results.json').write_text(json.dumps({'status':'pass','checks':rows},indent=2)+'\n')
print('Persistent DWARF index checks passed:',len(rows))
