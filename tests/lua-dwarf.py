#!/usr/bin/env python3
"""Owned Lua DWARF fixtures: valid profiles, wrong layouts and corrupt units."""
import os
from pathlib import Path
import struct
import subprocess
import tempfile

root=Path(__file__).resolve().parents[1]
os.chdir(root)
os.umask(0o022)
(root/'.work').mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix='lua-dwarf-',dir=root/'.work') as temporary:
    work=Path(temporary); work.chmod(0o755)
    driver=work/'driver.c'
    driver.write_text('''#include "lua.h"
#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>
int main(int argc, char **argv) {
 if (argc != 2) return 2;
 int fd=open(argv[1], O_RDONLY); if(fd<0) return 3;
 Dwarf *d=dwarf_begin(fd,DWARF_C_READ); struct xl_layout p;
 const uint8_t id[]={1},version[]={5,4,9};
 const char *error=d?xl_layout_build(d,id,1,version,&p):"LuaDwarfMalformed";
 puts(error?error:"ok"); if(d)dwarf_end(d); close(fd); return 0;
}
''')
    executable=work/'check'
    subprocess.run(['cc','-std=c11','-Wall','-Wextra','-Werror','-Isrc/language',str(driver),
        'src/language/lua_layout.c','-ldw','-lelf','-o',str(executable)],check=True,timeout=30)
    def check(target,expected):
        actual=subprocess.check_output([str(executable),str(target)],text=True,timeout=15).strip()
        assert actual==expected,(target.name,actual,expected)
        print(target.name,actual)
    for name,wrong in [('good',0),('wrong-number',1)]:
        target=work/name
        subprocess.run(['cc','-g','-O0','-fno-eliminate-unused-debug-types','-DWRONG_NUMBER='+str(wrong),
            'tests/fixtures/lua/layout.c','-o',str(target)],check=True,timeout=30)
        check(target,'LuaLayoutUnsupported' if wrong else 'ok')
    for encoding in ('zlib','zlib-gnu'):
        target=work/encoding
        subprocess.run(['objcopy','--compress-debug-sections='+encoding,str(work/'good'),str(target)],check=True,timeout=10)
        check(target,'ok')
    empty=work/'empty'
    subprocess.run(['cc','-g0','tests/fixtures/lua/layout.c','-o',str(empty)],check=True,timeout=30)
    # Root CU and irrelevant named base type; malformed child/sibling DIEs
    # must not quietly end the scan or certify a partial layout.
    abbrev=bytes([1,0x11,1,0,0,2,0x24,0,3,8,0,0,0])
    def unit(body,address_size=8):
        content=struct.pack('<HIB',4,0,address_size)+body
        return struct.pack('<I',len(content))+content
    valid=unit(b'\x01\x02unused\0\0')
    fixtures=[('missing-types',valid,abbrev,'LuaDwarfTypesUnavailable'),
        ('oversized-unit',struct.pack('<I',4000010)+valid[4:],abbrev,'LuaDwarfMalformed'),
        ('truncated-unit',valid[:-2],abbrev,'LuaDwarfMalformed'),
        ('bad-child',unit(b'\x01\x7f\0'),abbrev,'LuaDwarfMalformed'),
        ('bad-sibling',unit(b'\x01\x02unused\0\x7f\0'),abbrev,'LuaDwarfMalformed'),
        ('trailing-byte',valid+b'\xff',abbrev,'LuaDwarfMalformed'),
        ('wrong-address-size',unit(b'\x01\0',4),abbrev,'LuaDwarfMalformed'),
        ('missing-abbrev',valid,b'','LuaDwarfMalformed'),
        ('unit-limit',valid*8193,abbrev,'LuaDwarfUnitLimit')]
    for name,info,abbreviations,expected in fixtures:
        (work/'info').write_bytes(info);(work/'abbrev').write_bytes(abbreviations)
        target=work/name
        subprocess.run(['objcopy','--add-section','.debug_info='+str(work/'info'),
            '--add-section','.debug_abbrev='+str(work/'abbrev'),str(empty),str(target)],check=True,timeout=10)
        check(target,expected)
print('Lua DWARF profiles, corrupt units and compressed sections passed')
