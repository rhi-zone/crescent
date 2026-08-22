/* The base-less address is an operand shape, not an instruction feature, so
   it has to reach every path that emits a ModRM byte -- not just the
   register-destination two-operand ALU form the gap was first noticed on.
   Each group below picks a different encoder path: memory as destination,
   an immediate alongside the memory operand, the single-operand group-
   opcode forms, the legacy-SSE path, and the VEX path (`mulx', from 0015,
   which is where this gap was originally found and where the form had to be
   dropped from that patch's cases). */
	.text
	.globl nobase_instr_classes
nobase_instr_classes:
	/* memory as destination */
	movq	%rbx, (,%rdx,8)
	addq	%rbx, (,%rdx,8)
	/* immediate plus memory */
	movl	$7, (,%rsi,4)
	addq	$1, (,%rsi,8)
	cmpq	$0, (,%r9,8)
	/* single-operand group opcodes */
	incq	(,%rdi,2)
	negq	(,%rdi,8)
	/* address computation rather than a load */
	leaq	(,%rcx,8), %rdx
	leaq	32(,%rcx,4), %rdx
	/* indirect control transfer */
	jmp	*(,%rax,8)
	call	*(,%rcx,4)
	/* legacy SSE, including a REX.X index */
	movaps	(,%rsi,8), %xmm3
	movq	(,%rax,8), %xmm1
	pxor	(,%r9,2), %xmm5
	/* VEX-encoded three-operand */
	mulx	(,%rax,8), %rbx, %rcx
	mulx	(,%r13,4), %rbx, %rcx
	ret
