// Defining a macro twice in one unit.
        .text
.macro m
        nop
.endm
.macro m
        ret
.endm
f:
        m
