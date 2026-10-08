#!/usr/bin/env python3
"""Owned DWARF cross-check fixtures: malformed input must never certify a table."""
import os
from pathlib import Path
import struct
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
os.chdir(root)
(root/'.work').mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix='javascript-dwarf-', dir=root/'.work') as temporary:
    work = Path(temporary)
    work.chmod(0o755)
    driver = work/'driver.c'
    driver.write_text('''#include "javascript.h"
#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    int fd = open(argv[1], O_RDONLY); if (fd < 0) return 3;
    Dwarf *d = dwarf_begin(fd, DWARF_C_READ);
    struct xjs_dwarf_profile p = {0};
    if (d) xjs_dwarf_profile(d, &p);
    puts(!d ? "JavaScriptDwarfMalformed" : p.error ? p.error : "ok");
    if (d) dwarf_end(d);
    close(fd); return 0;
}
''')
    executable = work/'check'
    subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-Isrc/language',
                    str(driver), 'src/language/javascript_layout.c', '-ldw', '-lelf',
                    '-o', str(executable)], check=True, timeout=30)
    source = work/'empty.c'; source.write_text('int main(void) { return 0; }\n')
    empty = work/'empty'
    subprocess.run(['cc', '-g0', str(source), '-o', str(empty)], check=True, timeout=30)
    # CU, namespace(name), class(name), member(name, const_value:data1).
    abbrev = bytes([1, 0x11, 1, 0, 0, 2, 0x39, 1, 3, 8, 0, 0,
                    3, 2, 1, 3, 8, 0, 0, 4, 0x0d, 0, 3, 8, 0x1c, 0x0b, 0, 0, 0])
    prefix = b'\x01\x02v8\0\x02internal\0\x03JSArray\0'
    member = b'\x04kLengthOffset\0\x18'
    body = prefix + member + b'\0\0\0\0'
    def unit(dies, address_size=8):
        content = struct.pack('<HIB', 4, 0, address_size) + dies
        return struct.pack('<I', len(content)) + content
    fixtures = [
        ('valid', unit(body), abbrev, 'ok'),
        ('mismatch', unit(prefix + member[:-1] + b'\x19\0\0\0\0'), abbrev, 'JavaScriptDwarfLayoutMismatch'),
        ('oversized-unit', struct.pack('<I', 4000010) + unit(body)[4:], abbrev, 'JavaScriptDwarfMalformed'),
        ('truncated-unit', struct.pack('<I', 4000010) + unit(body)[4:] + bytes(2000000), abbrev, 'JavaScriptDwarfMalformed'),
        ('bad-child', unit(b'\x01\x7f\0'), abbrev, 'JavaScriptDwarfMalformed'),
        ('bad-sibling', unit(prefix + member + b'\x7f\0\0\0\0'), abbrev, 'JavaScriptDwarfMalformed'),
        ('bad-attribute', unit(prefix + b'\x04unterminated'), abbrev, 'JavaScriptDwarfMalformed'),
        ('trailing-byte', unit(body) + b'\xff', abbrev, 'JavaScriptDwarfMalformed'),
        ('wrong-address-size', unit(body, 4), abbrev, 'JavaScriptDwarfMalformed'),
        ('missing-abbrev', unit(body), b'', 'JavaScriptDwarfMalformed'),
        # Small sections are left uncompressed by objcopy. Repeated CUs force
        # compression and exercise errors after successfully decoded units.
        ('compressible-valid', unit(body) * 3000, abbrev, 'ok'),
        ('compressible-mismatch', unit(body) * 2999 + unit(prefix + member[:-1] + b'\x19\0\0\0\0'), abbrev, 'JavaScriptDwarfLayoutMismatch'),
        ('compressible-truncated', unit(body) * 2999 + struct.pack('<I', 4000010) + unit(body)[4:], abbrev, 'JavaScriptDwarfMalformed'),
    ]
    for name, info, abbreviations, expected in fixtures:
        info_file, abbrev_file = work/'info', work/'abbrev'
        info_file.write_bytes(info); abbrev_file.write_bytes(abbreviations)
        target = work/name
        subprocess.run(['objcopy', '--add-section', '.debug_info='+str(info_file),
                        '--add-section', '.debug_abbrev='+str(abbrev_file), str(empty), str(target)],
                       check=True, timeout=10)
        actual = subprocess.check_output([str(executable), str(target)], text=True, timeout=10).strip()
        assert actual == expected, (name, actual, expected)
        print(name, actual)
    def compressed_info(target, encoding):
        data = target.read_bytes()
        assert data[:6] == b'\x7fELF\x02\x01', 'owned fixture must be ELF64 little endian'
        offset, = struct.unpack_from('<Q', data, 40)
        stride, count, names = struct.unpack_from('<HHH', data, 58)
        sections = [struct.unpack_from('<IIQQQQIIQQ', data, offset + i * stride) for i in range(count)]
        strings = data[sections[names][4]:sections[names][4] + sections[names][5]]
        wanted = b'.debug_info' if encoding == 'zlib' else b'.zdebug_info'
        section = next(s for s in sections if strings[s[0]:strings.index(b'\0', s[0])] == wanted)
        if encoding == 'zlib':
            assert section[2] & 0x800, 'SHF_COMPRESSED is required'
        else:
            assert data[section[4]:section[4]+4] == b'ZLIB', 'GNU compression header is required'

    for encoding in ('zlib', 'zlib-gnu'):
        for name, _, _, expected in fixtures:
            if not name.startswith('compressible-'):
                continue
            target = work/(encoding + '-' + name)
            subprocess.run(['objcopy', '--compress-debug-sections='+encoding, str(work/name), str(target)],
                           check=True, timeout=10)
            compressed_info(target, encoding)
            actual = subprocess.check_output([str(executable), str(target)], text=True, timeout=10).strip()
            assert actual == expected, (encoding, name, actual, expected)
            print(encoding, name, actual)
print('JavaScript DWARF boundaries, DIE errors and compressed sections passed')
