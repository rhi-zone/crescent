/* Hand-written asm that says nothing about the stack, and must therefore
   come out with no marker at all.

   MEASURED, not assumed: neither `as` nor `gcc -c` adds a marker to this
   file (binutils 2.44 / gcc 15.2.0, checked directly). The convention is
   that hand-written asm declares its own stack-execution needs, and this
   file declines to. A compiler that answered on its behalf would be
   speaking for code it did not generate -- so this test fails if tcc starts
   injecting the marker here, not if it omits it.

   Running run.sh with a real gcc as its argument passes this case for the
   same reason it passes under tcc. */
.text
.globl asm_zero
.type asm_zero,@function
asm_zero:
  xorl %eax, %eax
  ret
.size asm_zero,.-asm_zero
