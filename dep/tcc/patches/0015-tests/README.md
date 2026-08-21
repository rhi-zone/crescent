# ADX / BMI2 opcode test cases (for `0015-adx-bmi2-opcodes.patch`)

Assembly inputs for `adcx`, `adox` and `mulx`, plus a harness that diffs a tcc
build's `.text` against real GNU `as`.

    ./run.sh /path/to/patched/tcc

Every accepted case is compared byte-for-byte. That is a stricter bar than the
whole-routine comparison in `tooling/scripts/verify-bignum-att-tcc.sh`, and it
is the right one here: these files are straight-line, with no branches and no
relocations, so no encoding freedom is left for the two assemblers to disagree
within. It also matters that the *bytes* are what is compared rather than the
disassembly — a VEX prefix with, say, an un-inverted `vvvv` field still
disassembles to a perfectly plausible `mulx`, naming the wrong registers.

| case | what it pins down |
|---|---|
| `t0_mulx` | every `mulx` operand shape used: register and memory sources, SIB with an extended index, both 32- and 64-bit widths, and `%r8`–`%r15` in each of the three register fields separately (each is a different inverted bit of the VEX prefix) |
| `t1_adx` | `adcx` and `adox` side by side — one opcode, told apart only by the `66`/`F3` mandatory prefix, so getting one right does not imply the other |
| `t2_suffixless` | the unsuffixed spelling, where the width comes from the registers; a different path through the matcher than a suffixed mnemonic |
| `t3_carry_chain` | the three interleaved with ordinary instructions, so a prefix emitted one byte early or late shows up in a *neighbouring* instruction |
| `n0_mulxw` | `mulxw` — BMI2 defines no 16-bit form; gas rejects it and so must tcc |
| `n1_adcxw` | `adcxw` — the `66` in `adcx` is the mandatory prefix, leaving no operand-size slot for a 16-bit form |
| `n2_adox_16bit_regs` | the same rejection reached through the unsuffixed spelling, where 16-bit-ness comes from the registers |

The `n*` half is not decoration. Without it, a template that quietly assembled
`adcxw` as the 32-bit form under a stray operand-size prefix would pass every
positive case in the table.

Against the `0001`–`0014` baseline the same harness reports `pass=3 fail=4`:
all four `t*` cases fail with `unknown opcode`, and the three `n*` cases pass
for the wrong reason (the mnemonics do not exist there at all).

`(,%reg,scale)` — a SIB address with no base — is deliberately absent from
`t0_mulx`. tcc's operand parser rejects that syntax for every instruction, not
just this one; it is a pre-existing limitation and not this patch's subject.
