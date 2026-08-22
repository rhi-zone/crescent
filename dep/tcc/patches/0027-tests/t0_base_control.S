/* Control: SIB memory operands that tcc accepted before 0027. Every form
   here has a base register, which is what the pre-0027 parser required.
   This case must pass identically before and after the patch -- it is the
   evidence that 0027 changed only the base-less spelling and nothing else
   about how a memory operand is parsed or encoded. */
	.text
	.globl base_control
base_control:
	movq	(%rax), %rbx
	movq	8(%rax), %rbx
	movq	(%rax,%rcx), %rbx
	movq	(%rax,%rcx,8), %rbx
	movq	16(%rax,%rcx,4), %rbx
	movq	sym(%rax,%rcx,2), %rbx
	/* the forced-SIB and forced-displacement base registers */
	movq	(%rsp,%rcx,8), %rbx
	movq	(%rbp,%rcx,8), %rbx
	movq	(%r12,%rcx,8), %rbx
	movq	(%r13,%rcx,8), %rbx
	/* a parenthesised displacement expression before the base, which is
	   the other consumer of the parser branch 0027 touches */
	movq	(4+4)(%rax), %rbx
	movq	(4+4)(%rax,%rcx,8), %rbx
	leaq	(%rax,%rcx,8), %rdx
	ret
	.data
	.globl sym
sym:
	.quad	0
