/* Which register may sit in the index slot of a base-less SIB, and what
   prefix that costs. %rbp and %r13 are the interesting ones: their forced
   -displacement behaviour belongs to the *base* slot, so as an index they
   must encode plainly, with no extra displacement and no promotion. The
   %r8-%r15 half needs REX.X, which is a different REX bit from the one a
   base register would set, and the 32-bit index forms need the 0x67
   address-size prefix. */
	.text
	.globl nobase_index_regs
nobase_index_regs:
	movq	(,%rax,8), %rbx
	movq	(,%rcx,8), %rbx
	movq	(,%rdx,8), %rbx
	movq	(,%rbx,8), %rbx
	movq	(,%rbp,8), %rbx
	movq	(,%rsi,8), %rbx
	movq	(,%rdi,8), %rbx
	/* REX.X, not REX.B */
	movq	(,%r8,8), %rbx
	movq	(,%r9,8), %rbx
	movq	(,%r10,8), %rbx
	movq	(,%r11,8), %rbx
	movq	(,%r12,8), %rbx
	movq	(,%r13,8), %rbx
	movq	(,%r14,8), %rbx
	movq	(,%r15,8), %rbx
	/* REX.X together with REX.R on the register operand */
	movq	(,%r13,4), %r14
	/* 32-bit index: 0x67 address-size prefix, no REX.W */
	movl	(,%eax,4), %ebx
	movl	(,%ebp,2), %ebx
	movl	16(,%esi,8), %edx
	ret
