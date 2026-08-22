/* Control spelling. t1 (.zero) and t2 (.space) carry byte-identical content
   with only the directive name changed, so run.sh can assert the three
   spellings agree rather than only that each one matches gas. */
	.text
	.globl	ctl_text
ctl_text:
	nop
	.skip	4
	.byte	0xaa
	.skip	3,0x5a
	.byte	0xbb
	.skip	1,0
	.byte	0xcc

	.data
	.globl	ctl_data
ctl_data:
	.byte	0x11
	.skip	7
	.byte	0x22
	.skip	2,0xff
	.long	0x44332211

	.bss
	.globl	ctl_bss
ctl_bss:
	.skip	32
	.globl	ctl_bss2
ctl_bss2:
	.skip	8

	.section .bss.named,"aw",@nobits
	.globl	ctl_named
ctl_named:
	.skip	24
