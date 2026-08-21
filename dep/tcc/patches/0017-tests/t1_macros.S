// .macro / .endm with zero, one and two parameters, and \name references in
// both operand and expression position.
        .text
.macro noargs
        nop
.endm

.macro one a
        movq    $\a, %rax
.endm

.macro two a,b
        movq    8*\b(%rsi), %rax
        movq    $\a, %rbx
.endm

// A parameter used where a whole operand goes, not just a number.
.macro store reg,off
        movq    \reg, \off(%rdi)
.endm

macros:
        noargs
        one 7
        two 3, 2
        store %rax, 16
        store %r12, 0
        one -1
        ret
