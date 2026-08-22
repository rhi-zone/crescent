/* Hand-written asm that says nothing about the stack. GNU as, gcc -c and
   clang -c all leave this object unmarked, and GNU ld reads the absence as
   "this object may require an executable stack" -- an implicit request that
   must survive a merge. */
.text
.globl undeclared_probe
undeclared_probe:
	ret
