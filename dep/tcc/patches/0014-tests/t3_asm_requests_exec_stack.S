/* Input declares the marker EXECUTABLE -- "I really do need an executable
   stack". That is the input's statement to make, and tcc must carry it
   through unaltered rather than overwriting it with its own default. If the
   marker were created unconditionally, or adopted and re-flagged, this file
   would silently lose its request. */
.text
.globl asm_execstack
.type asm_execstack,@function
asm_execstack:
  xorl %eax, %eax
  ret
.size asm_execstack,.-asm_execstack
.section .note.GNU-stack,"x",@progbits
