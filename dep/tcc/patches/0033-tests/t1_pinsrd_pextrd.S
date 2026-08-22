// pinsrd and pextrd: the two instructions in this patch whose xmm operand
// and whose r/m32 operand sit on opposite sides of the source/destination
// split.  pinsrd reads r/m32 and writes xmm; pextrd reads xmm and writes
// r/m32.  In both, ModRM.reg holds the xmm and ModRM.rm holds the r/m32 --
// so the assembler cannot pick the two fields by operand position, and a
// template that did would encode one of these two backwards while getting
// the other right.
//
// Both mnemonics are the 32-bit ones: a REX.W here would silently turn them
// into pinsrq/pextrq, which move eight bytes rather than four.  The register
// cases below therefore all use 32-bit register names, and the memory cases
// are what would expose a stray REX.W that no register operand asked for.
        .text
pinsrd_pextrd_forms:
        pinsrd  $0, %eax, %xmm0
        pinsrd  $3, %eax, %xmm0
        pinsrd  $1, %ecx, %xmm14
        pinsrd  $2, %r10d, %xmm5
        pinsrd  $3, %r15d, %xmm15
        pinsrd  $1, 16(%rdi), %xmm14
        pinsrd  $2, (%r11), %xmm1
        pinsrd  $0, 8(%rsp,%rbx,4), %xmm9

        pextrd  $0, %xmm0, %eax
        pextrd  $3, %xmm0, %eax
        pextrd  $1, %xmm2, %r11d
        pextrd  $2, %xmm13, %ecx
        pextrd  $3, %xmm15, %r15d
        pextrd  $0, %xmm13, 16(%rdi)
        pextrd  $1, %xmm1, (%r11)
        pextrd  $2, %xmm9, 8(%rsp,%rbx,4)
