// A macro body invoking another macro, and passing its own parameter
// through: by the time the inner invocation is read, \outer has already
// become a number, so the inner expansion sees an ordinary argument.
        .text
.macro inner a,b
        movq    $\a, %rax
        movq    $\b, %rbx
.endm

.macro outer n
        inner \n, 2
        inner 1, \n
.if (\n % 2 == 0)
        nop
.else
        cld
.endif
.endm

nested:
        outer 1
        outer 4
        ret
