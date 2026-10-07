# Lua values and stacks

Run `LUA=lua5.4 scripts/demo-lua`, press **Space** to reach `print`, then
**E**, `L`, **Return**. The watch shows the Lua state's top value. **Space**
advances through numbers, a string, a table and a closure. In another terminal,
`scripts/demo-lua stack` prints the Lua frames and bounded value previews.
`LUA=lua5.2` selects the other supported interpreter.

The current profiles cover PUC Lua **5.4.9** and **5.2.4**, x86-64 Linux,
little endian, standard 64-bit pointers and double precision numbers. The
interpreter needs DWARF; static embedded C/C++ hosts work too. Offsets and
strides come from the identified image's DWARF. The loaded build-id and
`lua_ident` bytes must agree with that image. Results label the layout source.
Shared-library runtimes, LuaJIT, stripped layouts, different versions, NaN-boxed
5.2 builds and other architectures are not covered by these profiles.

A `TValue *` shows nil, booleans, integers (5.4), numbers, byte strings, tables,
closures with upvalues, C functions, userdata or threads. A `lua_State *`
shows its top stack value and up to eight stack slots, even when the native
frame has only an opaque public-header declaration. A complete native type
must agree with the runtime layout. Strings escape non-ASCII and control bytes.
The reader never calls Lua APIs, metamethods, formatters or target code.

For an agent:

```json
{"name":"get_language_stack","arguments":{"tid":1234,"language":"lua"}}
```

Omit `state` to recover native `lua_State *` parameters. Supply a hexadecimal
`state` address to inspect a particular coroutine. Each distinct state remains
a separate observation. CallInfo links provide logical ordering and C function
boundaries. Saved PCs and Lua line tables provide current source lines,
including Lua 5.4 absolute-line entries. Tail-call flags do not reconstruct
eliminated callers. Suspended coroutines are explicitly marked; the 5.2 reader
interprets the saved function offset without changing the target.

Names that cannot be proved remain `<Lua function:LINE>` with
`LuaFunctionNameUnavailable`. Native anchors record recovered state arguments;
they do not establish an exact merge between each Lua frame and each native
activation. Those segments remain partial. Optimized-out state arguments need
an explicit state address.

Bounds are 128 frames, eight preview items, 128 string bytes, 8,192 memory reads
and 2 MiB per reader operation. Large or inconsistent line tables, cycles,
unreadable objects and unsupported layouts carry diagnostics. Table capacities
are slot counts, not Lua's `#` operator or a complete entry count. Lua 5.2's
hash capacity includes its shared nil dummy slot. Only a bounded set of slots
is inspected.

Header consistency cannot prove allocation extents or GC liveness. An unchanged
stale allocation can still look readable; a corrupt length may include nearby
readable bytes within the preview bound. A detected tag mismatch is a refusal,
not proof that every freed object can be recognized.

The semantic rules follow upstream [5.4 objects](https://www.lua.org/source/5.4/lobject.h.html),
[5.4 states](https://www.lua.org/source/5.4/lstate.h.html),
[5.4 line information](https://www.lua.org/source/5.4/ldebug.c.html), and their
[5.2 object](https://www.lua.org/source/5.2/lobject.h.html),
[state](https://www.lua.org/source/5.2/lstate.h.html) and
[debug](https://www.lua.org/source/5.2/ldebug.c.html) counterparts.
