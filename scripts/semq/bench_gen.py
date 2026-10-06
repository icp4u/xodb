#!/usr/bin/env python3
"""Generate SYNTHETIC xsg benchmark functions of increasing size.

usage: gen.py SEGMENTS OUT [--far-loads]

Each segment is a diamond (CBRANCH, two arms, MULTIEQUAL merge), an 8-op
arithmetic chain, a stack store/load pair and, every 16 segments, a call.
Every 32 segments a back edge forms a loop. Values flow from segment to
segment, so a slice of the final RETURN reaches the whole function.
With --far-loads each load's store is in an earlier block, which forces the
conservative memory scan over every earlier op (quadratic worst case).
"""
import sys

def main():
    segments = int(sys.argv[1])
    out = open(sys.argv[2], "w")
    far = "--far-loads" in sys.argv
    w = out.write
    w("xsg 1\n# SYNTHETIC benchmark graph: %d segments far_loads=%s\n" % (segments, far))
    w("image sha256=unknown build_id=unknown name=bench\n")
    w("spec language=x86:LE:64:default compiler=synthetic addr_bytes=8\n")
    w("producer bench-gen 1\nsource kind=synthetic sha256=none\n")
    w("space 0 const constant\nspace 1 ram ram\nspace 2 register register\nspace 3 unique unique\n")
    w("function 1 bench entry=0x0\n")
    w("vn 1 2 0x38 8 input param=0\nvn 2 2 0x30 8 input param=1\nvn 3 2 0x20 8 input spacebase\n")
    w("vn 4 1 0x0 1 annotation\nvn 5 0 0x1 8\nvn 6 0 0x1 4\nvn 7 0 0x0 4\nvn 8 1 0x9000 8 annotation\n")
    vn = [100]
    op = [100]

    def new_vn(size=8, space=3):
        vn[0] += 1
        w("vn %d %d 0x%x %d\n" % (vn[0], space, vn[0] * 8, size))
        return vn[0]

    def new_const(value, size=8):
        vn[0] += 1
        w("vn %d 0 0x%x %d\n" % (vn[0], value & ((1 << (8 * size)) - 1), size))
        return vn[0]

    def emit(block, seq, text):
        op[0] += 1
        w("op %d %d 0x%x %d %s\n" % (op[0], block, block * 0x40 + seq, seq, text))
        return op[0]

    cur = 1  # running value
    block = 0
    pending_store = None
    for s in range(segments):
        head, left, right, join = block, block + 1, block + 2, block + 3
        for b in (head, left, right, join):
            w("block %d 0x%x\n" % (b, b * 0x40))
        w("edge %d %d true\nedge %d %d false\nedge %d %d fall\nedge %d %d fall\n" % (
            head, left, head, right, left, join, right, join))
        cond = new_vn(1)
        emit(head, 0, "INT_LESS %d %d 2" % (cond, cur))
        emit(head, 1, "CBRANCH - 4 %d" % cond)
        a = new_vn()
        emit(left, 0, "INT_ADD %d %d 5" % (a, cur))
        b = new_vn()
        emit(right, 0, "INT_MULT %d %d 2" % (b, cur))
        m = new_vn()
        emit(join, 0, "MULTIEQUAL %d %d %d" % (m, a, b))
        x, seq = m, 1
        for k in range(8):
            y = new_vn()
            opcode = ("INT_ADD", "INT_XOR", "INT_SUB", "INT_AND")[k % 4]
            emit(join, seq, "%s %d %d %d" % (opcode, y, x, new_const(k + 3)))
            x, seq = y, seq + 1
        # stack slot store/load
        addr = new_vn()
        emit(join, seq, "PTRSUB %d 3 %d" % (addr, new_const(-8 * (s + 1))))
        seq += 1
        if far and pending_store is not None:
            loaded = new_vn()
            emit(join, seq, "LOAD %d 6 %d" % (loaded, pending_store))
            seq += 1
            z = new_vn()
            emit(join, seq, "INT_ADD %d %d %d" % (z, x, loaded))
            x, seq = z, seq + 1
        emit(join, seq, "STORE - 6 %d %d" % (addr, x))
        seq += 1
        if not far:
            loaded = new_vn()
            emit(join, seq, "LOAD %d 6 %d" % (loaded, addr))
            x, seq = loaded, seq + 1
        pending_store = addr
        if s % 16 == 15:
            r = new_vn()
            emit(join, seq, "CALL %d 8 %d" % (r, x))
            seq += 1
            z = new_vn()
            emit(join, seq, "INT_ADD %d %d %d" % (z, x, r))
            x, seq = z, seq + 1
        cur = x
        block += 4
        if s % 32 == 31 and s + 1 < segments:
            # loop: join -> loop test block -> (back to this group's head | next)
            test = block
            w("block %d 0x%x\nedge %d %d fall\n" % (test, test * 0x40, join, test))
            c2 = new_vn(1)
            emit(test, 0, "INT_EQUAL %d %d 2" % (c2, cur))
            emit(test, 1, "CBRANCH - 4 %d" % c2)
            w("edge %d %d true\n" % (test, test + 1))
            w("edge %d %d false\n" % (test, block - 4 * 32))
            block += 1
        if s + 1 < segments and s % 32 != 31:
            w("edge %d %d fall\n" % (join, block))
    w("block %d 0x%x\n" % (block, block * 0x40))
    emit(block, 0, "RETURN - 7 %d" % cur)
    w("end\n")

if __name__ == "__main__":
    main()
