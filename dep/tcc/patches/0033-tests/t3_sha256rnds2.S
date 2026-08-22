// sha256rnds2, the one instruction here with an implicit operand.
//
// It reads a third source from %xmm0 that has no field anywhere in the
// encoding.  gas spells that out as a leading operand, and libressl's
// sha256_amd64_shani.S uses that spelling, so the assembler has to accept a
// three-operand mnemonic while emitting a ModRM byte built from only the
// other two.
//
// The failure this file is aimed at is an assembler that treats %xmm0 as an
// ordinary operand and lets it win one of the two ModRM fields.  Every case
// below therefore names an xmm register OTHER than 0 in both encoded
// positions: if %xmm0 leaked into ModRM.reg or ModRM.rm, the register numbers
// would come out wrong rather than merely shifted, and the bytes would
// disagree with gas.
        .text
sha256rnds2_forms:
        sha256rnds2 %xmm0, %xmm2, %xmm1
        sha256rnds2 %xmm0, %xmm1, %xmm2
        sha256rnds2 %xmm0, %xmm7, %xmm6
        sha256rnds2 %xmm0, %xmm14, %xmm15
        sha256rnds2 %xmm0, %xmm3, %xmm12
        sha256rnds2 %xmm0, %xmm12, %xmm3
        sha256rnds2 %xmm0, (%rdi), %xmm9
        sha256rnds2 %xmm0, 16(%r10), %xmm2
        sha256rnds2 %xmm0, 32(%rsp,%r12,8), %xmm3
