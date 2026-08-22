/* Second control, and the one that locates the gap precisely: a base-less
   SIB whose displacement is written *before* the parenthesis already
   assembled correctly before 0027. The pre-0027 parser only lost its way
   when the operand began with `(' immediately followed by `,', because that
   branch went looking for a parenthesised displacement expression and an
   expression cannot start with a comma. Everything below reaches the same
   encoder as t2 and comes out of the pre-patch tcc byte-identical to gas --
   which is the evidence that asm_modrm()'s missing-base handling was
   already right and 0027 is a parser fix only, not an encoding change. */
	.text
	.globl nobase_disp_control
nobase_disp_control:
	movq	4(,%rax,8), %rbx
	movq	-8(,%rax,8), %rbx
	movq	1024(,%rax,8), %rbx
	movq	8(,%rax,1), %rbx
	movq	16(,%r13,4), %rbx
	/* a computed displacement, and a symbolic one */
	movq	4+4(,%rax,8), %rbx
	movq	sym(,%rax,8), %rbx
	movq	sym+8(,%rax,8), %rbx
	ret
	.data
	.globl sym
sym:
	.quad	0
