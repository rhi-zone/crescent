// \b names no parameter of m.  Passing it through unchanged would put a
// stray backslash into the instruction stream and produce a confusing
// diagnostic somewhere else, so it is rejected here.
        .text
.macro m a
        movq    $\b, %rax
.endm
f:
        m 1
