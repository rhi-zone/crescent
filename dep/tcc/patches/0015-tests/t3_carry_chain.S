// A carry chain in the shape the s2n-bignum routines actually use it: the
// two flags run independently, mulx feeds both, and ordinary instructions
// sit between them.  The forms are all covered above; what this file adds is
// context, so that a prefix emitted one byte early or late shows up as a
// difference in the *neighbouring* instruction rather than passing unnoticed.
//
// Deliberately straight-line.  A forward branch would make byte identity the
// wrong bar -- tcc defers same-section forward branches to relocations where
// gas resolves them short -- and that difference has nothing to do with ADX.
        .text
carry_chain:
        xorl    %ebp, %ebp
        movq    (%rcx), %rdx
        mulxq   (%rsi), %rax, %rbx
        adcxq   %rax, %r8
        adoxq   %rbx, %r9
        mulxq   8(%rsi), %rax, %rbx
        adcxq   %rax, %r9
        adoxq   %rbx, %r10
        movq    %r8, (%rdi)
        mulxq   16(%rsi), %rax, %r8
        adcxq   %rax, %r10
        adoxq   %rbp, %r8
        adcxq   %rbp, %r8
        movq    %r9, 8(%rdi)
        movq    %r10, 16(%rdi)
        movq    %r8, 24(%rdi)
        ret
