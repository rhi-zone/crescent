// GAS accepts a parameter default; this tcc does not implement one.  What is
// asserted here is that it is REJECTED rather than misread -- silently
// treating `a=5' as a parameter named `a' would make every call site that
// relied on the default expand to nothing.
        .text
.macro m a=5
        movq    $\a, %rax
.endm
f:
        m
