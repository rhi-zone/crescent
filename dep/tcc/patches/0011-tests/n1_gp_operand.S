/* A GP register is not an operand of these instructions. Real "as" rejects
   this; before this patch tcc accepted it and emitted the xmm of the same
   number, so "movups %eax,%xmm0" assembled as "movups %xmm0,%xmm0". */
	.text
n1_gp_operand:
	movups	%eax,%xmm0
