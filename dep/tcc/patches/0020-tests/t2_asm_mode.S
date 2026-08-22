/* tcc_predefs() also runs for asm input (its is_asm argument), so a broken
   __TINYC__ breaks preprocessed .S sources too -- the exact file kind this
   whole patch series exists to assemble. */
#if __TINYC__ != 928
#error "__TINYC__ is not 928 in asm mode"
#endif
	.text
	.globl asm_probe
asm_probe:
	xorl %eax, %eax
	ret
