/* Every boundary the four 32-bit limbs have to carry a value across: the
   32/64/96-bit limb edges, the point where a value stops fitting in the
   uint64_t that .quad would have used, and the full 128-bit width. */
	.data
	.octa	1
	.octa	0xffffffff
	.octa	0x100000000
	.octa	0x7fffffffffffffff
	.octa	0x8000000000000000
	.octa	0xffffffffffffffff
	.octa	0x10000000000000000
	.octa	0xffffffffffffffffffffffff
	.octa	0x1000000000000000000000000
	.octa	0xffffffffffffffffffffffffffffffff
	.octa	340282366920938463463374607431768211455
	.octa	170141183460469231731687303715884105728
