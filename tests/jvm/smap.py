#!/usr/bin/env python3
"""Read a class file's SourceFile/SourceDebugExtension (JSR-045 SMAP) from a jar and
resolve Kotlin inline line numbers. Used only to verify imported frame lines."""
import struct
import zipfile


def class_attributes(data):
    if data[:4] != b"\xca\xfe\xba\xbe":
        raise ValueError("not a class file")
    count = struct.unpack(">H", data[8:10])[0]
    pool, i, pos = [None] * count, 1, 10
    while i < count:
        tag = data[pos]
        if tag == 1:
            n = struct.unpack(">H", data[pos + 1:pos + 3])[0]
            pool[i] = data[pos + 3:pos + 3 + n].decode("utf-8", "surrogateescape")
            pos += 3 + n
        elif tag in (3, 4):
            pos += 5
        elif tag in (5, 6):
            pos += 9
            i += 1
        elif tag in (7, 8, 16, 19, 20):
            pos += 3
        elif tag in (9, 10, 11, 12, 17, 18):
            pos += 5
        elif tag == 15:
            pos += 4
        else:
            raise ValueError(f"constant tag {tag}")
        i += 1
    pos += 6
    interfaces = struct.unpack(">H", data[pos:pos + 2])[0]
    pos += 2 + 2 * interfaces

    def skip_members(pos):
        n = struct.unpack(">H", data[pos:pos + 2])[0]
        pos += 2
        for _ in range(n):
            pos += 6
            attrs = struct.unpack(">H", data[pos:pos + 2])[0]
            pos += 2
            for _ in range(attrs):
                length = struct.unpack(">I", data[pos + 2:pos + 6])[0]
                pos += 6 + length
        return pos
    pos = skip_members(skip_members(pos))
    out = {}
    attrs = struct.unpack(">H", data[pos:pos + 2])[0]
    pos += 2
    for _ in range(attrs):
        name, length = struct.unpack(">HI", data[pos:pos + 6])
        body = data[pos + 6:pos + 6 + length]
        if pool[name] == "SourceFile":
            out["SourceFile"] = pool[struct.unpack(">H", body)[0]]
        elif pool[name] == "SourceDebugExtension":
            out["SourceDebugExtension"] = body.decode("utf-8", "surrogateescape")
        pos += 6 + length
    return out


def parse_smap(text):
    """Return {stratum: (files {id: (name, path)}, lines [(in_start, file, repeat, out_start, inc)])}
    for the default (first) Kotlin stratum."""
    lines = text.splitlines()
    if not lines or lines[0] != "SMAP":
        raise ValueError("not an SMAP")
    strata, current, section = {}, None, None
    for line in lines[3:]:
        if line.startswith("*S "):
            current = strata.setdefault(line[3:].strip(), ({}, []))
            section = None
        elif line in ("*F", "*L", "*E"):
            section = line
        elif current is None:
            continue
        elif section == "*F":
            if line.startswith("+ "):
                fid, name = line[2:].split(" ", 1)
                current[0][int(fid)] = [name, None]
                last = int(fid)
            elif current[0] and current[0][last][1] is None:
                current[0][last][1] = line
            else:
                fid, name = line.split(" ", 1)
                current[0][int(fid)] = [name, None]
        elif section == "*L":
            left, right = line.split(":")
            in_part, _, repeat = left.partition(",")
            in_start, _, fid = in_part.partition("#")
            out_start, _, inc = right.partition(",")
            current[1].append((int(in_start), int(fid) if fid else None,
                               int(repeat) if repeat else 1, int(out_start),
                               int(inc) if inc else 1))
    # A missing file id repeats the previous entry's id (JSR-045).
    for files, entries in strata.values():
        fid = None
        for i, (a, f, r, o, n) in enumerate(entries):
            fid = f if f is not None else fid
            entries[i] = (a, fid, r, o, n)
    return strata


def resolve(smap, line, stratum="Kotlin"):
    files, entries = smap[stratum]
    for in_start, fid, repeat, out_start, inc in entries:
        if out_start <= line < out_start + repeat * inc:
            name, path = files[fid]
            return {"file": name, "path": path, "line": in_start + (line - out_start) // inc}
    return None


def class_info(jar, binary_name):
    with zipfile.ZipFile(jar) as z:
        data = z.read(binary_name.replace(".", "/") + ".class")
    info = class_attributes(data)
    if "SourceDebugExtension" in info:
        info["smap"] = parse_smap(info["SourceDebugExtension"])
    return info
