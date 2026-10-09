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

**E** accepts an ASCII local/capture name and the builtin container paths below. An unreadable inner name
prevents lookup of a potentially shadowed outer binding. Calls, operators,
constants, instance variables and method dispatch are unavailable; no Ruby code,
`inspect`, coercions or getters run. A missing name is `RubyLocalNotFound`.

Value previews cover tagged small integers, booleans, nil, floating-point values,
strings, static/dynamic Symbol names, and up to eight Array elements or Hash
entries. Containers show a one-level inline preview, such as
`Hash(2) {:state => :ready, "score" => 7}`. Nested containers show their count;
direct self-references show `{...}` or `[...]` and do not recurse. Hash keys appear in the children's `key` fields in MCP.
Strings and Symbol names display valid UTF-8 directly. ASCII control bytes,
invalid UTF-8 and non-ASCII bytes in BINARY or other encodings stay escaped. Names with punctuation are quoted, for example `:"white space"`.
Only the first 128 string/name bytes are considered; display buffers may shorten
that further without cutting an escape or UTF-8 codepoint. Ellipses and `truncated` mark omitted
content, including shortened children. Hash previews scan at most 512 stored
positions to find the first eight entries; exceeding that bound reports
`RubyHashPreviewScanLimit`. Unreadable children carry individual diagnostics.

Container previews require the exact builtin Hash or Array class. Subclasses
and objects with singleton classes refuse with `RubyPreviewContainerClassUnsupported`;
an unavailable class proof reports `RubyPreviewClassUnproved`. Previews show raw
storage, including identity hashes and non-nil defaults; they do not invoke `[]`, default procs, `hash`, `eql?` or
`inspect`. This differs from the stricter path-lookup rules below. A preview is
advisory, and does not establish complete container equality for watches.
Arbitrary objects still report `RubyValueKindUnsupported`.
Header consistency does not prove GC liveness or an
allocation's complete extent. Native previews require the CRuby public header's
`VALUE` typedef and representation in DWARF, plus the verified runtime.

Try `./scripts/demo-cruby`: **Space**, choose **Ruby**, select **tick**, then
**E**, enter `state`, **Return** to see a Symbol; repeat with `summary` or
`values` for Hash/Array contents. **E** `summary[:state]` reads a Symbol leaf.
Symbol and whole-container previews are not complete scalar watch samples.

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
`symbol.h`, `darray.h`, `internal/numeric.h`, `hash.c`, `internal/hash.h`,
`internal/class.h`, `id_table.c`, `method.h`, public value headers and `zjit.h` at
the revision above. DWARF also proves the succinct line-table implementation;
without that proof, source lines remain unavailable.

## Adding a CRuby revision

A new revision needs a proved C reader profile, not just another accepted version
string. The current profile uses `XRB_VERSION` and `XRB_REVISION` in
`src/language/ruby.h`; `ruby_layout.c` checks that exact pair and the DWARF
contract, while `ruby.zig` verifies the loaded runtime and selects the reader.

1. Build the candidate standalone CRuby with DWARF and matching development
   headers. Record its exact source revision and build ID. Check the upstream
   structures and semantics used by the existing profile: VALUE tags, control
   frames, environment flags and escaped environments, local tables, symbol
   names, succinct line tables and JIT frame markers.
2. Update the C profile only where supported by that revision's source and
   runtime evidence. `ruby_types.inc`, `ruby_fields.inc` and
   `ruby_constants.inc` describe the type/field/enum checks. Compare resolved
   offsets and widths independently with GDB or an owned C probe built against
   the candidate's headers. DWARF proves layout; it does not prove macro or
   flag semantics. Keep those rules in the C implementation.
3. Extend the explicit version/revision checks to select the verified profile,
   preserving the old profile's checks and tests. If semantics differ, add a
   separately keyed C profile instead of guessing from a nearby version. A
   deliberate replacement of the sole profile must also update the documented
   supported revision. Shared-library or architecture support is separate work.
4. Run the reader's malformed-memory and callback-failure tests, then the local,
   agent and GUI commands above with the candidate interpreter. Compare locals
   and captures against cooperating `Binding#local_variables` and
   `Binding#local_variable_get` observations across methods, closures, recursion,
   escaped environments, fibers and GC. Audit that inspection leaves registers,
   generation and target scheduling unchanged and performs no target writes.
5. Keep wrong-revision/build-ID, missing-DWARF and unsupported-kind negative
   controls. Test source lines separately from frame names. If claiming live JIT
   coverage, first prove the fixture reached a JIT frame and the guard; a missing
   native execution-context argument is an earlier refusal, not that coverage.
   Finish with the full release gate and independent review before enabling the
   revision in the documented supported set.

No interpreter calls, Ruby `inspect`, coercions or getters are needed to add a
profile. An unproved field, encoding or runtime identity must stay unavailable.

## Stopped value watches

Run `./scripts/demo-cruby`, press **Space**, open **Ruby** and select **tick**.
Press **Shift+E**, enter `round`, then **Return**. Continue with **Space** and
open **V** to see the current and previous complete samples. Alternatively click
a named local and press **W** to retain that declaration; **Delete** removes the
selected runtime watch. Ordinary **E** reads an expression at the current stop.

Ruby watches compare small integers, floats, nil, booleans, and complete strings
up to 4095 bytes plus their inline encoding index. String tails beyond the
preview are compared; changing only the encoding also counts as different.
Floats compare IEEE bytes, so signed zero and NaN payloads retain their bit
patterns. This is typed storage comparison, not Ruby `==`. Arrays, objects,
large integers, symbols, extended encodings and larger strings report a reason
instead of comparing partial previews.

The C reader resolves the control frame, instruction sequence and lexical
storage again at each stop. It retains no raw VALUE or environment address:
creating a Binding or running compacting GC may move that storage. A frame
observed absent in a complete chain retires the watch; an incomplete observation
stays unavailable. Reuse of the same frame location between stops cannot prove
continuous activation identity, so the GUI and MCP always retain that caveat,
including when the value differs. Watches do not interrupt execution or invoke
Ruby code, getters, coercions or comparison methods.

The exact supported revision supplies the encoding-bit rule; its names are not
present in the runtime-owned DWARF units. The live component oracle compares
this rule and scalar samples with the matching Ruby headers' public macros.

## Builtin container paths

Try `./scripts/demo-cruby`: press **Space**, choose **Ruby**, select **tick**,
then **Shift+E**, enter `values[0]`, **Return**, and **V**. Continue with **Space**
to compare that element at each stop. **E** reads the same expression once.

Paths start with a local/capture name and follow Array slots or Hash entries:
`items[0]`, `player["score"]`, `player[:score]`, or `state["players"][0][:score]`.
The initial syntax accepts decimal nonnegative indices/Integer keys through
2147483647, quoted printable ASCII String keys without escapes/interpolation,
and `:identifier` Symbol keys. It allows eight subscriptions and 128 expression
bytes. Calls, slicing, operators, negative indices and other syntax fail at add
or evaluation time with `UnsupportedRubyExpression`.

The C reader resolves the root and every intermediate container again at each
stop, including after root replacement or compacting GC. Arrays use a single
slot read. Hashes scan at most 512 stored entries, including deleted positions;
the runtime's compact and st_table representations are supported. Every stored
key hash or hint is checked against the runtime hash seed and supported key
representation before a value or missing-key reason is returned. A mismatch is
`RubyPathHashUnproved`. Missing keys and out-of-range indices remain unavailable
and can recover at the next stop; they are never invented nil samples.

Only exact builtin containers and supported String, Symbol or small Integer
keys are inspected. Subclasses, singleton overrides, custom `[]`/`hash`/`eql?`,
refined/prepended methods, unproved box-specific method tables, identity hashes,
default procs and unsupported keys have explicit refusals. A non-nil plain
default, such as `Hash.new(0)`, permits found stored keys; a miss remains
`RubyPathDefaultUnsupported` rather than becoming a default-value sample.
Unsupported syntax is still reported when the watch list is full.
Method pointers and tables are checked in stopped memory; no Ruby methods run.
The resulting scalar uses the complete-byte watch rules above, and the
activation-lifetime caveat remains visible.

```sh
python3 -B tests/ruby-path-component.py --ruby "$RUBY" --sanitize --work .work/ruby-path-component
python3 -B tests/ruby-path-watches.py --ruby "$RUBY" --strace --work .work/ruby-paths
python3 -B tests/ruby-path-watches.py --ruby "$RUBY" --strace --agent zig-out/bin/xodb-agent --work .work/ruby-paths-agent
```

## Rails demo

`scripts/demo-rails` runs `examples/rails-demo.rb`: ActiveModel `Order` and
`LineItem` models with attributes, validations, `ActiveModel::Dirty`, a
`Concern`, inflections, time helpers, `with_indifferent_access`,
`in_groups_of` and `ActiveSupport::Notifications`, checked out in a loop. It
stops in `rb_int_digits`, called by the order's Luhn validation inside
`valid?`. No gems are committed. Install activemodel (which brings
activesupport) for the supported debug interpreter into any directory, once:

```sh
"$RUBY" -S gem install --no-document -i "$XODB_RAILS_GEMS" activemodel
XODB_RAILS_GEMS="$XODB_RAILS_GEMS" ./scripts/demo-rails
```

The script only reads `XODB_RAILS_GEMS`: it is put on `GEM_PATH`, and
`GEM_HOME` is an empty per-run temporary directory, so another local user can
share a read-only install. Without the variable, or without activemodel in it,
the script prints the install command and exits.

Press **Space**, **Tab** to **Ruby** and click **checkout!**. The frames show
`valid?` at `validations.rb:367`, `run_validations!` and the
`ActiveSupport::Callbacks` blocks between them. Named locals include `round`,
`items`, `total`, `attrs` and `params`; **E** `attrs` previews the Hash with
its Symbol keys. `params` is a `HashWithIndifferentAccess`, a Hash subclass,
so it reports `RubyPreviewContainerClassUnsupported` instead of guessing.
**Shift+E** `attrs[:line_items][0][:price]`, then **Space**, shows the
price change at each stop. On **<main>**, **Shift+E** `errors[0]` is
`RubyPathIndexOutOfRange` until an order fails its checksum.
Frame labels are the instruction-sequence labels (`valid?`, not
`ActiveModel::Validations#valid?`); C methods appear as `<cfunc>`.
