/* An object that relocates into its OWN .eh_frame.  Linking this with
   -fno-asynchronous-unwind-tables used to fail outright --
   "Invalid relocation entry [ 2] '.rela.text'" -- because the input
   .eh_frame was dropped whenever tcc was not generating unwind info itself,
   leaving the relocation against a section that no longer existed. */
        .section .eh_frame,"a",@progbits
myeh:
        .long 0x2a

        .text
        .globl ehrefval
ehrefval:
        leaq myeh(%rip), %rax
        movl (%rax), %eax
        ret
