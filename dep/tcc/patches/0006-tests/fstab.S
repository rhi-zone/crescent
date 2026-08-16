/* A foreign .stab section carrying an R_X86_64_32 to a text symbol.
   Assembled under placeholder names and renamed by run.sh: GNU as 2.44
   hits an internal error on a literal `.section .stab` (stabs support is
   being withdrawn from binutils), so the section names are applied
   afterwards with objcopy --rename-section. */
        .text
        .globl helper
helper: movl $42, %eax
        ret
        .section .xstabstr,"",@progbits
.Lstr0: .string ""
.Lstr1: .string "helper:F(0,1)"
        .section .xstab,"",@progbits
        .long .Lstr1-.Lstr0
        .byte 36
        .byte 0
        .word 1
        .long helper
