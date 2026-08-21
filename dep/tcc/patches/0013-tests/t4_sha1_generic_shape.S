/* The construct as libressl actually writes it, condensed from
   crypto/sha/sha1_amd64_generic.S: register names come from object-like
   macros, the round body is a multi-line function-like macro, and the
   rotate amounts are immediates inside that body. This is the file shape
   that made the bug reachable from a real build. */
#define	hs0		%r8d
#define	hs1		%r9d
#define	tmp0		%eax
#define	tmp1		%ebx

#define sha1_round(a, b, kt)						\
	movl	a, tmp0;						\
	roll	$5, tmp0;						\
	movl	b, tmp1;						\
	roll	$30, tmp1;						\
	addl	$kt, tmp0;						\
	addl	tmp1, tmp0;						\
	movl	tmp0, a

	.text
	.globl	sha1_shape
sha1_shape:
	sha1_round(hs0, hs1, 0x5a827999)
	sha1_round(hs1, hs0, 0x6ed9eba1)
	sha1_round(hs0, hs1, 0x8f1bbcdc)
	ret
