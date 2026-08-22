# `.octa` test cases (for `0036-asm-octa-directive.patch`)

Assembly inputs for the `.octa` data directive, plus a harness that diffs a tcc
build's data bytes against real GNU `as` (binutils 2.44).

    ./run.sh /path/to/patched/tcc

`.octa` carries a constant and nothing else — no encoding freedom, no
relocation — so byte identity is the only meaningful bar, and the failure that
matters most (a 16-byte operand assembled at the wrong width, or with its two
64-bit halves swapped) is invisible in anything but the bytes.

## Why there is a third and fourth category

`as` accepts more operand forms for `.octa` than this patch does, deliberately.
Its documented contract is "zero or more bignums", and that is what tcc
implements here, plus one leading unary operator. Arithmetic, symbols and
character constants are refused.

The reason is what `as` emits for the upper 8 bytes of an expression operand.
It is not a sign extension of the value; it is `as`'s own `X_extrabit` flag
propagated through the operators, and it is visibly wrong on its own terms
(all measured against binutils 2.44):

| operand | `as` emits |
|---|---|
| `.octa 2-1` | `1`, with every bit of the upper half set |
| `.octa 1==1` | all ones |
| `.octa 0xffffffffffffffff` | zero-extended |
| `.octa 0-1` | sign-extended — the same 64-bit value as the row above |
| `.octa -0` | zero low half, all-ones upper half |

It is not even self-consistent between bases: 2.44 emits zero for 2^64 written
in octal while emitting the right value for the same number written in hex or
decimal, and the right value again for octal literals one digit longer — a
narrow band of its number lexer, found by fuzzing random literals in all four
bases against it. All of the above is measured against binutils 2.44.

Matching that byte for byte means reimplementing an `as` bug as a
specification. The alternative — widening tcc's expression evaluator, which is
64-bit end to end (`ExprValue` is one `uint64_t`) — would mean a hand-built
128-bit arithmetic subsystem, long division included, since tcc has no
`__int128`, and it would *still* disagree with `as` wherever that flag fires.
So operand forms that cannot be assembled into bytes that agree with `as` are
rejected instead, loudly. `d*` pins that rejection; `x*` pins the accepted
forms where `as`'s own answer is an artifact — there, tcc's bytes are pinned
against an `.expect` file and whether the local `as` agrees is reported and
never asserted, so the harness tracks tcc rather than whichever binutils is
installed.

Both real users in the tree — libressl's `crypto/sha/sha1_amd64_shani.S` and
`crypto/sha/sha256_amd64_shani.S` — are bare hex literals.

## Cases

| case | what it pins down |
|---|---|
| `t0_shani_masks` | the two operands that motivated the patch, copied from the libressl files with their `.align 16` context |
| `t1_bases` | every base a PPNUM can carry — hex in both cases, decimal, octal, binary — and bare `0`, where the leading zero is the whole literal |
| `t2_widths` | every 32-bit limb boundary the value crosses, the point where it stops fitting the `uint64_t` that `.quad` would have used, and the full 128-bit width |
| `t3_unary` | one leading `+`, `-` or `~`, restricted to the spellings where `as` answers from the value rather than from its extrabit flag, so a true 128-bit negate/complement is what it emits too |
| `t4_operand_lists` | several operands per directive, an empty operand list, and `.octa` interleaved with `.byte`/`.quad`/`.long` so a miscount of the 16 bytes shifts a *neighbour* rather than only corrupting `.octa` output |
| `t5_truncation` | operands wider than 128 bits, which `as` truncates with a warning rather than refusing — so the bytes are part of the comparison, not just the acceptance |
| `t6_macro_rept` | `.octa` reached through the `.rept` and `.macro` replay paths `0016` and `0017` added, including a macro argument that expands to a unary operator plus a literal |
| `n0_symbol_operand` | `as` refuses to relocate at this width ("cannot do unsigned 16 byte relocation"); no 128-bit absolute relocation exists to emit |
| `n1_junk_after_operand` | two literals with no comma; a parser that stopped at the first would silently drop the second |
| `n2_local_label_ref` | `1f` lexes as one PPNUM exactly as a number does, so the digit-string parser has to reject the trailing `f` rather than read it as a hex digit |
| `n3_nobits_nonzero` | `0024`'s rule at this width — a NOBITS section has a size and no bytes — with the same message `as` uses |
| `d0_arithmetic` | `.octa 1+2`; refused rather than routed through the 64-bit evaluator |
| `d1_absolute_symbol` | a `.set` symbol, which is an expression operand as far as this directive is concerned |
| `d2_char_constant` | `'a'`; accepted by `as`, not an integer literal token |
| `d3_chained_unary` | `- -1`, where `as`'s extrabit flag becomes visible even on an otherwise-literal operand |
| `d4_trailing_comma` | `.octa 1,`; `as` warns and assumes a zero. Only the *first* operand may be absent, which is what makes the empty `.octa` in `t4` legal and this one not |
| `d5_empty_prefix` | `0x` with no digits after it |
| `x0_negative_zero` | `-0`: a 128-bit negate of zero is zero; 2.44 sets its extrabit instead |
| `x1_complement_narrow` | `~` on a value that fits in 64 bits, where `as` fills the upper half from the same flag as `x0`. 2.44 happens to agree; that is not something to hold it to |
| `x2_octal_band` | 2^64 and 2^65 written in octal, which binutils 2.44 emits as zero while getting the same values right in hex, in decimal, and in octal one digit longer |

## Against the `0001`–`0035` baseline

10 pass, 10 fail: every `t*` and `x*` case fails, because `.octa` does not exist
there at all (`unknown opcode '.octa'`). The `n*` and `d*` cases pass for that
same wrong reason — the same footnote `0033`'s harness carries.

## Beyond the fixed cases

The limb arithmetic was also fuzzed against `as` directly: 200 random hex
literals of 1–33 digits, and 450 random decimal, octal and binary literals
including many wider than 128 bits, comparing the emitted bytes. Everything
agreed except the octal band `x2` now pins, which is what turned that `as`
artifact up in the first place. The sweep is not part of `run.sh` — it needs a
generator and it is not reproducible run to run — but it is worth redoing by
hand if the limb code is ever touched.
