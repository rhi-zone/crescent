# Native Code Tiers

How crescent handles native code — SIMD, compiled C, and platform libraries — without
requiring a C compiler from users or committing to a single strategy everywhere.

## The extended tier hierarchy

The base tier model extends to five levels for native/SIMD work:

| Priority | Tier | Mechanism | C compiler? | SIMD? | Vendored? |
|---|---|---|---|---|---|
| 1 | **vendored binary** | `.so`/`.dll` committed to repo | no | hardware | yes |
| 2 | **system** | `ffi.load("libvips")` at runtime | no | hardware | no |
| 3 | **DynASM + RA** | machine code generated at load time from Lua | no | yes | `.lua` files only |
| 4 | **C build** | `build.lua` compiles C sources | yes | yes | no — output not committed |
| 5 | **pure Lua** | `.lua` only | no | no | yes |

**Vendored binary is preferred over system** when a vendored binary exists for the
current platform. Reasons:

- **Known version** — vendored binary is pinned; system library version is unknown.
- **Security** — loading an unknown system library version risks using one with known
  CVEs. The vendored binary was audited when committed.
- **Reproducibility** — same binary runs everywhere regardless of what the OS has
  installed.
- **NixOS** — system tier is unreliable on NixOS (see below); vendored binary always works.

System tier is only preferred over vendored when **no vendored binary exists** for the
functionality (e.g. `libssl` — crescent does not vendor a crypto library; use the OS).
An explicit opt-in flag (`M.prefer_system = true`) can override for users who want OS-managed
security updates on a specific library.

Selection at load time: try each in priority order, fall through on failure.
`M._tier` exposes which was selected.

The **C build** tier is not a user-facing tier. It exists for CI and developers who need to
regenerate vendored binaries after updating upstream source. Users receive either the
vendored binary or the pure Lua fallback — they never run a compiler.

### System tier is opportunistic

`ffi.load("libname")` relies on the dynamic linker — `LD_LIBRARY_PATH`, `/etc/ld.so.cache`,
`DYLD_LIBRARY_PATH`. This works on FHS-compliant systems (Debian, Arch, Fedora, macOS with
Homebrew in standard paths). It does **not** work out of the box on:

- **NixOS** — libraries live under `/nix/store/<hash>-libvips-x.y.z/lib/`; the linker
  finds nothing unless `LD_LIBRARY_PATH` is set (e.g. inside a `nix develop` shell with
  the library in `buildInputs`).
- **Distroless / minimal containers** — no system libraries present.
- **Windows without the DLL on `PATH`** — same issue.

The system tier is "user has explicitly made this library available in their runtime
environment." Probe it via `pcall(ffi.load, name)` and silently skip if absent.

---

## Vendored binaries: the "earn their place" rubric

Vendored binaries are pre-compiled platform-specific blobs committed to the repo.
They are not hackable and require maintenance across 5 platform targets. They must
earn their place. All five criteria must pass:

1. **Capability gap** — pure Lua cannot do the operation correctly, not just slowly.
   "Slower" does not qualify. "Qualitatively wrong output" (nearest-neighbor as the only
   resize option) or "practically infeasible" (JPEG Huffman + DCT at useful throughput)
   does qualify.

2. **DynASM-RA gap** — the algorithm is too complex to maintain as generated assembly.
   Either the implementation is too large (stb's resampler with multiple filter types),
   or the algorithm evolves with upstream (security patches, format quirks), making an
   assembly port a permanent maintenance liability.

3. **Stability** — the library's ABI has been stable for years and shows no signs of
   churn. A library that breaks ABI every major version is not a vendoring candidate.

4. **Footprint** — the binary is ≤1 MB per platform. Stb libraries compile to 100–300 KB.

5. **Coverage** — binaries for all five target platforms are practical to produce and
   maintain: `linux-x86_64`, `linux-aarch64`, `macos-x86_64`, `macos-aarch64`,
   `windows-x86_64`.

### Current qualified libraries

| Library | Gap | Reason |
|---|---|---|
| `stb_image` | capability | JPEG decode (Huffman + IDCT) is infeasible in pure Lua at speed |
| `stb_image_resize2` | capability + DynASM-RA | Quality gap (bilinear/bicubic vs nearest-neighbor); resampling kernel too complex to maintain in assembly |
| `stb_truetype` | capability + DynASM-RA | Font rasterization + hinting; hundreds of KB of algorithm, evolves with font spec edge cases |

### Disqualified

| Library | Reason |
|---|---|
| `libssl`/`libcrypto` | System tier handles it; present on virtually all targets |
| `libvips` | Too large (~10 MB); system library — use as system tier only |
| `xxhash`, custom hashes | DynASM + RA handles these; algorithm is bounded and stable |
| `zlib` | System tier (present everywhere); pure Lua inflate is tractable for non-hot paths |

---

## TinyCC: enabling tier 4, not a tier

TinyCC (`tcc`, vendored source in `dep/tcc/`, prebuilt binaries in `bin/tcc-*`)
is not a sixth tier alongside the five above. Tier 4 ("C build") already
assumes *some* C compiler is available to run `build.lua`; tcc exists to
supply that compiler on a platform or CI runner that doesn't have gcc/clang
available, so tier 4 stays reachable everywhere rather than silently
degrading straight to tier 5 (pure Lua) for want of a compiler.

This is infrastructure underneath tier 4, not a new point in the priority
order — tier selection at load time is unaffected; `M._tier` still only
ever reports one of the five values above. `tcc` never appears as a load-time
tier because it doesn't produce a different runtime artifact than tier 4
does; it's a different way of *reaching* tier 4's output.

**Where it helps:** any tier-4 CI job or developer machine that lacks gcc/
clang/cl — a bare Alpine container without `build-base`, a minimal cross
target, or a contributor machine mid-setup. `.github/workflows/build-vendored.yml`'s
`workflow_dispatch`-only tcc jobs bootstrap tcc (built once with the
runner's own system compiler) and then use it as `CC` for the C-build tier.

**What it does not change:** tcc is never a substitute for the vendored
binaries in `lib/stb/vendor/` etc. — those are still built with gcc/clang/cl
in the primary CI path (`.github/workflows/build-vendored.yml`'s
push-triggered jobs), unmodified. tcc is a fallback path for regenerating
tier-4 output, not a replacement for how the shipped vendored binaries are
produced today.

**Known gap, found by actually building with it:** tcc (mob branch,
`dep/tcc/VERSION` pin) cleanly builds `sqlite3.c` and zlib's sources (the
former needs an explicit `-lm`; tcc's driver doesn't auto-link libm the way
gcc/clang's does). It still does not build LuaJIT end-to-end: `buildvm`'s
generated `lj_vm.S` used GNU-as-only `sym@PLT` relocation-suffix syntax that
tcc's assembler rejected outright ("end of line expected") — that specific
parser gap is now patched (see below) and verified in isolation, but a full
LuaJIT build with the patched tcc has not been attempted. LuaJIT source is
now vendored locally (`dep/luajit/`, pinned via `dep/luajit/VERSION`; used
by the gcc/clang/cl `luajit-*` jobs in `build-vendored.yml`) — the tcc gap
here is specifically about wiring that vendored source into the
`tcc-build-deps-*` job's tcc-as-`CC` path, which hasn't been attempted, not
about the source's availability. LuaJIT stays unwired in `tcc-build-deps-*`
until that's verified for real (see TODO.md). libressl's `--disable-asm`
tcc path is still wired (kept, not flipped):
the perlasm-generated `*-elf-x86_64.S` files' SSE2/AES-NI opcode gap is now
patched, but assembling them surfaced a *separate* gap — this vendored tcc
defines no `xmm8`–`xmm15` (or `r8`–`r15`) registers at all — that still
blocks two of the seven asm files. See TODO.md for the full breakdown.

**Patch mechanism (`dep/tcc/patches/`):** `dep/tcc/`'s vendored source stays
pristine — bugs found in it are fixed as unified diffs under
`dep/tcc/patches/*.patch` (numbered, e.g. `0001-plt-suffix.patch`), applied
via `git apply dep/tcc/patches/*.patch` (order matters; apply in numeric
order) as a CI step in each `tcc-bootstrap-*` job in
`.github/workflows/build-vendored.yml`, immediately after checkout and
before the tcc build step. It exists because tcc is infrastructure we
actively extend (assembler/opcode-table gaps) rather than a dependency we
only consume as-is. Currently: `0001-plt-suffix.patch` (tccasm.c, GNU-as `sym@PLT`
suffix parsing), `0002-libressl-sse-aesni-opcodes.patch`
(x86_64-asm.h + i386-asm.c, SSE2/AES-NI opcode-table entries for
libressl's perlasm output), `0003-asm-forward-label-diff-and-leb128.patch`
(tccasm.c, two related same-section-label-difference gaps: (1) `.file`
left `PARSE_FLAG_TOK_STR` cleared on every exit path instead of just the
one it needed it cleared for, permanently breaking string-directive
parsing — `.section`/`.string`/`.ascii`/`.asciz` — for the rest of the
translation unit; (2) a fixed-width forward-forward same-section label
difference (`.long .LEND-.LSTART` written before either label is defined
— the DWARF CIE/FDE length-prefix idiom) is now deferred via an
`AsmFixup` list and resolved once the whole input is read, instead of
erroring immediately as "invalid operation with label". Deliberately
does *not* implement variable-width LEB128 relaxation — that landed
separately as `0005`, below), `0004-asm-section-flags-alloc.patch`
(tccasm.c, `.section NAME,"flags"` directive: `SHF_ALLOC` was hardcoded
into every parsed section's flags and the flag-parsing loop never
recognized `a` at all, so an explicit `"w"`-only section came out
allocatable and an empty flags string still got `SHF_ALLOC` — both wrong
against real GNU `as`, which only sets `SHF_ALLOC` when `a` is actually
present), and `0005-asm-leb128-relaxation.patch` (tcc.h + tccpp.c +
tccasm.c + tccdbg.c, variable-width LEB128 relaxation — the gap `0003`
documented). A `.uleb128`/`.sleb128` whose operand is an unresolved label
difference has an unknown *width*, not just an unknown value, so nothing
can be reserved at parse time; and the emitted bytes cannot be patched
afterwards, because tcc writes same-section branch displacements as bare
immediates with no relocation, threads forward-jump chains through the
displacement fields themselves, and computes `.align` padding from the
absolute position — so a size delta is neither findable nor uniform.
Implemented as real multi-pass re-layout: assemble, measure, and if any
width was wrong rewind all state and assemble again with a larger guess.
Widths only grow, bounding the iteration and giving the same minimal
fixed point GNU `as` computes. Passes after the first replay a captured
token stream instead of re-reading source, so the preprocessor runs
exactly once (re-running it would re-evaluate `#include`/`#pragma once`
against mutated state). Relaxation is an explicit error inside
function-body inline `asm()`, which cannot be safely re-assembled. Note
this is general assembler infrastructure with no current in-tree
consumer: `lj_vm.S` and every `vm_*.dasc` target use only literal
constants as LEB128 operands.

Next, `0006-dwarf-section-flag-and-debug-retention.patch` (tcc.h +
tccelf.c + tccpe.c + tccdbg.c) fixes a link-time hard error on foreign
objects and lets debug sections survive a link without `-g`.

A 32-bit reference from one DWARF section to another is an *offset
within the target section*, not an address, and the linker has to
resolve it that way. tcc decided which sections those were by testing
whether a section's index fell in the `dwlo..dwhi` range — the block of
debug sections tcc creates for itself. That is a proxy for "is this a
debug section" via creation contiguity, and it breaks for any debug
section tcc did not create: a real `gcc -gdwarf-4 -fdebug-types-section`
object carries `.debug_types`, which merges in *outside* that range, so
its relocations were resolved as absolute addresses and every one of
them failed `relocation 'R_X86_64_32[S]' out of range`.

What makes it *fail* rather than merely be wrong is where the target
lands: `.debug_types`' references point at `.debug_abbrev`/`.debug_str`/
`.debug_line`, which are tcc's own sections and are `SHF_ALLOC` at high
addresses under `-run` with `-g`, so the absolute value overflows 32
bits. A foreign section whose 32-bit reference points *within itself*
(`.debug_frame`'s CIE pointer is the case actually checked here) stays
at `sh_addr` 0, where the absolute and section-relative readings happen
to coincide at 0 — misresolved in principle, identical in practice, and
so it silently worked before and still works now. The flag makes the
whole class correct rather than accidentally correct.

Replaced with an explicit `Section->is_dwarf` flag set at
creation in `new_section()`. ELF has no structural marker for this, so
it is a name check (`.debug_` prefix) — the same classification
`tcc_load_object_file()` already used to pick retained sections, now
made once in one place instead of inferred from index arithmetic.
Per-`Section` granularity is sufficient: correctness depends only on
which two sections a relocation is between, never on which object it
came from.

Debug sections from a foreign object are also now retained without `-g`
(previously gated on `do_debug` and dropped), and their `sh_size` is
published so they actually reach the output rather than being retained
at zero length and silently dropped by `alloc_sec_names()`.

**Real limitation, stated plainly: this rarely helps against real-world
gcc output.** tcc cannot decompress `SHF_COMPRESSED` sections, and skips
debug retention for an entire object if *any* section in it is
compressed. Modern gcc compresses debug sections by default, so a
typical `gcc -g -c` object still contributes no retained debug info at
all — retention only works for objects built with `-gz=none` or
equivalent. Adding decompression is new capability and deliberately out
of scope here; until it exists, treat this as "retains uncompressed
debug sections correctly", not as "debug section retention works".

`.stab` was deliberately left alone. Its three legacy special cases
(an out-of-range error suppressed by `.stab` address range in
`x86_64-link.c`, dynamic relocations dropped in `tccelf.c`, and
`.stabstr` excluded from strtab ordering) share a trigger but not a
concept, and none of them is the `is_dwarf` concept: `Stab_Sym.n_value`
is 32 bits wide, so for stabs there is no correct value for a high
address and the existing hack merely *tolerates* truncation, whereas the
dwarf fix makes the value *correct*. Extending truncation-tolerance to
foreign `.stab` sections would trade a hard error for silently wrong
debug data, so `.stab` retention stays gated on `-g`. See TODO.md for
the resulting known gap.

### `0007-reserved-section-gate-and-eh-frame-retention.patch`

`0007` (tcc.h + tccelf.c + tccdbg.c) closes the section-registry problem
that `0001`–`0006` kept running into from different directions.

**The structural problem.** tcc has two unrelated ways a section comes
into being. Around twenty reserved roles (`.got`, `.plt`, `.eh_frame`,
the dwarf sections, `.dynsym`, `.dynamic`, `.interp`, …) live in
`TCCState` fields and are created by scattered internal call sites that
call `new_section()` directly. Separately, ordinary input reaches a
fully general by-name path — an asm `.section` directive via
`find_section()`, or `tcc_load_object_file()`'s merge loop, which
matches an input section against an existing one *by name* and creates a
new one when nothing matches. Neither world knows about the other.
`new_section()` appends unconditionally, so whenever input introduced a
name before the internal creator ran, the output got two sections with
the same name and the role pointer referred to only one of them. Measured
on this tree before the patch, a one-line `.section .got` in an assembled
object produced an executable with two `.got` sections; likewise `.plt`,
`.interp`, `.dynamic` — silently, with no diagnostic.

**T1 — one creation gate.** Every internal creator of a reserved section
now goes through `reserved_section()` (tccelf.c) instead of bare
`new_section()`: look the name up first, and resolve a hit by an explicit
per-role policy rather than by appending a duplicate. This is not a new
invention — `add_array()` and `create_bsd_note_section()` already did
find-or-create-and-upgrade by hand; `0007` makes the idiom uniform. A
`Section->internal_role` flag records that tcc itself created a section,
so a second call for the same role rebinds instead of tripping a policy.
(The `dwlo`/`dwhi` index-range identity mechanism was already replaced by
the name-based `is_dwarf` flag in `0006`; `0007` does not revisit it.)

**T2 — three genuinely different treatments, not one abstraction.** The
roles do not share a policy, so the gate does not pretend they do:

- *Container roles* (`.text`, `.data`, `.rodata`, `.bss`) are created in
  `tccelf_new()` before any input is read. No race exists; unchanged.
- *tcc-emitted-stream roles* (`.eh_frame`, dwarf, `.stab`) are
  `SECTION_ROLE_SHARED`: tcc binds to an existing section and appends
  after whatever is already there. That is well-formed because these
  formats are chains of self-delimiting records that reference each other
  by *relative* offset — `tcc_debug_frame_end()` writes its CIE Pointer as
  `fde_start - s1->eh_start + 4`, and the `.eh_frame_hdr` walker already
  tracked arbitrary CIE offsets. tcc's own merge loop corroborates the
  classification: it already exempts `.eh_frame` from its section-type
  conflict check.
- *Synthesized-output-only roles* (`.got`, `.plt`, `.interp`, `.dynsym`,
  `.dynstr`, `.hash`, `.dynamic`, `.gnu.hash`, `.gnu.version`,
  `.gnu.version_r`, `.shstrtab`, `.eh_frame_hdr`, ARM/RISCV
  `.attributes`, `.tcov`) are `SECTION_ROLE_PRIVATE`. These are pure
  outputs of tcc's own linking algorithm, and tcc has no
  input-section-to-output-section mapping layer that could give input
  content a meaning under those names — building one would be wildly
  disproportionate. So the link is refused with
  `section '.got' is reserved for internal use`, via
  `tcc_error_noabort()` per tccelf.c's convention, which reports further
  problems in the same run and then fails before writing output. This
  removes no working behaviour: the cases it now rejects are exactly the
  cases that previously produced a silently corrupt executable.
- *Metadata-table roles* (`.symtab`/`.strtab`/`.hashtab`) are left
  `SHARED` deliberately. Real toolchains do not protect these either — a
  `.section .symtab` under GNU `as` also produces broken output — and
  they are created before any input, so the gate's lookup cannot hit.

**The `.eh_frame` fix is laziness, not collision logic.** tcc emitted the
`.eh_frame` CIE unconditionally in `tcc_eh_frame_start()` at session
creation, before reading any input. A CIE describes how to unwind the
frames its FDEs cover, so a CIE with no FDE after it describes nothing.
Assembling a `.S` file — where tcc generates no FDEs at all — therefore
produced an `.eh_frame` section containing only an orphan CIE, where GNU
`as` emits no `.eh_frame` section whatsoever. `0007` moves CIE emission
to the first FDE. This fixes the orphan directly *and* means the section
is usually never reached for at all, so the common `.eh_frame` collision
disappears without needing any namespace logic.

Note this could not be fixed by creating the section eagerly and only
deferring its bytes: tcc emits zero-size sections (`.data`, `.bss` come
out size 0 for pure-asm input), so an eagerly-created empty `.eh_frame`
would still reach the output. Deferring the *creation* is the only fix.

**Consequence, stated plainly: output is no longer byte-identical to the
`0006` baseline, by construction.** Because `.eh_frame` is now created
later, it lands later in the section table — for `tcc -c m.c` it moves
from index 7 to index 8, swapping with `.rela.text`. Every section's
*contents* are byte-identical (verified per-section on `m.c` and on
`dep/sqlite3/sqlite3.c`, whose object is the same size to the byte); only
the section table order shifts. This is inherent to the fix, not an
implementation choice.

**T3 — "tcc generates X" is not "X should survive a link".**
`tcc_load_object_file()` dropped *any* input `.eh_frame` whenever
`s1->eh_frame_section == NULL`, conflating whether tcc should generate
unwind info for code it compiles (`-f[no-]asynchronous-unwind-tables`)
with whether unwind info already present in a linked object survives the
link. The second must be unconditional, as `ld` does it. This was not a
quality bug: an object with a relocation into its own `.eh_frame`, linked
with `-fno-asynchronous-unwind-tables`, failed outright with
`Invalid relocation entry [ 2] '.rela.text' @ 00000003` — reproduced on
this tree, and fixed. Retention is now unconditional on every target.

That resolution was a real three-way tradeoff. *Guard by platform* leaves
the hard link failure standing on PE/mach-o/ARM, where `TCC_EH_FRAME` is
undefined entirely. *Retain then drop at write time per target* needs a
new, unmeasured mechanism and reintroduces per-target special-casing.
*Retain unconditionally* won: its cost is a few hundred bytes of inert
`.eh_frame`-named data on PE/mach-o, which use `.pdata`/`.xdata` and
`__TEXT,__eh_frame` respectively — dead weight, not wrong. The BSD
targets already retained unconditionally, so this makes the other targets
consistent with what BSD has shipped all along rather than inventing new
behaviour; the change is a deletion of the non-BSD-only guard.

**Verified.** `lj_vm.S` regenerated fresh via `buildvm` (not the
committed copy) contains its own `.section .eh_frame` with a hand-written
CIE, which is exactly the collision case: baseline tcc emitted 144 bytes
of `.eh_frame` where GNU `as` emits 120, the extra 24 being tcc's orphan
CIE sitting in front of LuaJIT's records. With `0007` the section is 120
bytes and **byte-identical to GNU `as`**, with `.text` identical across
baseline, patched and `as`. A LuaJIT linked with that tcc-assembled VM
passes JIT trace compilation, ffi calls/structs/buffers, error unwinding
through `pcall`, deep-recursion unwinding, coroutines and a GC stress
pass. tcc's own test suite reaches the identical stage and every
individual target (`abitest`, `btest`, `dlltest`, `vla_test-run`,
`asm-c-connect-test`, …) has identical pass/fail against the `0006`
baseline — `dlltest` and `abitest` matter most here, since shared-object
linking exercises `.got`/`.plt`/`.dynsym`/`.dynamic`/`.interp`, all now
gated. libressl's seven perlasm files are unchanged in outcome: the same
two still fail on the documented `%xmm8` register gap, and the five that
assemble now match GNU `as` by no longer carrying a spurious `.eh_frame`.

The cases above are kept as a harness in `dep/tcc/patches/0007-tests/`
(`./run.sh /path/to/tcc`): **18 pass** with `0007` applied and **8 fail**
against an `0001`–`0006` baseline — the eight `0007` fixes, including the
literal `Invalid relocation entry` and the reserved-name links that baseline
completes with no diagnostic at all. The other ten pass on both and exist as
regression guards.

**Known asymmetry, closed by `0009`.** `0007`'s gate protects a role only
when input introduces the name *before* tcc's internal creator runs. For a
role tcc creates first — `.tcov` under `-ftest-coverage` — an input section
of the same name was still merged into tcc's by `tcc_load_object_file()`'s
name match, with no diagnostic. See `0009` below.

### `0008-pt-gnu-stack.patch`

`0008` (tccelf.c) fixes a `dlopen()` failure on modern glibc, unrelated to
`0001`–`0007`'s section-identity problems.

**The bug.** tcc's ELF linker never emits a `PT_GNU_STACK` program header,
on any target, in any tinycc release — confirmed by grepping the full
upstream history (`repo.or.cz/tinycc.git`, all branches): `PT_GNU_STACK`
is defined in `elf.h` but referenced nowhere in `layout_sections()`. The
one `.note.GNU-stack` mention already in `tccelf.c` is unrelated — it
only dedups a doubled input *section* some `crt1.o` builds carry when
merging objects; it never fed into program-header emission. glibc
≥2.41's dynamic loader treats a completely absent `PT_GNU_STACK` as "this
object wants an executable stack" and refuses `dlopen()` on hardened
configurations: `cannot enable executable stack as shared object
requires: Invalid argument` (reproduced locally, NixOS glibc 2.42).

**The fix.** `layout_sections()` now unconditionally appends a
`PT_GNU_STACK` phdr with `PF_R | PF_W` (no `PF_X`) to every EXE/DLL link,
following the same `struct dyn_inf` index-slot pattern already used for
`PT_GNU_RELRO`/`PT_NOTE`/`PT_TLS`. This is not gated behind any existing
flag because none exists — tcc has no `-z execstack`/`-z noexecstack`
option to preserve, so there is no prior opt-in this could break. It
matches gcc/clang/binutils `ld`/`lld`'s non-executable-by-default stance,
and is safe for tcc specifically because tcc generates no code that needs
an executable stack — no nested-function trampolines, unlike GCC's
`-fnested-functions`. `elf_output_obj()` (the `.o`/`TCC_OUTPUT_OBJ` path)
is a separate function that never calls `layout_sections()`, so
relocatable-object output is untouched; PE and Mach-O outputs bypass
`elf_output_file()` entirely (`tccpe.c`/`tccmacho.c`), so the change is
inert there too — it only affects the ELF EXE/DLL path on Linux/BSD
targets, where the concept applies.

**Verified.** Local repro: a trivial `.so` built with unpatched tcc
carries no `GNU_STACK` program header at all and fails to `dlopen()` on
this NixOS glibc 2.42 sandbox with the error above; the same `.so` built
with `0008` applied carries `GNU_STACK … RW` and loads and `dlsym()`s
cleanly. Cross-checked on real musl (Alpine, via Docker — not
documentation-only reasoning): musl's `dlopen()` does **not** enforce
this even against the fully unpatched, header-absent `.so`, and the
patched build still produces a working, loadable `.so` there too — no
regression on either libc. `dep/tcc/patches/0007-tests/run.sh` gives
identical results against local patched and unpatched builds (the
harness's own local-only failures — a NixOS `ld.so` stub for
directly-executed binaries, a synthetic `--sysroot` needed to build tcc
at all on this sandbox — reproduce identically without `0008`, confirming
they predate and are unrelated to this patch).

**Separately noticed, not part of this patch:** `git apply
dep/tcc/patches/0001-*.patch … 0007-*.patch` was reported to fail on a clean
checkout of current `origin/master` (`patch failed: dep/tcc/tccasm.c:45`),
independent of any CI-specific environment. Recorded in TODO.md as a separate
issue. *Correction from the `0009` session:* that invocation was re-run at
`36c8ff97` and at `b6547ec2` (the commit the original report names), in a
freshly extracted tree both times, and the whole series applies cleanly —
including `0009`, and including the exact multi-argument form the workflow
uses. What does reproduce the reported message exactly is adding `--check`:
`git apply --check` validates every patch against the *unmodified* tree
rather than chaining them, so `0003`'s `tccasm.c` hunks fail against context
`0001` has not yet created. That is a candidate explanation for the original
report, not a confirmed account of what was run; the TODO entry stays open.

### `0009-reserved-section-input-side-gate.patch`

`0009` (tcc.h + tccelf.c + tccasm.c) closes the asymmetry `0007` left open:
the same policy now applies in both orderings.

**The gap.** `0007`'s `reserved_section()` sits at tcc's creation sites, so
it only sees the ordering where input named the section first. The reverse —
tcc creates the section for a role, *then* input claims the name — never
reaches it, because no creator runs a second time. Both of tcc's by-name
reuse paths on the input side took the section as-is: the merge loop in
`tcc_load_object_file()` matches an input section against an existing one by
name and merges into it, and the assembler's `.section`/`.pushsection` go
through `find_section()`, which returns the existing section. Reproduced
before touching anything, against a local `0001`–`0008` build: with
`-ftest-coverage` (which creates `.tcov` while compiling, before any object
is merged), both an input object carrying a `.tcov` section and an
`__asm__(".section .tcov")` linked with **exit 0 and no diagnostic**, their
content sitting inside tcc's coverage table — while naming the same section
in the other order was refused, as `0007` intends.

`.tcov` is the whole practical surface today, and that is a property of
creation order rather than of the role list: every other
`SECTION_ROLE_PRIVATE` role (`.got`, `.plt`, `.interp`, `.dynamic`,
`.dynsym`, `.gnu.*`, `.shstrtab`, `.eh_frame_hdr`) is created during
`elf_output_file()`, after all input has been merged, so input cannot arrive
second for them. The gate is written against the role, not against `.tcov`,
so a role that later starts being created earlier is covered without
revisiting this.

**Shared substrate, not a parallel mechanism.** The role classification
`0007` established is what decides both directions; only the direction of
lookup differs. `Section->internal_role` therefore stores *which* role a
section was created for (`SECTION_ROLE_NONE`/`SHARED`/`PRIVATE`) instead of
`0007`'s bare "has a role" bit, and `reserved_section_claim()` reads that
role back on the input side. Both it and `reserved_section()` raise the same
diagnostic through one helper, so the two orderings are indistinguishable to
a caller: `section '.tcov' is reserved for internal use`, via
`tcc_error_noabort()`, output suppressed. `SECTION_ROLE_SHARED` continues to
merge input content exactly as before — the `.eh_frame`/dwarf coexistence
`0007` relies on runs through the new check unchanged — and the `.symtab`
family stays `SHARED` by the same deliberate decision recorded above (GNU
`as` does not protect it either), so it is untouched here.

**Verified.** `dep/tcc/patches/0009-tests/run.sh`: **10 pass** with `0009`
applied, **3 fail** against an `0001`–`0008` baseline — the three orderings
`0009` fixes (object merge, `.section`, `.pushsection`). The other seven are
regression guards and pass on both: the reverse ordering still refused, an
input `.tcov` still linking and running when no coverage role exists (the
reservation follows the role, not the name), `.eh_frame` still merging input
content into tcc's section in this same "tcc first" ordering, and ordinary
compile/link/run. `0005`/`0006`/`0007`'s harnesses give identical results on
patched and baseline builds (9, 10 and 18 passing respectively). tcc's own
`make test` produces byte-identical output on both, stopping at the same
pre-existing environmental `test3` failure, and `abitest`/`btest`/`dlltest`/
`vla_test-run`/`asm-c-connect-test`/`asmtest2`/`weaktest`/`test4`/`tests2`
have identical results. Objects compiled by both binaries are byte-identical
across `sqlite3.c`, `tccelf.c` and `.S` inputs under `-g`, `-gdwarf-5`,
`-ftest-coverage` and `-fno-asynchronous-unwind-tables` (with the compilers'
own directory equalised: the only difference otherwise is the include path
tcc records in debug info, an artifact of the two builds living in
differently named directories). A freshly `buildvm`-generated `lj_vm.S`
assembles to a byte-identical object, and a LuaJIT linked from it passes
trace compilation, ffi, `pcall`/callback/coroutine unwinding, deep recursion
and GC churn identically to an all-gcc control; libressl's seven perlasm
objects keep the recorded baseline exactly (same five assemble
byte-identically, `aesni`/`ghash` fail on the same `%xmm8` gap), with no new
diagnostic from either. `0008`'s `PT_GNU_STACK` header and `dlopen()` still
behave as recorded.

### `0010-extended-sse-registers.patch`

`0010` (i386-tok.h + i386-asm.c) teaches the assembler `%xmm8`–`%xmm15`.

**The gap, as it actually is.** The standing TODO entry described this as two
missing register sets plus absent REX plumbing. Re-derived from the source, one
third of that is true. `%r8`–`%r15` and their `d`/`w`/`b` width forms already
assembled correctly, and byte-identically to GNU `as`, including as SIB base and
index — they are absent from `i386-tok.h` because they are not tokens at all:
`asm_parse_numeric_reg()` recognizes them from the identifier text. The REX
machinery already existed too. `asm_rex()` turns any register number `>= 8` into
REX.R (ModRM.reg), REX.B (ModRM.rm or SIB.base) or REX.X (SIB.index), subtracts
8, and `asm_modrm()` then sees a 3-bit number — and its `rmi` branch already
listed `OP_SSE` among the operand classes it extends. The one thing missing was
a way to *say* `%xmm8`: `i386-tok.h` stopped at `xmm7`, so the parser rejected
the name before any of that machinery could run.

**Why the tokens sit apart from the other registers.** `parse_operand()` derives
an operand's class from its position in one contiguous token block, as
`1 << ((tok - TOK_ASM_al) >> 3)` — eight names per class, in the same order as
the `OPT_*` enum. Appending `xmm8`–`xmm15` after `xmm7` would insert a ninth
group and silently renumber `cr`/`tr`/`db`. They go at the end of the register
list with an explicit parse branch instead, which is the pattern `%spl`/`%bpl`/
`%sil`/`%dil` already established for the same reason. The branch sets
`OP_SSE` and a register number of 8–15, and everything downstream is the code
that was already there.

**Verified.** `dep/tcc/patches/0010-tests/run.sh`: **8 pass** with `0010`
applied — every case byte-identical to GNU `as`, comparing PROGBITS content and
the normalized relocation table, across REX.R, REX.B, REX.X and their
combinations, the `%rsp`/`%r12` forced-SIB and `%rbp`/`%r13` forced-displacement
corners, the 0F38/0F3A three-byte maps (where REX must precede the `0x0f`
escape), mixed GP/SSE operands, and RIP-relative. Against an `0001`–`0009`
baseline the same harness gives **2 pass, 6 fail**, the six failing on
`unknown register %xmm8`; the two that pass are the `xmm0`–`xmm7` control and
the `%r8`–`%r15` regression guard, which is the direct evidence that the GP set
never needed this patch. On the real vendored perlasm: `aesni-elf-x86_64.S` and
`ghash-elf-x86_64.S` get past the register gap, and all **583** and **427**
extended-register instructions in them encode byte-identically to `as` (the only
`objdump` differences are symbol *names* in comments, tcc retaining local labels
in `.symtab`). The other five perlasm objects are byte-identical to the baseline
build, a freshly `buildvm`-generated `lj_vm.S` assembles to a byte-identical
object and the LuaJIT linked from it runs with the JIT on, and tcc's own
`make test` / `tests2` reach the same stage on patched and baseline builds with
output differing only in paths and ASLR addresses.

**Two unrelated gaps found behind this one, not fixed here.** Neither of the two
perlasm files assembles yet, and neither remaining blocker has anything to do
with registers. `x86_64-asm.h` types the second operand of `movups`/`movaps`/
`movhps` as `OPT_EA | OPT_REG32` where the register-to-register form needs
`OPT_SSE`, so `movaps %xmm0,%xmm1` is rejected on the unpatched tcc too; and
`.value` (the GAS spelling of `.short`) is not among tcc's assembler
directives. Both are closed by `0011` and `0012` below.

### `0011-sse-mov-operand-types.patch`

`0011` (x86_64-asm.h) corrects the operand types of `movups`, `movaps` and
`movhps`.

**The gap.** All six table entries typed the non-EA operand `OPT_EA |
OPT_REG32` — a *general-purpose* register class on instructions that take an
SSE register. That is wrong in both directions at once, and the dangerous
direction is not the obvious one. `movaps %xmm0,%xmm1` was rejected outright
(`bad operand with opcode 'movaps'`) — visible, and what surfaced the bug when
`0010` let `aesni-elf-x86_64.S` reach line 828. But `movups %eax,%xmm0`, which
real `as` rejects, *assembled*, emitting `movups %xmm0,%xmm0`: the GP register
number was taken as the xmm of the same number, silently, with no diagnostic.
`movhps %eax,%xmm1` was worse still, emitting `0f 16 c8` — `movlhps`, a
different instruction. Both misbehaviours predate `0010` and are independent of
the extended registers.

**Why `movhps` is not typed like the other two.** Checked against `as` rather
than assumed: `as` rejects `movhps %xmm0,%xmm1` with `operand type mismatch`,
because `0f16`/`0f17` with `mod=11` are `movlhps`/`movhlps`, different
instructions. So `movhps`'s EA operand takes no register class at all
(`OPT_EA`), while `movups`/`movaps` take `OPT_EA | OPT_SSE`.

**The ALT question.** With both operands SSE, both of a pair's table entries
match, and tcc takes the first. Checked against `as`: it emits the
load-direction opcode for the register-to-register form — `0f28` for `movaps`,
`0f10` for `movups` — which is the entry tcc's existing ALT order already
selects, so the order needed no change. `movlhps`/`movhlps` are absent from
tcc's tables entirely and are not added here; that would be new capability
rather than a correction.

**Verified.** `dep/tcc/patches/0011-tests/run.sh`: **7 pass** — two positive
cases byte-identical to `as` (register-to-register across `xmm0`–`xmm15`, and
the memory forms in both directions, which must be undisturbed), and five
negative cases where `as` rejects and tcc must too. Against an `0001`–`0010`
baseline: **2 pass, 5 fail** — the register-to-register case failing to
assemble and all four GP-operand cases failing *by assembling*. On the real
perlasm, all **450** `movaps`/`movups`/`movhps` instructions in
`aesni-elf-x86_64.S` encode byte-identically to `as`.

### `0012-asm-value-directive.patch`

`0012` (tcctok.h + tccasm.c) adds the `.value` assembler directive.

**The gap.** `.value` is GAS's x86 spelling of `.short`. tcc had `.word` and
`.short` but no `value`, so `dep/libressl/crypto/modes/ghash-elf-x86_64.S`
failed at its `.Lrem_8bit` lookup table with `incorrect number of operands` —
the directive was not recognized as one, so it fell through to opcode parsing.

**Equivalence checked, not assumed.** Before writing the alias: the same
content spelled `.short` and spelled `.value` assembles to *byte-identical
objects* in real `as`, relocations included, across constants, comma-separated
lists, negatives, expressions, symbol references and label differences. So
`.value` shares `.short`'s case in `tccasm.c` rather than getting a handler of
its own.

**Verified.** `dep/tcc/patches/0012-tests/run.sh`: **5 pass** — the `.short`
control, the identical content as `.value`, the real `.Lrem_8bit` table shape,
each byte-identical to `as`, plus the equivalence asserted directly in both
assemblers (`.value` output == `.short` output). Against an `0001`–`0011`
baseline: **1 pass, 4 fail**. On the real file, `ghash-elf-x86_64.S`'s data
sections — where the `.value` tables live — are byte-identical to `as`.

One pre-existing limitation is inherited deliberately and recorded in TODO.md:
tcc's 2-byte data directives reject a bare symbol operand (`constant
expected`, no `R_X86_64_16`), where `.long` accepts one. That is `.short`'s
gap; an alias that did not share it would not be an alias.

**All seven libressl perlasm objects now assemble.** With `0010`+`0011`+`0012`,
`aesni-elf-x86_64.S` and `ghash-elf-x86_64.S` join the five that already
worked, and those five stay byte-identical to the pre-`0011` build. Every
earlier harness (`0005`, `0006`, `0007`, `0009`, `0010`) produces output
identical to the baseline build, as do tcc's own `make test` and `tests2`
(both stopping at the same pre-existing environmental point), and a freshly
`buildvm`-generated `lj_vm.S` assembles to an object identical to the `0010`
build's, with the LuaJIT linked from it running with the JIT on.

### `0013-asm-macro-body-dollar-lexing.patch`

`0013` (tccpp.c) makes `$` lex as a plain token inside a `#define` in a `.S`
file, the way it already does everywhere else in asm mode.

**The gap.** `parse_define()` clears `PARSE_FLAG_ASM_FILE` while tokenizing a
define, so that `#` stays the stringize operator instead of becoming a line
comment. The lexer, though, decides `$` is a plain token from that same flag
rather than from the identifier table — so clearing it for the `#` reason also
turned `$` into an identifier character for the duration of every `#define`,
and `$5` in a macro body lexed as **one identifier token**. This is upstream
mob HEAD (`2ba12e83`) behaviour, unfixed there; the commit that introduced the
clear (`dd57a348`, 2016) hit the same problem for `.` and compensated through
`set_idnum()`, but `$` is the one character whose lexing does not go through
the identifier table alone, so the two mechanisms never composed. `0013`
extends that same per-character compensation to `$`.

**Two failures, only one of them loud.** Shift and rotate opcodes require an
8-bit immediate, so the operand — now an absolute address — was rejected with
`bad operand with opcode 'roll'`. But `mov`, `add`, `and`, `cmp` and `or`
accept a 32-bit immediate, so the same wrong operand **assembled with no
diagnostic**, as a load from the address of an undefined symbol literally named
`$5`. The baseline relocation table reads `R_X86_64_32S $5 + 0`. The silent
half is the reason `0013-tests` compares bytes rather than exit status.

**Scope.** The change fires only when the enclosing file is already being
parsed with `PARSE_FLAG_ASM_FILE` set, which no C compilation does — inline
`asm` in C goes through `tcc_assemble_inline()`, which runs with preprocessing
off and so processes no `#define`. `-fdollars-in-identifiers` in C is
untouched. In a `.S` file, `$` can no longer appear in a macro *parameter*
name; that follows from the file mode and could never have been referenced from
the body anyway.

**Verified.** `dep/tcc/patches/0013-tests/run.sh`: **10 pass** — a literal
control, the same sequence through object-like and through function-like
macros, the other `$` operand spellings, the real `sha1_amd64_generic.S`
shape, and a case that isolates the silent-wrong-bytes half; each byte-identical
to `as`, plus the equivalence asserted directly in both assemblers (macro
immediate == literal immediate). Against an `0001`–`0012` baseline: **1 pass,
9 fail**.

**The three libressl `crypto/sha/*_amd64_generic.S` files now assemble**
through tcc's integrated path, with no `tcc -E` pre-expansion. Their
instruction streams match `as` instruction for instruction; the objects are not
byte-identical because tcc emits `jmp rel32` where `as` relaxes to `rel8` and
pads `.align` differently, both pre-existing and unrelated. The seven
`*-elf-x86_64.S` perlasm objects stay byte-identical to the `0012` build, every
earlier harness (`0005`, `0006`, `0007`, `0009`, `0010`, `0011`, `0012`)
produces output identical to that build, and a freshly `buildvm`-generated
`lj_vm.S` assembles to an identical object with the LuaJIT linked from it
running with the JIT on — that last one a negative control, since the generated
`lj_vm.S` contains no `$` at all.

### `dep/libressl/patches/`: build-system gaps, not compiler gaps

The same numbered-unified-diff mechanism now also exists for
`dep/libressl/`, for a different reason. Compiling libressl with tcc
surfaced a bug in libressl's *vendored copy of libtool*, not in tcc:
libtool 2.4.2 has no capability probe for `wl` (the flag that passes
linker options through the compiler driver) — it is a lookup table keyed
on autoconf's `__GNUC__` test and then on `$cc_basename`, and tcc defines
`__TINYC__`, so the table falls through and `wl` comes out empty while
the *linker*-side specs, chosen by a separate probe that found GNU ld,
still contain `${wl}`. The result is a bare `--whole-archive` that tcc
rejects. `0001-libtool-tinycc-compiler-support.patch` backports upstream
GNU libtool's own `tcc*)` entries (first released in libtool 2.4.3–2.5.4;
our vendored macros predate all of them) into both `m4/libtool.m4` and
the tracked generated `configure`, since this repo has no autotools at
build time. Two consequences of that layer: the patch must be applied
with `git apply` from the repo root like the tcc ones, and because it
touches `m4/libtool.m4` the generated files must then be re-`touch`ed or
automake's rebuild rules will demand an `aclocal` that is not installed.

`0002-libtool-tinycc-soname.patch` then fixes an omission *in* those
upstream entries: the `tcc*)` `archive_cmds` reached on the non-GNU-ld
path carried no `-soname`, so tcc-built shared libraries had no
`DT_SONAME` at all and consumers recorded whatever filename they were
handed. Every other spec in that file which drives a GNU-ld-style linker
through `$CC` carries `${wl}-soname $wl$soname`; the patch does the same
for tcc, which accepts the flag in exactly that split spelling.

One divergence from the gcc-built libraries remains and is *not* fixed:
tcc-built libraries export their full symbol table rather than the set in
`crypto/crypto_portable.sym`. Restricting exports needs
`archive_expsym_cmds`, and both spellings libtool has for it
(`--version-script`, `--retain-symbols-file`) are linker options tcc does
not implement — a tcc feature gap, not a libtool spec gap.

See TODO.md for the verification record and for the gaps that remain
open behind it.

## Vendored binary layout

```
lib/stb/
  init.lua                     -- public API; selects tier at load time
  pure/
    image.lua                  -- pure Lua PNG/BMP decoder (no JPEG)
    resize.lua                 -- nearest-neighbor resize
  vendor/
    linux-x86_64/stb.so
    linux-aarch64/stb.so
    macos-x86_64/stb.dylib
    macos-aarch64/stb.dylib
    windows-x86_64/stb.dll
  build.lua                    -- compiles stb headers → .so; for regenerating vendor/
  src/
    stb_image.h
    stb_image_resize2.h
    stb_truetype.h
```

`build.lua` is a developer/CI tool, not part of the load-time tier chain.

Tier selection in `init.lua`:

```lua
local ffi = require("ffi")
local M = {}

-- 1. System tier (libvips or platform image library)
local ok, vips = pcall(ffi.load, "vips")
if ok then
  M._tier = "system-vips"
  -- ... bind vips API
  return M
end

-- 2. Vendored binary
local plat = detect_platform()   -- "linux-x86_64", "macos-aarch64", etc.
local ext  = plat:match("^windows") and "dll"
          or plat:match("^macos")   and "dylib"
          or                            "so"
local path = script_dir .. "/vendor/" .. plat .. "/stb." .. ext
local ok2, stblib = pcall(ffi.load, path)
if ok2 then
  M._tier = "vendored"
  -- ... bind stb API via ffi.cdef
  return M
end

-- 3. Pure Lua fallback
M._tier = "pure-lua"
-- ... require pure/ implementations
return M
```

---

## DynASM + RA: `lib/asm/`

For SIMD kernels that crescent owns — hash functions, string search, custom filters,
parser acceleration — the DynASM + register allocator approach eliminates the main
pain of hand-written assembly (manual register allocation) while staying entirely in
Lua with no external dependencies.

DynASM ships with LuaJIT (`dynasm/dasm_x86.lua`, `dynasm/dasm_arm.lua`) and is already
used to build LuaJIT itself. The addition is a register allocator and a typed virtual
IR sitting above it.

### Directory layout

```
lib/asm/
  init.lua          -- public API: compile kernel → callable FFI function
  ir.lua            -- virtual register IR builder
  ra.lua            -- linear scan register allocator
  cpu.lua           -- CPUID / HWCAP detection (avx2, sse2, neon, ...)
  abi/
    x64.lua         -- AMD64 SysV + Win64 calling conventions; register file
    arm64.lua       -- AAPCS64 calling convention; register file
  emit/
    x64.lua         -- IR → DynASM x86-64 directives
    arm64.lua       -- IR → DynASM ARM64 directives
  dynasm/           -- vendored DynASM from LuaJIT source
```

### Virtual IR

Types:

```
-- Scalars
i8  i16  i32  i64  f32  f64  ptr

-- 128-bit SIMD (SSE2 / NEON baseline)
i8x16  i16x8  i32x4  i64x2  f32x4  f64x2

-- 256-bit SIMD (AVX2 / SVE optional)
i8x32  i16x16  i32x8  i64x4  f32x8  f64x4
```

Instructions:

```
-- Memory
load(dst, ptr, offset?)       store(ptr, src, offset?)
-- Arithmetic
add  sub  mul  div  fma(a, b, c)   -- fma = a*b + c
-- Bitwise
and  or  xor  not  shl(n)  shr(n)
-- SIMD-specific
broadcast(scalar, type)        -- scalar → all lanes
shuffle(src, imm)              -- permute lanes within vector
blend(a, b, mask)              -- lane-wise select
cvt(dst_type, src)             -- convert between element types
hadd(vec)                      -- horizontal reduce (add all lanes)
extract(vec, lane)             -- pull one lane to scalar
insert(vec, lane, scalar)      -- write one lane
```

### Register allocator

Algorithm: linear scan (Poletto & Sarkar 1999).

For straight-line SIMD kernels (the primary target — loops with no branches in the hot
path), liveness is a single backward pass: each virtual register is live from its
definition to its last use. No CFG, no dominance, no phi nodes needed.

Steps:
1. Compute live intervals `[def, last_use]` for each virtual register.
2. Sort intervals by start point.
3. Walk intervals; maintain an active set sorted by end point.
   - Expire intervals whose end < current start → free their physical register.
   - If a free physical register of the correct type is available → assign it.
   - Otherwise spill: take the interval with the latest end point; assign its register
     to the current interval; insert load/store around the spilled interval's uses.
4. Emit prologue/epilogue for callee-saved registers that were assigned.

**Aliasing model** (critical for x64):
- Assigning `ymm3` implicitly occupies `xmm3` (upper 128 bits of the same physical register).
- The register file tracks aliasing groups; allocating any member of a group marks all
  members as in-use until the group is freed.
- On x64 pre-AVX (only 8 XMM): RA must not exceed 8 SIMD intervals active simultaneously.

### Register files

**x64:**
```
GPR (16):    rax rcx rdx rbx rsp rbp rsi rdi r8–r15
  SysV args:  rdi rsi rdx rcx r8 r9
  Win64 args: rcx rdx r8 r9
  Callee-saved (SysV):  rbx rbp r12–r15
  Callee-saved (Win64): rbx rbp rdi rsi r12–r15  xmm6–xmm15

SIMD (16 groups):  xmm0–xmm15  (alias ymm0–ymm15 with AVX, zmm0–zmm15 with AVX-512)
  SysV args:  xmm0–xmm7
  Callee-saved (SysV):  none
  Callee-saved (Win64): xmm6–xmm15 (lower 128 bits)
```

**ARM64:**
```
GPR (31+sp):  x0–x30  sp
  Args:         x0–x7
  Callee-saved: x19–x29  sp

NEON (32 groups):  v0–v31  (alias q/d/s/h/b registers)
  Args:         v0–v7
  Callee-saved: v8–v15 (lower 64 bits per AAPCS64)
```

### Usage sketch

```lua
local asm = require("lib.asm")
local ir  = require("lib.asm.ir")

-- Describe a kernel: element-wise multiply of two f32x8 arrays
local function make_mul_f32x8(n)
  local k = ir.kernel({ "ptr", "ptr", "ptr", "i64" }, {})  -- (dst, a, b, n)
  local dst, a, b, count = k:args()
  local i = k:vreg("i64")
  k:emit("mov", i, ir.imm(0))
  local loop = k:label()
    local va = k:vreg("f32x8")
    local vb = k:vreg("f32x8")
    local vc = k:vreg("f32x8")
    k:emit("load", va, a, i)
    k:emit("load", vb, b, i)
    k:emit("mul",  vc, va, vb)
    k:emit("store", dst, vc, i)
    k:emit("add", i, i, ir.imm(32))  -- 8 × 4 bytes
    k:emit("cmp_lt", i, count)
  k:loop(loop)
  return asm.compile(k)
end

local mul = make_mul_f32x8()
mul(dst_ptr, a_ptr, b_ptr, n)   -- callable FFI function
```

### What DynASM + RA is for vs. vendored binaries

Use DynASM + RA when:
- Crescent **owns** the algorithm (hash functions, string search, parser inner loops)
- The algorithm is bounded and stable (not a moving target like image format quirks)
- The SIMD code can be written once and maintained as an IR kernel

Use vendored binaries when:
- The upstream C library is large and algorithmically complex (stb)
- Tracking upstream bug fixes in assembly would be a permanent maintenance burden
- The capability gap criterion is met (see rubric above)

---

## CPU feature detection

```lua
local cpu = require("lib.asm.cpu")
-- x86-64
cpu.sse2   -- always true on x86-64
cpu.avx2
cpu.avx512f
-- ARM64
cpu.neon   -- always true on ARM64
cpu.sve
cpu.sve2
```

Detection via CPUID (x86) or `getauxval(AT_HWCAP)` (Linux ARM64) / `sysctlbyname`
(macOS ARM64), called once at load time and cached.

Tier selection in `lib/asm/` kernels:

```lua
local cpu   = require("lib.asm.cpu")
local asm   = require("lib.asm")

local dot = cpu.avx2
  and asm.compile(dot_avx2_kernel)
  or  cpu.sse2
  and asm.compile(dot_sse2_kernel)
  or  dot_pure_lua
```
