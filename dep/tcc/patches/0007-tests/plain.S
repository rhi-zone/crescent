/* Pure asm with no .eh_frame of its own and no tcc-generated FDEs.
   GNU as emits no .eh_frame section at all for this; tcc used to emit one
   holding nothing but an orphan CIE, because the CIE was written at session
   start before any input was read. */
        .text
        .globl asmfn
asmfn:
        movl $42, %eax
        ret
