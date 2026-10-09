const std = @import("std");
const c = @import("../c.zig").api;
const Session = @import("../model/session.zig").Session;
const disasm = @import("../model/disassembly.zig");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
const shared_context = @import("shared_context.zig");
const base_tool_definitions =
    \\[{"name":"get_session","description":"Inspect the shared session and its generation.","inputSchema":{"type":"object","properties":{"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"list_threads","description":"List threads and their stable session-local IDs.","inputSchema":{"type":"object","properties":{"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"get_registers","description":"Read target general registers from a stopped thread; values are hexadecimal strings. On LoongArch64, r0 is the kernel restart slot, not architectural zero.","inputSchema":{"type":"object","properties":{"tid":{"type":"integer","minimum":1},"generation":{"type":"integer","minimum":0},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":["tid"],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"read_memory","description":"Read up to 4096 bytes from the stopped process, returning hex bytes and the actual count.","inputSchema":{"type":"object","properties":{"address":{"type":"string","description":"Hexadecimal address, with optional 0x prefix"},"length":{"type":"integer","minimum":1,"maximum":4096},"generation":{"type":"integer","minimum":0},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":["address","length"],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"disassemble","description":"Decode up to 32 native target instructions at a stopped process address.","inputSchema":{"type":"object","properties":{"address":{"type":"string"},"generation":{"type":"integer","minimum":0},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":["address"],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"query_events","description":"Read up to 128 ordered events after a sequence number. Older events may have expired from the bounded history.","inputSchema":{"type":"object","properties":{"after":{"type":"integer","minimum":0},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"get_breakpoints","description":"Inspect installed software breakpoints and hardware watchpoints.","inputSchema":{"type":"object","properties":{"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":[],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"get_audit","description":"Inspect recent human and agent control actions.","inputSchema":{"type":"object","properties":{"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":[],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"set_breakpoint","description":"Set software breakpoints by address, ELF symbol, or source file and line. Returns all probe IDs for a source line. Symbol requests remain pending until resolved, including glibc shared library loads.","inputSchema":{"type":"object","properties":{"address":{"type":"string"},"generation":{"type":"integer","minimum":0},"symbol":{"type":"string"},"file":{"type":"string"},"line":{"type":"integer","minimum":1},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":["generation"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"xodbSessionAccess":"controller"}},{"name":"remove_breakpoint","description":"Remove a software breakpoint; requires control scope.","inputSchema":{"type":"object","properties":{"id":{"type":"integer","minimum":1},"generation":{"type":"integer","minimum":0},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":["id","generation"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"xodbSessionAccess":"controller"}},{"name":"set_watchpoint","description":"Set a hardware watchpoint on all threads; requires control scope.","inputSchema":{"type":"object","properties":{"address":{"type":"string"},"length":{"type":"integer","enum":[1,2,4,8]},"kind":{"type":"string","enum":["write","read_write","execute"]},"generation":{"type":"integer","minimum":0},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":["address","length","generation"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"xodbSessionAccess":"controller"}},{"name":"remove_watchpoint","description":"Remove a hardware watchpoint; requires control scope.","inputSchema":{"type":"object","properties":{"id":{"type":"integer","minimum":1},"generation":{"type":"integer","minimum":0},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":["id","generation"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"xodbSessionAccess":"controller"}},{"name":"continue","description":"Continue the target; returns before the next stop. Requires control scope.","inputSchema":{"type":"object","properties":{"generation":{"type":"integer","minimum":0},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":["generation"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"xodbSessionAccess":"controller"}},{"name":"interrupt","description":"Request a stop; poll get_session until stopped. Requires control scope.","inputSchema":{"type":"object","properties":{"generation":{"type":"integer","minimum":0},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":["generation"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"xodbSessionAccess":"controller"}},{"name":"step_instruction","description":"Step one machine instruction in one stopped thread. Requires control scope.","inputSchema":{"type":"object","properties":{"tid":{"type":"integer","minimum":1},"generation":{"type":"integer","minimum":0},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":["tid","generation"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"xodbSessionAccess":"controller"}},{"name":"write_memory","description":"Write target bytes supplied as hexadecimal. Requires mutate scope.","inputSchema":{"type":"object","properties":{"address":{"type":"string"},"hex":{"type":"string"},"generation":{"type":"integer","minimum":0},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":["address","hex","generation"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"xodbSessionAccess":"mutator"}},{"name":"write_register","description":"Write one native target general register. Requires mutate scope.","inputSchema":{"type":"object","properties":{"tid":{"type":"integer","minimum":1},"name":{"type":"string"},"value":{"type":"string"},"generation":{"type":"integer","minimum":0},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":["tid","name","value","generation"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"xodbSessionAccess":"mutator"}},{"name":"find_symbol","description":"Resolve an ELF symbol to a live runtime address.","inputSchema":{"type":"object","properties":{"name":{"type":"string"},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":["name"],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"list_modules","description":"List one page of the retained process memory mappings and module load failures. Follow next with cursor until null. Cursors are bound to the process session, mapping generation and contents; StaleModuleCursor requires restarting at the first page. Running targets expose the last stopped mapping snapshot.","inputSchema":{"type":"object","properties":{"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."},"cursor":{"type":"string","maxLength":128,"description":"Opaque next value from the preceding page; omit to begin."},"limit":{"type":"integer","minimum":1,"maximum":512,"default":128,"description":"Maximum combined region/failure rows; the response byte budget may return fewer."}},"required":[],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"evaluate_expression","description":"Evaluate a side-effect-free C/C++ scalar, pointer, struct-field, or $register expression in a stopped frame.","inputSchema":{"type":"object","properties":{"tid":{"type":"integer","minimum":1},"expression":{"type":"string"},"generation":{"type":"integer","minimum":0},"frame":{"type":"integer","minimum":0,"maximum":63},"inline_depth":{"type":"integer","minimum":0,"maximum":64,"description":"Inline scope within the physical frame, 0 innermost; inline_frames length selects the outer physical function."},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":["tid","expression"],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"step_over_instruction","description":"Step one instruction, running calls to their return address. Requires control scope; other threads can run while a call executes.","inputSchema":{"type":"object","properties":{"tid":{"type":"integer","minimum":1},"generation":{"type":"integer","minimum":0},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":["tid","generation"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"xodbSessionAccess":"controller"}},{"name":"get_source_location","description":"Map a runtime address to its source line.","inputSchema":{"type":"object","properties":{"address":{"type":"string"},"generation":{"type":"integer","minimum":0},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":["address"],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"get_stack","description":"Unwind up to 64 frames using CFI. Each frame carries availability diagnostics.","inputSchema":{"type":"object","properties":{"tid":{"type":"integer","minimum":1},"generation":{"type":"integer","minimum":0},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":["tid"],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"list_locals","description":"List visible variables and parameters, typed values and availability at a stopped frame. Paged with start/limit; next is the following start. Pass view_id from the first reply on later pages; stale views require restarting. A byte budget may shorten pages.","inputSchema":{"type":"object","properties":{"tid":{"type":"integer","minimum":1},"frame":{"type":"integer","minimum":0,"maximum":63},"generation":{"type":"integer","minimum":0},"inline_depth":{"type":"integer","minimum":0,"maximum":64,"description":"Inline scope within the physical frame, 0 innermost; inline_frames length selects the outer physical function."},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."},"start":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":128,"default":64},"view_id":{"type":"string","minLength":64,"maxLength":64}},"required":["tid"],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"step_source","description":"Step to a different source line, entering calls. Asynchronous, requires control scope.","inputSchema":{"type":"object","properties":{"tid":{"type":"integer","minimum":1},"generation":{"type":"integer","minimum":0},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":["tid","generation"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"xodbSessionAccess":"controller"}},{"name":"step_over","description":"Step to a different source line, running calls to their return address. Asynchronous, requires control scope.","inputSchema":{"type":"object","properties":{"tid":{"type":"integer","minimum":1},"generation":{"type":"integer","minimum":0},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":["tid","generation"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"xodbSessionAccess":"controller"}},{"name":"investigate_write","description":"Record an investigation and install a hardware write watchpoint on an addressable scalar expression.","inputSchema":{"type":"object","properties":{"tid":{"type":"integer","minimum":1},"question":{"type":"string"},"expression":{"type":"string"},"generation":{"type":"integer","minimum":0},"frame":{"type":"integer","minimum":0,"maximum":63},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":["tid","question","expression","generation"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"xodbSessionAccess":"controller"}},{"name":"get_investigation","description":"Export recorded observations, frames, values and instruction attribution with provenance.","inputSchema":{"type":"object","properties":{"id":{"type":"integer","minimum":1},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":["id"],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"get_function_graph","description":"Build a bounded static x86-64 function graph from stopped target bytes. Returns up to 16 blocks per page and their outgoing edges. This is decoded possibility, not observed execution; unresolved branches and assumed call returns are explicit.","inputSchema":{"type":"object","properties":{"address":{"type":"string"},"symbol":{"type":"string"},"start_block":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":16},"generation":{"type":"integer","minimum":0},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"start_profile","description":"Start bounded CPU sampling while stopped. All-thread captures follow new same-process threads by default; explicit tids remain fixed. Child processes remain outside scope. Preferences supply omitted options.","inputSchema":{"type":"object","properties":{"generation":{"type":"integer","minimum":0},"tids":{"type":"array","items":{"type":"integer","minimum":1},"minItems":1,"maxItems":1024,"uniqueItems":true},"sample_limit":{"type":"integer","minimum":1,"maximum":65536,"description":"Maximum retained samples; default from preferences (16384 initially). Memory can fill earlier."},"frequency_hz":{"type":"integer","minimum":1,"maximum":1000},"duration_ms":{"type":"integer","minimum":0,"maximum":4294967295,"description":"Wall-clock deadline in milliseconds; 0 means until stopped. Omitted settings use session defaults (initially 60000 ms, 99 Hz, scheduling off); resource and scope limits still stop collection."},"context_switch":{"type":"boolean","description":"Per-thread scheduling transitions with bounded retention; omitted uses the session default, initially false."},"user_stack_bytes":{"type":"integer","minimum":0,"maximum":8192,"multipleOf":8,"description":"0 disables (initial default); otherwise 64..8192 captured user stack bytes per sample plus x86-64 GPRs. Recommend 4096 when enabling."},"user_stack_budget_bytes":{"type":"integer","minimum":0,"maximum":67108864,"description":"Total retained stack-byte budget; initial default 33554432 (32 MiB). CPU samples and registers continue after exhaustion, with explicit missing stacks. Collection overhead continues."},"follow_threads":{"type":"boolean","description":"Follow held newborn threads only when tids is omitted; default comes from preferences (true)."},"ring_budget_bytes":{"type":"integer","minimum":4096,"maximum":268435456,"description":"Total live perf data-ring budget; metadata pages are additional. Default 64 MiB."},"syscall_timing":{"type":"boolean","description":"Opt-in x86-64 syscall timing; requires explicit tids (1..32). Arguments discarded."},"syscall_limit":{"type":"integer","minimum":1,"maximum":65536,"description":"Retained syscall detail ceiling; reaching it stops capture."},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":["generation"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"xodbSessionAccess":"controller"}},{"name":"stop_profile","description":"Stop collection and drain queued samples; does not pause target execution.","inputSchema":{"type":"object","properties":{"generation":{"type":"integer","minimum":0},"capture_id":{"type":"integer","minimum":1},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":["generation","capture_id"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"xodbSessionAccess":"controller"}},{"name":"get_profile","description":"Inspect capture status, user/kernel CPU accounting, accepted perf parameters, thread identities, loss/mapping diagnostics, and actionable start failures. Includes current session defaults for future GUI captures and omitted start_profile arguments.","inputSchema":{"type":"object","properties":{"capture_id":{"type":"integer","minimum":1},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":[],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"get_flamegraph","description":"Get a recorded CPU flame snapshot. Omit revision on an initial live request to snapshot current data. Live requests may return pending; poll the same revision/view_id. Pass view_id for pages and frame queries. Evicted views are stale. Optional basis=reconstructed uses saved stacks on a completed capture: pending/progress first, then its own view_id, coverage buckets and per-node example_sample. Recorded remains the default; node IDs belong only to their basis and view.","inputSchema":{"type":"object","properties":{"retry":{"type":"boolean","description":"Explicitly retry a failed live snapshot build."},"capture_id":{"type":"integer","minimum":1},"revision":{"type":"integer","minimum":1},"tid":{"type":"integer","minimum":1},"from_ns":{"type":"integer","minimum":0},"to_ns":{"type":"integer","minimum":1},"start":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":64},"view_id":{"type":"string","description":"View identity from get_flamegraph; required for frame lookup and paginated continuation."},"basis":{"type":"string","enum":["recorded","reconstructed"]},"tids":{"type":"array","items":{"type":"integer","minimum":1,"maximum":2147483647},"maxItems":1024,"uniqueItems":true,"description":"Selected TIDs; mutually exclusive with tid. Empty selects all threads."},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":["capture_id"],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"controller"}},{"name":"get_profile_frame","description":"Source and assembly for a flame node using the retained ELF image; repeat the graph filters. Representative location, not a per-line count. Works after target exit. Recorded basis only; reconstructed views use example_sample with get_profile_stack.","inputSchema":{"type":"object","properties":{"capture_id":{"type":"integer","minimum":1},"revision":{"type":"integer","minimum":1},"tid":{"type":"integer","minimum":1},"from_ns":{"type":"integer","minimum":0},"to_ns":{"type":"integer","minimum":1},"node":{"type":"integer","minimum":0},"view_id":{"type":"string","description":"View identity from get_flamegraph; required for frame lookup and paginated continuation."},"tids":{"type":"array","items":{"type":"integer","minimum":1,"maximum":2147483647},"maxItems":1024,"uniqueItems":true,"description":"Selected TIDs; mutually exclusive with tid. Empty selects all threads."},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":["capture_id","revision","node"],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"controller"}},{"name":"get_profile_mappings","description":"Read observed mapping identities and timestamps in capture-local ID order, with coverage limitations. Supply capture_id and revision; start/limit page opening ranges and retained changes.","inputSchema":{"type":"object","properties":{"capture_id":{"type":"integer","minimum":1},"revision":{"type":"integer","minimum":1},"start":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":64},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":["capture_id","revision"],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"get_profile_timeline","description":"CPU sample bins and per-thread counts with the same half-open relative-time filters as flames. Bins partition the clipped range; start/limit page threads. Includes unfiltered debugger observation markers. Scheduling status and limits are reported; use get_profile_schedule for per-thread spans. Pin capture_id/revision; stop collection for stable queries.","inputSchema":{"type":"object","properties":{"capture_id":{"type":"integer","minimum":1},"revision":{"type":"integer","minimum":1},"tid":{"type":"integer","minimum":1},"from_ns":{"type":"integer","minimum":0},"to_ns":{"type":"integer","minimum":1},"bins":{"type":"integer","minimum":1,"maximum":512},"start":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":64},"tids":{"type":"array","items":{"type":"integer","minimum":1,"maximum":2147483647},"maxItems":1024,"uniqueItems":true,"description":"Selected TIDs; mutually exclusive with tid. Empty selects all threads."},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":["capture_id","revision"],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"get_profile_schedule","description":"Read one opening thread\u2019s running/off-CPU/unknown intervals, paged at 128 spans. Uses half-open relative-time filters; totals cover the whole filtered range. Missing scheduling evidence remains unknown. Pin capture_id and revision; stop for stable pagination. No wait-cause inference.","inputSchema":{"type":"object","properties":{"capture_id":{"type":"integer","minimum":1},"revision":{"type":"integer","minimum":1},"tid":{"type":"integer","minimum":1},"from_ns":{"type":"integer","minimum":0},"to_ns":{"type":"integer","minimum":1},"start":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":128},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":["capture_id","revision","tid"],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"get_instruction_effects","description":"Inspect normalized typed operands and explicit/implicit register effects from stopped x86-64 bytes. Bounded inspection IR, not complete executable semantics. Memory expressions are not dereferenced; aliases/flags/implicit memory effects remain architecture-specific.","inputSchema":{"type":"object","properties":{"address":{"type":"string"},"generation":{"type":"integer","minimum":0},"length":{"type":"integer","minimum":1,"maximum":1024},"limit":{"type":"integer","minimum":1,"maximum":64},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":["address"],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"add_profile_intervals","description":"Add application-supplied timing intervals to a completed capture. Requires control scope and current target generation plus capture/revision. Atomic batch, at most 128 records and 4096 retained. Times are relative nanoseconds within capture extent; imported provenance is explicit. No target execution change.","inputSchema":{"type":"object","properties":{"capture_id":{"type":"integer","minimum":1},"revision":{"type":"integer","minimum":1},"generation":{"type":"integer","minimum":0},"source":{"type":"string","minLength":1,"maxLength":96},"intervals":{"type":"array","minItems":1,"maxItems":128,"items":{"type":"object","properties":{"from_ns":{"type":"integer","minimum":0},"to_ns":{"type":"integer","minimum":0},"tid":{"type":"integer","minimum":1},"label":{"type":"string","minLength":1,"maxLength":96},"kind":{"type":"string","enum":["frame","request","custom"]},"correlation_id":{"type":"integer","minimum":0}},"required":["from_ns","to_ns","label"],"additionalProperties":false}},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":["generation","capture_id","revision","source","intervals"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"xodbSessionAccess":"controller"}},{"name":"get_profile_intervals","description":"Read imported application intervals overlapping the same half-open relative range/TID used by flames. Endpoints and caller-supplied provenance are retained; these are not kernel observations. Global intervals match any selected TID.","inputSchema":{"type":"object","properties":{"capture_id":{"type":"integer","minimum":1},"revision":{"type":"integer","minimum":1},"from_ns":{"type":"integer","minimum":0},"to_ns":{"type":"integer","minimum":0},"tid":{"type":"integer","minimum":1},"start":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":128},"tids":{"type":"array","items":{"type":"integer","minimum":1,"maximum":2147483647},"maxItems":1024,"uniqueItems":true,"description":"Selected TIDs; mutually exclusive with tid. Empty selects all threads."},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":["capture_id","revision"],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"export_profile","description":"Write a completed selected CPU aggregate as a new Speedscope JSON file, with xodb metadata, CPU bins, scheduling totals and imported intervals. Units are sample counts and ordering is synthetic. No overwrite. Requires control scope and current generation plus capture/revision; target execution is unchanged.","inputSchema":{"type":"object","properties":{"generation":{"type":"integer","minimum":0},"capture_id":{"type":"integer","minimum":1},"revision":{"type":"integer","minimum":1},"path":{"type":"string","minLength":1,"maxLength":4096},"tid":{"type":"integer","minimum":1},"from_ns":{"type":"integer","minimum":0},"to_ns":{"type":"integer","minimum":1},"tids":{"type":"array","items":{"type":"integer","minimum":1,"maximum":2147483647},"maxItems":1024,"uniqueItems":true,"description":"Selected TIDs; mutually exclusive with tid. Empty selects all threads."},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":["generation","capture_id","revision","path"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"xodbSessionAccess":"controller"}},{"name":"get_value_children","description":"Read paged struct/array/Rust-Zig slice children from stopped memory; no target calls or automatic pointer traversal. raw=true exposes slice fields. Observe scope.","inputSchema":{"type":"object","properties":{"tid":{"type":"integer","minimum":1},"frame":{"type":"integer","minimum":0,"maximum":63},"expression":{"type":"string"},"generation":{"type":"integer"},"start":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":64},"raw":{"type":"boolean"},"inline_depth":{"type":"integer","minimum":0,"maximum":64,"description":"Inline scope within the physical frame, 0 innermost; inline_frames length selects the outer physical function."},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":["tid","expression"],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"save_capture_archive","description":"Start a background save of a completed capture or copy an immutable offline artifact to a new file. Poll get_archive_status for publication.","inputSchema":{"type":"object","properties":{"generation":{"type":"integer","minimum":0},"capture_id":{"type":"integer","minimum":0},"revision":{"type":"integer","minimum":0},"path":{"type":"string"},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":["generation","capture_id","revision","path"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"xodbSessionAccess":"controller"}},{"name":"get_archive_status","description":"Read archive job progress, publication result, recorded origin and analysis identity.","inputSchema":{"type":"object","properties":{"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":[],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"cancel_archive_job","description":"Request cooperative cancellation. Publication may already have completed; inspect get_archive_status.","inputSchema":{"type":"object","properties":{"generation":{"type":"integer","minimum":0},"job_id":{"type":"integer","minimum":0},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":["generation","job_id"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"xodbSessionAccess":"controller"}},{"name":"get_profile_samples","description":"Read normalized recorded samples with durable zero-based ordinals. Addresses are original evidence; no target memory is read.","inputSchema":{"type":"object","properties":{"capture_id":{"type":"integer","minimum":0},"revision":{"type":"integer","minimum":0},"start":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":16},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":["capture_id","revision"],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"get_profile_stack","description":"Inspect saved registers and paged stack bytes. By default queue completed-capture DWARF reconstruction on a worker; repeat the same request while pending. reconstruct=false reads raw evidence during collection. No target reads/resume. Existing archive status/cancel tools manage the worker.","inputSchema":{"type":"object","properties":{"capture_id":{"type":"integer","minimum":0},"revision":{"type":"integer","minimum":0},"sample":{"type":"integer","minimum":0},"stack_offset":{"type":"integer","minimum":0},"stack_limit":{"type":"integer","minimum":0,"maximum":1024},"reconstruct":{"type":"boolean"},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":["capture_id","revision","sample"],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"controller"}},{"name":"get_profile_stack_coverage","description":"Counts of retained and missing sampled stacks by thread within a half-open relative time range. Retention follows drain order; no guaranteed time prefix. Unfilterable records are counted separately.","inputSchema":{"type":"object","properties":{"capture_id":{"type":"integer","minimum":0},"revision":{"type":"integer","minimum":0},"tid":{"type":"integer","minimum":1},"from_ns":{"type":"integer","minimum":0},"to_ns":{"type":"integer","minimum":1},"start":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":128},"tids":{"type":"array","items":{"type":"integer","minimum":1,"maximum":2147483647},"maxItems":1024,"uniqueItems":true,"description":"Selected TIDs; mutually exclusive with tid. Empty selects all threads."},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":["capture_id","revision"],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"get_debug_view","description":"Bounded coherent GUI snapshot; explicit server --source shares one source file. Schema version 1.","inputSchema":{"type":"object","properties":{"tid":{"type":"integer","minimum":0},"frame":{"type":"integer","minimum":0,"maximum":63},"generation":{"type":"integer","minimum":0},"summary_only":{"type":"boolean","description":"Return only identity, generation, state and scope without inspection or thread rows."},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"detach","description":"Detach and preserve the target; requires control scope and the viewed generation.","inputSchema":{"type":"object","properties":{"generation":{"type":"integer","minimum":0},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":["generation"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"xodbSessionAccess":"controller"}},{"name":"configure_breakpoint","description":"Replace a breakpoint policy. Conditions and log expressions are side-effect-free; errors stop. Ignore counts consume matching-thread hits before conditions. Empty condition clears it. Thread filters bind to stable identity. Requires stopped target and control scope.","inputSchema":{"type":"object","properties":{"generation":{"type":"integer","minimum":0},"id":{"type":"integer","minimum":1},"enabled":{"type":"boolean"},"condition":{"type":"string","maxLength":512},"log_expression":{"type":"string","maxLength":512},"tid":{"type":"integer","minimum":1},"ignore_count":{"type":"integer","minimum":0},"mode":{"type":"string","enum":["stop","log"]},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":["generation","id"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"xodbSessionAccess":"controller"}},{"name":"get_breakpoint_logs","description":"Read bounded logpoint observations by sequence; overwritten observations are explicitly counted. Value evidence belongs to the recorded image/generation.","inputSchema":{"type":"object","properties":{"after":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":64},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"finish","description":"Run until the selected physical frame returns. Thread and caller stack identity distinguish recursive calls. Other meaningful stops interrupt the operation.","inputSchema":{"type":"object","properties":{"tid":{"type":"integer","minimum":1},"frame":{"type":"integer","minimum":0,"maximum":62},"generation":{"type":"integer","minimum":0},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":["tid","generation"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"xodbSessionAccess":"controller"}},{"name":"run_to","description":"Run to an address or source line on the selected thread. Other meaningful stops interrupt the operation; temporary probe ownership is preserved.","inputSchema":{"type":"object","properties":{"tid":{"type":"integer","minimum":1},"address":{"type":"string"},"file":{"type":"string"},"line":{"type":"integer","minimum":1},"generation":{"type":"integer","minimum":0},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":["tid","generation"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"xodbSessionAccess":"controller"}},{"name":"capture_memory","description":"Capture up to 64 KiB of stopped memory with per-byte availability; keep eight bounded observations.","inputSchema":{"type":"object","properties":{"generation":{"type":"integer","minimum":0},"address":{"type":"string"},"length":{"type":"integer","minimum":1,"maximum":65536},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":["generation","address","length"],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"controller"}},{"name":"read_memory_snapshot","description":"Page an immutable observation and optionally compare an overlapping baseline from the same session/image. ?? marks unreadable bytes.","inputSchema":{"type":"object","properties":{"id":{"type":"integer","minimum":1},"baseline":{"type":"integer","minimum":1},"start":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":4096},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":["id"],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"search_memory","description":"Start a bounded incremental search, max 64 MiB and 1024 hits. Poll get_memory_search. Target resume/change makes it stale.","inputSchema":{"type":"object","properties":{"generation":{"type":"integer","minimum":0},"address":{"type":"string"},"length":{"type":"integer","minimum":1,"maximum":67108864},"pattern":{"type":"string"},"encoding":{"type":"string","enum":["hex","utf8"]},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":["generation","address","length","pattern"],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"controller"}},{"name":"get_memory_search","description":"Page matches and inspect progress, unreadable coverage and terminal reason.","inputSchema":{"type":"object","properties":{"id":{"type":"integer","minimum":1},"start":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":128},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":["id"],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"cancel_memory_search","description":"Cancel only the named memory search; target execution is unchanged.","inputSchema":{"type":"object","properties":{"id":{"type":"integer","minimum":1},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":["id"],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"controller"}},{"name":"get_extended_registers","description":"Read x86-64 x87/SSE and available AVX/AVX-512 state, with typed low-to-high vector lanes. Read-only; unsupported widths are explicit.","inputSchema":{"type":"object","properties":{"tid":{"type":"integer","minimum":1},"generation":{"type":"integer","minimum":0},"format":{"type":"string","enum":["hex","f32","f64","i32","u32","u64"]},"width":{"type":"integer","enum":[128,256,512]},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":["tid"],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"restart","description":"Restart the original owned launch while stopped or exited. Preserve symbolic and build-ID-verified breakpoint locations. Clear address watches; thread-filtered breakpoints require rebinding. Attached targets cannot restart.","inputSchema":{"type":"object","properties":{"generation":{"type":"integer","minimum":0},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":["generation"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"xodbSessionAccess":"controller"}},{"name":"get_debug_files","description":"List retained verified debug companions and explicit source prefix substitutions. No file contents are returned. Paged with start/limit; next is the following start. Pass view_id from the first reply on later pages; stale views require restarting. A byte budget may shorten pages.","inputSchema":{"type":"object","properties":{"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."},"start":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":128,"default":32},"view_id":{"type":"string","minLength":64,"maxLength":64}},"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"get_core_info","description":"Describe a read-only ELF core, its recorded process/thread IDs, mappings and missing-memory semantics.","inputSchema":{"type":"object","properties":{"mapping_start":{"type":"integer","minimum":0},"segment_start":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":32},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":[],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"get_stop_info","description":"Inspect a stopped thread signal, kernel code, fault address and whether Continue would deliver a pending signal.","inputSchema":{"type":"object","properties":{"tid":{"type":"integer"},"generation":{"type":"integer"},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":["tid"],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"get_profile_syscalls","description":"Page scoped x86-64 syscall entry/exit elapsed durations, raw return values and observed scheduling overlap. Missing endpoints stay null; durations include debugger pauses. Arguments are not retained.","inputSchema":{"type":"object","properties":{"capture_id":{"type":"integer","minimum":1},"revision":{"type":"integer","minimum":1},"from_ns":{"type":"integer","minimum":0},"to_ns":{"type":"integer","minimum":0},"tid":{"type":"integer","minimum":1},"start":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":128},"tids":{"type":"array","items":{"type":"integer","minimum":1,"maximum":2147483647},"maxItems":1024,"uniqueItems":true,"description":"Selected TIDs; mutually exclusive with tid. Empty selects all threads."},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":["capture_id","revision"],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"get_processes","description":"List retained process sessions and held child admissions. MCP defaults to process 1; GUI selection never retargets requests.","inputSchema":{"type":"object","properties":{"start":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":128},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":[],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"set_process_following","description":"Enable or disable future process following for a stopped x86-64 process. Children stop for inspection; inherited following remains enabled. Optional process_limit bounds retained sessions globally.","inputSchema":{"type":"object","properties":{"generation":{"type":"integer","minimum":0},"enabled":{"type":"boolean"},"process_limit":{"type":"integer","minimum":1,"maximum":1024},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":["generation","enabled"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"xodbSessionAccess":"controller"}},{"name":"retry_process_admission","description":"Retry children held by process limit or adoption errors after correcting the cause.","inputSchema":{"type":"object","properties":{"generation":{"type":"integer","minimum":0},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":["generation"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"xodbSessionAccess":"controller"}},{"name":"detach_process_family","description":"Detach this process and any shared-vfork family, including pending children. Restores all traps before resuming any member. Independent adopted fork processes remain attached.","inputSchema":{"type":"object","properties":{"generation":{"type":"integer","minimum":0},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":["generation"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"xodbSessionAccess":"controller"}},{"name":"start_allocations","description":"Prepare bounded x86-64 allocation tracing on stopped, explicitly selected threads. Poll get_allocation_capture before continuing. May invoke an explicitly configured privileged helper.","inputSchema":{"type":"object","properties":{"process_id":{"type":"integer","minimum":1},"generation":{"type":"integer","minimum":0},"tids":{"type":"array","minItems":1,"maxItems":32,"uniqueItems":true,"items":{"type":"integer","minimum":1,"maximum":2147483647}},"mapping_address":{"type":"string","description":"Address within the executable mapping; default is unique libc.so.6."},"hooks":{"type":"array","minItems":1,"maxItems":16,"items":{"type":"object","properties":{"name":{"type":"string","minLength":1,"maxLength":256},"kind":{"type":"string","enum":["malloc","calloc","realloc","free"]}},"required":["name","kind"],"additionalProperties":false}},"duration_ms":{"type":"integer","minimum":0,"maximum":4294967295},"record_limit":{"type":"integer","minimum":2,"maximum":131072},"memory_limit":{"type":"integer","minimum":1048576,"maximum":134217728},"callstacks":{"type":"boolean","description":"Collect bounded frame-pointer prefixes and the return address at allocator entry. Default true."}},"required":["generation","tids"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":false,"idempotentHint":false,"openWorldHint":false,"xodbSessionAccess":"controller"}},{"name":"stop_allocations","description":"Stop and drain a capture or cancel preparation. Requires its session/capture identity and current target generation.","inputSchema":{"type":"object","properties":{"process_id":{"type":"integer","minimum":1},"generation":{"type":"integer","minimum":0},"session_id":{"type":"integer","minimum":1},"capture_id":{"type":"integer","minimum":1}},"required":["generation","session_id","capture_id"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"destructiveHint":false,"idempotentHint":false,"openWorldHint":false,"xodbSessionAccess":"controller"}},{"name":"get_allocation_capture","description":"Inspect preparation, failures, retained allocation coverage and lifetime summary. Outstanding does not mean leaked.","inputSchema":{"type":"object","properties":{"process_id":{"type":"integer","minimum":1}},"required":[],"additionalProperties":false},"annotations":{"readOnlyHint":true,"destructiveHint":false,"idempotentHint":true,"openWorldHint":false,"xodbSessionAccess":"observer"}},{"name":"get_allocation_events","description":"Page exact retained entry/return events and evidence gaps.","inputSchema":{"type":"object","properties":{"process_id":{"type":"integer","minimum":1},"session_id":{"type":"integer","minimum":1},"capture_id":{"type":"integer","minimum":1},"revision":{"type":"integer","minimum":0},"start":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":256},"thread_id":{"type":"integer","minimum":1},"from_ns":{"type":"integer","minimum":0},"to_ns":{"type":"integer","minimum":0}},"required":["session_id","capture_id","revision"],"additionalProperties":false},"annotations":{"readOnlyHint":true,"destructiveHint":false,"idempotentHint":true,"openWorldHint":false,"xodbSessionAccess":"observer"}},{"name":"get_allocation_calls","description":"Page paired calls with event citations; incomplete calls retain reasons.","inputSchema":{"type":"object","properties":{"process_id":{"type":"integer","minimum":1},"session_id":{"type":"integer","minimum":1},"capture_id":{"type":"integer","minimum":1},"revision":{"type":"integer","minimum":0},"start":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":256},"thread_id":{"type":"integer","minimum":1},"from_ns":{"type":"integer","minimum":0},"to_ns":{"type":"integer","minimum":0}},"required":["session_id","capture_id","revision"],"additionalProperties":false},"annotations":{"readOnlyHint":true,"destructiveHint":false,"idempotentHint":true,"openWorldHint":false,"xodbSessionAccess":"observer"}},{"name":"get_allocation_lifetimes","description":"Build/page bounded allocation lifetimes. Outstanding is within recorded scope, not proof of a leak.","inputSchema":{"type":"object","properties":{"process_id":{"type":"integer","minimum":1},"session_id":{"type":"integer","minimum":1},"capture_id":{"type":"integer","minimum":1},"revision":{"type":"integer","minimum":0},"start":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":256},"thread_id":{"type":"integer","minimum":1},"from_ns":{"type":"integer","minimum":0},"to_ns":{"type":"integer","minimum":0},"outstanding_only":{"type":"boolean"},"retry":{"type":"boolean"}},"required":["session_id","capture_id","revision"],"additionalProperties":false},"annotations":{"readOnlyHint":true,"destructiveHint":false,"idempotentHint":true,"openWorldHint":false,"xodbSessionAccess":"controller"}},{"name":"get_allocation_stack","description":"Read the captured entry stack for an allocation call; prefixes never imply a complete unwind.","inputSchema":{"type":"object","properties":{"process_id":{"type":"integer","minimum":1},"session_id":{"type":"integer","minimum":1},"capture_id":{"type":"integer","minimum":1},"revision":{"type":"integer","minimum":0},"allocation_span":{"type":"integer","minimum":0}},"required":["session_id","capture_id","revision","allocation_span"],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"get_allocation_flamegraph","description":"Build/page allocation call trees weighted by requested bytes or successful allocation count. Poll pending with the same filters.","inputSchema":{"type":"object","properties":{"process_id":{"type":"integer","minimum":1},"session_id":{"type":"integer","minimum":1},"capture_id":{"type":"integer","minimum":1},"revision":{"type":"integer","minimum":0},"start":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":256},"thread_id":{"type":"integer","minimum":1},"from_ns":{"type":"integer","minimum":0},"to_ns":{"type":"integer","minimum":0},"metric":{"type":"string","enum":["allocated_bytes","outstanding_bytes","allocations"]}},"required":["session_id","capture_id","revision"],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"controller"}},{"name":"save_allocation_archive","description":"Save finalized allocation evidence and recorded stack labels without overwriting a file. Poll get_archive_status for completion.","inputSchema":{"type":"object","properties":{"generation":{"type":"integer","minimum":0},"capture_id":{"type":"integer","minimum":0},"revision":{"type":"integer","minimum":0},"path":{"type":"string"},"process_id":{"type":"integer","minimum":1,"maximum":1024,"description":"Stable debugger process ID; omitted means original process 1, independent of GUI selection."}},"required":["generation","capture_id","revision","path"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"xodbSessionAccess":"controller"}},{"name":"get_profile_comparison","description":"Inspect an explicitly opened pair of CPU archives. Poll pending, then page normalized function rankings or differential flames; no elapsed-time or speedup inference.","inputSchema":{"type":"object","properties":{"process_id":{"type":"integer","minimum":1},"view":{"type":"string","enum":["functions","flames"]},"start":{"type":"integer","minimum":0,"maximum":16384},"limit":{"type":"integer","minimum":1,"maximum":256}},"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"start_inspection","description":"Retain a bounded coherent inspection of one stopped thread. Poll get_inspection; results survive resume. Eight retained jobs maximum; release explicitly.","inputSchema":{"type":"object","properties":{"process_id":{"type":"integer","minimum":1},"generation":{"type":"integer","minimum":0},"tid":{"type":"integer","minimum":1},"frame":{"type":"integer","minimum":0,"maximum":63},"registers":{"type":"boolean"},"stack":{"type":"boolean"},"locals":{"type":"boolean"},"expressions":{"type":"array","maxItems":16,"items":{"type":"string","minLength":1,"maxLength":256}},"memory":{"type":"array","maxItems":16,"items":{"type":"object","properties":{"address":{"type":"string"},"length":{"type":"integer","minimum":1,"maximum":4096}},"required":["address","length"],"additionalProperties":false}}},"required":["generation","tid"],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"controller"}},{"name":"get_inspection","description":"Read immutable completed items and progress from a retained inspection. Each item has an ordinal and independent availability.","inputSchema":{"type":"object","properties":{"process_id":{"type":"integer","minimum":1},"id":{"type":"integer","minimum":0},"start":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":2}},"required":["id"],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"cancel_inspection","description":"Cancel pending inspection work; retain already captured items.","inputSchema":{"type":"object","properties":{"process_id":{"type":"integer","minimum":1},"id":{"type":"integer","minimum":0}},"required":["id"],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"controller"}},{"name":"release_inspection","description":"Release a retained inspection and its memory; cancels pending work.","inputSchema":{"type":"object","properties":{"process_id":{"type":"integer","minimum":1},"id":{"type":"integer","minimum":0}},"required":["id"],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"controller"}},{"name":"start_observation","description":"Prepare generic function entry/return probes for selected held threads in one exact ELF mapping. Poll get_observation until collecting before continue; x86-64 SysV raw words only.","inputSchema":{"type":"object","properties":{"process_id":{"type":"integer","minimum":1},"generation":{"type":"integer","minimum":0},"tids":{"type":"array","minItems":1,"maxItems":32,"items":{"type":"integer","minimum":1}},"mapping_address":{"type":"string"},"functions":{"type":"array","minItems":1,"maxItems":16,"items":{"type":"string","minLength":1,"maxLength":256}},"duration_ms":{"type":"integer","minimum":0},"record_limit":{"type":"integer","minimum":0},"memory_limit":{"type":"integer","minimum":0},"callstacks":{"type":"boolean"}},"required":["generation","tids","mapping_address","functions"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"xodbSessionAccess":"controller"}},{"name":"stop_observation","description":"Disable and drain this observation, preserving incomplete and lost evidence.","inputSchema":{"type":"object","properties":{"process_id":{"type":"integer","minimum":1},"session_id":{"type":"integer","minimum":0},"capture_id":{"type":"integer","minimum":0},"generation":{"type":"integer","minimum":0}},"required":["generation","session_id","capture_id"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"xodbSessionAccess":"controller"}},{"name":"get_observation","description":"Observation preparation/collection status, exact source and thread identities, limits and loss.","inputSchema":{"type":"object","properties":{"process_id":{"type":"integer","minimum":1}},"required":[],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"get_observation_calls","description":"Page immutable calls after collection ends. Raw register and address words use hex strings.","inputSchema":{"type":"object","properties":{"process_id":{"type":"integer","minimum":1},"session_id":{"type":"integer","minimum":0},"capture_id":{"type":"integer","minimum":0},"start":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":64}},"required":["session_id","capture_id"],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"get_observation_records","description":"Page immutable records after collection ends. Raw register and address words use hex strings.","inputSchema":{"type":"object","properties":{"process_id":{"type":"integer","minimum":1},"session_id":{"type":"integer","minimum":0},"capture_id":{"type":"integer","minimum":0},"start":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":64}},"required":["session_id","capture_id"],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"compare_observation","description":"Start bounded asynchronous fast/slow wall-duration cohorts from complete calls. Cite raw entry/return records and exclude incomplete evidence.","inputSchema":{"type":"object","properties":{"process_id":{"type":"integer","minimum":1},"session_id":{"type":"integer","minimum":0},"capture_id":{"type":"integer","minimum":0},"threshold_ns":{"type":"integer","minimum":0},"thread_id":{"type":"integer","minimum":0},"function_id":{"type":"integer","minimum":0},"start_ns":{"type":"integer","minimum":0},"end_ns":{"type":"integer","minimum":0},"argument_index":{"type":"integer","minimum":0,"maximum":5},"argument_value":{"type":"string"},"return_value":{"type":"string"},"top_n":{"type":"integer","minimum":1,"maximum":32}},"required":["session_id","capture_id","threshold_ns"],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"controller"}},{"name":"get_observation_comparison","description":"Get observation comparison job; identity and exact cohort denominators are retained.","inputSchema":{"type":"object","properties":{"process_id":{"type":"integer","minimum":1},"id":{"type":"integer","minimum":0}},"required":["id"],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"cancel_observation_comparison","description":"Cancel observation comparison job; identity and exact cohort denominators are retained.","inputSchema":{"type":"object","properties":{"process_id":{"type":"integer","minimum":1},"id":{"type":"integer","minimum":0}},"required":["id"],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"controller"}},{"name":"save_observation","description":"Save ended invocation evidence as a self-contained .xoi investigation; destination must be new. Poll get_observation_archive.","inputSchema":{"type":"object","properties":{"generation":{"type":"integer","minimum":0},"session_id":{"type":"integer","minimum":0},"capture_id":{"type":"integer","minimum":0},"path":{"type":"string"},"process_id":{"type":"integer","minimum":1}},"required":["generation","session_id","capture_id","path"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"xodbSessionAccess":"controller"}},{"name":"get_observation_archive","description":"Get observation save/open progress, error and actual publication status.","inputSchema":{"type":"object","properties":{"id":{"type":"integer","minimum":0},"process_id":{"type":"integer","minimum":1}},"required":["id"],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"cancel_observation_archive","description":"Cancel unfinished observation archive work; an already published artifact remains published.","inputSchema":{"type":"object","properties":{"generation":{"type":"integer","minimum":0},"id":{"type":"integer","minimum":0},"process_id":{"type":"integer","minimum":1}},"required":["generation","id"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"xodbSessionAccess":"controller"}},{"name":"associate_observation","description":"Build bounded temporal associations from ended native CPU/syscall/allocation captures to complete function calls. Explicit source identities/revisions required; overlap is not causal cost.","inputSchema":{"type":"object","properties":{"session_id":{"type":"integer","minimum":0},"capture_id":{"type":"integer","minimum":0},"threshold_ns":{"type":"integer","minimum":0},"profile_id":{"type":"integer","minimum":0},"profile_revision":{"type":"integer","minimum":0},"allocation_id":{"type":"integer","minimum":0},"allocation_revision":{"type":"integer","minimum":0},"thread_id":{"type":"integer","minimum":0},"function_id":{"type":"integer","minimum":0},"start_ns":{"type":"integer","minimum":0},"end_ns":{"type":"integer","minimum":0},"include_cpu":{"type":"boolean"},"include_syscalls":{"type":"boolean"},"argument_index":{"type":"integer","minimum":0,"maximum":5},"argument_value":{"type":"string"},"return_value":{"type":"string"},"process_id":{"type":"integer","minimum":1}},"required":["session_id","capture_id","threshold_ns"],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"controller"}},{"name":"get_observation_associations","description":"Read classified associations, exact denominators, captured clock proof and raw-record citations. Optional stream_id pages owned normalized input records.","inputSchema":{"type":"object","properties":{"id":{"type":"integer","minimum":0},"start":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":64},"stream_id":{"type":"integer","minimum":0},"process_id":{"type":"integer","minimum":1}},"required":["id"],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"cancel_observation_associations","description":"Cancel a pending temporal association job.","inputSchema":{"type":"object","properties":{"id":{"type":"integer","minimum":0},"process_id":{"type":"integer","minimum":1}},"required":["id"],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"controller"}},{"name":"get_language_stack","description":"Read bounded language stack evidence at a retained native stop. Lua, JavaScript, Python, Perl, Ruby and Go (goroutines); no target calls.","inputSchema":{"type":"object","properties":{"tid":{"type":"integer","minimum":1},"frame":{"type":"integer","minimum":0,"maximum":63},"language":{"type":"string","enum":["perl","python","javascript","lua","ruby","go"]},"generation":{"type":"integer","minimum":0},"process_id":{"type":"integer","minimum":1,"maximum":1024},"state":{"type":"string","description":"Lua only: explicit lua_State address as hexadecimal. Omit to recover native state arguments."}},"required":["tid","language"],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"import_logical_frames","description":"Import declared logical JSONL or a JVM export asynchronously; exact weights are counts.","inputSchema":{"type":"object","properties":{"path":{"type":"string"},"kind":{"enum":["logical","jfr","thread_dump","thread_print","coroutines"]},"jvm_kind":{"type":"integer","minimum":0,"maximum":10},"replace":{"type":"integer","minimum":0,"maximum":7},"process_id":{"type":"integer","minimum":1,"maximum":1024}},"required":["path","kind"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"xodbSessionAccess":"controller"}},{"name":"open_frame_bundle","description":"Restore retained frame evidence without opening recorded source paths.","inputSchema":{"type":"object","properties":{"path":{"type":"string"},"process_id":{"type":"integer","minimum":1,"maximum":1024}},"required":["path"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"xodbSessionAccess":"controller"}},{"name":"get_frame_status","description":"Import status, source identities, collection method, read stability, loss and budget.","inputSchema":{"type":"object","properties":{"process_id":{"type":"integer","minimum":1,"maximum":1024}},"required":[],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"get_frame_threads","description":"Logical thread evidence; runtime IDs do not grant native control.","inputSchema":{"type":"object","properties":{"source":{"type":"integer","minimum":0,"maximum":7},"source_id":{"type":"string"},"start":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":64},"stack":{"type":"integer","minimum":0},"process_id":{"type":"integer","minimum":1,"maximum":1024}},"required":["source_id"],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"get_frame_stacks","description":"Logical stack records, original weights, acquisition and source citations.","inputSchema":{"type":"object","properties":{"source":{"type":"integer","minimum":0,"maximum":7},"source_id":{"type":"string"},"start":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":64},"stack":{"type":"integer","minimum":0},"process_id":{"type":"integer","minimum":1,"maximum":1024}},"required":["source_id"],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"get_frame_stack","description":"Page through logical frames; native stacks remain separate.","inputSchema":{"type":"object","properties":{"source":{"type":"integer","minimum":0,"maximum":7},"source_id":{"type":"string"},"start":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":64},"stack":{"type":"integer","minimum":0},"process_id":{"type":"integer","minimum":1,"maximum":1024}},"required":["source_id","stack"],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"get_frame_functions","description":"Function identity, source locations, JVM loader and execution-mode evidence.","inputSchema":{"type":"object","properties":{"source":{"type":"integer","minimum":0,"maximum":7},"source_id":{"type":"string"},"start":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":64},"stack":{"type":"integer","minimum":0},"process_id":{"type":"integer","minimum":1,"maximum":1024}},"required":["source_id"],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"get_frame_aggregate","description":"Completed exact decimal aggregate counts with partial and unknown-leaf weights.","inputSchema":{"type":"object","properties":{"source":{"type":"integer","minimum":0,"maximum":7},"source_id":{"type":"string"},"start":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":64},"stack":{"type":"integer","minimum":0},"process_id":{"type":"integer","minimum":1,"maximum":1024}},"required":["source_id"],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"select_frame_aggregate","description":"Run one bounded aggregate for a selected logical thread; null means all.","inputSchema":{"type":"object","properties":{"source":{"type":"integer","minimum":0,"maximum":7},"source_id":{"type":"string"},"thread":{"type":["integer","null"],"minimum":0},"process_id":{"type":"integer","minimum":1,"maximum":1024}},"required":["source_id"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"xodbSessionAccess":"controller"}},{"name":"get_frame_citation","description":"Return up to 4096 original source or adapted logical bytes as hex.","inputSchema":{"type":"object","properties":{"source":{"type":"integer","minimum":0,"maximum":7},"source_id":{"type":"string"},"basis":{"enum":["source","logical"]},"offset":{"type":"integer","minimum":0},"length":{"type":"integer","minimum":0,"maximum":4096},"process_id":{"type":"integer","minimum":1,"maximum":1024}},"required":["source_id","basis","offset","length"],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"save_frames","description":"Publish a no-overwrite .xof frame evidence bundle asynchronously.","inputSchema":{"type":"object","properties":{"path":{"type":"string"},"process_id":{"type":"integer","minimum":1,"maximum":1024}},"required":["path"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"xodbSessionAccess":"controller"}},{"name":"cancel_frame_job","description":"Request cancellation of the current frame import, aggregate or save.","inputSchema":{"type":"object","properties":{"process_id":{"type":"integer","minimum":1,"maximum":1024}},"required":[],"additionalProperties":false},"annotations":{"readOnlyHint":false,"xodbSessionAccess":"controller"}},{"name":"import_jit_map","description":"Import a declared jitdump/perf-map source with explicit process and clock facts. Metadata is operator-declared.","inputSchema":{"type":"object","properties":{"path":{"type":"string"},"kind":{"enum":["jitdump","perfmap"]},"declaration":{"type":"object"},"process_id":{"type":"integer","minimum":1,"maximum":1024}},"required":["path","kind","declaration"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"xodbSessionAccess":"controller"}},{"name":"prepare_jit_profile","description":"Prepare JIT labels for up to 64 native samples on a bounded worker; stops collection first.","inputSchema":{"type":"object","properties":{"capture_id":{"type":"integer"},"revision":{"type":"integer"},"start":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":64},"process_id":{"type":"integer","minimum":1,"maximum":1024}},"required":["capture_id","revision"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"xodbSessionAccess":"controller"}},{"name":"get_jit_profile","description":"Read prepared native PC labels, resolver outcomes, candidates and lifetime citations.","inputSchema":{"type":"object","properties":{"capture_id":{"type":"integer"},"revision":{"type":"integer"},"start":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":64},"process_id":{"type":"integer","minimum":1,"maximum":1024}},"required":["capture_id","revision"],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"get_jit_stack","description":"Page prepared native-profile caller labels, preserving raw PCs and uncertainty.","inputSchema":{"type":"object","properties":{"capture_id":{"type":"integer"},"revision":{"type":"integer"},"limit":{"type":"integer","minimum":1,"maximum":64},"process_id":{"type":"integer","minimum":1,"maximum":1024},"ordinal":{"type":"integer","minimum":0},"frame":{"type":["integer","null"],"minimum":0},"start":{"type":"integer","minimum":0}},"required":["capture_id","revision","ordinal"],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"get_jit_candidates","description":"Page candidates for a prepared sampled leaf or caller frame; names have bounded previews and original byte citations.","inputSchema":{"type":"object","properties":{"capture_id":{"type":"integer"},"revision":{"type":"integer"},"limit":{"type":"integer","minimum":1,"maximum":64},"process_id":{"type":"integer","minimum":1,"maximum":1024},"ordinal":{"type":"integer","minimum":0},"frame":{"type":["integer","null"],"minimum":0},"start":{"type":"integer","minimum":0}},"required":["capture_id","revision","ordinal"],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"get_debug_metadata","description":"Inspect background debug-data progress and availability without target I/O.","inputSchema":{"type":"object","properties":{"process_id":{"type":"integer","minimum":1,"maximum":1024}},"required":[],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"cancel_debug_metadata","description":"Cancel a debug-data job and withdraw its result.","inputSchema":{"type":"object","properties":{"process_id":{"type":"integer","minimum":1,"maximum":1024},"id":{"type":"integer","minimum":1}},"required":["id"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"xodbSessionAccess":"controller"}},{"name":"retry_debug_metadata","description":"Discard a metadata result so the next stack or value request retries.","inputSchema":{"type":"object","properties":{"process_id":{"type":"integer","minimum":1,"maximum":1024},"id":{"type":"integer","minimum":1}},"required":["id"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"xodbSessionAccess":"controller"}},{"name":"get_language_tabs","description":"Read right-pane selection and runtime version, build ID, proof generation and reader diagnostics.","inputSchema":{"type":"object","properties":{"generation":{"type":"integer","minimum":0},"process_id":{"type":"integer","minimum":1,"maximum":1024}},"required":[],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"select_language_tab","description":"Select a detected right-pane tab; presentation only, does not resume or mutate the target.","inputSchema":{"type":"object","properties":{"generation":{"type":"integer","minimum":0},"process_id":{"type":"integer","minimum":1,"maximum":1024},"tab":{"type":"string","enum":["registers","native","python","perl","lua","javascript","ruby","go"]}},"required":["generation","tab"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"xodbSessionAccess":"controller"}},{"name":"select_native_frame","description":"Select a native frame and offer language segments with reader-proved matching anchors. No target mutation.","inputSchema":{"type":"object","properties":{"generation":{"type":"integer","minimum":0},"process_id":{"type":"integer","minimum":1,"maximum":1024},"tid":{"type":"integer","minimum":1},"frame":{"type":"integer","minimum":0,"maximum":63}},"required":["generation","tid","frame"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"xodbSessionAccess":"controller"}},{"name":"select_language_frame","description":"Select a logical row and highlight its reader-proved native segment anchor. Unproved anchors stay partial; no target mutation.","inputSchema":{"type":"object","properties":{"generation":{"type":"integer","minimum":0},"process_id":{"type":"integer","minimum":1,"maximum":1024},"tid":{"type":"integer","minimum":1},"frame":{"type":"integer","minimum":0,"maximum":63},"language":{"type":"string","enum":["python","perl","lua","javascript","ruby","go"]},"segment":{"type":"integer","minimum":0,"maximum":63}},"required":["generation","tid","frame","language","segment"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"xodbSessionAccess":"controller"}},{"name":"get_language_locals","description":"Page retained language bindings. JavaScript returns context storage with lexical visibility explicitly unproved, scope depth and provenance; stack-only bindings are not shown. Unavailable layouts and names have diagnostics; no target code runs.","inputSchema":{"type":"object","properties":{"generation":{"type":"integer","minimum":0},"language":{"enum":["python","perl","lua","javascript","ruby"]},"tid":{"type":"integer","minimum":1},"segment":{"type":"integer","minimum":0,"maximum":63},"frame":{"type":"integer","minimum":0,"maximum":63},"start":{"type":"integer","minimum":0,"maximum":4096},"limit":{"type":"integer","minimum":1,"maximum":32},"process_id":{"type":"integer","minimum":1,"maximum":1024}},"required":["generation","language","tid","segment","frame"],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"evaluate_language_expression","description":"Resolve a bounded language expression in a retained logical frame without target execution. Lua accepts an ASCII local/upvalue name plus up to four .identifier or [int32] raw-table selectors (128 bytes); metatables are refused; Lua 5.4 follows at most 128 collision nodes while Lua 5.2 hash scans remain capped at 128 slots; Perl accepts a sigil plus ASCII identifier from the active pad. Python accepts exact fast-local, cell and free-variable roots with up to four [int32] or quoted printable ASCII-key subscripts (128 bytes), through exact builtin dict/list/tuple storage; custom keys, subclasses and oversized scans refuse. JavaScript refuses unproved bare names with JavaScriptLexicalUnproved: a retained context name may be shadowed by a stack binding. These readers refuse target execution.","inputSchema":{"type":"object","properties":{"generation":{"type":"integer","minimum":0},"language":{"enum":["python","perl","lua","javascript","ruby"]},"tid":{"type":"integer","minimum":1},"segment":{"type":"integer","minimum":0,"maximum":63},"frame":{"type":"integer","minimum":0,"maximum":63},"process_id":{"type":"integer","minimum":1,"maximum":1024},"expression":{"type":"string","minLength":1,"maxLength":128}},"required":["generation","language","tid","segment","frame","expression"],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"get_language_watches","description":"Read cached stopped-language watch values and previous values; never performs target reads.","inputSchema":{"type":"object","properties":{"generation":{"type":"integer","minimum":0},"process_id":{"type":"integer","minimum":1,"maximum":1024}},"required":[],"additionalProperties":false},"annotations":{"readOnlyHint":true,"xodbSessionAccess":"observer"}},{"name":"add_language_watch","description":"Create a bounded stopped-language comparison watch. Lua/Python accept bounded container paths or a row; Perl/Ruby accept a name or row; JavaScript accepts only an explicit context-storage row, with lexical visibility and continuous activation lifetime unproved. Re-resolves storage; never runs target code.","inputSchema":{"type":"object","properties":{"generation":{"type":"integer","minimum":0},"process_id":{"type":"integer","minimum":1,"maximum":1024},"language":{"enum":["lua","python","perl","ruby","javascript"]},"tid":{"type":"integer","minimum":1},"segment":{"type":"integer","minimum":0,"maximum":63},"frame":{"type":"integer","minimum":0,"maximum":63},"expression":{"type":"string","minLength":1,"maxLength":128},"row":{"type":"integer","minimum":0,"maximum":4095}},"required":["generation","language","tid","segment","frame"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"xodbSessionAccess":"controller"}},{"name":"remove_language_watch","description":"Remove a stopped-language comparison watch.","inputSchema":{"type":"object","properties":{"generation":{"type":"integer","minimum":0},"process_id":{"type":"integer","minimum":1,"maximum":1024},"id":{"type":"integer","minimum":1}},"required":["generation","id"],"additionalProperties":false},"annotations":{"readOnlyHint":false,"xodbSessionAccess":"controller"}}]
;
const static_definitions = std.mem.trimEnd(u8, @import("static_analysis.zig").definitions, " \n");
const tool_definitions = base_tool_definitions[0 .. base_tool_definitions.len - 1] ++ "," ++ static_definitions[1 .. static_definitions.len - 1] ++ "," ++ overview.definitions[1..];
const overview = @import("overview.zig");
fn member(value: Value, name: []const u8) ?Value {
    return if (value == .object) value.object.get(name) else null;
}
fn string(value: ?Value) ?[]const u8 {
    const v = value orelse return null;
    return if (v == .string) v.string else null;
}
fn number(value: ?Value) ?u64 {
    const v = value orelse return null;
    return if (v == .integer and v.integer >= 0) @intCast(v.integer) else null;
}
fn asValue(a: Allocator, value: anytype) !Value {
    const text = try std.json.Stringify.valueAlloc(a, value, .{});
    return (try std.json.parseFromSlice(Value, a, text, .{ .allocate = .alloc_always })).value;
}
fn address(args: Value) !u64 {
    const text = string(member(args, "address")) orelse return error.InvalidArguments;
    return std.fmt.parseInt(u64, if (std.mem.startsWith(u8, text, "0x")) text[2..] else text, 16) catch error.InvalidArguments;
}

pub const Server = struct {
    shared: ?shared_context.Context = null,
    policies: std.StringHashMapUnmanaged(shared_context.Policy) = .empty,
    policy_definitions: ?[]const u8 = null,
    request_limit: usize = 8,
    transmitted: u64 = 0,
    reported_revision: ?u64 = null,
    input: [65536]u8 = undefined,
    used: usize = 0,
    // Accommodates a full 1024-thread session plus capture in a single reply.
    output: [1048576]u8 = undefined,
    queued: usize = 0,
    sent: usize = 0,
    closed: bool = false,
    input_eof: bool = false,
    negotiated: bool = false,
    initialized: bool = false,
    stdout_flags: c_int = 0,
    input_fd: c_int = 0,
    output_fd: c_int = 1,
    source_path: ?[:0]const u8 = null,
    reported_scope: ?@import("../model/session.zig").AgentScope = null,
    overview: overview.State = .{},
    overview_shared: ?*overview.State = null,
    overview_only: bool = false,
    pub fn overviewTick(self: *Server) !void {
        if (self.overview_shared == null) _ = try self.overview.tick(@import("../target/linux.zig").now(), 0, false);
    }
    pub fn init(self: *Server) !void {
        self.stdout_flags = c.fcntl(self.output_fd, c.F_GETFL);
        if (self.stdout_flags < 0 or c.fcntl(self.output_fd, c.F_SETFL, self.stdout_flags | c.O_NONBLOCK) < 0) return error.McpOutputUnavailable;
    }
    pub fn deinit(self: *Server) void {
        _ = c.fcntl(self.output_fd, c.F_SETFL, self.stdout_flags);
        self.overview.deinit();
        self.clearPolicies();
    }
    fn clearPolicies(self: *Server) void {
        var keys = self.policies.keyIterator();
        while (keys.next()) |key| std.heap.c_allocator.free(key.*);
        self.policies.deinit(std.heap.c_allocator);
        self.policies = .empty;
        self.policy_definitions = null;
    }
    fn toolPolicy(self: *Server, definitions: []const u8, name: []const u8) !shared_context.Policy {
        // Cache only immutable schema metadata. Scope and lease are checked on
        // every call; mode changes rebuild the table before looking up a tool.
        if (self.policy_definitions == null or self.policy_definitions.?.ptr != definitions.ptr) {
            self.clearPolicies();
            errdefer self.clearPolicies();
            const a = std.heap.c_allocator;
            const parsed = try std.json.parseFromSlice(Value, a, definitions, .{});
            defer parsed.deinit();
            for (parsed.value.array.items) |definition| {
                const key = string(member(definition, "name")) orelse return error.MissingToolName;
                const policy = try shared_context.Policy.fromDefinition(definition);
                if (self.policies.contains(key)) return error.DuplicateToolName;
                const owned = try a.dupe(u8, key);
                errdefer a.free(owned);
                try self.policies.put(a, owned, policy);
            }
            self.policy_definitions = definitions;
        }
        return self.policies.get(name) orelse error.UnknownTool;
    }
    fn queue(self: *Server, bytes: []const u8) !void {
        if (self.sent > 0) {
            std.mem.copyForwards(u8, &self.output, self.output[self.sent..self.queued]);
            self.queued -= self.sent;
            self.sent = 0;
        }
        if (bytes.len + 1 > self.output.len - self.queued) return error.McpClientNotReading;
        @memcpy(self.output[self.queued..][0..bytes.len], bytes);
        self.queued += bytes.len;
        self.output[self.queued] = '\n';
        self.queued += 1;
    }
    fn reply(self: *Server, a: Allocator, id: Value, result: anytype) !void {
        const bytes = try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .id = id, .result = result }, .{});
        if (bytes.len >= self.output.len) {
            try self.failure(a, id, -32000, "McpResponseTooLarge: request a smaller page or range");
            return;
        }
        try self.queue(bytes);
    }
    fn failure(self: *Server, a: Allocator, id: Value, code: i32, message: []const u8) !void {
        try self.queue(try std.json.Stringify.valueAlloc(a, .{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = code, .message = message } }, .{}));
    }
    fn tool(self: *Server, a: Allocator, root: *Session, name: []const u8, args: Value) !Value {
        if (args != .object) return error.InvalidArguments;
        if (self.overview_only and !overview.handles(name) and !std.mem.eql(u8, name, "get_session_clients") and !std.mem.eql(u8, name, "get_session_events")) return error.UnknownTool;
        if (self.shared) |peer| {
            if (shared_context.handles(name)) return peer.call(a, root, name, args);
            try peer.tick(root);
        }
        // Visibility is not authorization. Resolve the declared policy before
        // routing or validating tool-specific arguments, for every transport.
        const policy = try self.toolPolicy(if (self.overview_only) overview.definitions else if (root.imported != null) @import("imported.zig").definitions else tool_definitions, name);
        if (self.shared) |peer| {
            switch (policy.required) {
                .observer => {},
                .controller => try peer.authorize(false),
                .mutator => try peer.authorize(true),
                .lease => return error.InvalidToolSessionAccess,
            }
        } else if (!policy.localAllowed(root.agent_scope, root.shared_jobs)) return error.AgentScopeDenied;
        if (@import("fd.zig").isControl(name)) {
            if (root.agent_scope == .observe) return error.AgentScopeDenied;
            // Shared calls already passed the authoritative lease check above.
            const collector = self.overview_shared orelse &self.overview;
            const result = try @import("fd.zig").control(a, collector, name, args);
            collector.fd_lease = if (std.mem.eql(u8, name, "start_fd_events"))
                (if (self.shared) |peer| @import("../service/lease.zig").Lease.capture(peer.service, peer.client_id) else null)
            else
                null;
            return result;
        }
        // Whole-system observation needs no debug target or process routing.
        if (overview.handles(name)) return overview.call(a, self.overview_shared orelse &self.overview, name, args);
        const process_id = try @import("profile.zig").number(args, "process_id", 1);
        const session = if (root.process_tree) |tree| (try tree.find(process_id)).session else if (process_id == root.process_id) root else return error.UnknownProcess;
        if (!policy.localAllowed(session.agent_scope, root.shared_jobs or session.shared_jobs)) return error.AgentScopeDenied;
        var local = Value{ .object = .empty };
        var fields = args.object.iterator();
        while (fields.next()) |field| if (!std.mem.eql(u8, field.key_ptr.*, "process_id")) try local.object.put(a, field.key_ptr.*, field.value_ptr.*);
        const previous_lease = session.agent_lease;
        session.agent_lease = if (self.shared) |peer| @import("../service/lease.zig").Lease.capture(peer.service, peer.client_id) else null;
        defer session.agent_lease = previous_lease;
        const previous_client = session.agent_client_id;
        session.agent_client_id = if (self.shared) |peer| peer.client_id else null;
        defer session.agent_client_id = previous_client;
        const previous_controller = session.agent_controller;
        session.agent_controller = if (self.shared) |peer| peer.visible(.controller) catch false else session.agent_scope != .observe;
        defer session.agent_controller = previous_controller;
        var result = try self.toolForProcess(a, session, name, local);
        if (result == .object) {
            try result.object.put(a, "process_id", .{ .integer = @intCast(session.process_id) });
            try result.object.put(a, "process_session_id", .{ .integer = @intCast(session.id) });
        }
        return result;
    }
    fn toolForProcess(self: *Server, a: Allocator, session: *Session, name: []const u8, args: Value) !Value {
        if (@import("frames.zig").handles(name)) return @import("frames.zig").call(a, session, name, args);
        const processes = @import("processes.zig");
        if (processes.handles(name)) return processes.call(a, session, name, args);
        if (session.imported) |*state| {
            if (std.mem.eql(u8, name, "get_session")) return asValue(a, session.snapshot());
            return @import("imported.zig").call(a, state, name, args);
        }
        if (std.mem.eql(u8, name, "get_core_info")) {
            const wire = @import("profile.zig");
            try wire.fields(args, &.{ "mapping_start", "segment_start", "limit" });
            const core = if (session.target.core) |*core| core else return error.NotCoreSession;
            const m = try wire.number(args, "mapping_start", 0);
            const p = try wire.number(args, "segment_start", 0);
            const limit = try wire.number(args, "limit", 16);
            if (m > core.mappings.items.len or p > core.segments.items.len or limit == 0 or limit > 32) return error.InvalidArguments;
            const me = m + @min(limit, core.mappings.items.len - m);
            const pe = p + @min(limit, core.segments.items.len - p);
            return asValue(a, .{ .generation = session.target.snapshot().generation, .path = core.path, .file_bytes = core.size, .pid = core.pid, .command = core.command, .signal = core.signal, .threads = core.threads.items.len, .segment_total = core.segments.items.len, .mapping_total = core.mappings.items.len, .mapping_next = if (me < core.mappings.items.len) @as(?u64, me) else null, .segment_next = if (pe < core.segments.items.len) @as(?u64, pe) else null, .segments = core.segments.items[@intCast(p)..@intCast(pe)], .mappings = core.mappings.items[@intCast(m)..@intCast(me)], .read_only = true, .memory_basis = "captured PT_LOAD bytes only; omitted memory is unavailable", .symbol_basis = "local ELF build ID matched against captured notes" });
        }
        if (std.mem.eql(u8, name, "get_stop_info")) {
            const wire = @import("profile.zig");
            try wire.fields(args, &.{ "tid", "generation" });
            const tid = try wire.number(args, "tid", 0);
            if (tid == 0 or tid > std.math.maxInt(i32)) return error.InvalidArguments;
            try session.target.expectGeneration(try wire.number(args, "generation", session.target.snapshot().generation));
            return asValue(a, .{ .generation = session.target.snapshot().generation, .stop = try session.target.stopInfo(@intCast(tid)) });
        }
        if (std.mem.eql(u8, name, "get_debug_metadata")) {
            try @import("profile.zig").fields(args, &.{});
            return asValue(a, .{ .jobs = session.metadata.snapshot() });
        }
        if (std.mem.eql(u8, name, "cancel_debug_metadata") or std.mem.eql(u8, name, "retry_debug_metadata")) {
            const wire = @import("profile.zig");
            try wire.fields(args, &.{"id"});
            const id = try wire.number(args, "id", null);
            if (std.mem.eql(u8, name, "cancel_debug_metadata")) try session.metadata.cancel(id) else try session.metadata.retry(id);
            return asValue(a, .{ .jobs = session.metadata.snapshot() });
        }
        if (std.mem.eql(u8, name, "get_debug_files")) return @import("debug_files.zig").call(a, session, args);
        if (std.mem.eql(u8, name, "get_extended_registers")) return @import("registers.zig").call(a, session, args);
        if (std.mem.eql(u8, name, "get_language_locals") or std.mem.eql(u8, name, "evaluate_language_expression")) return @import("language_locals.zig").call(a, session, name, args);
        if (@import("language_watches.zig").handles(name)) return @import("language_watches.zig").call(a, session, name, args);
        const language_tabs = @import("language_tabs.zig");
        if (language_tabs.handles(name)) return language_tabs.call(a, session, name, args);
        const allocations = @import("allocation_control.zig");
        if (allocations.handles(name)) return allocations.call(a, session, name, args);
        const memory = @import("memory.zig");
        if (memory.handles(name)) return memory.call(a, session, name, args);
        const inspection = @import("inspection.zig");
        if (inspection.handles(name)) return inspection.call(a, session, name, args);
        const observation = @import("observation.zig");
        if (observation.handles(name)) return observation.call(a, session, name, args);
        const associations = @import("associations.zig");
        if (associations.handles(name)) return associations.call(a, session, name, args);
        const probes = @import("probes.zig");
        if (probes.handles(name)) return probes.call(a, session, name, args);
        const remote = @import("remote.zig");
        if (remote.handles(name)) return remote.call(a, session, name, args, self.source_path);
        if (std.mem.eql(u8, name, "get_profile_comparison")) return @import("comparison.zig").call(a, session, args);
        const archives = @import("archive.zig");
        if (archives.handles(name)) return archives.call(a, session, name, args);
        const profiles = @import("profile.zig");
        if (profiles.handles(name)) return profiles.call(a, session, name, args);
        const static_analysis = @import("static_analysis.zig");
        if (static_analysis.handles(name)) return static_analysis.call(a, session, name, args);
        if (session.offline) {
            const reads = [_][]const u8{ "get_session", "get_audit", "query_events", "list_threads", "get_breakpoints" };
            for (reads) |read| {
                if (std.mem.eql(u8, name, read)) break;
            } else return error.OfflineSession;
        }
        if (std.mem.eql(u8, name, "list_locals")) return @import("locals_list.zig").call(a, session, args);
        if (std.mem.eql(u8, name, "list_modules")) return @import("module_list.zig").call(a, session, args);
        if (args != .object) return error.InvalidArguments;
        var fields = args.object.iterator();
        while (fields.next()) |field| {
            const key = field.key_ptr.*;
            const allowed = if (std.mem.eql(u8, key, "inline_depth") and (std.mem.eql(u8, name, "list_locals") or std.mem.eql(u8, name, "evaluate_expression") or std.mem.eql(u8, name, "get_value_children"))) true else if (std.mem.eql(u8, name, "get_registers"))
                std.mem.eql(u8, key, "tid") or std.mem.eql(u8, key, "generation")
            else if (std.mem.eql(u8, name, "read_memory"))
                std.mem.eql(u8, key, "address") or std.mem.eql(u8, key, "length") or std.mem.eql(u8, key, "generation")
            else if (std.mem.eql(u8, name, "disassemble") or std.mem.eql(u8, name, "get_source_location"))
                std.mem.eql(u8, key, "address") or std.mem.eql(u8, key, "generation")
            else if (std.mem.eql(u8, name, "get_instruction_effects"))
                std.mem.eql(u8, key, "address") or std.mem.eql(u8, key, "generation") or std.mem.eql(u8, key, "length") or std.mem.eql(u8, key, "limit")
            else if (std.mem.eql(u8, name, "get_language_stack"))
                std.mem.eql(u8, key, "tid") or std.mem.eql(u8, key, "frame") or std.mem.eql(u8, key, "language") or std.mem.eql(u8, key, "state") or std.mem.eql(u8, key, "generation")
            else if (std.mem.eql(u8, name, "get_value_children"))
                std.mem.eql(u8, key, "tid") or std.mem.eql(u8, key, "frame") or std.mem.eql(u8, key, "expression") or std.mem.eql(u8, key, "generation") or std.mem.eql(u8, key, "start") or std.mem.eql(u8, key, "limit") or std.mem.eql(u8, key, "raw")
            else if (std.mem.eql(u8, name, "get_function_graph"))
                std.mem.eql(u8, key, "address") or std.mem.eql(u8, key, "symbol") or std.mem.eql(u8, key, "start_block") or std.mem.eql(u8, key, "limit") or std.mem.eql(u8, key, "generation")
            else if (std.mem.eql(u8, name, "query_events")) std.mem.eql(u8, key, "after") else if (std.mem.eql(u8, name, "find_symbol")) std.mem.eql(u8, key, "name") else if (std.mem.eql(u8, name, "get_investigation")) std.mem.eql(u8, key, "id") else if (std.mem.eql(u8, name, "investigate_write")) std.mem.eql(u8, key, "tid") or std.mem.eql(u8, key, "question") or std.mem.eql(u8, key, "frame") or std.mem.eql(u8, key, "expression") or std.mem.eql(u8, key, "generation") else if (std.mem.eql(u8, name, "set_breakpoint")) std.mem.eql(u8, key, "address") or std.mem.eql(u8, key, "symbol") or std.mem.eql(u8, key, "file") or std.mem.eql(u8, key, "line") or std.mem.eql(u8, key, "generation") else if (std.mem.eql(u8, name, "remove_breakpoint") or std.mem.eql(u8, name, "remove_watchpoint")) std.mem.eql(u8, key, "id") or std.mem.eql(u8, key, "generation") else if (std.mem.eql(u8, name, "set_watchpoint")) std.mem.eql(u8, key, "address") or std.mem.eql(u8, key, "length") or std.mem.eql(u8, key, "kind") or std.mem.eql(u8, key, "generation") else if (std.mem.eql(u8, name, "continue") or std.mem.eql(u8, name, "interrupt")) std.mem.eql(u8, key, "generation") else if (std.mem.eql(u8, name, "evaluate_expression")) std.mem.eql(u8, key, "tid") or std.mem.eql(u8, key, "frame") or std.mem.eql(u8, key, "expression") or std.mem.eql(u8, key, "generation") else if (std.mem.eql(u8, name, "get_stack") or std.mem.eql(u8, name, "list_locals")) std.mem.eql(u8, key, "tid") or std.mem.eql(u8, key, "frame") or std.mem.eql(u8, key, "generation") else if (std.mem.eql(u8, name, "step_instruction") or std.mem.eql(u8, name, "step_over_instruction") or std.mem.eql(u8, name, "step_source") or std.mem.eql(u8, name, "step_over")) std.mem.eql(u8, key, "tid") or std.mem.eql(u8, key, "generation") else if (std.mem.eql(u8, name, "write_memory")) std.mem.eql(u8, key, "address") or std.mem.eql(u8, key, "hex") or std.mem.eql(u8, key, "generation") else if (std.mem.eql(u8, name, "write_register")) std.mem.eql(u8, key, "tid") or std.mem.eql(u8, key, "name") or std.mem.eql(u8, key, "value") or std.mem.eql(u8, key, "generation") else false;
            if (!allowed) return error.InvalidArguments;
        }
        if (member(args, "generation")) |v| {
            const generation = number(v) orelse return error.InvalidArguments;
            try session.target.expectGeneration(generation);
        }
        if (std.mem.eql(u8, name, "find_symbol")) {
            try session.refreshMaps();
            const symbol = try session.modules.findSymbol(string(member(args, "name")) orelse return error.InvalidArguments);
            return asValue(a, .{ .module_id = symbol.module_id, .name = symbol.name, .address = try std.fmt.allocPrint(a, "0x{x}", .{symbol.address}), .size = symbol.size, .local_entry = symbol.entry });
        }
        if (std.mem.eql(u8, name, "get_breakpoints")) return asValue(a, .{ .breakpoints = session.target.breakpointSlice(), .watchpoints = session.target.watchpointSlice(), .policies = session.probes.rules, .definitions = session.persistent.entries.items, .loader_status = session.persistent.loader_status, .loader_reads = session.persistent.loader_reads, .symbol_transfer = .{ .bytes = session.persistent.file_reads.bytes, .files = session.persistent.file_reads.files, .negative_hits = session.persistent.file_reads.negative_hits, .skipped = session.persistent.file_reads.skipped, .resumed_bytes = session.persistent.file_reads.resumed_bytes, .cached_modules = session.modules.symbol_images.items.len, .retained_bytes = session.modules.symbol_bytes }, .data_watch_slots = session.target.watchpointCapacity() catch null, .execution_watches = session.target.gdbRemoteInfo() == null and session.target.arch() == .x86_64 });
        if (std.mem.eql(u8, name, "get_investigation")) return asValue(a, (try session.investigation(number(member(args, "id")) orelse return error.InvalidArguments)).*);
        if (std.mem.eql(u8, name, "get_audit")) return asValue(a, .{ .actions = session.audit[0..session.audit_count] });
        const execution_names = [_][]const u8{ "continue", "interrupt", "step_instruction", "step_over_instruction", "step_source", "step_over", "investigate_write", "set_breakpoint", "remove_breakpoint", "set_watchpoint", "remove_watchpoint" };
        const mutation_names = [_][]const u8{ "write_memory", "write_register" };
        var effect: ?@import("../model/session.zig").Effect = null;
        var action: []const u8 = "";
        for (execution_names) |candidate| if (std.mem.eql(u8, name, candidate)) {
            effect = .execution;
            action = candidate;
        };
        for (mutation_names) |candidate| if (std.mem.eql(u8, name, candidate)) {
            effect = .mutation;
            action = candidate;
        };
        if (effect) |kind| {
            try session.authorize(.agent, kind, number(member(args, "generation")));
            var created_id: ?u64 = null;
            if (std.mem.eql(u8, name, "investigate_write")) {
                const tid = number(member(args, "tid")) orelse return error.InvalidArguments;
                if (tid == 0 or tid > std.math.maxInt(i32)) return error.InvalidArguments;
                const frame_index = if (member(args, "frame")) |v| number(v) orelse return error.InvalidArguments else 0;
                if (frame_index >= 64) return error.InvalidArguments;
                created_id = try session.investigateWrite(@intCast(tid), @intCast(frame_index), string(member(args, "question")) orelse return error.InvalidArguments, string(member(args, "expression")) orelse return error.InvalidArguments);
            } else if (std.mem.eql(u8, name, "continue")) try session.continueExecution(.agent) else if (std.mem.eql(u8, name, "interrupt")) {
                session.cancelStep();
                try session.target.interrupt();
            } else if (std.mem.eql(u8, name, "step_instruction") or std.mem.eql(u8, name, "step_over_instruction") or std.mem.eql(u8, name, "step_source") or std.mem.eql(u8, name, "step_over")) {
                session.probe_resume_actor = .agent;
                const t = number(member(args, "tid")) orelse return error.InvalidArguments;
                if (t == 0 or t > std.math.maxInt(i32)) return error.InvalidArguments;
                if (std.mem.eql(u8, name, "step_source") or std.mem.eql(u8, name, "step_over")) try session.startSourceStep(@intCast(t), std.mem.eql(u8, name, "step_over")) else if (std.mem.eql(u8, name, "step_instruction")) try session.stepInstruction(@intCast(t)) else try session.stepOverInstruction(@intCast(t));
            } else if (std.mem.eql(u8, name, "set_breakpoint")) {
                if (string(member(args, "file"))) |file| {
                    if (member(args, "address") != null or member(args, "symbol") != null) return error.InvalidArguments;
                    const line_number = number(member(args, "line")) orelse return error.InvalidArguments;
                    if (line_number == 0 or line_number > std.math.maxInt(u32)) return error.InvalidArguments;
                    const ids = try session.setSourceBreakpoint(a, file, @intCast(line_number));
                    session.record(.agent, action);
                    return asValue(a, .{ .id = ids[0], .ids = ids, .session = session.snapshot() });
                }
                if (member(args, "line") != null) return error.InvalidArguments;
                var location: u64 = undefined;
                if (string(member(args, "symbol"))) |symbol_name| {
                    if (member(args, "address") != null) return error.InvalidArguments;
                    try session.refreshMaps();
                    created_id = try session.persistent.addSymbol(session, symbol_name);
                    session.record(.agent, action);
                    return asValue(a, .{ .id = created_id, .pending = @import("../model/persistent.zig").Manager.probe(session, created_id.?).?.pending, .session = session.snapshot() });
                } else location = try address(args);
                created_id = try session.target.setBreakpoint(location, false);
            } else if (std.mem.eql(u8, name, "remove_breakpoint")) {
                const id = number(member(args, "id")) orelse return error.InvalidArguments;
                if (@import("../model/persistent.zig").Manager.probe(session, id)) |probe| if (probe.internal) return error.InternalBreakpoint;
                try session.target.removeBreakpoint(id);
            } else if (std.mem.eql(u8, name, "remove_watchpoint")) try session.target.removeWatchpoint(number(member(args, "id")) orelse return error.InvalidArguments) else if (std.mem.eql(u8, name, "set_watchpoint")) {
                const length = number(member(args, "length")) orelse return error.InvalidArguments;
                if (length > 8) return error.InvalidArguments;
                const watch_kind = std.meta.stringToEnum(@import("../target/breakpoints.zig").WatchKind, string(member(args, "kind")) orelse "write") orelse return error.InvalidArguments;
                created_id = try session.target.setWatchpoint(try address(args), @intCast(length), watch_kind);
            } else if (std.mem.eql(u8, name, "write_memory")) {
                const hex = string(member(args, "hex")) orelse return error.InvalidArguments;
                if (hex.len == 0 or hex.len > 8192 or hex.len % 2 != 0) return error.InvalidArguments;
                var bytes: [4096]u8 = undefined;
                for (0..hex.len / 2) |i| bytes[i] = std.fmt.parseInt(u8, hex[i * 2 ..][0..2], 16) catch return error.InvalidArguments;
                const before = session.target.snapshot().generation;
                session.target.writeMemory(try address(args), bytes[0 .. hex.len / 2]) catch |err| {
                    if (session.target.snapshot().generation != before) session.record(.agent, "write_memory_partial");
                    return err;
                };
            } else if (std.mem.eql(u8, name, "write_register")) {
                const tid = number(member(args, "tid")) orelse return error.InvalidArguments;
                if (tid == 0 or tid > std.math.maxInt(i32)) return error.InvalidArguments;
                const text = string(member(args, "value")) orelse return error.InvalidArguments;
                const value = std.fmt.parseInt(u64, text, 0) catch return error.InvalidArguments;
                try session.target.writeRegister(@intCast(tid), string(member(args, "name")) orelse return error.InvalidArguments, value);
            }
            session.record(.agent, action);
            return asValue(a, .{ .id = created_id, .session = session.snapshot() });
        }
        if (std.mem.eql(u8, name, "get_session")) return asValue(a, session.snapshot());
        if (std.mem.eql(u8, name, "list_threads")) {
            if (session.target.gdbRemoteInfo()) |info| if (info.threads == .unsupported) return error.UnsupportedControl;
            return asValue(a, .{ .generation = session.target.snapshot().generation, .threads = session.target.threadSlice() });
        }
        if (std.mem.eql(u8, name, "get_source_location")) return asValue(a, .{ .generation = session.target.snapshot().generation, .source = try session.sourceAt(a, try address(args)) });
        if (std.mem.eql(u8, name, "get_language_stack")) {
            const tid = number(member(args, "tid")) orelse return error.InvalidArguments;
            const frame = if (member(args, "frame")) |v| number(v) orelse return error.InvalidArguments else 0;
            const language = string(member(args, "language")) orelse return error.InvalidArguments;
            if (tid == 0 or tid > std.math.maxInt(i32) or frame >= 64) return error.InvalidArguments;
            if (std.mem.eql(u8, language, "lua")) {
                const state: ?u64 = if (member(args, "state")) |v| std.fmt.parseInt(u64, string(v) orelse return error.InvalidArguments, 0) catch return error.InvalidArguments else null;
                return asValue(a, try @import("../language/lua.zig").stack(session, a, @intCast(tid), @intCast(frame), state));
            }
            if (member(args, "state") != null) return error.InvalidArguments;
            if (std.mem.eql(u8, language, "ruby")) return asValue(a, try @import("../language/ruby.zig").stack(session, a, @intCast(tid), @intCast(frame)));
            if (std.mem.eql(u8, language, "go")) return asValue(a, try @import("../language/go.zig").stack(session, a, @intCast(tid), @intCast(frame)));
            if (std.mem.eql(u8, language, "javascript")) return asValue(a, try @import("../language/javascript.zig").stack(session, a, @intCast(tid), @intCast(frame)));
            if (std.mem.eql(u8, language, "python")) return asValue(a, try @import("../language/python.zig").stack(session, a, @intCast(tid), @intCast(frame)));
            if (!std.mem.eql(u8, language, "perl")) return error.InvalidArguments;
            return asValue(a, try @import("../language/perl.zig").stack(session, a, @intCast(tid), @intCast(frame)));
        }
        if (std.mem.eql(u8, name, "get_stack")) {
            const tid = number(member(args, "tid")) orelse return error.InvalidArguments;
            if (tid == 0 or tid > std.math.maxInt(i32)) return error.InvalidArguments;
            return asValue(a, .{ .generation = session.target.snapshot().generation, .frames = try session.stack(a, @intCast(tid), 64) });
        }
        if (std.mem.eql(u8, name, "get_value_children")) {
            const tid = number(member(args, "tid")) orelse return error.InvalidArguments;
            if (tid == 0 or tid > std.math.maxInt(i32)) return error.InvalidArguments;
            const frame = if (member(args, "frame")) |v| number(v) orelse return error.InvalidArguments else 0;
            const start = if (member(args, "start")) |v| number(v) orelse return error.InvalidArguments else 0;
            const limit = if (member(args, "limit")) |v| number(v) orelse return error.InvalidArguments else 16;
            const raw = if (member(args, "raw")) |v| switch (v) {
                .bool => v.bool,
                else => return error.InvalidArguments,
            } else false;
            if (frame >= 64 or limit == 0 or limit > 64) return error.InvalidArguments;
            const expression = string(member(args, "expression")) orelse return error.InvalidArguments;
            const v = try session.evaluateAtDepth(a, @intCast(tid), @intCast(frame), try inlineDepth(args), expression);
            return asValue(a, .{ .generation = session.target.snapshot().generation, .tid = tid, .frame = frame, .expression = expression, .view = try session.valueChildren(a, v, start, @intCast(limit), raw) });
        }
        if (std.mem.eql(u8, name, "evaluate_expression")) {
            const tid = number(member(args, "tid")) orelse return error.InvalidArguments;
            if (tid == 0 or tid > std.math.maxInt(i32)) return error.InvalidArguments;
            const expression = string(member(args, "expression")) orelse return error.InvalidArguments;
            const frame_index = if (member(args, "frame")) |v| number(v) orelse return error.InvalidArguments else 0;
            if (frame_index >= 64) return error.InvalidArguments;
            const value = try session.evaluateAtDepth(a, @intCast(tid), @intCast(frame_index), try inlineDepth(args), expression);
            return asValue(a, .{ .generation = session.target.snapshot().generation, .tid = tid, .expression = expression, .type = value.type.name, .kind = value.type.kind, .size = value.type.size, .bits = try std.fmt.allocPrint(a, "0x{x}", .{value.bits}), .availability = value.availability, .value = try session.summarize(a, value) });
        }
        if (std.mem.eql(u8, name, "get_registers")) {
            const tid = number(member(args, "tid")) orelse return error.InvalidArguments;
            if (tid == 0 or tid > std.math.maxInt(i32)) return error.InvalidArguments;
            const regs = try session.target.registers(@intCast(tid));
            var values: std.json.ObjectMap = .{};
            for (regs.descriptions()) |desc| try values.put(a, std.mem.span(desc.name), .{ .string = try @import("../target/runtime.zig").registerText(a, regs, desc) });
            const generation = session.target.snapshot().generation;
            if (regs.architecture() == .loongarch64)
                return asValue(a, .{ .generation = generation, .tid = tid, .note = "r0 is the kernel restart slot, not architectural zero", .registers = Value{ .object = values } });
            return asValue(a, .{ .generation = generation, .tid = tid, .registers = Value{ .object = values } });
        }
        if (std.mem.eql(u8, name, "read_memory")) {
            const addr = try address(args);
            const len = number(member(args, "length")) orelse return error.InvalidArguments;
            if (len == 0 or len > 4096) return error.InvalidArguments;
            const bytes = try a.alloc(u8, @intCast(len));
            const n = try session.target.readMemory(addr, bytes);
            const hex = try a.alloc(u8, n * 2);
            const digits = "0123456789abcdef";
            for (bytes[0..n], 0..) |v, i| {
                hex[i * 2] = digits[v >> 4];
                hex[i * 2 + 1] = digits[v & 15];
            }
            return asValue(a, .{ .generation = session.target.snapshot().generation, .address = try std.fmt.allocPrint(a, "0x{x}", .{addr}), .bytes_read = n, .hex = hex });
        }
        if (std.mem.eql(u8, name, "get_function_graph")) {
            if (session.target.snapshot().state != .stopped) return error.NotStopped;
            if ((member(args, "address") != null) == (member(args, "symbol") != null)) return error.InvalidArguments;
            try session.refreshMaps();
            const addr = if (member(args, "symbol")) |value| (try session.modules.findSymbol(string(value) orelse return error.InvalidArguments)).address else try address(args);
            const first = if (member(args, "start_block")) |value| number(value) orelse return error.InvalidArguments else 0;
            const limit = if (member(args, "limit")) |value| number(value) orelse return error.InvalidArguments else 8;
            if (limit == 0 or limit > 16) return error.InvalidArguments;
            const function = try session.functionGraph(a, addr);
            const graph = function.graph;
            if (first >= graph.blocks.len) return error.InvalidArguments;
            const end = @min(graph.blocks.len, first + limit);
            var blocks: std.array_list.Managed(Value) = .init(a);
            for (graph.blocks[@intCast(first)..@intCast(end)]) |block| {
                const last = graph.instructions[block.first + block.count - 1];
                const source = if (block.source) |site| try asValue(a, .{ .path = site.path[0..@min(512, site.path.len)], .path_truncated = site.path.len > 512, .line = site.line, .column = site.column }) else Value.null;
                try blocks.append(try asValue(a, .{ .id = block.id, .address = try std.fmt.allocPrint(a, "0x{x}", .{block.address}), .end = try std.fmt.allocPrint(a, "0x{x}", .{block.end}), .instruction_count = block.count, .reachable_via_resolved_edges = block.reachable, .source = source, .terminator = .{ .address = try std.fmt.allocPrint(a, "0x{x}", .{last.address}), .mnemonic = std.mem.sliceTo(&last.mnemonic, 0), .operands = std.mem.sliceTo(&last.operands, 0), .flow = last.flow } }));
            }
            var edges: std.array_list.Managed(Value) = .init(a);
            for (graph.edges) |edge| if (edge.from >= first and edge.from < end) {
                try edges.append(try asValue(a, .{ .from = edge.from, .to = edge.to, .kind = edge.kind, .resolution = edge.resolution, .assumed = edge.assumed, .address = if (edge.address) |to| try std.fmt.allocPrint(a, "0x{x}", .{to}) else @as(?[]const u8, null) }));
            };
            return asValue(a, .{ .generation = function.generation, .image_epoch = function.image_epoch, .module_id = function.module_id, .symbol = function.symbol[0..@min(512, function.symbol.len)], .symbol_truncated = function.symbol.len > 512, .address = try std.fmt.allocPrint(a, "0x{x}", .{graph.address}), .link_address = try std.fmt.allocPrint(a, "0x{x}", .{function.link_address}), .size = graph.size, .extent_source = function.extent_source, .range_index = function.range_index, .range_count = function.range_count, .whole_function = function.range_count == 1, .decoded_bytes = graph.decoded_bytes, .undecoded_bytes = graph.size - graph.decoded_bytes, .basis = "linear_decode_of_live_function_bytes_with_breakpoint_overlay", .execution_observed = false, .total_blocks = graph.blocks.len, .start_block = first, .next_block = if (end < graph.blocks.len) @as(?u64, end) else null, .blocks = Value{ .array = blocks }, .edges = Value{ .array = edges } });
        }
        if (std.mem.eql(u8, name, "get_instruction_effects")) {
            if (session.target.snapshot().state != .stopped) return error.NotStopped;
            if (session.target.arch() != .x86_64) return error.InstructionAnalysisUnsupportedArchitecture;
            const addr = try address(args);
            const length = if (member(args, "length")) |v| number(v) orelse return error.InvalidArguments else 256;
            const limit = if (member(args, "limit")) |v| number(v) orelse return error.InvalidArguments else 16;
            const ir = @import("../model/analysis_ir.zig");
            if (length == 0 or length > ir.max_bytes or limit == 0 or limit > ir.max_instructions) return error.InvalidArguments;
            var bytes: [ir.max_bytes]u8 = undefined;
            const n = try session.target.readMemory(addr, bytes[0..@intCast(length)]);
            if (n == 0) return error.FunctionMemoryIncomplete;
            const instructions = try ir.decode(a, bytes[0..n], addr, @intCast(limit));
            const decoded = if (instructions.len > 0) instructions[instructions.len - 1].address + instructions[instructions.len - 1].size - addr else 0;
            return asValue(a, .{ .generation = session.target.snapshot().generation, .image_epoch = session.target.snapshot().image_epoch, .architecture = @tagName(session.target.arch()), .schema_version = 1, .basis = "capstone_operands_and_register_access_from_live_bytes_with_breakpoint_overlay", .execution_observed = false, .address = addr, .bytes_read = n, .decoded_bytes = decoded, .uninspected_bytes = n - decoded, .instruction_limit_reached = instructions.len == limit, .next_address = if (decoded > 0) @as(?u64, addr + decoded) else null, .instructions = instructions, .limitations = "register aliases and flag meaning are architecture-specific; explicit memory expressions are not read; implicit memory, faults and full instruction semantics are not modeled" });
        }
        if (std.mem.eql(u8, name, "disassemble")) {
            const addr = try address(args);
            var bytes: [256]u8 = undefined;
            const n = try session.target.readMemory(addr, &bytes);
            var instructions: [32]disasm.Instruction = undefined;
            const count = try disasm.decodeFor(session.target.arch(), bytes[0..n], addr, &instructions);
            var list: std.array_list.Managed(Value) = .init(a);
            for (instructions[0..count]) |inst| try list.append(try asValue(a, .{ .address = try std.fmt.allocPrint(a, "0x{x}", .{inst.address}), .size = inst.size, .mnemonic = std.mem.sliceTo(@as([]const u8, &inst.mnemonic), 0), .operands = std.mem.sliceTo(@as([]const u8, &inst.operands), 0) }));
            return asValue(a, .{ .generation = session.target.snapshot().generation, .instructions = Value{ .array = list } });
        }
        if (std.mem.eql(u8, name, "query_events")) {
            const after = if (member(args, "after")) |v| number(v) orelse return error.InvalidArguments else 0;
            const events = session.target.eventSlice();
            var first: usize = 0;
            while (first < events.len and events[first].sequence <= after) : (first += 1) {}
            const end = @min(events.len, first + 128);
            return asValue(a, .{ .events = events[first..end], .has_more = end < events.len, .oldest_available = if (events.len > 0) events[0].sequence else 0 });
        }
        return error.UnknownTool;
    }
    fn handle(self: *Server, session: *Session, line: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const parsed = std.json.parseFromSlice(Value, a, line, .{ .max_value_len = 65536 }) catch {
            try self.failure(a, .null, -32700, "Parse error");
            return;
        };
        const request = parsed.value;
        const id = member(request, "id") orelse Value.null;
        const version = string(member(request, "jsonrpc")) orelse "";
        const method = string(member(request, "method")) orelse "";
        if (!std.mem.eql(u8, version, "2.0") or method.len == 0 or (id != .null and id != .string and id != .integer)) {
            try self.failure(a, .null, -32600, "Invalid Request");
            return;
        }
        if (member(request, "id") == null) {
            if (std.mem.eql(u8, method, "notifications/initialized") and self.negotiated) self.initialized = true;
            return;
        }
        if (self.shared) |peer| try peer.tick(session);
        const params = member(request, "params") orelse Value{ .object = .{} };
        if (std.mem.eql(u8, method, "initialize")) {
            const capabilities = member(params, "capabilities") orelse Value.null;
            const client_info = member(params, "clientInfo") orelse Value.null;
            if (self.negotiated or string(member(params, "protocolVersion")) == null or capabilities != .object or string(member(client_info, "name")) == null or string(member(client_info, "version")) == null) {
                try self.failure(a, id, -32602, "Invalid initialization parameters");
                return;
            }
            self.negotiated = true;
            try self.reply(a, id, .{ .protocolVersion = "2025-06-18", .capabilities = .{ .tools = .{ .listChanged = true } }, .serverInfo = .{ .name = "xodb", .version = "0.0.1" }, .instructions = if (self.overview_only) "Observer-only live system overview. Tools read a shared cache; inspect group ages and pending status, then poll after the owner tick. No debug target, control lease, or attach tools are available." else if (self.shared != null) "Shared local debugger session. Inspect as an observer; claim_session_control with the original process generation to start jobs or control targets. Renew before lease expiry. The human scope is authoritative; scope change, expiry, release or disconnect revokes control. Jobs and retained evidence survive reconnect. Poll get_session_clients/get_session_events for ownership and query_events for target events. Process mutations still require that process generation." else "Inspect and control debugger process sessions within the human-configured agent_scope. Optional process_id selects a stable process; omitted means original process 1, independent of GUI selection. List IDs with get_processes. Mutations require that process\'s current generation from get_session; the human may revoke scope for all processes. Continue/step/interrupt are asynchronous. Poll get_session and query_events for outcomes." });
        } else if (std.mem.eql(u8, method, "ping")) {
            try self.reply(a, id, Value{ .object = .{} });
        } else if (!self.initialized) {
            try self.failure(a, id, -32002, "Initialize first");
        } else if (std.mem.eql(u8, method, "tools/list")) {
            const definitions = try std.json.parseFromSlice(Value, a, if (self.overview_only) overview.definitions else if (session.imported != null) @import("imported.zig").definitions else tool_definitions, .{});
            var visible: std.array_list.Managed(Value) = .init(a);
            for (definitions.value.array.items) |definition| {
                if (!try shared_context.localAllowed(session.agent_scope, session.shared_jobs, definition)) continue;
                if (self.shared) |peer| if (!try peer.visible(try shared_context.access(definition))) continue;
                try visible.append(definition);
            }
            if (self.shared) |peer| {
                const extra = try std.json.parseFromSlice(Value, a, shared_context.definitions, .{});
                const state = try peer.state();
                for (extra.value.array.items) |definition| {
                    _ = try shared_context.access(definition);
                    const name = string(member(definition, "name")).?;
                    if (std.mem.eql(u8, name, "claim_session_control") and session.agent_scope == .observe) continue;
                    if (std.mem.eql(u8, name, "release_session_control") and state.controller != peer.client_id) continue;
                    try visible.append(definition);
                }
            }
            try self.reply(a, id, .{ .tools = Value{ .array = visible } });
        } else if (std.mem.eql(u8, method, "tools/call")) {
            const name = string(member(params, "name")) orelse {
                try self.failure(a, id, -32602, "Missing tool name");
                return;
            };
            const args = member(params, "arguments") orelse Value{ .object = .{} };
            const result = self.tool(a, session, name, args) catch |err| {
                if (err == error.UnknownTool or err == error.InvalidArguments) {
                    try self.failure(a, id, -32602, @errorName(err));
                    return;
                }
                try self.reply(a, id, .{ .isError = true, .content = .{.{ .type = "text", .text = @errorName(err) }} });
                return;
            };
            try self.toolReply(a, id, result);
        } else try self.failure(a, id, -32601, "Method not found");
    }
    fn toolReply(self: *Server, a: Allocator, id: Value, result: Value) !void {
        var exact_result = result;
        @import("exact.zig").addresses(a, &exact_result) catch |err| switch (err) {
            error.ConflictingEvidenceWord, error.InvalidEvidenceWord => {
                // The handler may already have completed an operation. Refuse
                // its invalid representation without ending the session or
                // publishing a partially projected result.
                try self.reply(a, id, .{ .isError = true, .content = .{.{ .type = "text", .text = @errorName(err) }} });
                return;
            },
            else => return err,
        };
        const text = try std.json.Stringify.valueAlloc(a, exact_result, .{});
        try self.reply(a, id, .{ .structuredContent = exact_result, .isError = false, .content = .{.{ .type = "text", .text = text }} });
    }
    pub fn pump(self: *Server, session: *Session) !void {
        // A request executes exactly once, only when its full reply has room.
        // Leave both buffered requests and unread pipe bytes pending while the
        // client drains output. A burst is backpressure, not a client failure.
        try self.flush();
        if (self.queued != 0) return;
        const revision: ?u64 = if (self.shared) |peer| (try peer.state()).revision else null;
        const scope_changed = self.reported_scope != null and self.reported_scope.? != session.agent_scope;
        const policy_changed = self.reported_revision != null and self.reported_revision != revision;
        if (self.initialized and (scope_changed or policy_changed)) {
            try self.queue("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}");
            self.reported_scope = session.agent_scope;
            self.reported_revision = revision;
            try self.flush();
            if (self.queued != 0) return;
        }
        self.reported_scope = session.agent_scope;
        self.reported_revision = revision;
        if (!self.input_eof and self.used < self.input.len) {
            var fd = c.pollfd{ .fd = self.input_fd, .events = c.POLLIN, .revents = 0 };
            if (c.poll(&fd, 1, 0) > 0 and fd.revents & (c.POLLIN | c.POLLHUP) != 0) {
                const n = c.read(self.input_fd, self.input[self.used..].ptr, self.input.len - self.used);
                if (n < 0 and std.c._errno().* != c.EAGAIN and std.c._errno().* != c.EINTR) return error.McpInputClosed;
                if (n == 0) self.input_eof = true;
                if (n > 0) self.used += @intCast(n);
            }
        }
        // Keep target polling and the GUI responsive even for notification or
        // tiny-response floods. Buffered lines are processed without new input.
        for (0..self.request_limit) |_| {
            const end = std.mem.indexOfScalar(u8, self.input[0..self.used], '\n') orelse {
                if (self.used == self.input.len) return error.McpRequestTooLarge;
                if (self.input_eof) self.closed = true;
                return;
            };
            try self.handle(session, self.input[0..end]);
            const consumed = end + 1;
            std.mem.copyForwards(u8, &self.input, self.input[consumed..self.used]);
            self.used -= consumed;
            try self.flush();
            if (self.queued != 0) return;
        }
    }
    fn flush(self: *Server) !void {
        if (self.sent < self.queued) {
            const n = c.write(self.output_fd, self.output[self.sent..].ptr, self.queued - self.sent);
            if (n > 0) {
                self.sent += @intCast(n);
                self.transmitted +%= @intCast(n);
            } else if (n < 0 and std.c._errno().* != c.EAGAIN and std.c._errno().* != c.EINTR) return error.McpOutputClosed;
            if (self.sent == self.queued) {
                self.sent = 0;
                self.queued = 0;
            }
        }
    }
};

fn inlineDepth(args: Value) !usize {
    const n = if (member(args, "inline_depth")) |v| number(v) orelse return error.InvalidArguments else 0;
    if (n > 64) return error.InvalidArguments;
    return @intCast(n);
}

test "every advertised tool has a unique name and explicit session access classification" {
    const a = std.testing.allocator;
    for ([_][]const u8{ tool_definitions, @import("imported.zig").definitions, shared_context.definitions }, 0..) |definitions, kind| {
        const parsed = try std.json.parseFromSlice(Value, a, definitions, .{});
        defer parsed.deinit();
        for (parsed.value.array.items, 0..) |definition, i| {
            const name = string(member(definition, "name")) orelse return error.MissingToolName;
            const annotations = member(definition, "annotations") orelse return error.MissingToolAnnotations;
            const readonly = member(annotations, "readOnlyHint") orelse return error.MissingToolAccess;
            try std.testing.expect(readonly == .bool);
            const access = try shared_context.access(definition);
            if (kind != 2) try std.testing.expect(access != .lease);
            for (parsed.value.array.items[0..i]) |previous| try std.testing.expect(!std.mem.eql(u8, name, string(member(previous, "name")).?));
        }
    }
}

test "one oversized reply returns a protocol error and preserves the server" {
    const a = std.testing.allocator;
    const server = try a.create(Server);
    defer a.destroy(server);
    server.* = .{};
    const huge = try a.alloc(u8, server.output.len);
    defer a.free(huge);
    @memset(huge, 'x');
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    try server.reply(arena.allocator(), .{ .integer = 7 }, huge);
    const reply = try std.json.parseFromSlice(Value, a, server.output[0 .. server.queued - 1], .{});
    defer reply.deinit();
    try std.testing.expectEqual(7, member(reply.value, "id").?.integer);
    try std.testing.expectEqual(-32000, member(member(reply.value, "error").?, "code").?.integer);
    try std.testing.expect(!server.closed);
}

test "tool policy cache is mode-specific and does not cache authorization" {
    const a = std.testing.allocator;
    const server = try a.create(Server);
    defer a.destroy(server);
    server.* = .{};
    defer server.clearPolicies();
    const control = try server.toolPolicy(tool_definitions, "add_language_watch");
    try std.testing.expect(control.localAllowed(.control, true));
    try std.testing.expect(!(try server.toolPolicy(tool_definitions, "add_language_watch")).localAllowed(.observe, true));
    try std.testing.expectError(error.UnknownTool, server.toolPolicy(overview.definitions, "add_language_watch"));
    try std.testing.expectError(error.UnknownTool, server.toolPolicy(@import("imported.zig").definitions, "write_memory"));
    try std.testing.expectEqual(shared_context.Access.mutator, (try server.toolPolicy(tool_definitions, "write_memory")).required);
}

test "tool replies preserve numeric fields and share exact structured and text results" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const server = try a.create(Server);
    server.* = .{};
    const result = try asValue(a, .{ .rows = .{.{ .address = @as(u64, 9007199254740993), .slot_address = std.math.maxInt(u64), .offset = std.math.minInt(i64) }} });
    try server.toolReply(a, .{ .integer = 1 }, result);
    const reply = (try std.json.parseFromSlice(Value, a, server.output[0 .. server.queued - 1], .{})).value.object.get("result").?;
    const structured = reply.object.get("structuredContent").?;
    const text = reply.object.get("content").?.array.items[0].object.get("text").?.string;
    try std.testing.expectEqualStrings(text, try std.json.Stringify.valueAlloc(a, structured, .{}));
    const row = structured.object.get("rows").?.array.items[0];
    try std.testing.expectEqual(@as(i64, 9007199254740993), row.object.get("address").?.integer);
    try std.testing.expectEqualStrings("0x20000000000001", row.object.get("address_hex").?.string);
    try std.testing.expectEqualStrings("0xffffffffffffffff", row.object.get("slot_address_hex").?.string);
    try std.testing.expectEqualStrings("-0x8000000000000000", row.object.get("offset_hex").?.string);
}

test "hex expansion obeys the reply cap and leaves the next request usable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const server = try a.create(Server);
    server.* = .{};
    const Row = struct { address: u64 };
    const rows = try a.alloc(Row, 10000);
    for (rows) |*row| row.* = .{ .address = std.math.maxInt(u64) };
    const value = try asValue(a, rows);
    const old_text = try std.json.Stringify.valueAlloc(a, value, .{});
    const old_reply = try std.json.Stringify.valueAlloc(a, .{ .structuredContent = value, .isError = false, .content = .{.{ .type = "text", .text = old_text }} }, .{});
    try std.testing.expect(old_reply.len < server.output.len);
    try server.toolReply(a, .{ .integer = 1 }, value);
    const reply = (try std.json.parseFromSlice(Value, a, server.output[0 .. server.queued - 1], .{})).value;
    try std.testing.expectEqual(-32000, reply.object.get("error").?.object.get("code").?.integer);
    try std.testing.expect(!server.closed);
    server.queued = 0; // Previous reply drained by the peer.
    try server.toolReply(a, .{ .integer = 2 }, try asValue(a, .{ .address = @as(u64, 9007199254740993) }));
    const next = (try std.json.parseFromSlice(Value, a, server.output[0 .. server.queued - 1], .{})).value;
    try std.testing.expectEqualStrings("0x20000000000001", next.object.get("result").?.object.get("structuredContent").?.object.get("address_hex").?.string);
}

test "invalid exact-word replies stay tool errors and the next reply succeeds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const server = try a.create(Server);
    server.* = .{};
    const cases = [_]struct { json: []const u8, reason: []const u8 }{
        .{ .json = "{\"address\":7,\"address_hex\":\"0x9\"}", .reason = "ConflictingEvidenceWord" },
        .{ .json = "{\"address\":18446744073709551616}", .reason = "InvalidEvidenceWord" },
        .{ .json = "{\"offset\":-9223372036854775809}", .reason = "InvalidEvidenceWord" },
    };
    for (cases) |case| {
        server.queued = 0;
        const bad = (try std.json.parseFromSlice(Value, a, case.json, .{})).value;
        try server.toolReply(a, .{ .string = "word-error" }, bad);
        const reply = (try std.json.parseFromSlice(Value, a, server.output[0 .. server.queued - 1], .{})).value;
        try std.testing.expectEqualStrings("word-error", reply.object.get("id").?.string);
        const result = reply.object.get("result").?;
        try std.testing.expect(result.object.get("isError").?.bool);
        try std.testing.expect(!result.object.contains("structuredContent"));
        try std.testing.expectEqualStrings(case.reason, result.object.get("content").?.array.items[0].object.get("text").?.string);
        try std.testing.expect(!server.closed);
        server.queued = 0;
        try server.toolReply(a, .{ .integer = 2 }, try asValue(a, .{ .address = @as(u64, 9007199254740993) }));
        const next = (try std.json.parseFromSlice(Value, a, server.output[0 .. server.queued - 1], .{})).value;
        try std.testing.expectEqualStrings("0x20000000000001", next.object.get("result").?.object.get("structuredContent").?.object.get("address_hex").?.string);
    }
}

test {
    std.testing.refAllDecls(@import("module_list.zig"));
}

test {
    std.testing.refAllDecls(@import("list_page.zig"));
    std.testing.refAllDecls(@import("locals_list.zig"));
    std.testing.refAllDecls(@import("debug_files.zig"));
}
