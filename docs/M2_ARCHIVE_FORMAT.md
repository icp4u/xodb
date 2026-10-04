# Experimental native capture format 2.4

This extends the integrated formats 2.0/2.1/2.2/2.3, which superseded T11's unshipped prototype 1.
The canonical field order and validation are in src/profile/archive.zig.
This document describes the extension boundary; it is not a compatibility promise
for arbitrary future formats.

All integer scalars are little endian. Fixed code tables encode enum meanings
independently of Zig enum ordinals. Strings are u32 byte length followed by bytes;
optional scalars are a boolean byte followed by the scalar if present. Boolean
and enum values, counts, ranges, references and trailing bytes are checked.
Architecture is x86-64, address width 64, clock CLOCK_MONOTONIC within the
recorded boot domain.

## Container

The 64-byte header has these offsets:

| Offset | Field |
| --- | --- |
| 0 | Eight bytes: XODBCAPT |
| 8, 10 | u16 major, minor |
| 12 | u32 header size (64) |
| 16 | u64 total file size |
| 24 | u32 section count, at most 64 |
| 28 | u32 reserved, zero |
| 32, 33 | u8 byte order (1), address width (64) |
| 34 | u16 machine (62 / EM_X86_64) |
| 36 | u32 clock (1 / CLOCK_MONOTONIC) |
| 40, 48 | u64 required features, optional features |
| 56 | u32 CRC32 over header bytes 0–55 |
| 60 | Four reserved zero bytes |

Each 24-byte directory entry contains u32 tag, u32 flags, u64 absolute offset,
u32 length and u32 payload CRC32. Payloads are contiguous in directory order:
no gaps, overlap or unaccounted trailing bytes. Flag bit 0 marks an ignorable
extension. Known sections cannot be marked ignorable. Other flags are rejected.

Required feature bit 0 declares recorded annotation schema 1 and is mandatory.
Bit 1 declares extended duration semantics in META: duration_ms=0 disables the
deadline; other u32 values can exceed the old 60,000 ms ceiling. Writers set this
bit for zero or greater-than-60,000 values; readers require it for those values.
Payload layout is unchanged. Version 2.0 artifacts remain readable, and an older
reader rejects bit 1 explicitly. Bit 2 declares USTA schema 1 (sampled user state),
requires minor >= 2 and a non-ignorable USTA section. Bit 3 declares thread scope
and enrollment evidence (TSCP), requires minor >= 3 and that non-ignorable section.
Bit 4 declares a configured sample ceiling (LIMT), requires minor >= 4 and that
non-ignorable section. Other required bits are unsupported. Unknown required sections/features fail
explicitly; an unknown optional section is checksum/length checked, reported and
retained inside the original bytes. Copying an opened artifact preserves its
complete bytes and SHA-256. Re-encoding the runtime offline capture is refused.
Unknown optional feature bits are retained and reported.

The decoder accepts later minor numbers only when all known required section
schemas and validations still hold. Changes inside required payloads must not
pretend to be compatible merely by incrementing the minor number.

## Required sections

Required sections appear in this relative order:

| Tag | Payload |
| --- | --- |
| META | Original capture/session/process/generation/epoch/revision, capture boot and timing, collector acceptance/configuration, loss/stop information; separate writer boot/time/encoder |
| THRD | Recorded thread identities, names, debugger IDs and perf thread information; opening/enrolled distinction is in TSCP |
| IMGS | Complete image manifest: placement/path, file length, SHA-256 and optional build ID |
| MAPS | Opening regions and ordered mapping-change history |
| SMPL | Normalized raw CPU sample fields and original kernel callchain, including context markers and presence bits |
| SCHD | Per-thread switch transitions, cutoffs, contradictions and loss accounting |
| MARK | Debugger event markers and loss accounting |
| INTV | Imported application intervals and source/correlation provenance |
| ANNO | Schema 1: key by lookup address/mapping/trust/ambiguity; frame identity/name, optional symbol size, optional source site and failure reason |

ANNO is generated from a fresh deterministic traversal at finalization, independent
of whichever UI queries warmed the live cache. Its resolver/basis strings are
defined by schema 1 in src/profile/annotations.zig. Image references resolve
against IMGS even when assets cannot be loaded. This records analysis provenance;
raw SMPL and MAPS evidence are not replaced with derived frames.

Source paths/lines are annotations, not embedded source contents. Image manifests
identify held file snapshots, not arbitrary future files found at the same path.
Neither ELF assets nor source files are embedded in this version.

## Sampled user state: USTA schema 1

USTA follows the nine core required sections and is present exactly when required
feature bit 2 (value 4) is set. SMPL and META layouts remain unchanged. Older
readers reject the required feature. Captures with stack collection disabled omit
USTA; 2.0/2.1 files remain readable and byte-identical copying remains available.

The canonical encoding is `encodeUserState`/`decodeUserState` in archive.zig:

1. u32 schema (1), u32 requested bytes per sample, u32 total retained-byte budget,
   u64 accepted x86 perf GPR mask, u32 total retained bytes, u32 raw sample count.
2. For each SMPL ordinal in order: boolean state-present. If absent, no following
   fields for that ordinal. Present records contain u8 retention status (0 captured,
   1 budget), u64 register ABI, 24 u64 register slots in perf index order, u64 kernel
   stack-record size, u64 valid/dynamic size, u32 retained size, then those bytes.
3. No padding/trailing bytes. Registers outside the accepted mask, or all registers
   with ABI_NONE, are zero. Mask/ABI determine validity, never an assumed value.

The production x86 GPR mask is required; nonzero stack requests are multiples of
8 from 64 through 8192. Configured total budget is 0 through 64 MiB. The original
32 MiB default is a capture preference, not a decoder assumption. The decoder
checks count/length/config consistency, dense side references, valid <= record <=
request, exact retained bytes, and prefix-retention semantics. At the first dump
that does not fit, later nonempty stacks remain marked budget. Zero valid bytes
remain kernel absence rather than a budget loss. Presence/short flags and side
buffer offsets are rebuilt from these fields. Original sample order/callchains
remain untouched. Missing state records remain explicit after collector errors.

Large stack/body buffers use exact allocations; total archive input/output is
bounded at 256 MiB, decoded Zig allocations at 512 MiB, with separate ELF budgets.
Stack bytes and file size remain independent of the configured sample ceiling.

Derived callers are worker results, not an emitted UNWD section. They carry
algorithm/input/asset identity, raw PC/SP, lookup convention, mapping identity,
method and terminal partial reason. No decoder fetches process memory to fill
missing evidence. Unknown optional future sections remain preservable; unknown
required analysis/evidence features fail explicitly.

See [sampled-state workflow and tests](M2_SAMPLED_UNWIND.md).

## Dynamic thread scope: TSCP

Version 2.3 writers append TSCP after the core sections and optional USTA, with
required feature bit 3 (value 8). Its fields are a boolean effective follow_threads,
u32 ring_budget_bytes, u32 thread count, then optional u64 enrolled_ns for each
THRD row in the same order. Null denotes an opening thread; a timestamp records
enrollment beginning while the newborn was held before user code. New threads
are appended, and numeric TIDs remain unique across the whole capture.

The count must match THRD and META's accepted thread count. Enrollment timestamps
are monotonic, within the capture's start/end, and allowed only with following
enabled. Opening rows precede enrolled rows. Ring budget is 4096–268435456 bytes.
Older readers reject the required feature. Versions 2.0–2.2 decode as fixed scope,
all opening threads, with unknown ring budget; original bytes remain copyable.


## Configured sample ceiling (LIMT, feature bit 4)

When sample_limit differs from the default 16,384, a version 2.4 writer appends a
required LIMT section after TSCP: one little-endian u32, in the range 1–65,536.
The reader validates the section and count before allocating SMPL or USTA storage.
Both sample and sampled-state counts must fit this ceiling; the compact sample
store's independent 32 MiB allocation bound still applies.

Archives without LIMT imply 16,384. Default captures retain the 2.3 encoding and
required bits; a nondefault value, even below 16,384, uses 2.4/bit 4. Old readers
reject the unknown required feature instead of silently interpreting a new limit.
Duplicate, ignorable, missing or malformed LIMT sections are rejected.
