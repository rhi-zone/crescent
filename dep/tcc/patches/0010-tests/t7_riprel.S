/* RIP-relative addressing has no base or index register to extend, so only
   REX.R is in play -- and it must not be confused with REX.B here. The
   symbol is external so both assemblers emit a relocation rather than
   folding the displacement, which keeps the comparison meaningful. */
	.text
t7:
	movdqa	extsym(%rip),%xmm0
	movdqu	%xmm0,extsym(%rip)
	movdqa	extsym(%rip),%xmm7
	movdqu	%xmm7,extsym(%rip)
	movdqa	extsym(%rip),%xmm8
	movdqu	%xmm8,extsym(%rip)
	movdqa	extsym(%rip),%xmm15
	movdqu	%xmm15,extsym(%rip)
