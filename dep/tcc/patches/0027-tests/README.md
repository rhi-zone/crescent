# Base-less SIB operand test cases (for `0027-asm-nobase-sib-operand.patch`)

Assembly inputs for GAS's base-less SIB memory operand, `(,%reg,scale)`, plus
a harness that diffs a tcc build's output against real GNU `as`.

    ./run.sh /path/to/patched/tcc

Each case is compared on the bytes of `.text` and `.data` plus the normalized
relocation table. Bytes, because that is the whole claim — none of these cases
are executed, and several would fault if they were.

Against the `0001`–`0026` baseline the same harness reports `pass=5 fail=4`:
`t0` and `t1` pass (they are the controls, and both already worked), `t2`,
`t3` and `t4` fail with `bad expression syntax [,]`, and the scale-equivalence
check fails for want of an object to compare.

The whole script also passes unchanged against a real gcc
(`./run.sh "$(command -v gcc)"`), which is what makes it a reference rather
than this patch's own opinion.

| case | what it pins down |
|---|---|
| `t0_base_control` | base-ful SIB, including the `%rsp`/`%rbp`/`%r12`/`%r13` corners and the parenthesised-displacement spelling; passes before and after |
| `t1_nobase_disp_control` | base-less SIB *with* a leading displacement — already correct before the patch, so it is what proves the encoder half was never the problem |
| `t2_nobase_bare` | the spelling that was actually missing: all four scales, the omitted scale, and `(0)(,%reg,scale)` |
| `t3_nobase_index_regs` | every index register, so REX.X (`%r8`–`%r15`) and the 32-bit `0x67` address-size forms are covered, and `%rbp`/`%r13` are shown not to drag their base-slot behaviour into the index slot |
| `t4_nobase_instr_classes` | the same operand across memory-destination, immediate-plus-memory, group-opcode, `lea`, indirect `jmp`/`call`, legacy-SSE and VEX (`mulx`) encoder paths |

## Where the gap actually was

Narrower than "tcc rejects `(,%reg,scale)`". `8(,%rax,8)` and `sym(,%rax,8)`
assembled byte-identically to `as` before the patch — that is `t1`, and it
passes against the pre-patch baseline. Only the *bare* form, where the operand
begins with `(` immediately followed by `,`, was rejected.

`parse_operand()` in `i386-asm.c`, on seeing an operand that starts with `(`,
has to decide between a parenthesised displacement expression (`(4+4)(%rax)`)
and an address with no displacement at all (`(%rax)`). It decided by looking
for `%`, and everything else went to `asm_expr()` — where a leading comma is
a syntax error. Reaching that branch at all requires the operand to *start*
with the parenthesis, which is why the leading-displacement spellings were
unaffected.

`asm_modrm()` already handled a missing base: it substitutes `SIB.base=101`
with `mod=00` and forces a four-byte displacement. So this is a parser fix
with no encoding change, and `t1` is the evidence for that claim rather than
an assertion of it.

## What `as` does

Measured against the binutils on the machine the patch was written on, before
writing it:

    mov (,%rax,8),%rbx      ->  48 8b 1c c5 00 00 00 00
    mov (,%rax,1),%rbx      ->  48 8b 1c 05 00 00 00 00
    mov (,%rax),%rbx        ->  48 8b 1c 05 00 00 00 00
    mov 0x10(,%rax,8),%rbx  ->  48 8b 1c c5 10 00 00 00

Two things there are the parts an implementation gets wrong, so the harness
asserts both directly rather than leaving them to the per-case diffs:

- **The displacement is always four bytes.** A small one does not shrink to
  the `disp8` encoding that the base-ful form would use — `mod=00` with
  `SIB.base=101` *means* "disp32 follows", there is no shorter spelling. The
  `disp32/` check compares `.text` sizes for the same displacement written
  base-less and base-ful and requires exactly three bytes of difference.
- **An omitted scale is scale 1**, not an error. The `equivalence/` check
  assembles the same instruction both ways and requires one object.

Both are asserted in `as` (the premise) as well as in tcc (what 0027 has to
reproduce).

## Deliberately absent

**`%rsp` in the index slot.** `as` rejects `(,%rsp,8)` —
`not a valid base/index expression`. tcc accepted it, and accepted the base-ful
`(%rax,%rsp,4)` before 0027 too, assembling it to an encoding `objdump` reads
back as `%riz`: `SIB.index=100` is the architectural "no index" code, and tcc
never validated a written index register against it. That was a pre-existing
missing-diagnostic gap, unrelated to which spellings parse; `0032` closed it
and `0032-tests/` owns those cases. A case here would test neither assembler
agreement nor 0027's change.

**32-bit (`-m32`) targets.** The changed code is in the shared `i386-asm.c`
and applies to both, but the vendored build is x86_64-only, so there is
nothing to compare against. The 32-bit *index* forms (`(,%eax,4)`, which take
the `0x67` address-size prefix) are in `t3` and do exercise the same path.

**Instructions outside the vendored opcode table.** `shlx` and `andn` were
tried in `t4` and are not in this tcc — `0015` added a subset of BMI2, not all
of it. Missing opcodes are that patch's scope, not this one's, so `t4` uses
`mulx`, which is present.
