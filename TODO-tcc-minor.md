# tcc: deferred, lower-priority gaps

Items moved out of `TODO.md` because full parity/implementation isn't needed right
now — nothing currently vendored depends on either, and both hit real scoping
questions (per-target divergence, or feature/diagnostic slicing) that make "just
implement it" the wrong next step. Kept here rather than deleted per the
"write things down" convention; move back to `TODO.md` if a vendored target ever
needs one of these.

- [ ] **tcc's 2-byte data directives reject *any* symbol-bearing operand.** Found while
  building `0012`'s test cases (a `.short sym` line in the control case failed on the
  unpatched tcc, which is how it was distinguished from anything `0012` introduced).
  `.value` inherits it by being an alias, which is correct — the gap belongs to
  `.short`/`.word`. Nothing currently vendored needs it: all seven libressl
  `*-elf-x86_64.S` files and `lj_vm.S` assemble without it.

  **Re-derived 2026-08-22; the earlier wording of this item was wrong twice.** `.short
  sym-.` does *not* work, and this is not specific to 16-bit relocations. Every
  symbol-bearing 2-byte form errors `constant expected`: `sym`, `sym+4`, `sym-4`, a local
  label, `lab - .`, `ext - d1`, and a forward same-section difference `d2-d1`. Only an
  expression that folds to a pure constant passes. `asm_data`'s `size == 2` arm in
  `tccasm.c` has no symbol path at all and goes straight to `expect("constant")`; the
  `.short sym-.` case reaches it because `asm_expr_sum()`'s PC-relative branch leaves
  `pe->sym` set with `pcrel=1`, not because a relocation was attempted.

  Measured against binutils 2.44: `.short sym` → `R_X86_64_16`, addend 0, with `+4`/`-4`
  riding in the addend; a local label reduces to the section symbol plus offset;
  `sym - <same-section label>` and `sym - .` → `R_X86_64_PC16` with addend equal to the
  relocation's own offset; stored bytes zero (RELA). On overflow `as` warns and truncates
  for a literal (`.short 70000`) but for a symbol parks the oversized addend in the
  relocation silently and lets `ld` fail with "relocation truncated to fit"; `ld` also
  refuses `R_X86_64_16` outright under PIE.

  **The x86_64 assembler half is prototyped and matches `as` byte-for-byte** on content and
  relocation type/addend (`gen_addr16`/`gen_addrpc16` in `x86_64-gen.c`, `gen_expr16` in
  `i386-asm.c`, `size == 2` routed to it). It is not landed, because closing it needs two
  calls that are the owner's and not the implementer's:

  1. **How many targets.** `asm_data` is shared by every target and tcc's own `make test`
     cross-builds i386/arm/arm64/riscv64/c67, so an x86-only hook fails the cross-test with
     `unresolved reference to 'gen_addr16'`. The per-target answers are not uniform: i386
     has `R_386_16`/`R_386_PC16` (already in `i386-link.c`, but gated to
     `--oformat=binary`), arm64 has `ABS16`/`PREL16`, arm has `ABS16`, and riscv64's psABI
     has no absolute 16-bit relocation at all (only `ADD16`/`SUB16`), so there the right
     behaviour is probably still to reject — divergent per-target semantics that would be
     minted rather than measured, since there is no cross assembler on hand to observe.
  2. **The linker side on x86_64.** `x86_64-link.c` has no `R_X86_64_16`/`PC16` support, so
     with the assembler fix in, `tcc x.S -o prog` fails loudly (`Unknown relocation type
     for got: 12`) instead of `constant expected`. No silent corruption either way, but the
     feature half-works. i386's policy ("can only produce 16-bit binary files") is a
     real-mode thing that does not transfer, and `ld`'s own policy is split (refuse under
     PIE, truncation error otherwise) — more than one defensible answer and no reference to
     copy.

  Two things worth knowing whichever way it goes. Baseline tcc already emits a spurious
  `R_X86_64_PC32` where `as` folds a forward same-section difference to a constant
  (`.long d2-d1` in `.data`: `as` gives `04 00 00 00` and no relocation, tcc a relocation
  and zeros) — same linked value, a representation divergence rather than a bug, but it
  means a `.short d2-d1` harness case would MISMATCH for a pre-existing reason. Same story
  for local-label-vs-section-symbol reduction, which `.long sym` already diverges on today.
  A harness here therefore needs a `.long` control case to show both divergences are
  pre-existing and shared, or the normalization looks like the patch's own opinion. And
  `.byte sym` (`R_X86_64_8`) is the same hole one size down, open under any of these
  directions.

- [ ] **tcc's `.section` flags-string parser only understands `a`, `w`, `x`.** GNU `as` also
  takes `M`/`S` (mergeable/strings, with the entity-size and group operands that follow),
  `G` (group), `T` (`SHF_TLS`), `e` (`SHF_EXCLUDE`), `o` (`SHF_LINK_ORDER`), `R`
  (`SHF_GNU_RETAIN`) and `d`/`l` (`SHF_GNU_MBIND` / `SHF_X86_64_LARGE`). tcc silently drops
  them: `.section .foo,"awT"` comes out `WA` where `as` gives `WAT`. `0021` masks the two
  cases that matter most today — `.tdata`/`.tbss` get `SHF_TLS` from their names — but a
  non-special name with an explicit `T` still loses it. Also `as` warns on both directions
  of a special-section flags mismatch (`ignoring changed section attributes` / `setting
  incorrect section attributes`) and tcc says nothing; that is a diagnostic gap, not a
  layout one. Related: the table omits `.lrodata`/`.ldata`/`.lbss`, which `as` marks
  `SHF_X86_64_LARGE` — tcc has no large code model and no name for that flag in its `elf.h`.
  (`.gnu.linkonce.b*`, also missing from `0021`, was added by `0022`.)

  **Measured 2026-08-22 against binutils 2.44, and it does not close as one patch.** Two
  claims above needed correcting and the rest splits three ways with different costs, so
  the scope is an open call rather than an implementation detail.

  Corrections. `as` does not *warn* on an unrecognized flag character — it is a **Fatal
  error**, exit 1, no object written: `bad .section directive: want a,l,w,x,M,S,G,T in
  string`. And that message does not describe the accepted set: characters silently
  accepted are `a e l o w x R S T`, the digits `0`–`9`, and `? + -`; `d` is accepted and
  sets `D`; `M` and `G` are accepted but demand an operand (`entity size for SHF_MERGE not
  specified` / `group name for SHF_GROUP not specified`); everything else is fatal. The
  meaning of the digits and of `? + -` was not determined.

  What tcc does today with each, measured side by side: `awT`/`awe`/`awR`/`awd` all come
  out `WA` where `as` gives `WAT`/`WAE`/`WAR`/`WAD` — silently dropped, as recorded. But
  `aMS,…,1`, `axG,…,mygrp,comdat` and `ao,…,.bar` are **not** silently dropped: tcc errors
  `end of line expected`, because the extra operand after the type is grammar it has never
  seen. Loud rejection, not wrong output.

  The three slices:

  1. **Plain bits, no grammar change** — `T` (`SHF_TLS`), `e` (`SHF_EXCLUDE`), `R`
     (`SHF_GNU_RETAIN`), `d` (`SHF_GNU_MBIND`). Parsing only; `0021`'s name-attribute
     override does not interfere, since a non-special name has no `attr` to win over the
     string. `T` is the one with downstream machinery already present (the linker handles
     TLS sections via the `.tdata`/`.tbss` name entries). `e`/`R`/`d` would be bits tcc
     records for a real `ld` and does not itself act on — defensible for object output,
     but it is a decision about what "supported" means here, not a measurement.
  2. **Extra-operand flags** — `M`/`S` (entity size → `sh_entsize`), `G` (group name plus
     linkage → a COMDAT `.group` section, an ELF feature tcc's linker does not have), `o`
     (linked section → `sh_link`). Each needs the operand grammar *and* the machinery
     behind it. Real feature work, and `G` is the largest by a wide margin.
  3. **The unrecognized-character diagnostic** — matching `as` means turning silence into
     a fatal error, i.e. tcc starts rejecting inputs it accepts today. Whether that is
     wanted, and whether the oddities in `as`'s accepted set (digits, `? + -`) get
     reproduced or just not-rejected, are both calls to make before writing anything.

  `l` (`SHF_X86_64_LARGE`) stays out under any of these: tcc has no large code model, so
  there is nothing to derive the flag *for* — same reason the `.lrodata`/`.ldata`/`.lbss`
  name-table entries stay out, noted above.

- [ ] **`str %rax` and `swapgs`: two pre-existing divergences from `as` in the same
  opcode-table neighbourhood as `bswap`.** Found 2026-08-22 while building `0034`'s test
  harness, and measured against the `0001`–`0033` baseline as well as the patched tree —
  both predate `0034` and neither is caused by it.
  - `str %rax`: gas encodes it `0f 00 c8` (and disassembles that back as `str %eax`,
    since the instruction stores into a 16-bit selector regardless). tcc emits
    `48 0f 00 c8` from an `OPC_48` `ALT()` entry already in the table — a spurious REX.W.
    `str %ax` and `str %eax` agree between the two.
  - `swapgs`: gas assembles it; tcc rejects it with `bad MODR/M opcode without operands`.
    Its table entry is `DEF_ASM_OP0L(swapgs, 0x0f01, 7, OPC_MODRM)`, i.e. a no-operand
    form that still asks for a MODR/M byte.
  Both are system/privileged instructions that nothing vendored uses — no libressl
  `*-elf-x86_64.S` file and no LuaJIT `lj_vm.S` contains either — which is why they sit
  here rather than in `TODO.md`. `0034-tests/run.sh` deliberately does not pin either one:
  a "refused" row for `swapgs` would assert the opposite of what `as` does, and the
  `str` row there is narrowed to the two widths that agree. The byte evidence for both is
  written up under "Deliberately absent" in `0034-tests/README.md`.
