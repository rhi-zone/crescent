// The implicit operand of sha256rnds2 is fixed at %xmm0 by the hardware.
// gas rejects any other register in that position, and so must tcc: the
// register is not encoded anywhere, so accepting %xmm5 would mean silently
// assembling an instruction that reads %xmm0 instead -- a wrong answer at
// runtime rather than a build failure.
//
// Without this case, a template that typed the leading operand as an
// ordinary xmm and then ignored it would pass every positive case in
// t3_sha256rnds2.S.
        .text
        sha256rnds2 %xmm5, %xmm2, %xmm1
