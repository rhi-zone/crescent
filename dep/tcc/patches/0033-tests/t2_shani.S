// The SHA-NI instructions that take no implicit operand.
//
// What separates these from every other 0F38/0F3A instruction already in
// tcc's table is that they have NO mandatory prefix.  The aes-ni and SSE4
// entries all carry 0x66, so a table mechanism that assumed a prefix byte was
// always present would have gone unnoticed until now; here a spurious 0x66
// would change the instruction's length and shift everything after it.
//
// sha1msg1 (0F 38 C9), sha1msg2 (0F 38 CA) and sha1nexte (0F 38 C8) are
// adjacent opcodes, as are sha256msg1 (0F 38 CC) and sha256msg2 (0F 38 CD),
// so an off-by-one in the opcode byte still produces a valid instruction of
// the same shape.  All five are listed rather than a representative one.
//
// sha1rnds4 is the only 0F3A member of the group, and its opcode byte (CC)
// collides with sha256msg1's in the 0F38 map -- the escape byte is the only
// thing telling those two apart.
        .text
shani_forms:
        sha1nexte %xmm1, %xmm2
        sha1nexte %xmm9, %xmm10
        sha1nexte %xmm2, %xmm11
        sha1nexte (%rsi), %xmm5
        sha1nexte 16(%r13,%rax,8), %xmm0

        sha1msg1 %xmm3, %xmm4
        sha1msg1 %xmm12, %xmm13
        sha1msg1 (%rdi), %xmm0

        sha1msg2 %xmm5, %xmm6
        sha1msg2 (%rsi), %xmm5
        sha1msg2 8(%rbp), %xmm14

        sha256msg1 %xmm9, %xmm10
        sha256msg1 %xmm0, %xmm1
        sha256msg1 (%r8), %xmm15

        sha256msg2 %xmm11, %xmm12
        sha256msg2 8(%rbp), %xmm11
        sha256msg2 (%rax,%r9,4), %xmm2

        sha1rnds4 $0, %xmm1, %xmm2
        sha1rnds4 $1, %xmm10, %xmm11
        sha1rnds4 $2, %xmm3, %xmm12
        sha1rnds4 $3, (%rdx), %xmm15
        sha1rnds4 $3, 32(%rsp,%rdi,2), %xmm0
