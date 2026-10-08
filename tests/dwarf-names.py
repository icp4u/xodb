#!/usr/bin/env python3
"""Ranged accelerator lookup: compiler oracles, sparse images and corrupt indexes."""
import argparse
import json
import os
from pathlib import Path
import re
import struct
import subprocess

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--work',required=True,type=Path)
p.add_argument('--sanitize',action='store_true')
a=p.parse_args();os.umask(0o022)
root=Path(__file__).resolve().parents[1];os.chdir(root)
w=a.work.resolve();w.mkdir(mode=0o755,parents=True,exist_ok=True)
exe=w/'names'
flags=['-O1','-fsanitize=address,undefined','-fno-omit-frame-pointer'] if a.sanitize else ['-O2']
subprocess.run(['clang' if a.sanitize else 'cc','-std=c11','-g',*flags,'-Wall','-Wextra','-Werror','tests/dwarf-names.c','src/debug/dwarf_names.c','src/binary/object.c','-ldw','-lelf','-o',str(exe)],check=True,timeout=60)
rows=[]
def run(label,path,name='Record',hits=None,reason=None,raw=False,budget=97,max_bytes=None):
 r=subprocess.run([str(exe),str(path),name,'raw' if raw else 'oracle',str(budget)],capture_output=True,text=True,timeout=30)
 (w/(label+'.log')).write_text(r.stdout+r.stderr)
 assert r.returncode==(2 if reason else 0),(label,r.returncode,r.stdout,r.stderr)
 if reason:assert reason in r.stderr,(label,r.stderr)
 if hits is not None:assert len(re.findall(r'^hit ',r.stdout,re.M))==hits,(label,r.stdout)
 if max_bytes is not None:assert int(re.search(r'bytes=(\d+)',r.stdout)[1])<=max_bytes,(label,r.stdout)
 rows.append({'name':label,'status':'pass','stdout':r.stdout,'stderr':r.stderr})
source='''namespace demo {struct Record {int value;};
__attribute__((noinline)) int calculate(Record *r) {return r->value;}}
extern int other();int main(){demo::Record r={42};return demo::calculate(&r)+other();}
'''
(w/'fixture.cc').write_text(source)
(w/'other.cc').write_text('namespace other {struct Record {double value;};} int other(){other::Record r={1.0};return (int)r.value;}\n'.replace('namespace other','namespace second').replace('other::Record','second::Record'))
for version in (4,5):
 out=w/f'clang{version}'
 subprocess.run(['clang++','-O0',f'-gdwarf-{version}','-gpubnames',str(w/'fixture.cc'),str(w/'other.cc'),'-o',str(out)],check=True,timeout=30)
 # Clang emits .debug_names for DWARF 5, and GNU pubnames for DWARF 4.
 if version==5:
  run('clang-record',out,hits=2);run('clang-function',out,'calculate',hits=1)
  run('clang-missing',out,'Missing',hits=0);run('clang-one-byte',out,hits=2,budget=1)
  r=subprocess.run([str(exe),str(out),'Record','mutate'],capture_output=True,text=True,timeout=30)
  assert r.returncode==0,(r.stdout,r.stderr)
  rows.append({'name':'changed-retained-source','status':'pass','stdout':r.stdout})

 else:
  subprocess.run(['gdb','-nx','-nh','-batch','-iex','set auto-load off','-ex','file '+str(out),'-ex','save gdb-index '+str(w)],check=True,timeout=30,capture_output=True)
  indexed=w/'gdb9'
  subprocess.run(['objcopy','--add-section','.gdb_index='+str(out)+'.gdb-index',str(out),str(indexed)],check=True,timeout=30)
  run('gdb-record',indexed,'demo::Record',hits=1);run('gdb-other',indexed,'second::Record',hits=1)
  run('gdb-missing',indexed,'Missing',hits=0);run('gdb-one-byte',indexed,'demo::Record',hits=1,budget=1)
  data=Path(str(out)+'.gdb-index').read_bytes();header=struct.unpack('<7I',data[:28]);assert header[0]==9
  for old_version in (7,8):
   old_header=[old_version]+[offset-4 for offset in header[1:6]]
   old_data=struct.pack('<6I',*old_header)+data[28:header[5]]+data[header[6]:]
   index_path=w/f'index{old_version}';index_path.write_bytes(old_data)
   converted=w/f'gdb{old_version}'
   subprocess.run(['objcopy','--add-section','.gdb_index='+str(index_path),str(out),str(converted)],check=True,timeout=30)
   run(f'gdb-version-{old_version}',converted,'demo::Record',hits=1)
  # Mutate header/table/vector bounds in the actual GDB-produced index.
  def malformed_gdb(label,position,value,reason):
   corrupt=bytearray(data);struct.pack_into('<I',corrupt,position,value)
   idx=w/(label+'.index');idx.write_bytes(corrupt);bad=w/(label+'.elf')
   subprocess.run(['objcopy','--add-section','.gdb_index='+str(idx),str(out),str(bad)],check=True,timeout=30)
   run(label,bad,'demo::Record',raw=True,reason=reason)
  malformed_gdb('gdb-version',0,99,'GdbIndexVersionUnsupported')
  malformed_gdb('gdb-header',4,len(data)+4096,'GdbIndexHeaderExtent')
  malformed_gdb('gdb-shortcut',24,header[6]+4,'GdbIndexShortcutExtent')
  # Locate the exact independent GDB hash-table entry by its pool string.
  for at in range(header[4],header[5],8):
   name,vector=struct.unpack_from('<II',data,at)
   if data[header[6]+name:].split(bytes([0]),1)[0]==b'demo::Record':break
  else:raise AssertionError('GDB oracle name absent')
  malformed_gdb('gdb-pool',at,len(data),'GdbIndexPoolExtent')
  malformed_gdb('gdb-vector',header[6]+vector,0xffffffff,'GdbIndexVectorExtent')
  malformed_gdb('gdb-cu',header[6]+vector+4,0x10ffffff,'GdbIndexCuInvalid')

# Hand-built index with owned opaque CU bytes. This checks format boundaries;
# actual DIE agreement is separately checked by libdw above.
def elf(path,index,kind='.debug_names',endian='<',sparse=False):
 names=('\0.shstrtab\0.debug_info\0.debug_str\0'+kind+'\0').encode()
 parts=[('.shstrtab',3,names),('.debug_info',1,bytes(1024)),('.debug_str',1,b'\0Record\0Other\0'),(kind,1,index)]
 with path.open('wb') as f:
  f.write(bytes(64));headers=[bytes(64)]
  for name,typ,data in parts:
   if sparse and name==kind:f.seek(5*1024**3+17)
   off=f.tell();f.write(data)
   headers.append(struct.pack(endian+'IIQQQQIIQQ',names.index(name.encode()),typ,0,0,off,len(data),0,0,1,0))
  table=f.tell();f.write(b''.join(headers));f.seek(0)
  f.write(struct.pack(endian+'16sHHIQQQIHHHHHH',b'\x7fELF\x02'+(b'\x01' if endian=='<' else b'\x02')+b'\x01'+bytes(9),2,62,1,0,0,table,0,64,0,0,64,len(headers),1))
def names(endian='<',width=4,hashes=True,**replace):
 pack=lambda fmt,*v:struct.pack(endian+fmt,*v)
 off=lambda v:pack('I' if width==4 else 'Q',v)
 # abbreviation: structure with explicit CU index and CU-relative DIE ref.
 ab=bytes([1,0x13,1,0x0b,3,0x13,0,0,0])
 h=5381
 for c in b'record':h=(h*33+c)&0xffffffff
 values={'cu':0,'die':32,'bucket':1,'str':1,'entry':0,'ab':ab,'version':5,'names':1,'buckets':1 if hashes else 0,'length_extra':0}
 values.update(replace);v=values
 hdr=pack('HH7I',v['version'],0,1,0,0,v['buckets'],v['names'],len(v['ab']),0)
 tables=off(v['cu'])
 if v['buckets']:tables+=pack('II',v['bucket'],h)
 tables+=off(v['str'])+off(v['entry'])
 body=hdr+tables+v['ab']+bytes([1,0])+pack('I',v['die'])+bytes([0])
 return (pack('I',len(body)+v['length_extra']) if width==4 else pack('IQ',0xffffffff,len(body)+v['length_extra']))+body
for endian in ('<','>'):
 for width in (4,8):
  for hashed in (False,True):
   label=f'sparse-{endian=="<"}-{width}-{hashed}';path=w/(label+'.elf')
   elf(path,names(endian,width,hashed),endian=endian,sparse=True)
   run(label,path,raw=True,hits=1,max_bytes=512)
   assert path.stat().st_size>5*1024**3 and path.stat().st_blocks*512<32768
# Many per-CU contributions must resume through independent headers/indexes.
path=w/'many.elf';elf(path,b''.join(names(cu=i*8,die=32) for i in range(100)))
run('many-contributions',path,raw=True,hits=100,budget=13)
path=w/'no-hash.elf';elf(path,names(hashes=False));run('no-hash',path,raw=True,hits=1)
empty=struct.pack('<HH7I',5,0,1,0,0,0,0,1,0)+struct.pack('<I',0)+bytes([0])
path=w/'empty.elf';elf(path,struct.pack('<I',len(empty))+empty);run('empty',path,raw=True,hits=0)

cases=[('length',{'length_extra':1000},'DwarfIndexContributionExtent'),
       ('version',{'version':6},'DwarfIndexVersionUnsupported'),
       ('bucket',{'bucket':2},'DwarfIndexBucketExtent'),
       ('string',{'str':999},'DwarfIndexExtent'),
       ('entry',{'entry':999},'DwarfIndexEntryExtent'),
       ('cu',{'cu':99999},'DwarfIndexDieExtent'),
       ('die',{'die':99999},'DwarfIndexDieExtent'),
       ('missing-abbrev',{'ab':bytes([0])},'DwarfIndexAbbreviationMissing'),
       ('duplicate-abbrev',{'ab':bytes([1,0x13,1,0xb,3,0x13,0,0])*2+bytes([0])},'DwarfIndexDuplicateAbbreviation'),
       ('bad-form',{'ab':bytes([1,0x13,1,0x13,3,0x13,0,0,0])},'DwarfIndexAttributeForm')]
for label,args,reason in cases:
 path=w/(label+'.elf');elf(path,names(**args));run(label,path,raw=True,reason=reason)
(w/'results.json').write_text(json.dumps({'status':'pass','checks':rows},indent=2)+'\n')
print('DWARF name-index checks passed:',len(rows))
