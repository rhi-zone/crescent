/* The directive this patch adds. Byte-identical to t0_skip_control.S with
   every `.skip' respelled `.zero' -- fill-value forms included, because
   `.zero' takes a fill operand in as and honours it. That is the part of
   this easy to get backwards, so it is in the control content on purpose. */
	.text
	.globl	ctl_text
ctl_text:
	nop
	.zero	4
	.byte	0xaa
	.zero	3,0x5a
	.byte	0xbb
	.zero	1,0
	.byte	0xcc

	.data
	.globl	ctl_data
ctl_data:
	.byte	0x11
	.zero	7
	.byte	0x22
	.zero	2,0xff
	.long	0x44332211

	.bss
	.globl	ctl_bss
ctl_bss:
	.zero	32
	.globl	ctl_bss2
ctl_bss2:
	.zero	8

	.section .bss.named,"aw",@nobits
	.globl	ctl_named
ctl_named:
	.zero	24
