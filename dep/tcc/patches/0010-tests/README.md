# Extended x86_64 register test cases (for `0010-extended-sse-registers.patch`)

Assembly inputs exercising `%xmm8`–`%xmm15` across the ModRM/SIB encoding
space, plus a harness that diffs a tcc build's output against real GNU `as`.

    ./run.sh /path/to/patched/tcc

The harness compares the bytes of every non-empty PROGBITS section and the
normalized relocation table, so a pass means the encoding is byte-identical to
`as`, not merely accepted. `.eh_frame` is excluded for the same pre-existing,
unrelated reason documented in `0005-tests/README.md`.

`%r8`–`%r15` (and their `d`/`w`/`b` width forms) are **not** what this patch
adds — they already assembled correctly, because `asm_parse_numeric_reg()` in
`i386-asm.c` parses them out of the identifier text rather than from tokens.
`t6_gp_extended` covers them anyway, as a regression guard over the shared REX
path the SSE change touches.

| case | what it pins down |
|---|---|
| `t0_control` | the same shapes restricted to `xmm0`–`xmm7`; passes before and after, so a pass proves the harness can pass |
| `t1_reg_reg` | direct register operands: REX.R (ModRM.reg), REX.B (ModRM.rm), and both at once |
| `t2_mem_base` | extended base register: REX.B on ModRM.rm and on SIB.base, over every displacement form, including the `%rsp`/`%r12` forced-SIB and `%rbp`/`%r13` forced-displacement corners |
| `t3_sib_index` | REX.X on SIB.index, in every combination with REX.B on the base and REX.R on the reg field |
| `t4_three_byte_map` | 0F38/0F3A opcodes (AES-NI): the REX prefix must precede the `0x0f` escape, not sit inside the escape sequence |
| `t5_gp_sse_cross` | one GP and one SSE operand in the same instruction, where the two register numbers are extended by different REX bits |
| `t6_gp_extended` | `%r8`–`%r15` in all four widths plus addressing modes (regression guard, see above) |
| `t7_riprel` | RIP-relative operands, where there is no base or index to extend and only REX.R is in play; the symbol is external so both assemblers emit a relocation rather than folding the displacement |

Against the `0001`–`0009` baseline the same harness reports `pass=2 fail=6` —
`t0_control` and `t6_gp_extended` pass, and the six extended-SSE cases fail with
`unknown register %xmm8`.
