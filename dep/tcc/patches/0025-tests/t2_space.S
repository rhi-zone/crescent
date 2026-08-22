/* The second existing spelling, carried so the three-way agreement is
   asserted rather than inferred from two independent gas comparisons:
   `.skip', `.space' and `.zero' are one directive in as. */
	.text
	.globl	ctl_text
ctl_text:
	nop
	.space	4
	.byte	0xaa
	.space	3,0x5a
	.byte	0xbb
	.space	1,0
	.byte	0xcc

	.data
	.globl	ctl_data
ctl_data:
	.byte	0x11
	.space	7
	.byte	0x22
	.space	2,0xff
	.long	0x44332211

	.bss
	.globl	ctl_bss
ctl_bss:
	.space	32
	.globl	ctl_bss2
ctl_bss2:
	.space	8

	.section .bss.named,"aw",@nobits
	.globl	ctl_named
ctl_named:
	.space	24
