# SIB index-register test cases (for `0032-asm-index-register-rsp.patch`)

A harness that checks a tcc build refuses `%rsp` / `%esp` written in the SIB
**index** slot, and that everything else about index and base parsing is
byte-for-byte unchanged against real GNU `as`.

    ./run.sh /path/to/patched/tcc

50 checks, no committed `.S` files — every case is an instruction or two and
they are generated in a temp directory.

## The gap

`SIB.index == 100b` is the architectural "no index" code, so register 4 has
no encoding as an index at all. `as` refuses the operand; tcc encoded it as
the index-less form, which `objdump` reads back as `%riz`:

    mov (%rax,%rsp,4),%rbx   ->  48 8b 1c a0   mov (%rax,%riz,4),%rbx

Different code than was written, with no diagnostic — the silent-miscompile
shape, not a wrong-message one. It predates `0027`: it reproduces on the
base-ful form against the `0001`–`0026` baseline, and `0027` extended the
same silence to the base-less `(,%rsp,8)` spelling.

## Why the detection is the whole condition

`parse_operand()` leaves the index register in `op->reg2` as a plain 0–15
register number. `%rsp`/`%esp` is exactly `4`; `%r12` is `12`, because REX.X
extends the field *upwards* and never aliases anything back onto 4. So
`op->reg2 == 4` is not a heuristic — it is the complete and exact
characterisation of the invalid operand, and it cannot catch a legitimate
form. The parity half of this harness is what holds that claim to account
rather than asserting it.

## What this pins, and what it deliberately does not

It pins **the set of inputs refused**, with `as` as the reference, and the
**byte-for-byte encoding of everything still accepted**. It does not pin the
message text.

`as` echoes the operand *as written in the source, unevaluated*: `2*4(...)`
keeps its arithmetic, `foo+8(...)` keeps its symbol, `(%rax,%RSP,4)` keeps
its case, `%fs:` prefixes are included, odd whitespace comes back in as's own
scrubbed form. By the time tcc knows the operand is invalid it has folded the
arithmetic and dropped every one of those distinctions, and nothing in
`i386-asm.c` echoes operand source text at all — matching `as` literally
would mean building source-span capture, which has a hole of its own under
`.macro`/`.rept` replay where there is no backing text to quote.

**Owner call, 2026-08-22:** diagnose in tcc's own idiom instead. tcc says

    error: %rsp cannot be used as an index register

phrased after the existing `can't encode register %%%ch when REX prefix is
required` in the same file. The two assemblers' sentences overlap on exactly
two things — the register named and the word *index* — and that intersection
is what the `bad` cases assert. Which is why the whole script still passes
unchanged against a real gcc (`./run.sh "$(command -v gcc)"`), making it a
reference rather than this patch's own opinion.

## The cases

| group | what it holds |
|---|---|
| spellings | scale 1/2/4/8, omitted scale, disp8/disp32/negative/folded/symbolic, base-less, segment prefix, odd whitespace |
| operand positions | memory destination, immediate group opcode, `lea`, indirect branch, legacy SSE, VEX (`0015`'s `mulx`), single-operand group |
| 32-bit | the `0x67` forms, which report `%esp` and not `%rsp` |
| macro replay | inside `.macro` and inside `.rept`, the paths with no source line to quote |
| refused by both, worded differently | `%riz` written out, and `%r4` — the numeric spelling tcc accepts and `as` does not |
| parity | `%rax`/`%rbp`/`%r12`/`%r13`/`%ebp`/`%eax` as index, with and without a base |
| parity | `%rsp`/`%esp` as a **base**, which is a different field and always valid, plus a whole ordinary prologue/epilogue |

The parity rows are the ones that matter for "nothing legitimate got caught".
`%r12` is in there twice on purpose: its low three bits *are* `100b`, and it
is the register a detection written against the encoded field rather than the
parsed one would break.

## Baselines

| build | result |
|---|---|
| the stack up to `0031` | `pass=20 fail=30` |
| plus this patch | `pass=50 fail=0` |
| a real gcc | `pass=50 fail=0` |

The 20 that already passed are the parity rows and `%riz` — i.e. exactly the
behaviour this patch must not disturb; the 30 that failed are every
index-slot rejection.

## Deliberately absent

**`%riz` as an accepted index.** `as` takes `(%rax,%riz,4)` as an explicit
request for the no-index encoding; tcc has no such token and answers
`register expected`. Both refuse *this patch's* inputs, so there is no silent
miscompile either way — teaching tcc `%riz` is a separate feature, not part
of closing this gap, and it is asserted here only as "refused", not as
"refused with as's reason".

**`-m32` targets.** The check is in the shared `i386-asm.c` and applies to
both, but the vendored build is x86_64-only, so there is nothing to compare
against. The 32-bit *addressing* forms are covered above and do exercise the
same code.
