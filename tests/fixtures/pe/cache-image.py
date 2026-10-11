"""Owned PE with identical file/loaded layout and a bounded exception table."""
import struct

def write(path, rows=0, symbol='cache_value'):
    assert 0 <= rows <= 4 * 1024 * 1024
    name = symbol.encode('ascii')
    assert 0 < len(name) < 64
    align = lambda n: (n + 4095) & ~4095
    code = align(max(rows, 16))
    text = 4096
    data = text + code
    table = data + 4096
    data_size = align(4096 + rows * 12)
    size = data + data_size
    header = bytearray(4096)
    header[:2] = b'MZ'
    struct.pack_into('<I', header, 60, 64)
    header[64:68] = b'PE\0\0'
    struct.pack_into('<HHIIIHH', header, 68, 0x8664, 2, 0, 0, 0, 240, 0x2022)
    optional = 88
    struct.pack_into('<H', header, optional, 0x20b)
    struct.pack_into('<I', header, optional + 16, text)
    struct.pack_into('<Q', header, optional + 24, 0x180000000)
    struct.pack_into('<II', header, optional + 32, 4096, 4096)
    struct.pack_into('<II', header, optional + 56, size, 4096)
    struct.pack_into('<I', header, optional + 108, 16)
    directories = optional + 112
    if rows:
        struct.pack_into('<II', header, directories + 24, table, rows * 12)
    page = bytearray(4096)
    export = 0x400
    struct.pack_into('<II', header, directories, data + export, 0x100)
    struct.pack_into('<I', page, export + 12, data + export + 0x60)
    struct.pack_into('<IIIIII', page, export + 16, 1, 1, 1,
                     data + export + 0x40, data + export + 0x44, data + export + 0x48)
    struct.pack_into('<I', page, export + 0x40, data + 0x800)
    struct.pack_into('<I', page, export + 0x44, data + export + 0x70)
    page[export + 0x60:export + 0x68] = b'cache.pe'
    page[export + 0x70:export + 0x70 + len(name)] = name
    struct.pack_into('<8sIIIIIIHHI', header, 328, b'.text', code, text, code, text, 0, 0, 0, 0, 0x60000020)
    struct.pack_into('<8sIIIIIIHHI', header, 368, b'.rdata', data_size, data, data_size, data, 0, 0, 0, 0, 0x40000040)
    with path.open('wb') as f:
        f.write(header)
        f.seek(data)
        f.write(page)
        for first in range(0, rows, 65536):
            f.write(b''.join(struct.pack('<III', text+i, text+i+1, data)
                             for i in range(first, min(rows, first+65536))))
        f.truncate(size)
