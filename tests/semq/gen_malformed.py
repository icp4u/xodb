#!/usr/bin/env python3
"""Generate adversarial xsg inputs from one small valid base graph.

Each output starts with '# expect: STATUS SUBSTRING'; tests/test_xsq.c loads
every file and requires exactly that status and an error containing SUBSTRING.
Generated (not hand-picked) so the corpus is reproducible: run with OUTDIR.
"""
import os
import sys

BASE = """xsg 1
image sha256=unknown build_id=unknown name=adversarial
spec language=x86:LE:64:default compiler=synthetic addr_bytes=8
producer gen_malformed 1
source kind=synthetic sha256=none
space 0 const constant
space 1 ram ram
space 2 register register
space 3 unique unique
function 1 f entry=0x1000
block 10 0x1000
block 11 0x1010
block 12 0x1020
edge 10 11 true
edge 10 12 false
vn 100 2 0x38 4 input param=0
vn 101 2 0x30 4 input param=1
vn 102 3 0x100 1
vn 103 1 0x1010 1 annotation
vn 104 3 0x104 4
vn 105 0 0x0 4
vn 106 0 0x1 4
op 1 10 0x1000 0 INT_LESS 102 100 101
op 2 10 0x1004 1 CBRANCH - 103 102
op 3 11 0x1010 0 INT_ADD 104 100 101
op 4 11 0x1014 1 RETURN - 105 104
op 5 12 0x1020 0 RETURN - 105 106
function 2 g entry=0x2000
block 20 0x2000
vn 200 2 0x38 4 input param=0
vn 201 0 0x0 4
op 20 20 0x2000 0 RETURN - 201 200
end
"""

def sub(old, new, count=1):
    assert old in BASE, old
    return BASE.replace(old, new, count)

CASES = {
    "valid-base": ("ok", "", BASE),
    "no-header": ("malformed", "missing xsg header", BASE.replace("xsg 1\n", "")),
    "bad-version": ("malformed", "unsupported xsg version", sub("xsg 1", "xsg 2")),
    "truncated-no-end": ("malformed", "missing end", BASE.replace("end\n", "")),
    "truncated-mid-line": ("malformed", "no newline", BASE[:BASE.index("op 3 ") + 9]),
    "empty": ("malformed", "missing end", ""),
    "nul-byte": ("malformed", "NUL byte", sub("op 3 11", "op 3\x0011")),
    "dup-op-id": ("malformed", "duplicate op id", sub("op 5 12", "op 4 12")),
    "dup-vn-id": ("malformed", "duplicate varnode id", sub("vn 106 0 0x1 4", "vn 105 0 0x1 4")),
    "dup-block-id": ("malformed", "duplicate block id", sub("block 12 0x1020", "block 11 0x1020")),
    "dup-function-id": ("malformed", "duplicate function id", sub("function 2 g", "function 1 g")),
    "dup-space-id": ("malformed", "duplicate space id", sub("space 3 unique", "space 2 unique")),
    "undefined-vn": ("malformed", "undefined varnode 999", sub("INT_ADD 104 100 101", "INT_ADD 104 100 999")),
    "undefined-block": ("malformed", "undefined block 99", sub("op 3 11", "op 3 99")),
    "undefined-space": ("malformed", "undefined space", sub("vn 104 3 0x104 4", "vn 104 9 0x104 4")),
    "undefined-indirect-op": ("malformed", "undefined @op", sub("op 3 11 0x1010 0 INT_ADD 104 100 101", "op 3 11 0x1010 0 INDIRECT 104 100 @777")),
    "cross-function-vn": ("malformed", "cross-function reference to varnode", sub("INT_ADD 104 100 101", "INT_ADD 104 100 200")),
    "cross-function-block": ("malformed", "cross-function reference to block", sub("op 20 20", "op 20 10")),
    "cross-function-edge": ("malformed", "cross-function", sub("edge 10 12 false", "edge 10 20 false")),
    "cross-function-output": ("malformed", "cross-function output", sub("op 20 20 0x2000 0 RETURN - 201 200", "op 21 20 0x2000 0 COPY 104 200\nop 20 20 0x2000 1 RETURN - 201 200")),
    "width-binary": ("malformed", "width error", sub("vn 104 3 0x104 4", "vn 104 3 0x104 8")),
    "width-compare": ("malformed", "width error", sub("vn 102 3 0x100 1", "vn 102 3 0x100 4")),
    "width-constant": ("malformed", "constant exceeds", sub("vn 106 0 0x1 4", "vn 106 0 0x100000000 4")),
    "width-zero": ("malformed", "width error", sub("vn 104 3 0x104 4", "vn 104 3 0x104 0")),
    "width-oversized": ("malformed", "width error", sub("vn 104 3 0x104 4", "vn 104 3 0x104 999999")),
    "width-extend": ("malformed", "extension must widen", sub("op 3 11 0x1010 0 INT_ADD 104 100 101", "op 3 11 0x1010 0 INT_ZEXT 104 100")),
    "width-subpiece": ("malformed", "truncation exceeds", sub("op 3 11 0x1010 0 INT_ADD 104 100 101", "op 3 11 0x1010 0 SUBPIECE 104 100 106")),
    "cbranch-cond-size": ("malformed", "CBRANCH needs", sub("op 2 10 0x1004 1 CBRANCH - 103 102", "op 2 10 0x1004 1 CBRANCH - 103 100")),
    "load-nonconst-space": ("malformed", "LOAD needs", sub("op 3 11 0x1010 0 INT_ADD 104 100 101", "op 3 11 0x1010 0 LOAD 104 100 101")),
    "load-undefined-space": ("malformed", "undefined space", sub("op 3 11 0x1010 0 INT_ADD 104 100 101", "op 3 11 0x1010 0 LOAD 104 107 101\nvn 107 0 0x9 4")),
    "store-arity": ("malformed", "STORE needs", sub("op 5 12 0x1020 0 RETURN - 105 106", "op 5 12 0x1020 0 STORE - 106 100\nop 6 12 0x1024 1 RETURN - 105 106")),
    "double-def": ("malformed", "defined twice", sub("op 5 12 0x1020 0 RETURN - 105 106", "op 5 12 0x1020 0 COPY 104 100\nop 6 12 0x1024 1 RETURN - 105 106")),
    "input-with-def": ("malformed", "has a definition", sub("INT_ADD 104 100 101", "INT_ADD 101 100 100")),
    "use-without-def": ("malformed", "neither a definition nor input", sub("vn 101 2 0x30 4 input param=1", "vn 101 2 0x30 4")),
    "write-constant": ("malformed", "writes a constant", sub("INT_ADD 104 100 101", "INT_ADD 106 100 101")),
    "non-ssa-cycle": ("malformed", "cycle without a merge", sub("op 3 11 0x1010 0 INT_ADD 104 100 101", "op 3 11 0x1010 0 INT_ADD 104 107 101\nop 7 11 0x1012 1 COPY 107 104\nvn 107 3 0x108 4").replace("op 4 11 0x1014 1", "op 4 11 0x1014 2")),
    "phi-arity": ("malformed", "MULTIEQUAL has", sub("op 3 11 0x1010 0 INT_ADD 104 100 101", "op 3 11 0x1010 0 MULTIEQUAL 104 100 101")),
    "cbranch-one-edge": ("malformed", "one true and one false", BASE.replace("edge 10 12 false\n", "")),
    "terminator-mid-block": ("malformed", "control transfer before end", sub("op 3 11 0x1010 0 INT_ADD 104 100 101", "op 3 11 0x1010 0 RETURN - 105 100").replace("op 4 11 0x1014 1 RETURN - 105 104", "op 4 11 0x1014 1 COPY 104 100\nop 8 11 0x1018 2 RETURN - 105 104")),
    "return-with-successor": ("malformed", "RETURN block has successors", sub("edge 10 12 false", "edge 10 12 false\nedge 11 12 fall")),
    "dup-sequence": ("malformed", "duplicate sequence", sub("op 4 11 0x1014 1", "op 4 11 0x1014 0")),
    "dup-edge-kind": ("malformed", "duplicate edge kind", sub("edge 10 12 false", "edge 10 12 true")),
    "no-entry-block": ("malformed", "no block starts at entry", sub("function 1 f entry=0x1000", "function 1 f entry=0x1001")),
    "function-no-blocks": ("malformed", "has no blocks", sub("end\n", "function 3 h entry=0x3000\nend\n")),
    "unknown-directive": ("malformed", "unknown directive", sub("end\n", "frobnicate 1\nend\n")),
    "unknown-attribute": ("malformed", "unknown vn attribute", sub("vn 105 0 0x0 4", "vn 105 0 0x0 4 colour=red")),
    "header-after-function": ("malformed", "after first function", sub("end\n", "space 7 extra other\nend\n")),
    "content-after-end": ("malformed", "content after end", BASE + "block 99 0x9\n"),
    "hex-overflow": ("malformed", "invalid block", sub("block 12 0x1020", "block 12 0x10000000000000000")),
    "id-reserved": ("malformed", "invalid op", sub("op 5 12", "op 4294967295 12")),
    "negative-id": ("malformed", "invalid op", sub("op 5 12", "op -5 12")),
    "param-not-input": ("malformed", "requires input", sub("vn 104 3 0x104 4", "vn 104 3 0x104 4 param=3")),
    "annotation-input": ("malformed", "annotation must be", sub("vn 103 1 0x1010 1 annotation", "vn 103 1 0x1010 1 annotation input")),
    "op-ref-misplaced": ("malformed", "only valid as INDIRECT", sub("INT_ADD 104 100 101", "INT_ADD 104 100 @1")),
    "missing-image": ("malformed", "must precede", BASE.replace("image sha256=unknown build_id=unknown name=adversarial\n", "")),
    "bad-token-byte": ("malformed", "invalid token byte", sub("name=adversarial", "name=adv\x01ersarial")),
    "call-annotation-noncall": ("malformed", "non-call op", sub("end\n", "call 3 target=0x10\nend\n")),
    "oversized-line": ("limit", "line bytes", sub("end\n", "#" + "x" * 70000 + "\nend\n")),
    "oversized-tokens": ("limit", "tokens per line", sub("end\n", "op 9 12 0x1 0 COPY 104 " + " ".join(["100"] * 5000) + "\nend\n")),
    "oversized-op-inputs": ("limit", "op inputs", sub("end\n", "op 9 12 0x1 0 COPY 104 " + " ".join(["100"] * 4097) + "\nend\n")),
}

def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    for name, (status, needle, text) in sorted(CASES.items()):
        with open(os.path.join(out, name + ".xsg"), "w", newline="") as f:
            f.write("# expect: %s %s\n" % (status, needle) + text if text else
                    "# expect: %s %s\n" % (status, needle))
    print("%d cases" % len(CASES))

if __name__ == "__main__":
    main()
