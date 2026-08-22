/* The same macro, in the mode that actually matters for the real-world use.
   tcc loads include/tccdefs.h only when !is_asm, so a macro defined there is
   invisible here; this file fails to define the symbol unless __ELF__ comes
   from the always-on predefine table instead.  Asserted by exporting a
   symbol rather than by .error, which is not portable to every assembler
   this script is also run against. */
.text
.globl asm_probe
asm_probe:
	ret
#ifdef __ELF__
.globl elf_was_defined_in_asm
elf_was_defined_in_asm:
#endif
