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
against real GNU `as`, which for a section name it does not recognize only
sets `SHF_ALLOC` when `a` is actually present. For a name it *does*
recognize the name decides, which `0004` got wrong in the other direction
and `0021-asm-section-name-attrs.patch` corrects), and
`0005-asm-leb128-relaxation.patch` (tcc.h + tccpp.c +
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

**Already covered — do not re-report.** A separate investigation reported what
looked like a distinct remaining gap: `#define step(c) adcq $0, c` used as
`step(%r9)` in a `.S` file emitting `adc 0x0,%r9` plus a bogus
`R_X86_64_32S $0 + 0` relocation, attributed to `s->dollars_in_identifiers`
defaulting on (`libtcc.c:882`) with nothing clearing it for the x86_64 `.S`
path. Reconciled 2026-08-21 by running that exact input against both builds:
on an `0001`–`0012` build it reproduces the reported bytes and relocation
character for character; on the `0001`–`0013` build it assembles to
`49 83 d1 00` / `adc $0x0,%r9` with no relocations, byte-identical to
`gcc -x assembler-with-cpp`. Same bug, same mechanism — the report predates
`0013`. The `dollars_in_identifiers` reset that the report points at
(`tccasm.c`, guarded off for `TCC_TARGET_X86_64`) sits inside
`tcc_assemble_inline()`, the entry point for C `asm(...)` statements, which is
not on the `.S` file path at all; the `.S` path reaches the same `$`-as-ident
state through `parse_define()` instead, which is what `0013` compensates.
`-fno-dollars-in-identifiers` makes the symptom go away on a pre-`0013` build
because it flips the underlying ident-table bit, not because the option is the
right lever — nothing in the build passes it.

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

### `0014-note-gnu-stack-object-marker.patch`

`0014` (tcc.h + libtcc.c + tccelf.c) makes `elf_output_obj()` emit an empty
`.note.GNU-stack` marker in objects holding tcc-generated code.

**The bug.** GNU `ld` decides an executable's `PT_GNU_STACK` permissions from
its inputs' `.note.GNU-stack` sections, and its default for an input carrying
none is *this object requires an executable stack*. One unmarked object makes
the whole link `RWE`. tcc emitted the section in no object at all, so linking
any `tcc -c` output with a real `ld` produced an executable-stack binary plus
binutils 2.44's `missing .note.GNU-stack section implies executable stack`
warning. Reproduced directly: trivial `.c` → `tcc -c` → `gcc` link →
`GNU_STACK … RWE`; the same source through gcc gives `RW`.

**Relationship to `0008`.** They are the two halves of one stance and neither
substitutes for the other. `0008` writes a `PT_GNU_STACK` program header from
`layout_sections()`, which runs only when tcc performs the final link; `0014`
marks the object, which is what a foreign `ld` reads. Verified to compose:
with both applied, tcc-linked binaries still carry `GNU_STACK … RW`, and
because the marker is not `SHF_ALLOC` it is dropped from executable output
rather than duplicated there.

**Scope, and why it is narrower than "every object".** The marker is added
only when tcc's own code generator contributed to the object — a new sticky
`TCCState.compiler_generated_code`, set on the `tccgen_compile()` branch in
`tcc_compile()`, sticky because `-r` merges several inputs into one object.
Two cases are deliberately untouched:

- **Assembled input that said nothing about the stack gets nothing.**
  Measured, not assumed: neither `as` nor `gcc -c` marks a hand-written `.S`
  (binutils 2.44 / gcc 15.2.0). The convention is that asm authors declare
  their own stack-execution needs, and an `.S` that genuinely requires an
  executable stack but omitted the declaration would start crashing if the
  compiler answered on its behalf.
- **Input that supplied the section keeps it verbatim.** `"x"` there is a
  real requirement, and re-flagging it would discard that requirement with a
  runtime crash as the only symptom.

**`-r` merges, and parity with `ld -r`.** `-r` puts both kinds of input in
one object, and the marker is a property of the object, so the two statements
have to be reconciled. GNU `ld -r` is the incumbent and reconciles by
upgrading: merging a marked object with an unmarked one yields a marker
carrying `SHF_EXECINSTR`, so the unmarked input's implicit *I need an
executable stack* survives rather than being silently dropped. Measured on
binutils 2.44 — the final link of such a merged object reports `requires
executable stack (because the .note.GNU-stack section is executable)` and
produces `GNU_STACK … RWE`.

tcc matches via `TCCState.undeclared_stack_input`, raised by either input
class that declares nothing: an assembled source, tracked by a per-input flag
the `.section`/`.pushsection` directive sets when it names the marker; and a
merged object file with no such section, detected by a single pass over its
section headers in `tcc_load_object_file()`. The section `elf_output_obj()`
creates is executable whenever such an input shares the object. Both classes
have to count — keying only on assembled sources left `tcc -r foo.c bar.o`
marking the object non-executable on `bar.o`'s behalf, which is worse than
emitting nothing, since it converts an implicit requirement into an explicit
denial of it. All seven mixed `-r` shapes now agree with `ld -r` exactly,
checked side by side.

Two `-r` shapes are deliberately left divergent, both recorded in `TODO.md`,
and they share a cause: this patch only ever *creates* a marker and never
rewrites one an input supplied. `-r` over asm sources only where one declares
the marker and another does not, and `tcc -r a.o b.o` with no compilation at
all, both get `SHF_EXECINSTR` from `ld -r` and neither gets it here. Closing
either means deciding whether raising a flag on an input-supplied section
counts as rewriting it — an input's own statement would only ever be
strengthened, never weakened — which is a question to settle on its own terms
rather than inherit from this patch.

**Standing caveat.** binutils 2.44 prints that the missing-marker-implies-
executable-stack rule is deprecated and slated for removal. That cuts both
ways here: it is the rule the "emit nothing for undeclared asm" behaviour
leans on, and it is why the explicit `SHF_EXECINSTR` on merged markers is
worth more over time than the absence that happens to mean the same thing
today.

The section is created via `reserved_section()` with `SECTION_ROLE_SHARED`
and forced to `sh_addralign 1`, matching gcc's output byte for byte rather
than merely in effect. It is inert on the PE and Mach-O targets, whose
objects are also written by `elf_output_obj()`: both `tccpe.c` and
`tccmacho.c` skip non-`SHF_ALLOC` sections when building their own output, so
no target gate is needed.

**Verified.** `0014-tests/run.sh` scores 6/11 on the `0001`–`0013` +
`0015`–`0017` baseline, 11/11 with `0014`, and 11/11 against a real gcc — the
reference being an actual toolchain rather than the patch's own opinion.

**Adjacent gap, addressed by `0018`.** The common real-world idiom guards the
directive as `#if defined(__linux__) && defined(__ELF__)`, and tcc did not
define `__ELF__` on Linux targets — `include/tccdefs.h` defined it only under
the NetBSD branch. The directive was therefore preprocessed away and the
object came out unmarked; `dep/libressl`'s AT&T bignum mirror was affected,
which is where the original `RWE` observation came from. `0014` did not change
this — it deliberately does not speak for assembled input — so those `.S`
objects stayed unmarked under `0014` alone. Closed by
`0018-elf-target-predefine.patch`, below.

**Second gap, addressed by `0019`.** `0014` only ever *creates* the marker.
When an input supplied one, `0014` adopted it verbatim, which diverges from
`ld -r` whenever a different input declared nothing. Closed by
`0019-note-gnu-stack-merge-raise.patch`, below.

### `0015-adx-bmi2-opcodes.patch`

`0015` (i386-asm.c + i386-tok.h + x86_64-asm.h) teaches the assembler `adcx`,
`adox` and `mulx`, and with them the VEX prefix.

**The gap.** The six s2n-bignum `bignum_{mul,sqr}_{4_8,6_12,8_16}.S` routines
are built around two carry chains running at once (`adcx` on CF, `adox` on OF)
fed by a multiply that touches neither (`mulx`). None of the three was in
tcc's tables at all.

**`adcx`/`adox` are ordinary table entries; `mulx` needed new machinery.** The
first two are `0F 38 F6` told apart only by a mandatory prefix — `66` for
`adcx`, `F3` for `adox` — which is *not* an operand-size prefix: `REX.W`
selects the 64-bit form on top of it. That shape the existing table already
expresses (`0002` added the `0F38` escape map). `mulx` has no non-VEX encoding
at all, and tcc had no VEX support whatsoever.

**What the VEX support is, and what it is not.** VEX folds the mandatory
prefix, the escape map, `REX` and one extra register operand into a two- or
three-byte prefix. The patch adds `asm_vex()` beside `asm_rex()` (the two are
mutually exclusive by construction — `asm_opcode()` calls one or the other),
takes the map from the existing `OPC_0F`/`OPC_0F38`/`OPC_0F3A` bits and the
`pp` field from the prefix byte already in the opcode column, and takes `W`
from the same width decision that drives `REX.W`. The one genuinely new thing
in the table is *which operand* goes in `VEX.vvvv`, since that varies per
instruction (`mulx` puts its middle operand there; `bextr`, were it added,
would put its first) — so it is named declaratively, per operand, with an
`OPT_VVVV` role flag alongside the existing `OPT_EA`, rather than being
inferred from the mnemonic.

Two boundaries are deliberate and are stated in the code rather than left to
be discovered. `VEX.L` is fixed at 0: every VEX instruction in the table is a
general-purpose integer one, for which the field is defined as `LZ`, and a
256-bit instruction would need `L` in the table before it could be added. And
only the three-byte `C4` form is emitted, because the two-byte `C5` form can
encode neither `W=1` nor a map other than `0F`, so it never applies here.

**`OPC_NO16`, so `adcxw` is refused rather than mis-encoded.** None of the
three has a 16-bit form. Without saying so in the table, `adcxw` would match
the same template and assemble as the 32-bit operation under a stray
operand-size prefix — silently wrong output for input GNU `as` rejects
outright. The flag is a declarative property of the instruction, checked in
both places a width is settled (the suffix match, and the later inference for
the unsuffixed spelling).

`instr_type` widens from `uint16_t` to `uint32_t` to hold the two new bits.
The 3-bit group field occupies the top of the old width and only one low bit
was free, which is not enough; `ASMInstr` stays 12 bytes either way, since the
widening only fills padding the trailing `uint8_t`s already implied.

**Verified.** `dep/tcc/patches/0015-tests/run.sh`: **7 pass** — four accepted
files byte-identical to `as` (every `mulx` operand shape, `adcx` and `adox`
side by side, the unsuffixed spelling, and the three interleaved with ordinary
instructions), and three `w`-suffix files rejected exactly as `as` rejects
them. Byte identity is the right bar there: the files are straight-line, so no
encoding freedom is left, and a VEX prefix with an un-inverted `vvvv` field
would still *disassemble* plausibly. Against an `0001`–`0014` baseline:
**3 pass, 4 fail**.

On the real files, this unblocks `bignum_sqr_4_8.S` and `bignum_sqr_6_12.S` —
the two of the six that need no macro directives.

### `0016-asm-rept-replay-double-capture.patch`

`0016` (tccasm.c) stops `.rept` from recording its own expansion into the
token stream the LEB128 relaxation pass replays.

**The gap.** Two mechanisms that each work alone. `.rept` replays its body by
pushing the recorded tokens back through the assembler. LEB128 relaxation
(`0005`) records the *whole* token stream on the first pass and re-assembles
from it when a `.uleb128` width guess was too small. The replayed body was
being recorded too, landing in the stream immediately after the
`.rept`/`.endr` that produces it — so a second pass expanded the body and then
found another copy of it sitting there. In practice it desynchronizes the
statement loop and the unit fails with `end of line expected`; the shape of
the bug is duplicated output, and the error is how it happens to surface.

Found while building `0017`, which needs the same replay mechanism and would
otherwise have inherited the same defect. Fixed separately because it is a
pre-existing bug in `.rept` with its own reproducer.

**Verified.** `dep/tcc/patches/0016-tests/run.sh`: **3 pass** — `.rept` with
no second pass (the control), `.rept` plus a forward `.uleb128` label
difference (the minimal form), and three `.rept` blocks on both sides of the
relaxation site (which separates a suppression that leaked from one that never
applied). Against an `0001`–`0015` baseline: **1 pass, 2 fail**.

Nested `.rept` remains unsupported and is not this patch's subject: tcc's body
scan stops at the first `.endr` rather than counting depth. Recorded in
TODO.md.

### `0017-asm-macro-and-conditional-directives.patch`

`0017` (tccasm.c + tccpp.c + tcc.h + tcctok.h) adds `.macro`/`.endm` and
`.if`/`.elseif`/`.else`/`.endif`.

**The gap.** Four of the six remaining bignum files are written as parameter-
ized macros whose bodies branch on arithmetic over their own parameters —
`.if ((\i + \j) % 4 == 0)` and so on. tcc had `.rept` and nothing else: no
named macro directive at all, and no assembler conditionals either. The
conditionals were an unlisted third gap; `.macro` alone would not have
assembled a single one of those files.

**Assembler conditionals are not the preprocessor's.** tcc runs `#if` over a
`.S` file already, at an earlier layer and over preprocessor expressions.
These evaluate assembler expressions, through the existing `asm_int_expr()` —
which already had `%`, `==` and the comparisons, and already returns GAS's
`-1`/`0` — so the directives are control flow over a stack of "has an arm been
taken yet" flags, and the skipping matches `.endif` to `.if` by depth rather
than stopping at the first one it meets.

**Substitution is by token, not by text.** The body is captured once and each
expansion copies it out with every `\`+name pair replaced by the argument's
tokens. Nesting falls out of that: by the time an inner invocation inside a
body is read, the outer `\n` has already become a number, so the inner
expansion sees an ordinary argument.

The one lexer change is narrow and scoped: `\` is a stray everywhere else in
an asm file and the lexer refuses it, so `PARSE_FLAG_ACCEPT_STRAYS` is set for
exactly the span between `.macro` and `.endm`. Outside a macro body a stray
backslash is still an error.

Expansion suppresses the relaxation capture for the same reason `.rept` does
after `0016` — the definition and the invocation are both already in the
recorded stream, so a later pass re-expands them itself.

**What is not implemented is refused, not misread.** Parameter defaults
(`\name=value`), qualifiers (`:req`, `:vararg`), the per-expansion counter
`\@`, `<...>`-quoted arguments, `.purgem` and `.exitm` are all absent. The
first three produce a diagnostic naming them; that matters most for defaults,
where reading `a=5` as a parameter named `a` would make every call site
relying on the default expand to nothing, quietly. A `\` naming no parameter
is an error rather than being passed through, since passing it through puts a
stray backslash into the instruction stream to be diagnosed somewhere
unrelated. One deliberate strictness difference: GNU `as` warns on a stray
`.endm` and carries on, this tcc errors.

**Verified.** `dep/tcc/patches/0017-tests/run.sh`: **14 pass** — six accepted
files byte-identical to `as` (conditionals alone, macros alone, the two
composed the way the bignum sources compose them, nested macros, expansion
under relaxation, and macros and `.rept` nested both ways round), five inputs
`as` rejects and tcc rejects too, and three inputs `as` *accepts* which tcc
must refuse with a diagnostic rather than misread. Against an `0001`–`0016`
baseline: **8 pass, 6 fail**.

### `0018-elf-target-predefine.patch`

`0018` (tccpp.c + include/tccdefs.h) predefines `__ELF__` on every target
whose object format is ELF.

**The gap.** gcc and clang define `__ELF__` wherever they emit ELF. tcc had
one `#define __ELF__ 1`, in `include/tccdefs.h`, inside the
`#elif defined __NetBSD__` arm — so on Linux, FreeBSD, OpenBSD and Android it
was absent entirely. Hand-written assembler overwhelmingly guards its
`.note.GNU-stack` declaration as
`#if defined(__linux__) && defined(__ELF__)`, so under tcc that guard
evaluated false, the directive vanished, and the object came out unmarked —
which GNU `ld` reads as *requires an executable stack*. A file that had
correctly declared it needs nothing got the opposite outcome, and one such
object makes the whole link `RWE`.

**Why the fix is in `tccpp.c` rather than `tccdefs.h`, which is the substance
of the patch.** `tcc_predefs()` pulls `tccdefs.h` in only when `!is_asm`.
Measured, not recalled: `tcc -E -dM -x assembler` reports 13 macros against 44
for C. A macro defined in `tccdefs.h` is therefore invisible in exactly the
mode the motivating idiom lives in — a tccdefs-only fix would have looked
correct under `-E -dM -x c` while leaving the real case broken.
`0018-tests` `t1` is the case that separates the two candidate fixes.

**Scope, re-derived from tcc's output-format logic rather than per-OS.**
`tcc_output_file()` dispatches on exactly three formats, and `target_os_defs`
is already structured on that axis, so the define is placed for everything
that is not `TCC_TARGET_PE`, not `TCC_TARGET_MACHO`, and not
`TCC_TARGET_COFF` (which `tcc.h` sets for `TCC_TARGET_C67`, routing to
`tcc_output_coff()`). That leaves precisely the ELF writers: Linux/Android,
FreeBSD, FreeBSD_kernel, NetBSD, OpenBSD. The NetBSD `tccdefs.h` line is
removed as redundant — NetBSD is covered by the new scope, and now gets the
macro in assembler mode too.

**Verified.** `0018-tests/run.sh` scores 0/5 on the `0001`–`0017` baseline,
5/5 with `0018`, 5/5 against a real gcc. The baseline `t3` measures the harm
itself rather than the macro's absence: `GNU_STACK is RWE`, plus binutils
2.44's `missing .note.GNU-stack section implies executable stack`. Scope
verified by building the cross compilers — `x86_64-win32-tcc`,
`x86_64-osx-tcc` and `c67-tcc` report no `__ELF__` in either mode;
`x86_64-tcc`, `i386-tcc` and `arm64-tcc` report it in both — and the BSD arms
by preprocessing the table under each `TARGETOS_*` combination. All 21
libressl AT&T `bignum_*.S` go from 0 marked to 21 marked with gcc's flags,
`.text` byte-identical to the unpatched build in every case. LuaJIT
unaffected and measured: `lj_vm.o` byte-identical, links and runs,
`GNU_STACK RW`. libressl builds and passes `make check` 136/136 with
`libcrypto.so` byte-identical across the two builds. tcc's `tests2`: 129
tests, output identical.

### `0019-note-gnu-stack-merge-raise.patch`

`0019` (tccelf.c) makes `tcc -r` raise `SHF_EXECINSTR` on an
*input-supplied* `.note.GNU-stack` marker when another input declared
nothing, matching `ld -r`.

**The gap.** `0014` only ever *creates* the marker. When an input already
supplied the section, tcc adopted it verbatim — but `ld -r` does not: it
raises the executable flag so the undeclared input's implicit *I may need an
executable stack* survives the merge (measured, binutils 2.44). Three shapes
reached this: asm sources only with one declaring and one not; `tcc -r a.o
b.o` with no compilation at all; and `tcc -r foo.c marked.o unmarked.o`,
where compilation happens but a marker already exists so none is created. In
all three the merged object came out unflagged, dropping the requirement in
the unsafe direction.

**The question `0014` left open, and its answer.** Does raising a flag on an
input-supplied section count as rewriting it — the thing `0014-tests` `t3`
exists to forbid? Direction settles it. Raising only ever *strengthens* the
statement the section already makes; it never weakens one. An explicit `"x"`
is never cleared and an input-supplied section is never replaced, so `t3`
passes unchanged. The asymmetry has teeth: a marker executable when it need
not be costs a more permissive stack, while the reverse costs a segfault.
This is the same parity-with-the-incumbent stance `0014` took for the create
path, applied to the path `0014` could not see — the raise sits *above* the
`compiler_generated_code` gate, which the two no-compilation shapes never
reach.

**Verified.** `0019-tests/run.sh` scores 6/9 on the `0001`–`0018` baseline,
9/9 with `0019`, 9/9 against a real gcc (whose `-r -nostdlib` hands the merge
to the same `ld`). The three failures are exactly the three shapes above. Six
guards cover the seven shapes that already matched, including both ways an
over-broad rule would go wrong: a false raise where every input declared, and
inventing a marker where `ld -r` produces none. Nine `-r` shapes were measured
side by side against `ld -r` before any code was written; all nine now agree.
`0014-tests` still 11/11.

### `0020-tinyc-version-predefine.patch`

`0020` (tcc.h + tccpp.c) restores `__TINYC__` to a usable preprocessor
number. Unlike `0001`–`0019`, it fixes damage crescent's own vendoring did
to upstream rather than a gap in upstream.

**The gap.** `tcc_predefs()` builds the predefine by slicing tcc's own
version string — `"#define __TINYC__ 9%.2s"` over `&TCC_VERSION[4]`, i.e.
`"0.9.XX"` → `9XX` — and `TCC_VERSION` is whatever `./configure` (or
`win32/build-tcc.bat`) read out of the `VERSION` file. crescent overwrites
`dep/tcc/VERSION` with the vendored commit SHA, following the
`dep/<name>/VERSION` convention every vendored dep uses; mob is untagged and
rolling, so a SHA is the only pin that names this exact source. The slice then
ran over a SHA: offset 4 of `2ba12e83…` is `2e`, so tcc predefined
`__TINYC__ 92e`, which is not a number. Every `#if __TINYC__` it compiled died
with `exponent digits expected`, tcc's own `tests/tcctest.c:338` included.
Present on a pristine unpatched tree since the original vendoring commit
`9d389a37`, and reachable in asm mode too — `tcc_predefs()` runs for `.S`
input as well, which is the file kind this whole series exists to assemble.

**The fix splits the two meanings apart rather than choosing between them.**
`TCC_VERSION` keeps meaning *which commit is vendored*: it stays the SHA, and
the pin, `tcc -v`, the DWARF producer string and `tcc.1` are all untouched. A
new `TCC_UPSTREAM_VERSION` in `tcc.h` means *what this source calls itself*,
and is what the slice reads. Its value is upstream's own, not an invention —
tinycc's `VERSION` at the pinned commit is `0.9.28rc`, so upstream's rule
gives `928`, exactly what a tcc built from unmodified upstream there reports.
The alternative one-file fix — putting a real version back into `VERSION` —
was rejected because it silently discards the pin; `0020-tests` `t4` fails if
anyone tries it.

**Verified.** `0020-tests/run.sh` scores 2/5 on the `0001`–`0019` baseline and
5/5 with `0020`; the three that move are the `#if` shape, the exact value, and
the asm-mode case. Unlike `0019-tests` this is not meaningful against gcc —
`__TINYC__` is tcc's own identity macro — so the external reference is
upstream's `VERSION` file at the pinned SHA. All fourteen earlier harnesses
score identically either side of `0020`. `tcctest.c` compiled by the patched
tcc and run produces output byte-identical to the gcc-built `test.ref` (1062
lines); `test1`/`test3` themselves still failed at the time `0020` landed, one
stage later, in `-run`. That second failure was read then as a NixOS `-run`
quirk; it was not. It was `0004`, and `0021` below fixes it. A freshly
`buildvm`-generated `lj_vm.S` assembles byte-identically
either side, the resulting luajit links and runs identically (traces, ffi,
callbacks, coroutines), and `verify-bignum-att-tcc.sh` output is unchanged
line for line — none of which is surprising, since none of those sources
mention `__TINYC__`; they are the regression floor, not the demonstration.

### `0021-asm-section-name-attrs.patch`

`0021` (tccasm.c) makes a section's **name** decide its flags, the way GNU
`as` decides them, and is a correction to `0004`.

`0004` fixed a real upstream bug — tcc forced `SHF_ALLOC` into every section
`.section` created and never parsed `a` out of the flags string at all — by
making the default flags `0`. That is right for a name `as` has no opinion
about, and wrong for one it does. `as` derives flags from the name first
(binutils `bfd_elf_special_sections`, `bfd/elf.c`); the flags string only
gets to add to them. `0004` was checked against `as` on made-up names, where
the two rules agree. On recognized names they do not, and after `0004` the
ordinary hand-written spelling `.section .rodata` produced a section with no
`SHF_ALLOC` — dropped from every linked image. Four of the seven vendored
libressl `crypto/*/*-elf-x86_64.S` files (`aes`, `aesni`, `ghash`, `mont5`)
spell it exactly that way, and their constant tables were non-allocated in
every object tcc produced from them between `0004` and `0021`.

The same defect is what the `relocation '2' out of range` failure of
`make test1`/`test3` was. `tests/tcctest.c` pushes a `.long 661b - .` into
`.data.ignore`; that is a `.data.` name, so allocatable to `as`, but flagless
after `0004`. `tccrun.c` assigns run-time addresses only to `SHF_ALLOC`
sections while `tccelf.c`'s `relocate_sections()` relocates every section
that has relocations, so the `R_X86_64_PC32` (`'2'` is the relocation type
number) computed `symbol - 0` — which does not fit in int32 when `-run`'s
addresses are real heap pointers. Under `-c`/link the same subtraction is
computed against `ELF_START_ADDR`-scale values, fits, and lands in a section
nobody reads, which is why compiled output stayed byte-identical to gcc's and
only `-run` ever complained. Nothing about it was NixOS-specific or
memory-layout-specific; it reproduces identically wherever the patch stack is
applied.

The patch adds binutils' table for the entries that carry flags, reproducing
its `suffix_length` matching (`.text`/`.text.hot` but not `.textfoo`;
`.init` but not `.init.foo`), plus `as`'s precedence rule: name-implied flags
win outright unless the directive's flags string is a strict superset of
them. `.section .text,"w"` is still `AX`, `.section .rodata,""` is still `A`,
`.section .rodata,"aw"` is `WA`. The subset half of that rule is why the
patch also deletes upstream's hand-written `.init`/`.fini` →
`SHF_EXECINSTR` `strcmp`: that two-name special case was a fragment of this
table, and a plain default-if-absent rule would have broken
`.section .init,"a"`, which musl's crt asm relies on.

Two things were deliberately out of scope here and each got its own patch
immediately after: `sh_type`, derived from neither the name nor the
directive's `@type` argument (`0022` below), and `-run`'s inability to
relocate a genuinely non-allocated section — the underlying
`relocate_sections()` defect, which `0004` exposed rather than introduced
(`0023` below).

**Verified.** `0021-tests/run.sh` scores 35/61 on the `0001`–`0020` baseline,
61/61 with `0021`, and 61/61 against a real gcc — the gcc run is what makes
the expected flags a measurement of binutils 2.44 rather than this patch's
own opinion. tcc's own `make test` completes end to end for the first time in
this stack (`test1` and `test3` included), and produces results identical to
a build with `0004` dropped entirely, which is the other way to make those
tests pass and is not acceptable because it puts `0004`'s original bug back.
The four affected libressl objects gain `A` on `.rodata` and are otherwise
byte-identical, `.text` and `.rodata` contents unchanged. A freshly
`buildvm`-generated `lj_vm.S` assembles byte-identically either side and the
relinked luajit runs traces, the interpreter, coroutines, varargs and an ffi
call unchanged — `lj_vm.S`'s only `.section` directives are
`.note.GNU-stack`, `.debug_frame` and `.eh_frame`, all with explicit flags
strings and none in the table, so that axis never reaches the changed path.

### `0022-asm-section-type.patch`

`0022` (tccasm.c) is the other half of `0021`: a section's **type**, from its
name and from `.section`'s `@type` argument.

tcc left every section its `.section` directive created `SHT_PROGBITS`. It
parsed the `,@type` / `,%type` argument and threw it away — two bare `next()`
calls after the flags string — and it consulted no name table for the type at
all. So a tcc-assembled `.bss.foo` occupied file space where an
`as`-assembled one does not, and `@nobits`, the way to ask for that on a name
`as` has no opinion about, did nothing whatsoever.

The reason this was not folded into `0021` is that the precedence rule is a
different shape. For flags, name-implied wins unless the flags string is a
strict superset. For types, `as` honours a disagreeing `@type` argument —
warning `setting incorrect section type` — *except* for `SHT_INIT_ARRAY`,
`SHT_FINI_ARRAY` and `SHT_PREINIT_ARRAY`, where it keeps the name's type and
warns `ignoring incorrect section type` instead, because older gcc emitted
`.section .init_array,"aw",@progbits` for
`__attribute__((section(".init_array")))` and `as` refuses to believe it. So
`.section .bss.foo,"aw",@progbits` really is `PROGBITS` while
`.section .init_array.1,"aw",@progbits` really is still `INIT_ARRAY`. A rule
of "argument always wins" and a rule of "name always wins" each get one of
those wrong. Both directions are in the harness. Like `0021`, all of this
applies only to a section the directive is *creating*, which the handler was
already gated on; and like `0021`, `as` warns on every mismatch and tcc says
nothing, a diagnostic gap rather than a layout one.

Three rows in the table are worth naming, each measured rather than recalled.
`.note` matches **any** suffix — binutils `suffix_length == -1` — so
`.notefoo` is a note section, unlike `.text`/`.data`/`.bss`, which take a
dotted suffix only. `.note.GNU-stack` therefore needs its own exact
`SHT_PROGBITS` row ahead of `.note`, exactly as binutils lists it: `as` gives
the bare name `PROGBITS` and only `.note.GNU-stack.something` falls through to
`NOTE`. tcc records stack requirements against that section (`0014`, `0019`),
so a wrong type there would not have stayed quiet. And `.gnu.linkonce.b*` is
`SHT_NOBITS` with `WA` — a row `0021` had omitted, so `0022` closes that flags
gap in passing.

An unrecognized type name behaves as if no argument had been given, which is
`as`'s own fallback after its `unrecognized section type` warning; a bare
number is accepted, as `as` accepts it, so `@0x70000001` really does come out
`SHT_X86_64_UNWIND`.

One divergence stayed at the time: `as` refuses a non-zero store into an
`SHT_NOBITS` section and tcc dropped the bytes silently. That was not new —
tcc already did it for its own built-in `.bss` — but `0022` widened the set of
names it applies to. Zero fill was byte-identical to `as` either way. `0024`
below closes it.

**Verified.** `0022-tests/run.sh` scores 44/44 with `0022`, 44/44 against a
real gcc, and 16/44 on the `0001`–`0021` baseline. `0021-tests` still scores
61/61, so restructuring the table moved no flags. tcc's own `make test`
reaches `ALL TESTS PASSED` either side. A freshly `buildvm`-generated
`lj_vm.S` and all seven libressl `crypto/*/*-elf-x86_64.S` objects are
byte-identical either side — `lj_vm.S`'s `.note.GNU-stack,"",@progbits` now
agrees with its own name's row instead of falling to the old blanket default,
which is the same answer — and the relinked luajit runs unchanged.

### `0023-run-unplaced-section-relocs.patch`

`0023` (tccelf.c) stops `-run` relocating sections that have no runtime
address. This is the defect `0004` exposed and `0021` moved out of the way
rather than removed.

`tccrun.c` hands out runtime addresses to `SHF_ALLOC` sections only — the
`shf[]` table in `tcc_run_prepare()` matches three `ALLOC|WRITE|EXECINSTR`
combinations and nothing else — and never copies anything else into the run
memory at all. `relocate_sections()` relocated those sections anyway, against
an address they do not have, while the symbols they referred to had real heap
addresses. A PC-relative relocation computed `symbol - 0` and failed with
`relocation '2' out of range`; an absolute 32-bit one wrote the symbol's real
address and failed with `relocation 'R_X86_64_32[S]' out of range`; an
absolute 64-bit one fitted, and quietly wrote a live pointer into bytes nobody
will ever map. Linking to a file never had the problem, because a real linker
computes the same subtractions against `sh_addr == 0` and the answers, equally
unread, are no longer wild.

The recorded lead was "do not relocate non-`SHF_ALLOC` sections under
`TCC_OUTPUT_MEMORY`", flagged as needing verification because it touches DWARF.
Checking it out: the debug sections tcc's own backtrace reads are *already*
`SHF_ALLOC` under `-run`, on purpose — `tccdbg.c`'s `tcc_debug_new()` turns on
`do_backtrace` whenever `do_debug && output_type == TCC_OUTPUT_MEMORY` and
then creates `.debug_info`, `.debug_line`, `.debug_str` and `.stab` with
`shf = SHF_ALLOC`, commented "have debug data available at runtime" — and the
`rt_context` that points at them is built in `.data`. So the blanket skip
would not have broken backtraces. It would still have discarded the one
relocation that means something without an address: the dwarf-to-dwarf
`R_DATA_32DW` case subtracts the target section's own `sh_addr` back out and
yields the same section-relative offset whether or not either section was
placed. `0023` keeps that one running and skips the rest, which costs one
condition and loses nothing.

**Verified.** `0023-tests/run.sh` scores 12/12 with `0023` on both glibc and
alpine/musl, and 10/12 on the `0001`–`0022` baseline, failing exactly the two
32-bit cases with the two messages above. It cannot be pointed at gcc — `-run`
has no gcc equivalent — so instead every numeric expectation is checked twice,
once through `-run` and once by building the same source into an executable
with `$CC` and running that, which is what keeps the numbers a measurement.
The harness also carries an allocated-section control whose relocated pointer
the program dereferences, so a fix that widened into "skip relocations under
`-run`" would segfault rather than print a wrong number. `-run -g` backtraces
resolve to `file:line` unchanged in dwarf-4, dwarf-5 and stabs modes, and
tcc's own `make test` — `btest` included — reaches `ALL TESTS PASSED` either
side.

### `0024-asm-nobits-content.patch`

`0024` (tccasm.c) makes tcc refuse content it cannot represent in a
`SHT_NOBITS` section, which is what `0022`'s own "what is not fixed" note was
pointing at.

A NOBITS section has a size in the file and no bytes. tcc reserved the space,
dropped the value and said nothing, so `.long 0xdeadbeef` in `.bss.foo`
assembled quietly into four zero bytes. The silent drop predates `0022` —
tcc's built-in `.bss` always did it — but once `0022` derived the type from
the name and from `@type`, every name `as` calls NOBITS reached it.

`as` does not have one diagnostic here, it has three errors and a warning, and
which applies is a property of the directive rather than the value: the data
directives (`.byte` … `.quad`, `.uleb128`, `.sleb128`) error once per offending
**value**, the string directives once per non-zero **byte**, `.fill` once per
**directive** with its own wording, and `.skip`/`.space`/`.align` given a fill
value only **warn** — `ignoring fill value` — because the size they ask for is
exactly what a NOBITS section is for and only the fill byte is homeless. That
last row is the one a naive "error on any write" fix gets wrong. Two further
details read backwards from the obvious guess: the value is tested *before*
truncation to the field, so `.byte 256` is an error, and *after* constant
folding, so `foo: .long foo-foo` passes while `foo: .long foo` does not, a
relocation counting as non-zero whatever its addend. Instructions are not
policed at all — `nop` in `.bss` assembles and grows the section — so that path
is untouched. Errors go through `tcc_error_noabort`, so every offending value
in a directive is reported before the assembly fails, as `as` does.

**Verified.** `0024-tests/run.sh` scores 62/62 against the patched tcc and
62/62 against a real gcc — binutils 2.44 locally, and each container's own `as`
in CI — against 28/62 on the `0001`–`0023` baseline. Each case pins the
classification, the message text, and the message *count*, which is what
catches a once-per-directive rule implemented once-per-byte. `0005`–`0023`'s
harnesses all still pass, and tcc's own `make test` reaches `ALL TESTS PASSED`
on glibc and on alpine/musl either side of the patch. A freshly generated
luajit `lj_vm.S` and all seven libressl `crypto/*/*-elf-x86_64.S` objects are
byte-identical either side and draw no new diagnostics; a luajit relinked
against the tcc-assembled `lj_vm.o` runs with the JIT on.

Two gaps it deliberately does not close, both in `TODO.md`: tcc has no `.zero`
directive at all (a missing directive, not a NOBITS matter — it fails in
`.text` too), and no `.space repeat count is zero` warning (which `as` emits in
every section type).

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

The supported invocation, with both patches applied:

```bash
CC=/path/to/tcc LD=/path/to/tcc ./configure --disable-asm
```

`LD` must be set alongside `CC` — this is upstream libtool's own
documented answer ("making sure to set LD correctly now avoids
mis-matching GNU ld with tcc"). Without it, libtool probes `ld` from
`PATH`, finds GNU ld, sets `with_gnu_ld=yes`, and emits an anonymous
version script for libcrypto's `-export-symbols`; tcc implements no
`--version-script` and the link fails. Setting `LD` moves the build onto
the non-GNU-ld branch where the question never arises. `--disable-asm` is
needed for a different reason — libressl 4.3.2's s2n-bignum `.S` files
are Intel syntax and tcc's assembler is AT&T-only.

One divergence from the gcc-built libraries remains and is *not* fixed:
tcc-built libraries export their full symbol table rather than the set in
`crypto/crypto_portable.sym`. Restricting exports needs
`archive_expsym_cmds`, and both spellings libtool has for it
(`--version-script`, `--retain-symbols-file`) are linker options tcc does
not implement — a tcc feature gap, not a libtool spec gap.

See TODO.md for the verification record and for the gaps that remain
open behind it.

### libressl bignum: AT&T mirror for tcc

`--disable-asm` above is a workaround, not a fix — it drops the
hand-optimized s2n-bignum routines entirely, gcc/clang builds included would
still use them normally since those compilers accept `.intel_syntax
noprefix` directly. tcc's assembler is AT&T-only and implements no
`.intel_syntax` directive at all, so the actual fix is a second copy of
each `.S` file in AT&T syntax, kept in lockstep with the Intel-syntax
original.

`dep/libressl/crypto/bn/arch/amd64/att/` holds that copy: 21 files,
one per file in the parent directory, generated by running AWS's own
`attrofy.sed` (vendored alongside them, from `awslabs/s2n-bignum`
`x86_att/attrofy.sed` — see that directory's README for the exact
provenance commit) against each Intel-syntax original. This is upstream's
own translator — s2n-bignum ships both syntaxes for every file and
regenerates the AT&T tree from the Intel tree with this exact script as
part of its own release process, so running it here is not a novel or
untested transform.

**gcc/clang builds are unaffected and unchanged.** They keep using the
Intel-syntax originals in the parent directory via `.intel_syntax
noprefix`. The AT&T files are a parallel, tcc-only artifact — vendored
output, not vendored source, checked in (rather than generated at build
time) so the build has no dependency on `sed` or on re-deriving a
translation whose correctness has to be independently checked anyway.
**They are not wired into any build configuration yet** (see TODO.md).

#### Verification methodology

A sed translation is not trustworthy on its own — the only thing that
matters is whether the *encoded instructions* match, not whether the
text looks plausible. For each of the 21 files, both the Intel original
and its AT&T translation are assembled with real GNU `as` (via `gcc -c`)
under 4 preprocessor configurations that gate real branches in these
files' macros:

- default
- `-DWINDOWS_ABI=1`
- `-DNO_IBT=1`
- `-DS2N_BN_HIDE_SYMBOLS=1`

For each config, the two resulting objects are compared on three axes,
not just raw bytes, so that a coincidental checksum collision can't hide
a real divergence:

- `.text` section bytes (`objcopy -O binary --only-section=.text`, then
  compared directly — this is the actual encoded instruction stream)
- relocations (`readelf -rW`)
- symbol table (`readelf -sW`, filtered to name/value/type/bind/vis)

21 files × 4 configs = 84 checks. All 84 pass: the AT&T files are
byte-identical to the Intel originals in every config, as assembled by a
real assembler — not merely "the sed script ran without error." This
re-verification was re-run directly against the current
`dep/libressl/crypto/bn/arch/amd64/*.S` sources (not against a cached
copy) before these files were vendored, and should be re-run again any
time the Intel-syntax originals change (e.g. a libressl version bump) —
see the regeneration steps in `att/README.md`.

#### tcc buildability is a separate, narrower question

The byte-identity check above says nothing about whether tcc's assembler
*accepts* these files — GNU `as` compatibility and tcc compatibility are
different claims. Attempting to assemble all 21 with the vendored tcc
directly:

- **6 files reject outright**: `bignum_mul_4_8.S`, `bignum_mul_6_12.S`,
  `bignum_mul_8_16.S`, `bignum_sqr_4_8.S`, `bignum_sqr_6_12.S`,
  `bignum_sqr_8_16.S` — the ADX/BMI2 fast-path routines. Each of the four
  constructs was confirmed missing individually, with a one-line probe
  assembled by both tcc and `as`, rather than inferred from the
  first-error message: `mulxq`, `adcxq`, `adoxq` and `.macro` are each
  "unknown opcode" to tcc and each accepted by `as`. All 6 files use
  `mulx`/`adcx`/`adox`; 4 of the 6 (`bignum_mul_4_8`, `bignum_mul_6_12`,
  `bignum_mul_8_16`, `bignum_sqr_8_16`) additionally use `.macro`/`.endm`,
  while `bignum_sqr_4_8` and `bignum_sqr_6_12` fail on the opcodes alone.
  Closing this is a tcc assembler feature gap, not a translation problem —
  separate work, tracked in TODO.md.
- The other **15 files assemble under tcc, and all 15 are verified
  instruction-equivalent to the gas ground truth** — see the next section
  for how, and for the two encoding-level differences that verification
  deliberately looks past.

#### Verifying tcc's own codegen: 15/15, by three independent axes

Re-derived from scratch (2026-08-22) after two earlier, conflicting
informal reports — one claiming 15/21 verified, one deflating that to 4 —
neither of which held up. The deflated number turned out to be an artifact
of the comparison method, not a real finding, which is why the method is
written down here in as much detail as the result.

Re-runnable: `tooling/scripts/verify-bignum-att-tcc.sh <path-to-patched-tcc>`
(build tcc from `dep/tcc/` with all of `dep/tcc/patches/*.patch` applied in
numeric order; all apply cleanly at `dep/tcc/VERSION`). The counts in this
subsection are the state at `0013`; `0015`–`0017` close the remaining six —
see "21/21 after `0015`–`0017`" below.

**Byte identity is the wrong bar here, and that is the whole difficulty.**
The 84/84 check above compares two objects both produced by GNU `as`, where
raw bytes are exactly right. tcc is a different assembler, and differs from
`as` in two ways that change bytes without changing the program:

- it does not always choose the shortest encoding (e.g. `xor $0x3f,%rax`
  as `48 35 3f 00 00 00` where `as` emits `48 83 f0 3f`), and
- it does not resolve same-section *forward* branches at assembly time. It
  emits rel32 plus an `R_X86_64_PLT32` relocation against the local label
  and lets the linker finish the job. (Backward branches it resolves
  itself, so the two forms appear side by side in the same file.)

**And naive disassembly-text diffing is what produced the false report.**
`objdump` labels a jump target with the nearest *preceding* symbol it can
find. tcc's local symbol table is sparser than gas's, so the same target
address gets annotated `<f+0x30>` in one dump and `<g>` in the other. That
is `objdump` guessing, not a difference in the object.

So the comparison normalizes exactly three things, each for a stated
reason, and compares everything else:

1. **Addresses** — one longer encoding shifts every later address, so
   instructions are identified by *position* (index) and addresses are
   never compared.
2. **`objdump`'s guessed `<...>` labels** — dropped entirely. Branch
   targets are resolved through the real ELF symbol table instead.
3. **Branch form** — an assembler-resolved displacement and a
   `PLT32`-against-a-local-label relocation naming the same destination
   both reduce to "branch to instruction index N". The form difference is
   still *reported*, on separate `FORM` lines, so it is normalized for
   comparison rather than hidden.

What is compared, and must match exactly: mnemonics, all operand values
(registers, immediates, memory base/index/scale/displacement), branch
destinations, relocations against symbols the object does not define, and
the GLOBAL/WEAK symbol table (value, type, bind, visibility, name).

**Axis 1 — instruction stream, all 4 preprocessor configs.** Same configs
as the 84/84 check (default, `-DWINDOWS_ABI=1`, `-DNO_IBT=1`,
`-DS2N_BN_HIDE_SYMBOLS=1`). 15 files × 4 configs = 60 comparisons. 56 come
out identical. The remaining 4 are the same single instruction in
`bignum_sqr` in each config: `as` emits the `D1 /5` shift-by-one form
(`49 d1 ec`), tcc emits `C1 /5` with `ib = 1` (`49 c1 ec 01`). Same
operation, same count, same result; and the next instruction is
`sub %r8,%rbx`, which overwrites the flags, so even the `OF`-on-1-bit-shift
subtlety is unobservable. Global symbols match in all 60.

**Axis 2 — runtime differential.** The instruction stream cannot show what
the *linker* does with those deferred branches, so both assemblers' objects
are linked into one program (tcc's with every symbol renamed via
`objcopy --prefix-symbols=T_`, so both copies coexist) and every routine is
called next to its twin on identical inputs. 320,000 comparisons across all
15 routines — including a full sweep of `word_clz` over every leading-zero
count, which random inputs alone would not cover — with **0 mismatches**.
Default config only: `-DWINDOWS_ABI=1` changes the calling convention, so
those objects cannot be called from this ABI.

**Axis 3 — link behavior of the deferred branches.** `R_X86_64_PLT32`
against a *local* label is unusual enough to check rather than assume. The
15 tcc objects were also linked with `-shared`, the case where a PLT
indirection would actually be possible: the resulting `.so` has no PLT
entries and no dynamic relocations for any of those labels — the linker
resolved every one of them directly. The runtime harness above is itself a
PIE, so the position-independent case is covered at runtime too.

**Cost, not correctness:** the deferred branches make tcc's `.text` larger
— `bignum_add` is 219 bytes against gas's 185, `bignum_sub` 191 against
170. The 6 `_alt` files that contain no forward branches come out
*byte-identical* to gas.

**One real defect found, unrelated to these files.** tcc emitted no
`.note.GNU-stack` section in *any* object it produced (`-c` on `.c` sources
too, not just `.S`), so GNU `ld` marked the linked program's stack
executable — the verification harness linked with `GNU_STACK ... RWE`.
`0008-pt-gnu-stack.patch` fixed this for tcc acting as the *linker* (it
emits the `PT_GNU_STACK` program header in its own output). The
object-emission side is closed by `0014` for compiled objects and by `0018`
for these `.S` files, whose own guarded directive tcc could not see until
`__ELF__` existed. The harness now reads `gas=1 tcc=1` where it read
`gas=1 tcc=0`.

#### 21/21 after `0015`–`0017`

The six files the 15/15 pass could not assemble were blocked on three missing
capabilities, not two: the ADX/BMI2 opcodes (`0015`), `.macro`/`.endm`, and —
the one that was not on the original list — `.if`/`.elseif`/`.else`/`.endif`
(both `0017`). `bignum_sqr_4_8` and `bignum_sqr_6_12` needed only the opcodes;
the other four needed all three, since their macro bodies are conditionals
over their own parameters and a macro directive without `.if` would not have
assembled any of them.

Same harness, same three axes, extended to cover all 21:

- **Axis 1 — instruction stream, all 4 configs.** 21 files × 4 configs = 84
  comparisons; **80 identical, 0 rejected**. The remaining 4 are the same
  pre-existing single instruction in `bignum_sqr` in each config (`shr $1`,
  `D1 /5` against `C1 /5 ib`) that the 15/15 pass already recorded — unchanged
  by this work, and the only difference in the whole set.
- **Axis 2 — runtime differential.** Extended from 15 routines to 21, and
  each of the six new ones is checked *twice*: against its own tcc-assembled
  twin, and against the `_alt` routine beside it, which is an independent
  implementation of the same function from base-ISA instructions. 368,000
  comparisons, **0 mismatches**. The harness now guards the ADX/BMI2 routines
  behind a CPUID check, since on a host without those features calling them
  is `SIGILL` rather than a wrong answer.
- **Axis 3 — link behavior.** Unchanged; the six new files add no new
  relocation shapes.

**Regression, against the `0001`–`0014` build.** Every earlier patch harness
(`0005`, `0006`, `0007`, `0009`, `0010`, `0011`, `0012`, `0013`) produces
output identical to the baseline, and tcc's own `make test` stops at the same
pre-existing environmental point with the same output. A freshly
`buildvm`-generated `lj_vm.S` assembles to a **byte-identical object** — same
hash over the whole `.o` — and the LuaJIT linked from it runs with the JIT on,
through trace compilation, FFI, `pcall` unwinding, deep recursion unwind,
coroutines and GC churn. That last one is a negative control in the strict
sense: the generated `lj_vm.S` contains no macro or conditional directive and
no ADX/BMI2 instruction at all, so what it establishes is the absence of
collateral damage, not the presence of the new features.

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
