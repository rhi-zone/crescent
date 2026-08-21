# `mov{ups,aps,hps}` operand-type test cases (for `0011-sse-mov-operand-types.patch`)

Assembly inputs pinning down which operands these three instructions take,
plus a harness that diffs a tcc build's output against real GNU `as`.

    ./run.sh /path/to/patched/tcc

`t*.S` are positive cases, compared byte-for-byte (PROGBITS content plus the
normalized relocation table). `n*.S` are negative cases: `as` rejects them and
tcc must too. Both halves matter here. The wrong operand type did not only
reject valid input — it silently *accepted* invalid input and encoded something
else, which is the more dangerous half.

| case | what it pins down |
|---|---|
| `t0_reg_reg` | the register-to-register forms `as` accepts, across `xmm0`–`xmm15`; also settles the ALT question, since both table entries match and `as` picks the load-direction opcode (`0f28` / `0f10`) |
| `t1_mem` | the memory forms in both directions, which already worked — retyping the non-EA operand must not change which ALT entry a memory operand selects |
| `n0_movhps_reg` | `movhps %xmm0,%xmm1` — `0f16`/`0f17` with `mod=11` are `movlhps`/`movhlps`, so there is no register-to-register `movhps`; `as` rejects it |
| `n1_gp_operand` | `movups %eax,%xmm0` — before this patch tcc emitted `movups %xmm0,%xmm0`, taking the GP register as the xmm of the same number |
| `n2_movaps_gp_src` | same for `movaps`, source side (emitted `movaps %xmm0,%xmm0`) |
| `n3_movaps_gp_dst` | same for `movaps`, destination side (emitted `movaps %xmm0,%xmm0`) |
| `n4_movhps_gp` | same for `movhps`, which additionally aliased onto `movlhps` |

Against the `0001`–`0010` baseline the same harness reports `pass=2 fail=5`:
`t0_reg_reg` fails with `bad operand with opcode 'movaps'`, the four GP negative
cases fail by assembling, and `t1_mem` and `n0_movhps_reg` pass on both.

`movlhps`/`movhlps` are absent from tcc's tables entirely and are not added
here — that would be new capability, not a correction.
