/* The form 0027 adds, and the only spelling that was actually missing: a
   SIB address with an index, no base, and nothing at all before the open
   parenthesis. `as' encodes it ModRM.mod=00, ModRM.rm=100 (SIB follows),
   SIB.base=101 -- which in mod=00 means "no base, disp32 follows" -- so
   every one of these carries a four-byte displacement of zero. All four
   scales, plus the scale omitted entirely, which `as' reads as scale 1.
   A parenthesised zero displacement is included because `(0)(,%rax,8)' goes
   down the *other* side of the parser branch 0027 touches and has to keep
   working. */
	.text
	.globl nobase_bare
nobase_bare:
	movq	(,%rax,1), %rbx
	movq	(,%rax,2), %rbx
	movq	(,%rax,4), %rbx
	movq	(,%rax,8), %rbx
	/* no scale given: same encoding as an explicit ,1 */
	movq	(,%rax), %rbx
	movq	(,%rcx), %rbx
	/* the parenthesised-displacement spelling of the same address */
	movq	(0)(,%rax,8), %rbx
	movq	(4+4)(,%rax,8), %rbx
	ret
