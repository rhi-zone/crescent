# Suffix-less 64-bit `bswap` test cases (for `0034-asm-bswap-reg64.patch`)

A harness that checks a tcc build accepts `bswap` with a 64-bit register and
no size suffix, and that everything else about `bswap` and its neighbours in
the opcode table is byte-for-byte unchanged against real GNU `as`.

    ./run.sh /path/to/patched/tcc

65 checks, no committed `.S` files — every case is an instruction or two and
they are generated in a temp directory. The last five are C programs, for the
reason below.

## The gap

`x86_64-asm.h` gave `bswap` a single form, `OPT_REG32`, with explicit
`bswapl` and `bswapq` beside it. So the suffix-less 64-bit spelling had no
entry to match:

    bswap %rax   ->  error: bad operand with opcode 'bswap'

`as` assembles it as `48 0f c8` without comment. The patch is one `ALT()`
giving `bswap` an `OPT_REG64` form with `OPC_48`, mirroring the `bswapq` row
directly below it.

This is a rejected-valid-input gap, not a silent-miscompile one — nothing was
assembled wrongly, the input simply could not be assembled at all.

## Why it was a live blocker

luajit's `lj_def.h` defines `lj_bswap64` on x86_64 as

    __asm__("bswap %0" : "=r"(r) : "0"(x))

and the compiler substitutes a 64-bit register into `%0`, so what reaches the
assembler is exactly the rejected form: no suffix, `%r..` operand. luajit did
not compile under tcc until this landed. That is why the harness ends with C
programs that are compiled *and run* rather than only assembled — the C path
is the real trigger, and the programs return non-zero unless every byte-swap
produces the right value, so they pin the bytes computed and not merely that
compilation stopped failing.

## What this pins, and what it deliberately does not

It pins **the byte-for-byte encoding of everything accepted**, with `as` as
the reference, and **the set of inputs refused**. It pins no message text, in
either direction.

The accepted half has nothing to argue about: `parity` compares section bytes
and relocations, not a disassembly rendering, so a row either matches gas or
it does not.

For the refused half the two assemblers agree on *which* inputs are invalid
and share no wording at all for saying so:

| input | `as` | tcc |
|---|---|---|
| `bswap %ax` | operand size mismatch for `bswap` | bad operand with opcode 'bswap' |
| `bswapw %ax` | invalid instruction suffix for `bswap` | unknown opcode 'bswapw' |

The second row is not even the same *kind* of complaint — as knows the
mnemonic and rejects the suffix, tcc has no such token. This patch adds a
table entry and touches no diagnostics, so `refused` asserts only that
neither assembler quietly emits something. A wrong encoding here would be a
silent miscompile; a differently-worded sentence is not, and matching as's
wording is a separate patch about messages.

Every `refused` row also runs the input through `as` first and fails if `as`
accepts it, so a row cannot quietly decay into a claim about tcc alone.

That is what lets the whole script pass unchanged against a real gcc
(`./run.sh "$(command -v gcc)"`), making `as` the reference rather than this
patch's own opinion.

## The 16-bit claim, measured rather than assumed

The line above the entry in `x86_64-asm.h` says *bswap can't be applied to
16bit regs*. That was checked instead of taken on trust. `as` and tcc both
refuse `bswap %ax`, `bswap %bx`, `bswap %r8w`, `bswapw %ax`, and the
mismatched `bswapl %ax` / `bswapq %ax` — before and after this patch, on
different wording each time. Those rows are in the harness to keep the
agreement, without asserting either assembler's sentence.

## The cases

| group | what it holds |
|---|---|
| the gap | suffix-less `bswap` on all eight legacy 64-bit GPRs |
| REX.B | `%r8`–`%r15`, where the register-extension bit rides alongside `OPC_48`'s REX.W |
| 32-bit | the form the table already had, legacy and extended, unregressed |
| explicit suffixes | `bswapl`/`bswapq`, including that `bswap %rax` and `bswapq %rax` encode identically |
| macro replay | inside `.macro` and `.rept` |
| table neighbours | `xadd`, `cmpxchg`, `cmpxchg8b`, `cmpxchg16b`, `invlpg`, `str`, `bsf`/`bsr`/`bt` |
| refused by both | 16-bit and 8-bit registers, memory, immediate, `%xmm`, `%fs`, `%cr0`, no operand, two operands, mismatched suffixes |
| C, compiled and run | luajit's `lj_bswap64` verbatim, its 32-bit sibling, both widths together, explicit suffixes, and a 64-iteration loop |

The neighbour rows are there because inserting an `ALT()` shifts the table
and extends a chain; `str` is the group immediately above `bswap` and the one
most exposed to that.

`%rsp` and `%r12` are in the 64-bit rows for the usual reason — their low
three bits are `100b`, which is where an encoding written against the wrong
field breaks.

## Baselines

| build | result |
|---|---|
| the stack up to `0033` | `pass=43 fail=22` |
| plus this patch | `pass=65 fail=0` |
| a real gcc | `pass=65 fail=0` |

The 22 that failed are the sixteen suffix-less 64-bit registers, the
same-encoding row, the two macro-replay rows, and the three C programs whose
inline asm reaches a 64-bit register. The 43 that already passed — the 32-bit
forms, the explicit suffixes, every neighbour, every refusal — are exactly
what this patch must not disturb.

The gcc cross-check was run here against binutils 2.44 and gcc 15.2. CI
invokes every harness against the built tcc only, so nothing in this one's CI
result depends on which binutils the container ships.

## Deliberately absent

**`str %rax`.** It is in the ALT chain immediately above `bswap`, so it
belongs in the neighbour group, but its 64-bit row is left out: gas encodes
`str %rax` as `0f 00 c8` and disassembles it back as `str %eax`, while tcc
emits `48 0f 00 c8` from the `OPC_48` ALT already in the table. Both encodings
execute the same way — `str` writes 16 bits and zero-extends regardless — but
the bytes differ, and they differ **identically before and after this patch**,
measured against a build of the `0001`–`0033` stack. It is a pre-existing
divergence with its own cause and is not this patch's to close or to pin.
`str %ax` and `str %eax` are in the harness and do match.

**`swapgs`.** Also in the neighbourhood, and also a pre-existing divergence:
`as` assembles it, tcc answers `bad MODR/M opcode without operands`. Same on
the `0001`–`0033` build, so likewise not this patch's business. Left out
rather than pinned as "refused", since `as` accepts it and a `refused` row
here would assert the opposite of the truth.

**`-m32` targets.** The `bswap` rows live in `x86_64-asm.h`, which the 32-bit
target does not read; the vendored build is x86_64-only, so there is nothing
to compare against. The 32-bit *register* forms are covered above and do
exercise the neighbouring entry.

**Message wording.** Covered in "What this pins" above — a separate patch, if
it is ever worth one.
