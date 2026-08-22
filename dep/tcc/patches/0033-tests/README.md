# SSSE3 / SSE4.1 / SHA-NI opcode test cases (for `0033-ssse3-sse41-shani-opcodes.patch`)

Assembly inputs for the twelve opcodes libressl's `crypto/sha/sha1_amd64_shani.S`
and `crypto/sha/sha256_amd64_shani.S` need, plus a harness that diffs a tcc
build's `.text` against real GNU `as`.

    ./run.sh /path/to/patched/tcc

Every accepted case is compared byte-for-byte. The bytes rather than the
disassembly are what gets compared, because both failure modes these
instructions invite survive disassembly intact: a missing or doubled mandatory
`0x66` still yields a decodable instruction stream, and a ModRM byte whose two
register fields were filled from the wrong operands disassembles to the right
mnemonic naming the wrong registers.

| case | what it pins down |
|---|---|
| `t0_ssse3_sse41` | `pshufb`, `palignr`, `pblendw` — each of the three REX-extendable register fields (ModRM.reg, ModRM.rm base, SIB index) driven separately, so a template sourcing one from the wrong operand shows up |
| `t1_pinsrd_pextrd` | the pair whose xmm operand and whose `r/m32` operand sit on opposite sides of the source/destination split, so operand position cannot be what selects the ModRM field |
| `t2_shani` | the five prefix-free SHA-NI instructions with no implicit operand; `sha1msg1`/`sha1msg2`/`sha1nexte` and `sha256msg1`/`sha256msg2` are adjacent opcodes, and `sha1rnds4`'s opcode byte collides with `sha256msg1`'s across the two escape maps |
| `t3_sha256rnds2` | the implicit-`%xmm0` instruction; every case names a non-zero xmm in both encoded positions, so `%xmm0` leaking into either ModRM field changes register numbers rather than just shifting them |
| `t4_prefix_neighbours` | all of the above interleaved with instructions of other shapes — prefix-free next to `66`-prefixed, REX next to no-REX — so a prefix byte emitted one position early or late lands in a *neighbouring* instruction |
| `n0_sha256rnds2_wrong_implicit` | `%xmm5` where the hardware fixes `%xmm0`; unencoded, so accepting it would silently read `%xmm0` at runtime |
| `n1_sha1rnds4_no_imm` | the two-operand `sha1rnds4`, which does not exist — a fallback to the same-opcode `sha256msg1` template would assemble it |
| `n2_pextrd_operand_classes` | `pextrd` with its operands swapped, which is `pinsrd`'s operand shape and one opcode byte away |
| `n3_pinsrd_64bit_reg` | `pinsrd` with a 64-bit register, which width autodetection would turn into `pinsrq` — writing eight bytes where the source asked for four |

The `n*` half is not decoration. Each names an encoding that does not exist but
that a too-permissive template would assemble as some *neighbouring*
instruction, which is a wrong answer at runtime rather than a build failure —
and no positive case can catch that.

Against the `0001`–`0032` baseline the same harness reports `pass=4 fail=5`:
all five `t*` cases fail with `unknown opcode`, and the four `n*` cases pass for
the wrong reason (the mnemonics do not exist there at all).

Three spellings that GNU `as` accepts are deliberately absent from the table
and so cannot appear here in either half — they are omissions, not
divergences, and tcc rejects each with `unknown opcode` rather than
mis-assembling it:

- the 64-bit MMX forms of `pshufb` and `palignr`. Typing their operands
  `OPT_MMXSSE` to reach those would make `asm_opcode()` synthesise its own
  operand-size `0x66` on the xmm forms, on top of the mandatory one already in
  the opcode field.
- the two-operand `sha256rnds2`, which leaves the implicit `%xmm0` unwritten.

`t4_prefix_neighbours` ends in a backward branch to a label in the same file.
Both assemblers resolve it at assembly time with no relocation and both pick
the short form, so the byte comparison still holds; it is there because a loop
is the shape these instructions actually appear in.
