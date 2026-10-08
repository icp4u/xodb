# Stopped CRuby frames and locals

Run `scripts/demo-cruby`, press **Space**, choose **Ruby**, then select **tick**.
The pane shows `values`, `round`, `doubled` and the captured environment.
Press **E**, type `round`, **Return**; continue with **Space** to inspect the next
iteration. In **C/C++**, native `VALUE` arguments also have Ruby previews.
`RUBY=path scripts/demo-cruby` selects an interpreter; `XODB=path` selects xodb.

The initial reader supports x86-64 Linux and a static/standalone CRuby **4.1.0dev,
revision `4eed7d64eae2cc5fe072992e5d5da25aaa9d5171`**, with DWARF. Other revisions,
architectures and shared-library runtimes report unavailable. A version string
alone is insufficient: xodb compares the loaded build ID, version and revision
with the image, then checks its DWARF field offsets, widths, type strides and
constants. This deliberately narrow development-version profile needs new
runtime evidence before another revision is enabled.

The logical stack comes from the stopped `rb_vm_exec` frame's typed `ec`
argument. A Ruby tab selection highlights that native segment anchor; it does
not claim one native frame per Ruby activation. Fibers have separate execution
contexts and are never merged by name. Method, block, class, top, eval and rescue
frames show the instruction sequence label and source position when proved.
C functions and internal callbacks remain explicit boundaries. Active JIT
frames refuse with `RubyJitFrameUnsupported` or `RubyZjitFrameUnsupported`.
Missing optimized-out arguments report their reason instead of guessing TLS.

Named locals come from the canonical control frame's local table and environment
pointer. The reader verifies VM-stack bounds or, for an escaped environment,
its instruction-sequence identity, environment pointer and heap-storage bounds.
Outer block environments follow the lexical parent chain. The closest named
binding shadows an outer one; callers in the Ruby stack are separate activations.
Internal unnamed slots are marked hidden. Isolated environment boundaries,
cycles, unreadable names and malformed bounds have explicit diagnostics.

**E** accepts a bare ASCII local/capture name only. An unreadable inner name
prevents lookup of a potentially shadowed outer binding. Calls, operators,
constants, instance variables and method dispatch are unavailable; no Ruby code,
`inspect`, coercions or getters run. A missing name is `RubyLocalNotFound`.

Value previews cover tagged small integers, booleans, nil, floating-point values,
strings and up to eight array elements. Strings retain their bytes with escapes
for control and non-ASCII bytes. Larger strings/arrays show truncation. Other
kinds, including hash contents and arbitrary objects, report
`RubyValueKindUnsupported`. Header consistency does not prove GC liveness or an
allocation's complete extent. Native previews require the CRuby public header's
`VALUE` typedef and representation in DWARF, plus the verified runtime.

Agents use `get_language_stack` with `language: "ruby"` and a stopped thread ID,
then `get_language_locals` or `evaluate_language_expression` with that generation,
segment and logical-frame index. Locals page at most 32 rows per request, through
at most 64 environments and 4096 slots. Each inspection is limited to 8192 memory
reads and 2 MiB of requested bytes. Addresses expire on resume, GC, stack movement
or fiber switches. **W** does not turn a Ruby binding into a raw heap watchpoint.

For owned-fixture checks, use matching Ruby development headers and:

```sh
scripts/build test install -Doptimize=ReleaseSafe
python3 tests/ruby-language.py --ruby "$RUBY" --work .work/ruby
python3 tests/ruby-language.py --ruby "$RUBY" --agent zig-out/bin/xodb-agent --work .work/ruby-agent
python3 tests/ruby-gui.py --ruby "$RUBY" --work .
scripts/release-check all --ruby "$RUBY"
```

The layout contract is derived from CRuby's `vm_core.h`, `iseq.c`, `symbol.c`,
`symbol.h`, `darray.h`, `internal/numeric.h`, public value headers and `zjit.h` at
the revision above. DWARF also proves the succinct line-table implementation;
without that proof, source lines remain unavailable.
