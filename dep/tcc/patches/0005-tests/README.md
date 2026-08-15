# LEB128 relaxation test cases (for `0005-asm-leb128-relaxation.patch`)

Assembly inputs whose correct encoding depends on variable-width
`.uleb128`/`.sleb128` relaxation, plus a harness that diffs a tcc build's
output against real GNU `as`.

    ./run.sh /path/to/patched/tcc

The harness compares the bytes of every non-empty PROGBITS section and the
normalized relocation table. `.eh_frame` is excluded: `tcc_eh_frame_start()`
(`tccdbg.c`) unconditionally prepends tcc's own 24-byte "zR" CIE to every
object even for pure-asm input that supplies its own CFI — a real
pre-existing divergence from gas, unrelated to relaxation, tracked separately.

| case | what it pins down |
|---|---|
| `t0_control` | constant LEB128s + a `.long` label difference; passes without relaxation, so a pass here proves the harness can pass |
| `t1_basic` | forward-forward difference, single-byte result |
| `t2_boundary` | result crosses the 127/128 boundary into two bytes |
| `t3_cascade` | two independent sites in one section |
| `t4_sleb` | signed, negative difference |
| `t5_selfref127` | site *inside* the range it measures; 1-byte fixed point |
| `t6_selfref128` | same, but 1 byte is inconsistent — requires growing to 2 and re-running layout (`as` emits `8101`) |
| `t7_align` | growth absorbed by `.align`, whose padding is a function of absolute position |
| `t8_reloc` | relocations after a grown site; their offsets are only correct if layout re-ran |

`t5`–`t8` reach the deferred path via a *defined backward* subtrahend, which
routes through `asm_expr_sum()`'s PC-relative case rather than the `sym2`
case `0003` added — both have to work.

Beyond this suite, the rewind itself was validated by forcing ≥3 passes on
inputs that need none and requiring byte-identical output (28/28 with and
without `-g`); that check is what caught the token-capture and debug-state
bugs described in TODO.md.
