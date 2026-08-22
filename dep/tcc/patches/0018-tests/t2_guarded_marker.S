/* The idiom this patch exists for, verbatim as real-world asm writes it --
   dep/libressl/crypto/bn/arch/amd64/att/bignum_*.S all end exactly like this,
   and so do many upstream projects.  Under a compiler that defines only
   __linux__ the guard is false and the marker silently vanishes, leaving GNU
   ld to conclude the object needs an executable stack. */
.text
.globl guarded_probe
guarded_probe:
	ret
#if defined(__linux__) && defined(__ELF__)
.section .note.GNU-stack,"",%progbits
#endif
