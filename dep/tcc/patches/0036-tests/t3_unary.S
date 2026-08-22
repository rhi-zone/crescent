/* One leading unary operator on a literal.  `~' on a value that fits in 64
   bits, and `-0', are not here: `as' answers those from its X_extrabit flag
   rather than from the value, so they are pinned in x0 and x1 instead of
   compared. */
	.data
	.octa	+1
	.octa	+0x000102030405060708090a0b0c0d0e0f
	.octa	-1
	.octa	-0xffffffffffffffff
	.octa	-0x0102030405060708090a0b0c0d0e0f10
	.octa	~0x000102030405060708090a0b0c0d0e0f
	.octa	-340282366920938463463374607431768211455
