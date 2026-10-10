#!/usr/bin/env python3
"""Fast PE component lane: compiler oracles, layout distinctions and hostile fields.

--fuzz adds a bounded periodic ASan/UBSan libFuzzer run.
"""
import argparse
import array
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import time
from helpers import orphans

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--work',type=Path,required=True)
p.add_argument('--fuzz',action='store_true')
a=p.parse_args()
root=Path(__file__).resolve().parents[1]
os.chdir(root);os.umask(0o022);orphans.adopt()
w=a.work.resolve();w.mkdir(parents=True)
started=time.monotonic();results=[]

def command(args,name,expect=0,timeout=30):
    begin=time.monotonic()
    run=subprocess.run(args,capture_output=True,text=True,timeout=timeout)
    (w/(name+'.log')).write_text(run.stdout+run.stderr)
    row=dict(name=name,exit=run.returncode,expected=expect,seconds=time.monotonic()-begin,status='pass' if run.returncode==expect else 'fail')
    results.append(row)
    (w/'results.json').write_text(json.dumps(dict(checks=results,elapsed_seconds=time.monotonic()-started),indent=2)+'\n')
    assert run.returncode==expect,(row,run.stdout,run.stderr)
    return run.stdout

(w/'kernel32.def').write_text('LIBRARY KERNEL32.dll\nEXPORTS\n    GetCurrentProcessId\n')
command(['lld-link','/lib','/def:'+str(w/'kernel32.def'),'/machine:x64','/out:'+str(w/'kernel32.lib')],'import-library')
command(['clang','--target=x86_64-pc-windows-msvc','-O2','-g','-gcodeview',
         '-ffile-prefix-map='+str(root)+'=.', '-c','tests/fixtures/pe/library.c','-o',str(w/'library.obj')],'compile-fixture')
command(['lld-link','/dll','/noentry','/machine:x64','/debug','/pdb:'+str(w/'owned-pe.pdb'),
         '/def:tests/fixtures/pe/library.def','/out:'+str(w/'owned-pe.dll'),str(w/'library.obj'),str(w/'kernel32.lib')],'link-fixture')
check=w/'check'
command(['cc','-std=c11','-O2','-g','-DNDEBUG','-Wall','-Wextra','-Werror','tests/pe-image.c','src/binary/pe.c','-o',str(check)],'compile-check')
actual=command([str(check),str(w/'owned-pe.dll')],'file-and-memory')
command([str(check),str(w/'owned-pe.dll'),'wrong-result'],'wrong-result',expect=-6)
command([str(check),str(w/'owned-pe.dll'),'faults'],'source-faults')
oracle=command(['llvm-readobj','--file-headers','--sections','--coff-exports','--coff-imports','--coff-debug-directory','--unwind',str(w/'owned-pe.dll')],'compiler-oracle')
for line in actual.splitlines():
    if not line.startswith('export\t'):continue
    _,name,ordinal,rva,forward=line.split('\t')
    block=next(block for block in re.findall(r'Export \{(.*?)\n\}',oracle,re.S) if re.search(r'\n  Name: '+re.escape(name)+r'\n',block))
    assert int(re.search(r'Ordinal: (\d+)',block)[1])==int(ordinal)
    if forward:assert forward in block
    else:assert int(re.search(r'RVA: (0x[0-9a-fA-F]+)',block)[1],16)==int(rva)
base=0x180000000
expected=[tuple(int(x,16)-base for x in row) for row in re.findall(r'StartAddress: \((0x[0-9A-Fa-f]+)\)\s+EndAddress: \((0x[0-9A-Fa-f]+)\)\s+UnwindInfoAddress: \((0x[0-9A-Fa-f]+)\)',oracle)]
found=[tuple(map(int,line.split('\t')[1:])) for line in actual.splitlines() if line.startswith('function\t')]
assert found==expected and len(found)==2,(found,expected)
original=(w/'owned-pe.dll').read_bytes()
pe=struct.unpack_from('<I',original,60)[0];optional=pe+24
count=struct.unpack_from('<H',original,pe+6)[0];section_table=optional+struct.unpack_from('<H',original,pe+20)[0]
sections=[struct.unpack_from('<IIII',original,section_table+i*40+8) for i in range(count)]

def offset(rva):
    for virtual,start,size,raw in sections:
        if start<=rva<start+size:return raw+rva-start
    raise AssertionError(('no file byte',rva))

def mutation(name,edits,status=3):
    data=bytearray(original)
    for at,blob in edits:data[at:at+len(blob)]=blob
    path=w/name;path.write_bytes(data)
    command([str(check),str(path),'status='+str(status)],name)
    return path

u16=lambda n:struct.pack('<H',n)
u32=lambda n:struct.pack('<I',n)
export_rva,export_size=struct.unpack_from('<II',original,optional+112)
export=offset(export_rva)
functions=struct.unpack_from('<I',original,export+20)[0]
ordinals=offset(struct.unpack_from('<I',original,export+36)[0])
pdata=offset(struct.unpack_from('<I',original,optional+112+3*8)[0])
debug=offset(struct.unpack_from('<I',original,optional+112+6*8)[0])
forward=next(int(line.split('\t')[3]) for line in actual.splitlines() if line.startswith('export\tforwarded_pid\t'))
cv_size,cv_rva,cv_file=struct.unpack_from('<III',original,debug+16)
mutation('pe32',[(optional,u16(0x10b))],2)
mutation('section-limit',[(pe+6,u16(97))],4)
mutation('optional-directory-overflow',[(optional+108,u32(17))])
mutation('image-base-overflow',[(optional+24,struct.pack('<Q',0xfffffffffffff000))])
mutation('directory-range-overflow',[(optional+112+6*8,u32(0xfffffff0)+u32(128))])
mutation('section-virtual-overlap',[(section_table+40+12,u32(sections[0][1]))])
mutation('section-raw-overlap',[(section_table+40+20,u32(sections[0][3]))])
mutation('export-limit',[(export+20,u32(65537))],4)
mutation('bad-export-ordinal',[(ordinals,u16(functions))])
mutation('forwarder-no-terminator',[(offset(forward),b'A'*(export_rva+export_size-forward))])
mutation('pdata-overlap',[(pdata+12,u32(expected[0][1]-1))])
# One empty row is left out and counted; the image keeps every other row.
empty=w/'pdata-empty-row';data=bytearray(original);data[pdata+16:pdata+20]=data[pdata+12:pdata+16];empty.write_bytes(data)
command([str(check),str(empty),'functions=%d,1'%(len(expected)-1)],'pdata-empty-row')

def crafted(name,rows,empty=()):
    """A minimal image with one-byte functions sharing one unwind record."""
    align=lambda n,to:(n+to-1)&~(to-1)
    text_rva=0x1000;rdata_rva=text_rva+align(rows,0x1000);table_rva=rdata_rva+16
    values=array.array('I',bytes(12*rows))
    values[0::3]=array.array('I',range(text_rva,text_rva+rows))
    values[1::3]=array.array('I',range(text_rva+1,text_rva+rows+1))
    values[2::3]=array.array('I',[rdata_rva])*rows
    for row in empty:values[3*row+1]=values[3*row]
    if sys.byteorder!='little':values.byteswap()
    rdata=bytes([1,0,0,0])+bytes(12)+values.tobytes()
    text_raw=0x400;rdata_raw=text_raw+align(rows,0x200)
    image=bytearray(rdata_raw+align(len(rdata),0x200))
    image[0:2]=b'MZ';image[60:64]=u32(64);image[64:68]=b'PE\0\0'
    image[68:88]=struct.pack('<HHIIIHH',0x8664,2,0,0,0,240,0x2022)
    header=bytearray(240);header[0:2]=u16(0x20b)
    struct.pack_into('<Q',header,24,0x180000000);struct.pack_into('<II',header,32,0x1000,0x200)
    struct.pack_into('<II',header,56,rdata_rva+align(len(rdata),0x1000),0x400)
    struct.pack_into('<I',header,108,16);struct.pack_into('<II',header,112+3*8,table_rva,12*rows)
    image[88:328]=header
    image[328:368]=struct.pack('<8sIIIIIIHHI',b'.text',rows,text_rva,align(rows,0x200),text_raw,0,0,0,0,0x60000020)
    image[368:408]=struct.pack('<8sIIIIIIHHI',b'.rdata',len(rdata),rdata_rva,align(len(rdata),0x200),rdata_raw,0,0,0,0,0x40000040)
    image[text_raw:text_raw+rows]=b'\xc3'*rows;image[rdata_raw:rdata_raw+len(rdata)]=rdata
    path=w/name;path.write_bytes(image);return path

# More rows than the former 262,144 cap, with empty rows at both ends and inside.
command([str(check),str(crafted('pdata-300k',300000,(0,150000,299999))),'functions=299997,3'],'pdata-300k')
mutation('pdata-in-data',[(pdata,u32(0x3000)+u32(0x3004))])
mutation('codeview-file-pointer-is-rva',[(debug+24,u32(cv_rva))])
mutation('codeview-missing-terminator',[(cv_file+24,b'A'*(cv_size-24))])

imports=offset(struct.unpack_from('<I',original,optional+112+8)[0])
mutation('bound-iat-outside-image',[(imports,u32(0)),(imports+4,u32(1)),(imports+16,u32(0xfffffff0))])
bound=mutation('bound-iat-unavailable',[(imports,u32(0)),(imports+4,u32(1))],0)
command([str(check),str(bound),'bound'],'bound-iat-explicit-state')
eat=offset(struct.unpack_from('<I',original,export+28)[0]);base_ordinal=struct.unpack_from('<I',original,export+16)[0]
data_ordinal=next(int(line.split('\t')[2]) for line in actual.splitlines() if line.startswith('export\texported_counter\t'))
mutation('data-export-in-headers',[(eat+(data_ordinal-base_ordinal)*4,u32(64))],0)

# Truncated prefixes at header and table boundaries must be rejected.
# Complete referenced data can remain valid without unrelated trailing bytes.
for length in (0,1,2,63,64,pe+3,optional+111,section_table+39):
    path=w/('truncated-'+str(length));path.write_bytes(original[:length])
    # The CLI harness requires a nonempty input; an empty source is fuzzed.
    if length:command([str(check),str(path),'status='+str(1 if length<2 else 3)],'truncated-'+str(length))
if a.fuzz:
    # The row cap is a cap: exactly at it loads, one past it is refused unread.
    command([str(check),str(crafted('pdata-cap',4194304)),'functions=4194304,0'],'pdata-cap',timeout=60)
    command([str(check),str(crafted('pdata-over-cap',4194305)),'status=4'],'pdata-over-cap',timeout=60)
    for name in ('pdata-cap','pdata-over-cap'):(w/name).unlink()
    seeds=w/'seeds';seeds.mkdir()
    (seeds/'file').write_bytes(b'\0'+original)
    size,headers=struct.unpack_from('<II',original,optional+56)
    memory=bytearray(size);memory[:headers]=original[:headers]
    for virtual,rva,size,raw in sections:memory[rva:rva+size]=original[raw:raw+size]
    (seeds/'memory').write_bytes(b'\1'+memory)
    fuzz=w/'fuzz'
    command(['clang','-std=c11','-Wall','-Wextra','-Werror','-g','-O1','-fsanitize=fuzzer,address,undefined','tests/pe-fuzz.c','src/binary/pe.c','-o',str(fuzz)],'compile-fuzz')
    command([str(fuzz),str(seeds),'-max_total_time=30','-timeout=3','-rss_limit_mb=768','-max_len=65536','-artifact_prefix='+str(w)+'/'],'fuzz',timeout=50)
assert orphans.reap(),'a child process is still running'
print(json.dumps(dict(status='pass',checks=len(results),elapsed_seconds=time.monotonic()-started)))
