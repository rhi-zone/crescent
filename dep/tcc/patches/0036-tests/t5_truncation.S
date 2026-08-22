/* Wider than 128 bits.  as truncates to the low 16 bytes and warns rather
   than refusing, so the bytes are part of the comparison, not just the
   acceptance. */
	.data
	.octa	0x1ffffffffffffffffffffffffffffffff
	.octa	99999999999999999999999999999999999999999
