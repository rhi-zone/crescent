/* Only opcodes that accept a 32-bit immediate, all reached through macros.
   Against the 0001-0012 baseline this file ASSEMBLES -- no diagnostic at all --
   and every line comes out as an absolute-address memory operand instead of an
   immediate, because "$5" had lexed as one identifier and resolved as an
   undefined symbol at 0. It is the reason this harness compares bytes: the
   other cases die on the shift/rotate operand check and never get far enough
   to show that a build without those opcodes would just silently be wrong.

   Baseline reports MISMATCH here, not FAIL. */
#define set(a)		movl $5, a
#define bump(a)		addl $5, a
#define mask(a)		andl $255, a
#define cmp_to(a)	cmpl $16, a
#define or_in(a)	orl $64, a
	.text
	.globl	silent
silent:
	set(%ebx)
	bump(%ebx)
	mask(%edx)
	cmp_to(%ecx)
	or_in(%esi)
	ret
