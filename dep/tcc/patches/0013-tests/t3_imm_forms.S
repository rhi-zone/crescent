/* Every spelling of a '$' operand that the corpus uses, each one reached
   through a macro: hex, a parenthesised expression, negative, arithmetic, a
   symbol, and a symbol with an offset. The point is that '$' stops the
   identifier the same way it does outside a macro body -- not that '$5'
   specifically is special-cased. */
#define hex(a)		movl $0x10, a
#define shifted(a)	movl $(1 << 4), a
#define neg(a)		movl $-1, a
#define sum(a)		movl $(1 + 2), a
#define sym(a)		movq $target, a
#define sym_off(a)	movq $target+8, a
#define rot_hex(a)	roll $0x1f, a
#define rot_expr(a)	roll $(2 * 3), a
	.text
	.globl	imm_forms
	.globl	target
target:
	nop
imm_forms:
	hex(%eax)
	shifted(%eax)
	neg(%eax)
	sum(%eax)
	sym(%rax)
	sym_off(%rax)
	rot_hex(%ebx)
	rot_expr(%ebx)
	ret
