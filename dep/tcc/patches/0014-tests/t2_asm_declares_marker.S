/* Input supplies the marker itself. tcc must reuse it, not add a second
   one, and must not touch its (empty) flags. */
.text
.globl asm_declared
.type asm_declared,@function
asm_declared:
  xorl %eax, %eax
  ret
.size asm_declared,.-asm_declared
.section .note.GNU-stack,"",@progbits
