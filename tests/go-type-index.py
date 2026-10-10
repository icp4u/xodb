#!/usr/bin/env python3
"""Fast component lane: independent small Go-DWARF images and C index checks.
Uses CHECK under NDEBUG, a planted wrong count, GCC and Clang sanitizers."""
import argparse, os, resource, subprocess, time
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--work',required=True,type=Path);a=p.parse_args()
root=Path(__file__).resolve().parents[1];os.chdir(root);os.umask(0o022)
w=a.work.resolve();w.mkdir(parents=True,exist_ok=True);w.chmod(0o755)
resource.setrlimit(resource.RLIMIT_CORE,(0,0));began=time.monotonic()
# DWARF4; Go producer extensions have independent fixed encodings here.
# References are CU-relative, runtime-type offsets are section-relative.
for mode in ('valid','collision','bad-form'):
 def abbrev(code,tag,children,attrs):
  return '\n'.join([f'.uleb128 {code}',f'.uleb128 {tag}',f'.byte {children}',*[f'.uleb128 {name}\n.uleb128 {form}' for name,form in attrs],'.byte 0,0'])
 abbrevs=[abbrev(1,0x11,1,[(0x13,5)]),
          abbrev(2,0x24,0,[(3,8),(0x0b,0x0b),(0x2900,0x0f),(0x2904,0x0f if mode=='bad-form' else 1)]),
          abbrev(3,0x16,0,[(3,8),(0x49,0x13),(0x2900,0x0f),(0x2904,1)]),
          abbrev(4,0x13,0,[(3,8),(0x0b,0x0b)]),
          abbrev(5,0x16,0,[(3,8),(0x49,0x13),(0x2900,0x0f),(0x2904,1),(0x2901,0x13),(0x2902,0x13)])]
 source='''
.section .debug_abbrev,"",@progbits
'''+ '\n'.join(abbrevs)+'''
.byte 0
.section .debug_info,"",@progbits
.Lcu: .long .Lend-.Lstart
.Lstart: .short 4
.long 0
.byte 8
.byte 1
.short 0x16
.Lint: .byte 2
.asciz "int"
.byte 8,2
.quad 64
.byte 3
.asciz "alias"
.long .Lint-.Lcu
.byte 2
.quad 64
.Luint: .byte 2
.asciz "uint"
.byte 8,7
.quad '''+str(64 if mode=='collision' else 72)+'''
.Liface: .byte 4
.asciz "runtime.eface"
.byte 16
.byte 3
.asciz "interface {}"
.long .Liface-.Lcu
.byte 20
.quad 80
.byte 5
.asciz "map[int]uint"
.long .Lint-.Lcu
.byte 21
.quad 88
.long .Lint-.Lcu
.long .Luint-.Lcu
.byte 2
.asciz "unreachable"
.byte 8,0
.quad 0
.byte 0
.Lend:
.section .note.GNU-stack,"",@progbits
'''
 asm=w/(mode+'.S');asm.write_text(source)
 subprocess.run(['cc','-shared','-nostdlib','-Wl,--build-id=none',str(asm),'-o',str(w/(mode+'.so'))],check=True,timeout=10)
for cc,flags,label in ((os.environ.get('CC','cc'),['-O2'],'gcc'),('clang',['-O1','-fsanitize=address,undefined','-fno-omit-frame-pointer'],'san')):
 exe=w/label
 subprocess.run([cc,'-std=c11','-g','-DNDEBUG','-Wall','-Wextra','-Werror',*flags,'tests/go-type-index.c','src/language/go_type_index.c','src/language/go_layout.c','-ldw','-lelf','-o',str(exe)],check=True,timeout=30)
 env=dict(os.environ,ASAN_OPTIONS='detect_leaks=1:abort_on_error=1',UBSAN_OPTIONS='halt_on_error=1')
 for mode in ('valid','collision','bad-form'):
  subprocess.run([str(exe),str(w/(mode+'.so')),mode],env=env,check=True,timeout=5)
 wrong=subprocess.run([str(exe),str(w/'valid.so'),'wrong'],env=env,capture_output=True,text=True,timeout=5)
 (w/(label+'-wrong.log')).write_text(wrong.stdout+wrong.stderr)
 if wrong.returncode==0 or 'xgo_type_index_count(index)' not in wrong.stderr:raise SystemExit('wrong count must fail under NDEBUG')
print(f'go-type-index: normal, sanitizer and wrong oracle pass ({time.monotonic()-began:.2f}s)')
