# xodb architecture review and proposed refactoring plan

_date: october 13, 2026 · author: GPT-6 Pro, a fresh read of the repository with no prior context in this project · status: design proposal, not an implementation claim_

## scope and conclusion

this document consolidates the architectural review and expands four areas: enforceable dependency boundaries, the existing runtime-language-adapter direction, generic representations versus platform-specific implementations, and using the remote ownership model locally.

basis: the preceding static review, supplemented by targeted reads of public `master` source and planning documents. the reads were not a commit-pinned checkout; some planning pages may lag implementation. no build, runtime audit, performance benchmark, or repository modification was performed. source links identify the inspected implementation; an implementation handoff should record its actual base commit.

**keep the low-level runtime. reorganize application ownership and execution around the strongest existing boundaries.**

xodb's main structural problem is not insufficient file decomposition. it is that ownership, authority, state lifetime, and command execution cross the apparent module boundaries. splitting files while continuing to pass the entire session everywhere would mostly rearrange the problem.

priority order:

| priority | change | intended result |
| --- | --- | --- |
| p0 | one transport-independent command executor | a debugger operation has one semantic implementation |
| p0 | universal owner/publication boundary | local gui code cannot reach live target state |
| p1 | explicit validity and authority stamps | audit activity does not masquerade as target-state change |
| p1 | shared job ownership and retained inputs | cancellation and publication stop depending on scattered busy flags |
| p1 | distinct live, workspace, and client-view state | evidence and navigation have appropriate lifetimes |
| p2 | independent image, debug, isa/abi, and language providers | extending one dimension does not require editing unrelated subsystems |
| p2 | consolidate generic representations and enforce imports | no second application model or competing analysis ir appears accidentally |

these are sequencing priorities, not conventional staffing or calendar estimates. interface inventories and dependency checks can begin immediately; the full ir work must not block the owner refactor.

## 1. structural findings

### 1.1. the better application architecture is a remote-only path

**observed:** the local gui path combines target polling, mcp servicing, workspace operations, and rendering. the runtime-remote path instead uses an owner worker and copied publications; its frame loop deliberately receives no live session, process-tree, or server pointers. workspace code has local-versus-remote execution branches. [s01] [s02] [s03]

**criticism:** transport choice changes the application integration contract. a feature can be correct through the queued path but behave differently through direct session access. local backend work and window processing also share scheduling; the resulting latency was not measured.

**change:** use the command/publication boundary in local, remote, and headless modes. keep offline analysis on the same application api without inventing a live process. “remote” should describe how the backend is reached, not how application ownership works.

**important qualification:** adopt the boundary, not every incidental detail of the remote implementation. do not add localhost networking, json serialization, or a mandatory daemon to the local path.

### 1.2. command semantics and caller authority leak into protocol handling

**observed:** the owner dispatcher has typed actions, but also an mcp action carrying a tool name and json arguments that re-enters mcp execution. caller identity, lease, and controller status are temporarily installed in session fields. [s04]

**criticism:** some operation semantics still belong to the protocol adapter, while authority is partly ambient state. a queue around two dispatchers is not one application core. this is an architectural risk, not evidence of an authorization bypass.

**change:** decode frontend requests into application commands, pass an explicit request context, and execute through one semantic handler. perform the authoritative access check at execution, including the side-effect point of deferred work. mcp owns parsing and encoding, not debugger policy.

retain fail-closed access classification. the tool catalog already checks its classifications; move the canonical effect requirements into the command contract and verify each exposed tool against it. [s05]

### 1.3. the session groups objects with unrelated lifetimes

**observed:** the session holds target control, image and language state, caller context, captures, jobs, imported evidence, comparisons, presentation selections, and audit storage. [s06]

**criticism:** coordination is reasonable; common mutable ownership of all those things is not. a capture should not depend on a process remaining attached. inspecting another frame should not implicitly claim another client's navigation state.

**change:** separate the live process-family controller, analysis workspace, per-client view state, and job supervisor. retain a small coordinator rather than replacing one large session with several equally omniscient managers.

the existing remote dispatcher deliberately uses canonical session frame selection for some inspection operations. preserve “follow the human's focus” as an explicit collaboration mode, not the only way to inspect. an agent should also be able to ask for a different thread/frame without moving the gui. [s04]

### 1.4. audit bookkeeping is coupled to observation validity

**observed:** allocation and observation setup anticipate an extra generation increment for agent calls. audit recording emits an agent-action target event and compensates for generation changes in deferred execution bookkeeping. [s06]

**criticism:** validity arithmetic should not depend on whether an operation happens to create an audit record. this is evidence of conceptual coupling, not proof that a particular result is incorrect.

**change:** separate target observation validity, image/metadata revisions, authority validity, and audit/publication ordering. preserve conservative stale-command rejection during migration. changing counters must not weaken human revocation or allow old commands to resume a new process incarnation.

### 1.5. background-job ownership is reproduced feature by feature

**observed:** the archive job combines an operation kind with many optional inputs, owns a worker and unpublished outputs, and relies on coordinated capture/frame lifetimes. teardown joins the worker and releases busy/pinned state on borrowed objects. [s07]

**criticism:** each new job risks acquiring its own rules for input retention, cancellation, access, polling, and publication. correct individual implementations still create an expensive system-wide ownership protocol.

**change:** introduce a small shared job supervisor with explicit retained inputs, requester ownership, budgets, cancellation, and terminal outcomes. keep the algorithms and typed job payloads feature-specific. do not build a general-purpose task framework.

### 1.6. image formats and runtime languages overlap in core types

**observed:** the principal module contains an elf image and language-specific layout caches. darwin image handling has a separate integration path. runtime binding imports the full session. [s08] [s06] [s09]

**criticism:** obtaining bytes, identifying an executable image, interpreting debug metadata, and decoding a language runtime are different extension axes. coupling them makes each new combination a potential special case.

**change:** separate image identity/placement, executable-format and debug-metadata providers, isa/abi descriptions, and runtime-language providers. providers should receive the minimum read/analysis context, not a session pointer.

this is not a demand for dynamic plugins or a universal format that erases important differences. use static registration and explicit capabilities.

### 1.7. dependency boundaries are not yet structural constraints

**observed:** the owner boundary imports timeline request/prepared types from the ui tree; model dispatch imports mcp execution. [s10] [s04]

**criticism:** inner layers depend on presentation and protocol details. filenames suggest a direction that the import graph does not enforce.

**change:** move shared request/result types inward, define narrow provider ports, and enforce the graph through build modules and dependency tests. the application service must execute an operation without importing its gui or mcp adapter.

existing headless/null-platform builds and runtime test targets provide useful separation to extend rather than replace. [s11]

## 2. mechanisms to preserve

retain the opaque c runtime handles and explicit owner-thread/borrowed-view rules. the c runtime boundary is a portability and ownership asset; this review does not propose rewriting it in zig. [s12]

retain the immutable presentation checks and copied publication path. the debugger presentation types already reject inappropriate pointer shapes at compile time. use that mechanism more broadly, while remembering that a const slice still needs an actual lifetime guarantee. [s13]

retain bounded work, cancellation, incomplete-evidence reporting, and explicit uncertain remote outcomes. the worker has substantial lifecycle machinery; generalizing it should preserve those protections. [s03]

retain the existing static-analysis investment. the semq host integrates ghidra-worker exports, and its adapter converts those exports into xsg while carrying producer qualifications. the generic-ir proposal below is an inventory-and-consolidation task, not permission to create a parallel ir because the new diagram looks cleaner. [s14] [s15]

## 3. proposed dependency boundaries

### 3.1. distinguish imports from runtime data flow

runtime flow should be:

```text
human gui / mcp agent / cli / future scripting
    -> application commands and queries
    -> application service
        -> live process-family owner, when live target access is required
        -> workspace/evidence service, for retained or offline analysis
        -> job supervisor, for longer work
    -> typed outcomes, immutable publications, retained evidence handles
    -> requesting frontend
```

this is not the import graph. a service may call a provider through an inward-defined interface while having no dependency on that provider's concrete implementation.

proposed compile-time boundaries:

| boundary | owns | permitted dependencies |
| --- | --- | --- |
| domain vocabulary | ids, addresses, target descriptions, evidence/provenance, semantic records | standard library and deliberately small common utilities |
| application api | command/query payloads, outcomes, public view records, public access requirements | domain vocabulary |
| provider ports | narrow contracts for target access, reads, images, metadata, runtime languages | domain vocabulary; no application coordinator |
| analysis | unwind/evaluation/graph/profile algorithms and analysis representations | domain vocabulary and the read/provider ports actually needed |
| application service | authorization, routing, live ownership, workspace mutations, job scheduling | application api, domain, ports, analysis |
| concrete providers | c-runtime wrapper, rsp client, format parsers, language decoders, storage codecs | relevant ports/domain, external libraries, narrowly shared analysis helpers |
| frontends | gui interactions, mcp/cli parsing, protocol output, client navigation | application api and domain; gui additionally uses rendering/host-platform code |
| composition root | startup configuration and concrete provider selection | the modules it assembles |

**the application service and concrete providers are siblings around inward-defined ports.** a provider does not import the application service to obtain access to its state. the composition root selects implementations and injects handles/function tables.

not every boundary needs a new directory. initially, enforce the distinction in existing modules and extract only types that currently force reversed dependencies.

### 3.2. hard import rules

- `domain`, `ports`, and public api types must not import ui, renderer, mcp, sessions, concrete target backends, or parser-library objects.
- generic analysis must not obtain a live target handle. it consumes retained inputs or a bounded read interface supplied by its caller.
- live target handles stay inside the process-family owner and its backend implementation. frontends receive neither those handles nor an unrestricted callback into the session.
- application execution must not call an mcp handler or construct ui widgets. presentation-only state stays outside debugger command handlers.
- providers must not use the composition root as a service locator. a new feature should not gain arbitrary authority merely by importing a convenient root module.

a shared result may contain ordinary slices backed by a retained immutable arena. “no live handles” does not mean “no efficient references anywhere.”

### 3.3. ownership boundaries

| owner | mutable state | lifetime |
| --- | --- | --- |
| process-family owner | target handles, thread/process lifecycle, active probes, stepping, collection control | attach/launch through detach/termination and required cleanup |
| workspace service | artifact catalog, binary/debug assets, investigations, annotations, comparisons, retained results | independent of an individual target connection |
| client view | selected thread/frame, filters, scroll state, expanded nodes, follow-focus preference | individual frontend/client |
| job supervisor | job ownership, retained inputs, cancellation, resource reservations, publication status | until job resources are reclaimed |
| provider instance | provider-private caches with explicit keys and invalidation | bound to declared image/runtime/analysis identities |

one actor per live process family is the starting point, not one global actor for every independent target. a workspace mutation has a defined owner as well; splitting the session must not introduce unsynchronized shared maps.

shared captures should publish sealed chunks or retained immutable snapshots. do not hand workers a mutable collection and rely on the word “read-only.”

## 4. make the remote ownership model universal

### 4.1. same application contract, different backend adapters

```text
local debugging
  frontend -> typed in-process queue -> family owner -> local c runtime -> target

runtime-agent debugging
  frontend -> typed in-process queue -> family owner -> runtime client
    -> transport -> c agent's native owner -> target

rsp debugging
  frontend -> typed in-process queue -> family owner -> rsp backend -> debug stub

offline analysis
  frontend -> application api -> workspace + retained artifacts -> analysis jobs
```

these paths share application semantics. they do not require identical transport messages or capabilities. the target-side c agent remains a low-level target/collector implementation; it need not acquire the gui, symbol analysis, workspace, or complete application command catalog.

there are two ownership boundaries in the runtime-agent case: the host owner coordinates the application session, and the agent's owner performs native target operations. transport is below the host application contract.

### 4.2. create native targets on their final owner

the current worker explicitly avoids transferring native ptrace ownership. [s03]

for local migration, start the owner before attach/launch and let that thread create the native tracing relationship and perform its lifecycle work. do not attach on the gui thread and then move an already-live session into a worker.

keep fork/vfork/shared-address-space handling coordinated within the process-family ownership domain. independent processes can be split only when the backend's actual ownership rules permit it.

### 4.3. command and query contract

the following is schematic, not a proposed wire format or compilable declaration:

```text
request_context
  authenticated requester and client identity
  request id
  requested operation's authority/lease reference
  expected identity and validity preconditions
  deadline and cancellation handle

command_or_query
  typed operation
  typed arguments
  explicit target/process/thread/frame or artifact selection

outcome
  completed(typed result, resulting stamps)
  accepted(operation id)
  rejected(typed reason)
  failed(typed reason, any known partial effects)
  outcome_unknown(reconciliation information)
```

the service derives requester identity from a trusted local binding or authenticated connection; a client cannot grant itself authority by filling in `request_context` fields. a queued lease reference is checked against current owner-held authority, not trusted as a permanent grant.

the command descriptor states required effects: inspection, execution control, memory/register mutation, workspace mutation, and resource-consuming analysis as appropriate. these are not interchangeable. observing a target must not silently grant another client's job cancellation or arbitrary file export.

queries that need live target reads cross the owner boundary too. cheap reads of an already-published immutable view do not need another request. pan, zoom, hover, and ordinary selection changes remain client-local unless they trigger new inspection or intentionally update shared focus.

returning `accepted` means queued or started, not completed. request ids let the gui and mcp client correlate the eventual terminal result. stale inspection results retain their input identity and must not overwrite a newer selection.

### 4.4. ordering, authorization, and revocation

validate authority and relevant identity when executing a queued command. revalidate before a deferred side effect, such as the actual resume after symbol resolution. stop/exec/detach or revocation must invalidate the operations they supersede.

not every command requires the same precondition. writing a value or stepping a particular stopped frame should require the appropriate observation identity. an emergency interrupt must not be rejected merely because the displayed stop generation is old; it still requires correct process/connection identity and authority.

reserve queue capacity and priority for interrupt, cancellation, revocation, and shutdown. preserve order among conflicting mutations; do not coalesce two continue/step commands into a vague “latest desired state.” coalescing is appropriate for superseded view requests, not for arbitrary side effects.

### 4.5. publication and responsiveness

publish small state headers and visible inspection results, not the entire session on each frame. retain large evidence in immutable arenas/chunks and publish handles or pages. keep both command and publication queues bounded.

separate replaceable view updates from terminal command outcomes and evidence events. intermediate views may be superseded; completions must remain retrievable until consumed or explicitly expired. bounded evidence retention must report gaps rather than silently imply completeness.

while a backend is slow, render the last publication with pending/stale/connection status. the ui must not borrow the owner's locks, wait for its queue, join a worker, or trigger symbol parsing during paint.

an owner thread alone does not solve backend head-of-line blocking. use bounded or incremental reads, cancellation-aware transport operations, and resumable inspection where needed. long pure analysis goes to workers. a high-priority interrupt queue cannot preempt an indefinitely blocking syscall by itself.

batch related memory reads and cache immutable metadata. the local path should use ordinary calls inside the owner and typed in-process messages across threads—not emulate network serialization merely for symmetry.

### 4.6. disconnect and shutdown

cancel queued work, invalidate the relevant connection identity, and publish explicit lifecycle state. join workers only after their input ownership is accounted for; keep the ui pumping during cleanup. never free native handles or buffers merely because a shutdown deadline elapsed.

for remote mutations, a dropped connection can leave the outcome uncertain. do not automatically replay a mutation because its reply was lost. reconnect must establish what identity and state are actually known before accepting new control commands.

local and remote should use the same outcome vocabulary; they need not manufacture the same failure modes.

## 5. generic representations and specific platform structure

### 5.1. do not make “the ir” mean three different things

use three related representations with explicit purposes:

| representation | purpose | not its job |
| --- | --- | --- |
| semantic/evidence model | processes, images, threads, frames, values, events, captures, provenance | executing instructions or knowing parser internals |
| machine-analysis ir | instruction effects, control/data flow, static analysis and decompiler integration | representing gui selections or every runtime object |
| expression evaluation representation | language-aware lookup, types, locations and bounded evaluation | pretending source expressions are machine instructions |

they share identities, address conventions, type references where appropriate, and provenance. they do not need to become one giant tagged union or one universal graph.

the original architecture brief already distinguishes expression lowering, runtime adapters, and machine-independent static analysis. this plan refines that direction. [s16]

### 5.2. semantic model: normalize facts, retain their qualifications

proposed common records should include:

**identity.** distinguish target connection, process incarnation, thread incarnation, runtime instance, image artifact, loaded image instance, capture, and analysis result. an operating-system pid/tid is an attribute, not sufficient long-lived identity.

**addresses.** represent a target address as an address-space-qualified value with explicit target width. distinguish runtime virtual addresses, image-relative addresses, file offsets, and host pointers. arithmetic must be checked against the declared space/width. supporting today's address widths does not require speculative arbitrary precision; it does require rejecting unsupported widths instead of truncating them.

**registers.** use a register schema with width, role, bank, and alias information. keep dwarf register numbers, rsp register numbers, and kernel regset offsets as adapter mappings. do not make one numbering scheme the universal identity or assume every register fits one host integer.

**memory and mappings.** return valid spans plus explicit holes/refusals and observation identity. include permissions and coverage without assuming every backend provides a complete mapping enumeration. treat target paths and host artifact paths as different namespaces.

**frames and values.** distinguish physical frames, inline frames, runtime logical frames, and other logical execution contexts. represent unavailable, optimized-out, partial, stale, and unsupported states structurally; do not collapse them into an empty string or zero.

**provenance.** attach source/input identity, producer/version, observation basis, coverage, and assumptions. keep compiler-provided, observed, inferred, and user-supplied claims distinguishable. a confidence number is not a substitute for that information.

**events.** include sequencing and clock domain, with correlation uncertainty where clocks differ. a static branch possibility and an observed branch event are different kinds of evidence.

platform-specific detail can survive in typed extensions or retained raw records. generic consumers must not need to decode opaque extension strings to perform ordinary operations.

### 5.3. image and debug providers

split the current overloaded module role into:

```text
image artifact
  stable identity, format, architecture description, retained bytes/debug companions

loaded image instance
  process/address-space identity, artifact reference, mapping placement, observation stamp

format provider
  sections/segments, symbols, relocations, format-specific identity and extensions

debug provider
  source locations, types, variable locations, inline records, unwind metadata

language-runtime binding
  provider-private layout/cache + runtime instance identity + discovery evidence
```

image placement should expose checked address conversions, not force all formats and loader arrangements into one elf-style bias. retain multiple placements of one artifact and distinguish sparse metadata-only coverage from readable executable bytes.

debug format is independent of executable format. bind a debug provider to the actual metadata available; do not make the general architecture equate “elf” with “dwarf” or “pe” with one mandatory debug source. multiple providers may contribute with stated precedence and provenance.

normalize query results lazily. keep library-specific handles and parse trees inside providers, and use retained provider-owned handles internally where needed. there is no requirement to eagerly translate every type or dwarf location expression into a giant common database.

for a common location/evaluation representation, specify which operations it supports. otherwise retain a bounded provider evaluator that returns the shared result model. unsupported metadata must remain unsupported, not receive a plausible approximation.

### 5.4. machine-analysis ir: extend the existing path

**first inventory semq/xsg, ghidra import, disassembly records, and control-flow records.** the existing host already converts ghidra exports into xsg, and the lightweight graph explicitly separates decoded possibilities from observations. [s14] [s15] [s17]

identify the canonical representation for each stage before changing it:

```text
retained code bytes + image/architecture/abi identity
  -> decoder or existing semantic producer
  -> qualified instruction effects / imported analysis graph
  -> canonical machine-analysis representation
  -> generic graph, dataflow, slice and inference passes
  -> semantic results + source/byte provenance
```

prefer extending the existing representation and adding narrow adapters. do not make semq, the disassembler, and a new “generic ir” maintain competing definitions of the same semantics indefinitely. lightweight display/flow records may remain a separate cheaper stage; they are not full instruction semantics.

the machine-analysis contract should account for:

| area | required semantics |
| --- | --- |
| values | explicit bit widths, signed versus unsigned operations, extension/truncation |
| registers | aliasing, subregister writes, flags and special state without host assumptions |
| memory | address space, access width, endianness, reads/writes and relevant ordering effects |
| control flow | conditional/unconditional/indirect transfers, calls, returns, exceptional exits |
| incomplete semantics | unsupported instructions, unknown effects, qualified intrinsics and analysis refusal |
| evidence | code/input hash or identity, instruction origin, producer version, declared assumptions |

this is a target contract to compare against existing capabilities, not a claim that every row is currently missing.

use ssa and memory-effect modeling where an analysis needs them. preserve the producer's qualifications and distinguish raw instruction semantics from a decompiler's recovered high-level graph. imported high-level ir is not automatically exact operational semantics.

an unsupported operation must conservatively invalidate affected reasoning or cause a typed refusal. it must not become a nop. likewise, an instruction omitted under a producer-specific assumption cannot silently become an unconditional machine-level equivalence claim.

keep isa-specific lifting and intrinsics outside generic analysis passes. an intrinsic needs a typed effect summary; otherwise the consumer must conservatively refuse or widen its result. do not scatter architecture switches throughout dataflow algorithms.

**a normal debugger stop, stack display, or watch evaluation must not require decompilation.** rich machine ir is optional analysis infrastructure, not an obligatory intermediate representation for every application operation.

### 5.5. expression frontends and runtime decoding remain separate

source-expression semantics, runtime object layouts, and machine instructions are related but distinct.

use language-specific parsing/type rules over shared bounded lookup/read/evaluation infrastructure. do not force python, c++, rust, and zig to have the same overflow, indexing, dispatch, or object-access semantics.

runtime object inspection is not equivalent to executing an expression inside the target. any operation that invokes target code or language hooks belongs to an explicitly effectful command path with appropriate authority; it must not hide inside a value visualizer.

### 5.6. orthogonal platform axes

| axis | examples of responsibility | must not determine |
| --- | --- | --- |
| host platform | windowing, input, graphics surface, local file/network primitives | target isa, image format, language semantics |
| target os/backend | native tracing, process/thread lifecycle, collectors, stop causes | gui framework or host architecture |
| target isa | registers, instruction decode/lift, trap encoding, architecture-specific control rules | executable format or all calling conventions |
| target abi | argument/return locations, stack conventions, data layout, unwind conventions | transport or window system |
| transport/protocol | in-process, runtime-agent connection, rsp; framing and capability negotiation | a separate application model |
| image/debug format | elf, mach-o, pe, dwarf, other metadata providers | how the live process is controlled |
| runtime language | interpreter/runtime discovery, object layouts, logical stacks | target control policy or ui rendering |
| artifact storage | archive versions, retained bytes, import/export codecs | live attachment lifetime |

these are extension seams, not a promise that every cartesian-product combination works. validate supported combinations explicitly. a backend's capabilities should be scoped to the actual process/thread/context and include limits and reasons—not one platform-wide `supported` boolean.

for example, design the same host-side stack/symbol pipeline to consume an aarch64 mach-o target through rsp, an aarch64 elf target through the c agent, or retained evidence. choose different image/abi/backend providers; do not build three unrelated stack viewers. this is an acceptance scenario, not a claim of present feature parity.

### 5.7. illustrative source layout

this is a dependency guide, not a mass-rename task:

```text
src/
  domain/                    # identities, evidence, shared semantic records
  api/                       # application requests, outcomes and public views
  ports/                     # target/read/image/debug/language contracts
  app/                       # owner, commands, workspace, publications, jobs
  analysis/                  # unwind, evaluation, graphs and profiles
  semq/                      # retain existing implementation; clarify its ir boundary
  target/                    # zig adapters over runtime/rsp and target descriptions
  runtime/                   # existing c runtime and low-level target implementations
  binary/                    # image and debug-format implementations
  language/                  # runtime providers and language-specific evaluation
  ui/                        # presentation and client-local interaction
  mcp/                       # protocol adapter over application api
  platform/                  # host window/input/os services, not target semantics
  render/                    # rendering only
  main.zig                   # composition root, not command implementation
```

shared isa descriptions may remain c-owned if that preserves the lean agent build. share facts between c and zig through a narrow abi or generated tables rather than maintaining conflicting register/trap definitions. the current architecture wrapper already obtains descriptions from the c runtime. [s18]

## 6. runtime-language providers: finish the existing architectural todo

### 6.1. existing notes to connect

the original architecture brief has a **runtime and language adapters** section with an interface sketch covering discovery, frames, values, objects, source resolution, and runtime state. the root todo separately calls for mixed-language logical stacks with runtime-instance identity and native/logical bridge evidence. the milestones document also places runtime adapters in richer investigations. [s16] [s19] [s20]

therefore, treat this as completing an existing direction, not inventing a new plugin initiative. the exact title “runtime language providers” was not found in the checked todo; the adapter sketch and mixed-stack task are the concrete cross-references.

### 6.2. proposed provider contract

use a statically registered provider with optional capabilities and a bounded inspection context:

```text
runtime provider
  discover candidate runtime instances
  establish identity and execution evidence
  enumerate logical execution contexts and stack segments
  decode/expand values
  enumerate objects, where supported
  resolve source/runtime metadata, where supported

inspection context
  process/address-space/observation identity
  target isa, abi and register schema
  retained image and debug-metadata query interfaces
  bounded memory reader
  relevant native frames/registers or retained evidence
  read/byte/work budgets and cancellation

provider result
  typed frames/values/objects
  runtime-instance identity
  native/logical bridge evidence
  availability, coverage and diagnostics
  producer/layout identity and input stamps
```

this is a minimum contract inventory, not one mandatory vtable in which every provider pretends to implement every function. avoid a boolean `detect`: distinguish absent, candidate, witnessed, ambiguous, unsupported layout, and incomplete discovery.

keep source-language expression frontends separable from runtime-object providers. a language can need native type rules without an interpreter instance; an interpreter can expose objects without permitting arbitrary expression execution.

### 6.3. ownership and safety rules

providers must not receive the entire session, a raw live target handle, ui state, or ambient caller authority. they own private caches keyed by relevant artifact/layout/runtime identity; central module types do not acquire a field for each language.

live reads execute on the owner through a bounded context. expensive processing can run on workers after capturing the necessary inputs. a provider that requires iterative reads should support bounded continuation or an owner-mediated read plan; do not secretly let its worker call ptrace or drive the transport.

store shared immutable layout information separately from per-runtime-instance state. one process may contain multiple interpreters or several instances of the same runtime. a module identifying the runtime library is not by itself an interpreter identity.

mixed stacks need a bridge to particular native frames from compatible evidence. where no bridge is established, show a separate qualified segment instead of inventing interleaving from timestamps. retain ambiguity when two runtime candidates remain plausible.

provider queries are inspection by default. target writes, invocation of language hooks, or target-side expression execution require a separate explicit effectful command.

### 6.4. first implementation slice

wrap two existing providers—python and perl are concrete starting points because they already share runtime-binding machinery—without changing their observed semantics. replace their session dependency with the narrowed context, and move their layout storage behind provider-owned caches. [s09]

acceptance: existing fixtures retain their results and diagnostics; both providers coexist; ambiguous/unwitnessed candidates remain qualified; exec and metadata changes invalidate the right bindings; gui and mcp consume the same logical records. adding the next provider should require registration and provider code, not fields in the central module or a switch in command dispatch.

## 7. validity, authority, and job contracts

### 7.1. separate meanings before multiplying counters

start with a conservative validity model and split only where the meaning is clear:

| identity/revision | what it protects |
| --- | --- |
| connection incarnation | replies and operations from a particular transport connection |
| process incarnation / image epoch | pid reuse, restart, exec and image replacement |
| observation stamp | target reads and mutations relevant to a stopped/read context |
| maps / metadata revision | image placement, symbols, debug data and layout-dependent caches |
| authority revision / lease state | controller changes, expiry, revocation and permitted effects |
| artifact identity / revision | retained capture inputs and analysis results |
| publication revision | ordering of frontend-facing updates |
| audit sequence | ordering of recorded actions |

not every cache key needs every stamp. specify dependencies per operation/result. audit append advances audit ordering without pretending the target's bytes changed; revocation changes authority even if those bytes are identical.

an observation stamp is not proof of an atomic memory snapshot. retain which threads were stopped, whether shared memory or other writers can change the data, which ranges were actually read, and any detected inconsistencies. a worker's result is no stronger than its inputs.

for protocol compatibility, retain the existing conservative generation checks until both producer and consumer contracts are migrated. version changed meanings; do not silently reinterpret an old agent's `generation` field or simply delete guards to make tests pass.

### 7.2. minimal shared job supervisor

share job id/requester ownership, reservations, cancellation, lifecycle, retained inputs, and publication. keep worker implementations and payload types specialized.

```text
queued -> running -> succeeded | failed | cancelled
                         |
                         -> publication eligibility is checked separately
```

cancellation is a request until acknowledged. `cancel_requested` does not mean it is safe to free inputs or pretend an irreversible effect did not happen. work that publishes a file or causes a target effect needs an explicit publication/effect outcome, including partial or unknown states where applicable.

use tagged input payloads: a stack job carries a capture handle and sample selection; an archive save carries retained evidence and a destination policy. impossible combinations should not be represented as many unrelated nullable fields.

retain immutable input handles or sealed capture ranges. requester access and cancellation rights remain distinct from shared cache reuse. stopping one client's query must not automatically cancel another client's legitimate use of the same retained result.

publish a completed result against its actual artifact and input stamp. it may remain valuable historical evidence after the current target moves on, but it must not replace an unrelated live view. release reservations and inputs on every terminal path, including failed initialization and failed publication.

## 8. migration packets and acceptance gates

### packet a — establish the command boundary

extract transport-independent execution for continue, interrupt, stepping, and breakpoint operations. make both gui and mcp produce typed requests, with an explicit caller context. remove their duplicate semantic handlers as each operation migrates.

**gate:** both entry paths reach one operation implementation; authority is checked on execution; stale mutations are rejected; interrupt/revocation remain effective with an old frontend view. internal executor code imports neither mcp handlers nor ui modules.

### packet b — run local targets behind the owner

generalize the current worker/publication machinery and create native targets on the final owner. move local gui target reads and writes behind that boundary. preserve the existing low-level runtime and thin remote agent.

**gate:** frontend code cannot obtain live session/target pointers. an artificially delayed backend does not block window input/rendering. test native attach/launch, fork/exec, shutdown during startup, cancellation, remote disconnect, and two clients inspecting different frames. pending and terminal outcomes remain distinguishable.

measure local stepping latency, input latency, queue depth, copied bytes, and publication costs against the pre-refactor baseline. do not choose performance targets without first establishing that baseline.

### packet c — separate authority and validity

document current generation semantics, introduce explicit authority/observation dependencies, and remove actor-dependent audit compensation only after preserving its safety invariants.

**gate:** audit-only activity does not invalidate captured bytes; lease expiry or human revocation rejects queued/deferred effects even with unchanged target state; exec/restart invalidates old identities; shared-memory uncertainty is not hidden. compatibility tests cover older request contracts during transition.

### packet d — shared job ownership and workspace lifetime

migrate archive and observation analysis to retained inputs and shared lifecycle/accounting. separate the evidence catalog from the live controller. use existing jobs to prove the supervisor rather than building a framework first.

**gate:** closing/replacing a capture cannot free a worker's input; cancellation, allocation failure, and late completion clean up correctly; one client cannot take another's jobs; evidence remains openable and comparable after detach; an offline-only run needs no fake live target.

### packet e — provider seams and canonical representations

inventory existing image/debug, disassembly/semq/xsg, and runtime-language interfaces. narrow the image identity/placement contract, extract python/perl contexts, and document the existing machine-ir producer/consumer contract before adding another representation.

**gate:** two languages use the provider interface without changing central module fields; existing image paths retain their diagnostics; unsupported capabilities remain explicit; existing analysis fixtures still carry producer qualifications; the generic consumers require no new platform switches.

### packet f — enforce and document the graph

add import-boundary tests and build targets for domain/api types, pure analysis, the application service with a deterministic fake backend, and native integration. check transitive imports and broad re-export modules, not just direct filenames.

**gate:** forbidden imports fail the check. pure analysis fixtures run without gui libraries or native tracing. the fake backend exercises delayed reads, interleaved events, cancellation, stale completion, changed capabilities, and unknown remote outcomes. runtime integration tests verify the assumptions a fake cannot establish.

packets a and b are the principal critical path. validity/job work can follow incrementally. provider and ir inventory can proceed in parallel, but shared public types need one integration owner. merge vertical slices that remove an old path; avoid maintaining two permanent application architectures behind a feature flag.

## 9. non-goals and completion criteria

this proposal does not require a new kernel interface, a c-to-zig runtime rewrite, a daemon, dynamic plugins, a new programming language, a universal task scheduler, event sourcing, a complete decompiler, or implementing every platform combination.

it also does not require turning all application state into a huge immutable object copied every frame. use small publications, retained evidence, and ownership-conscious caches.

the refactor is successful when:

- one debugger operation has one semantic handler regardless of frontend or target transport;
- frontend code cannot touch live target handles, and slow backend work does not own the frame loop;
- caller authority and result validity are explicit rather than ambient or encoded through audit side effects;
- jobs retain their inputs and evidence outlives the relevant live session when appropriate;
- new runtime/image/isa providers do not require unrelated core fields or frontend-specific branches;
- generic analysis consumes qualified shared representations without erasing platform-specific meaning.

**the objective is fewer independent execution paths, fewer accidental shared lifetimes, and narrower authority—not more layers for their own sake.**

## source references

links below are relative to this repository and may change. planning documents establish intent, not completion. proposed interfaces, layouts, and acceptance gates above are recommendations, not claims that those interfaces already exist.

| reference | inspected source / relevance |
| --- | --- |
| [s01] | application entry points and local/remote gui loops |
| [s02] | workspace integration paths |
| [s03] | owner worker, ownership transfer limits, publication and lifecycle machinery |
| [s04] | owner dispatcher, mcp re-entry, request context and selection |
| [s05] | mcp access classification validation |
| [s06] | session state, capture generations, audit and deferred execution |
| [s07] | archive worker inputs, retained results, cancellation and teardown |
| [s08] | image/module representation and language layout caches |
| [s09] | runtime binding, discovery evidence and session dependencies |
| [s10] | owner request/publication types and ui timeline dependency |
| [s11] | build/test and headless/null-platform separation |
| [s12] | low-level c target interface |
| [s13] | immutable debugger presentation checks |
| [s14] | existing static-analysis host and ghidra integration |
| [s15] | existing ghidra-to-xsg adapter and qualifications |
| [s16] | original expression, runtime-adapter and machine-ir direction |
| [s17] | bounded control-flow graph and explicit assumptions |
| [s18] | target architecture descriptions through the c runtime |
| [s19] | root mixed-language-stack todo |
| [s20] | runtime-adapter and executable-analysis roadmap |

[s01]: ../src/main.zig
[s02]: ../src/ui/workspace.zig
[s03]: ../src/model/remote_worker.zig
[s04]: ../src/model/remote_dispatch.zig
[s05]: ../src/mcp/tool_catalog.zig
[s06]: ../src/model/session.zig
[s07]: ../src/profile/archive_job.zig
[s08]: ../src/model/modules.zig
[s09]: ../src/language/runtime_binding.zig
[s10]: ../src/model/remote_owner.zig
[s11]: ../build.zig
[s12]: ../src/runtime/xrt_target.h
[s13]: ../src/model/debugger_view.zig
[s14]: ../src/semq/host.zig
[s15]: ../src/semq/adapter.zig
[s16]: ../linux-ai-debugger-agents.md#runtime-and-language-adapters
[s17]: ../src/model/control_flow.zig
[s18]: ../src/target/arch.zig
[s19]: ../TODO.md
[s20]: ../docs/MILESTONES.md
