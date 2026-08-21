// More arguments than the macro has parameters.
        .text
.macro m a
        movq    $\a, %rax
.endm
f:
        m 1, 2
