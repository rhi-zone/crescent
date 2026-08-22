/* `.octa' reached through the two replay paths `0016' and `0017' added:
   inside `.rept', and inside a `.macro' with the operand arriving as an
   argument -- including one whose expansion is a unary operator followed by
   a literal, which is where a replayed token stream could deliver the two
   as one token or in the wrong order. */
	.data
	.rept 2
	.octa	0x000102030405060708090a0b0c0d0e0f
	.endr
	.macro	m v
	.octa	\v
	.endm
	m	0x0c0d0e0f08090a0b0405060700010203
	m	-1
	m	0x1
