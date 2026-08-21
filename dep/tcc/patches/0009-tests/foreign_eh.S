/* Input .eh_frame, relocated into from this object's own .text.  .eh_frame is
   SECTION_ROLE_SHARED, so when this object is merged into a link where tcc has
   already created .eh_frame for its own FDEs, the merge must still happen --
   the input-side gate has to let SHARED through, exactly as the creation gate
   does in the opposite ordering.  Reading the value back at runtime proves the
   content survived rather than merely that no diagnostic appeared. */
        .section .eh_frame,"a",@progbits
myeh:
        .long 0x2a

        .text
        .globl eh_value
eh_value:
        leaq myeh(%rip), %rax
        movl (%rax), %eax
        ret
