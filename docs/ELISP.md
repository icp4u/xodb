# Emacs Lisp stack and values

## Try the demo

```sh
./scripts/demo-emacs
# Or choose the executables explicitly:
XODB=./zig-out/bin/xodb EMACS=/opt/debug/bin/emacs ./scripts/demo-emacs
```

Press **Space**, choose **Elisp**, then select `xodb-demo-checkpoint`.
Its lexical `label` is `"item"`. The immediately inner `let` row
shows `title = "Profile delta"` and `points = 2`;
scroll within the bindings pane to see the remaining names.
The workload uses `cl-defun`, a lexical lambda and `condition-case` to turn
two JSON tasks into an Org-style outline. It creates a fresh batch Emacs with
`-Q` and does not load your editor configuration.

Press **Space** for `"Cache budget"` / `3`, then for the `"render"` checkpoint.
The render `let` has dynamic `demo-stage = "render"`; the next outer `let`
owns `lines`. The outer `let*` has lexical `total = 5` and dynamic
stage `"normalize"`.
The fourth stop is `"error"`: an intentionally malformed estimate is handled
by `condition-case`. One more **Space** lets Emacs print the result and exit.
**Shift+Q** quits xodb. A proved Lisp-to-C argument link selects the corresponding
native caller beside the Lisp stack. Unproved boundaries stay labelled.
Elisp **E** captures input but expressions and watches are not implemented;
**Esc** closes the field.

The launcher prints these tips and passes extra arguments to xodb, for example
`./scripts/demo-emacs --runtime-agent ./zig-out/bin/xodb-agent`.

## Supported builds

The initial reader supports GNU Emacs **31.1**, x86-64 Linux, little endian,
with modules enabled and the executable's own DWARF debug information. The
loaded build ID, version, type layout and tagging constants must agree.
Optimized builds are supported for the saved Lisp backtrace. The selected
native thread must be the process's main thread and match `current_thread`.
Other threads return `ElispThreadAssociationUnproved`.

An owned batch example from the checkout:

```sh
XODB_ELISP_FUNCTIONS="$PWD/tests/fixtures/elisp/functions.el" \
XODB_ELISP_ORACLE="$PWD/.work/emacs-oracle.json" \
XODB_ELISP_MODE=interpreted \
xodb --break Fdebugger_trap -- /opt/debug/bin/emacs -Q --batch \
  -l tests/fixtures/elisp/driver.el
```

Create `.work` first. Press **Space**, then click **Elisp** or cycle with **Tab**.
The stack lists function symbols and argument counts, innermost first.
`unevaluated` means the runtime saved forms, rather than a counted argument
array. Select a Lisp row to link to its C **segment anchor**. Several Lisp
activations may share a native evaluator frame; the link does not establish
a one-to-one pairing.

`condition-case`, catch/handler records and unwind cleanup records appear with
their associated stack depth. A cleanup record can be a C callback, so it is
not automatically described as a Lisp `unwind-protect`. Callbacks are never
executed. MCP `get_language_stack` with `language: "elisp"` also exposes the
records, saved depths, argument metadata and additional native anchors.

Interpreted and bytecode labels require active evidence. A native `apply_lambda`
or `funcall_lambda` call must expose the actual function, argument storage and
count; those must match one saved Lisp frame, and the still-active evaluator
call path must agree with the closure's code type. Proven argument bindings
appear as an adjacent **C:** row. Selecting a Lisp frame or its native stack
counterpart selects the linked frame on the other side.
These are invocation argument links, not a bijection of entire stacks.

Bytecode-to-bytecode calls additionally use the saved bytecode frame's function,
bounded caller stack slots, and the function word stored beside those slots.
A symbol's current definition is never used: a function can be redefined while
an older activation remains active. Shared bytecode evaluator frames may still
have only a segment anchor. Unproved native-comp/C boundaries remain
**native/unknown** with a reason. Other threads, ambiguous storage, changed
roots, malformed bytecode chains, or disagreement with the active call path
never become guessed labels.

Typed native `Lisp_Object` variables now have bounded previews in C/C++ expressions
and native-value rows. For the example above, select `xodb-elisp-mark`, click
**C/C++**, press **E**, type `arg_vector[1]`, then **Enter**: the result is
`"sample"`. `arg_vector[0]` shows `-17`; `arg_vector[2]` shows `(-17 "sample")`.
Press **Esc** to leave the field. This reads stored arguments without executing Lisp.

Previews cover fixnums, finite floats, strings, symbol names, lists (including dotted
lists), vectors, records, hash-table entries, buffers (name and point), markers and
windows. Buffer children include the explicit `local_var_alist`; built-in per-buffer
slots are not included in that summary. Hash tables use a bounded linear scan of
stored slots, without computing hashes or calling hash/equality functions.
Multibyte strings preserve Unicode; Emacs raw-byte and non-Unicode characters are
escaped. String properties and symbol intern status are not inspected.

Values are limited to 24 child entries, 128 decoded nodes, depth 4 and 256 source
string bytes, within the same cumulative read/byte budget. Cycles, corrupt headers,
unsupported pseudovectors, unreadable memory and clipping carry diagnostics. A
consistent header does not establish GC liveness or allocation extent.

Select a saved Lisp frame to see its **frame bindings**. Dynamic bindings show
that frame's value even when a younger call shadows the same symbol. Lexical
rows come from saved interpreter environments. The row labels distinguish
`dynamic` and `lexical`; scroll within the bindings pane to see more.
Optimized bytecode/native stack locals, buffer-local bindings, aliases and
non-object forwarding remain unproved or unavailable. These are stopped-memory
views; no interpreter evaluation or state rewinding takes place.

For a small shadowing example:

```sh
mkdir -p .work
XODB_ELISP_ORACLE="$PWD/.work/emacs-bindings.json" \
xodb --break Fdebugger_trap -- /opt/debug/bin/emacs -Q --batch \
  -l tests/fixtures/elisp/bindings.el
```

Press **Space**, select **Elisp**, then `xodb-binding-child`: its lexical
`xodb-child-arg` is `42`. `xodb-binding-parent` has `xodb-parent-arg = 17`.
The `let` row immediately inside each function carries its locals: the child's
`xodb-dynamic` is `23`, while the parent's is `11`. The MCP
`get_language_locals` tool accepts `language: "elisp"`, retained generation,
thread, segment and frame, plus `start`/`limit` pagination.
Bindings are capped at 128 rows with 256 shadow-history entries and 256
cons cells per environment walk. A lexical walk stops at that record's previous
environment: rows show the bindings introduced by that frame, without repeating
the enclosing environment. Stack validation, binding collection and each row's
preview have separate bounded readers; one large preview cannot blank later rows.

Named Lisp expressions and watches are subsequent work.
In the **Elisp** tab, **E** opens an input-capturing unavailable prompt;
**Esc** closes it.

The C reader limits frames, unwind records and handlers to 128 each, specpdl
records to 8,192, and each reader to 8,192 calls and 2 MiB. A locals page has at
most 32 previews, plus separate stack and binding readers; its reported read
counts include all of them. Reaching a frame or control cap keeps the validated
inner frames usable and still visits the handler chain. Changed roots and
invalid memory continue to withdraw results. GUI selection currently
covers the first 64 frames. Truncation and unreadable data carry explicit
reasons. Stack function names preserve printable ASCII and escape other bytes; value
previews use the bounded multibyte decoder. All results belong to the
retained stop and are discarded after continue, exec or thread changes.

Tests compare against the fixture's own `backtrace-frames` output in interpreted,
bytecode and native-compiled modes, including active redefinitions in both directions. Run
`scripts/release-check gui --emacs /opt/debug/bin/emacs` for the private Sway
check, or the `host` tier for local/agent and C-reader oracles. Without
`--emacs`, the release report explicitly lists omitted Elisp checks. Use an
owned test Emacs only; the scripts never attach to an existing editor.

To see bindings on a capped recursive stack, then a page of large previews:

```sh
xodb --break Fdebugger_trap -- /opt/debug/bin/emacs -Q --batch \
  -l tests/fixtures/elisp/deep-bindings.el
```

Press **Space**, select **Elisp**, then the innermost `let`: `xodb-depth` is `0`
and `xodb-token` is `"level-0"`, despite the stack-cap diagnostic. Press **Space**
again and select the `let` below `xodb-budget-mark` to inspect 32 bounded vector
previews.

The full page can require many individual memory reads through an agent. Its
oracle is in `scripts/release-check periodic --emacs /opt/debug/bin/emacs`;
the fast host lane covers the local page and the agent's deep stack separately.
