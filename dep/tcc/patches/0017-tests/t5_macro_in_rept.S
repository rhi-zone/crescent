// A macro invoked from inside .rept, and .rept inside a macro body: the two
// replay mechanisms nest, in both orders.
        .text
.macro thrice
        .rept 3
        nop
        .endr
.endm

.macro one a
        movq    $\a, %rax
.endm

in_rept:
        .rept 2
        one 5
        cld
        .endr
        thrice
        ret
