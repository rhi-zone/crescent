// pshufb, palignr and pblendw: 66-prefixed 0F38/0F3A instructions.
//
// The three register fields are exercised separately because each becomes a
// different bit of the REX prefix -- ModRM.reg is REX.R, the ModRM.rm base is
// REX.B, and a SIB index is REX.X -- and a template that got one of them from
// the wrong operand would still assemble every same-numbered case correctly.
//
// The 0x66 here is the instruction's own mandatory prefix, not an
// operand-size prefix.  Ordering matters: it has to land before any REX byte,
// so the extended-register cases below are what catches a template that
// emitted it in the wrong place.
        .text
ssse3_sse41_forms:
        pshufb  %xmm1, %xmm2
        pshufb  %xmm7, %xmm0
        pshufb  %xmm2, %xmm11
        pshufb  %xmm12, %xmm3
        pshufb  %xmm13, %xmm14
        pshufb  (%rax), %xmm1
        pshufb  (%r9), %xmm2
        pshufb  16(%rsp,%r13,4), %xmm0
        pshufb  -8(%rbp,%rcx,2), %xmm15

        palignr $0, %xmm1, %xmm2
        palignr $4, %xmm9, %xmm10
        palignr $8, %xmm2, %xmm9
        palignr $12, %xmm10, %xmm3
        palignr $0xff, %xmm1, %xmm2
        palignr $8, (%r12), %xmm1
        palignr $4, 64(%rdi,%r10,8), %xmm14

        pblendw $0xf0, %xmm12, %xmm3
        pblendw $0x0f, %xmm3, %xmm12
        pblendw $0x00, %xmm5, %xmm6
        pblendw $0xff, %xmm15, %xmm8
        pblendw $0x0f, 32(%rbx), %xmm15
        pblendw $0xaa, (%r14,%r15,1), %xmm0
