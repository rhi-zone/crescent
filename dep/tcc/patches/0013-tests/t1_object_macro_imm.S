/* t0's sequence with every immediate reached through an object-like macro --
   both spellings: the macro carrying the whole '$n' operand, and the macro
   carrying only the number after a literal '$'. Registers come from macros too,
   the way libressl's *_generic.S files name them. */
#define I5		$5
#define I7		$7
#define N2		2
#define N31		31
#define N3		3
#define I255		$255
#define I4660		$4660
#define N8		8
#define b		%ebx
#define c		%ecx
#define d		%edx
#define s		%esi
#define i		%edi
	.text
	.globl	control
control:
	roll	I5, b
	rorl	I7, c
	shll	$N2, d
	shrl	$N31, s
	sarl	$N3, i
	movl	I5, b
	addl	I5, b
	andl	I255, d
	movq	I4660, %rax
	shlq	$N8, %rdi
	ret
