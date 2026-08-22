/* The shapes `.zero' actually turns up in, rather than only the literal-count
   form: a computed count, a label difference as the count, and the
   zero-initialised-object idiom gcc emits (`.globl'/`.type'/`.size' around a
   `.zero' body) that is the reason this directive is worth having at all. */
	.data
	.globl	tab_start
tab_start:
	.byte	1,2,3,4
tab_end:
	.zero	4*3
	.zero	tab_end - tab_start
	.byte	0x77

	.bss
	.globl	zeroed_object
	.type	zeroed_object, @object
	.size	zeroed_object, 64
zeroed_object:
	.zero	64

	.section .rodata
	.globl	ro_pad
ro_pad:
	.long	0xdeadbeef
	.zero	16
	.long	0xfeedface
