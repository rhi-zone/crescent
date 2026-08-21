// A macro expanded in a unit that needs a second layout pass.  As for .rept
// (patch 0016), the definition and the invocation are both in the recorded
// token stream, so the second pass re-expands them itself; recording the
// expansion as well would emit each body twice.
        .text
.macro body n
        movq    $\n, %rax
        nop
.endm

relaxed:
        body 1
        body 2
        .uleb128 L2-L1
        body 3
L1:
        .space 200
L2:
        body 4
        ret
