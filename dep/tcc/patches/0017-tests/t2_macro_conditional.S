// The shape the s2n-bignum sources actually use: a macro whose body branches
// on arithmetic over its own parameters, so each invocation assembles a
// different arm.  This is the case that needs .macro and .if to compose --
// the conditional is evaluated at expansion time, over the substituted
// arguments, not at definition time.
        .text
.macro window i,j
        movq    8*\j(%rsi), %rdx
.if ((\i + \j) % 4 == 0)
        addq    %rdx, %r8
.elseif ((\i + \j) % 4 == 1)
        addq    %rdx, %r9
.elseif ((\i + \j) % 4 == 2)
        addq    %rdx, %r10
.else
        addq    %rdx, %r11
.endif
.endm

macro_conditional:
        window 0, 0
        window 0, 1
        window 0, 2
        window 0, 3
        window 1, 3
        window 2, 3
        ret
