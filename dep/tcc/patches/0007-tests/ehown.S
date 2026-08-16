/* Asm carrying its own hand-written .eh_frame (a CIE plus one FDE), which is
   the shape buildvm emits for LuaJIT's lj_vm.S.  The whole section must come
   out byte-identical to GNU as: tcc must contribute nothing of its own to it,
   since tcc generates no FDEs for a .S file. */
        .text
        .globl ehownfn
ehownfn:
        movl $7, %eax
        ret
.Lend:

        .section .eh_frame,"a",@progbits
.LCIE:
        .long .LCIEend-.LCIEstart
.LCIEstart:
        .long 0                         /* CIE id */
        .byte 1                         /* version */
        .string "zR"                    /* augmentation */
        .uleb128 1                      /* code alignment factor */
        .sleb128 -8                     /* data alignment factor */
        .uleb128 16                     /* return address column */
        .uleb128 1                      /* augmentation length */
        .byte 0x1b                       /* FDE encoding: pcrel|sdata4 */
        .byte 0x0c                       /* DW_CFA_def_cfa */
        .uleb128 7                      /* rsp */
        .uleb128 8
        .byte 0x90                       /* DW_CFA_offset r16 */
        .uleb128 1
        .align 8
.LCIEend:

        .long .LFDEend-.LFDEstart
.LFDEstart:
        .long .LFDEstart-.LCIE          /* CIE pointer */
        .long ehownfn-.                 /* PC begin */
        .long .Lend-ehownfn             /* PC range */
        .uleb128 0                      /* augmentation length */
        .align 8
.LFDEend:
