// sha1rnds4 has no two-operand encoding: the round-function selector is an
// immediate byte with no default.  gas rejects the two-operand spelling.
//
// This case guards the boundary between sha1rnds4 (0F 3A CC) and
// sha256msg1 (0F 38 CC), which share an opcode byte and differ only in the
// escape map -- and which differ in operand count.  An assembler that fell
// back to a same-opcode template of the other arity would assemble this line
// as sha256msg1 and produce a silently wrong instruction.
        .text
        sha1rnds4 %xmm1, %xmm2
