/* Several operands to one directive, an empty operand list (as documents
   .octa as taking zero or more), and .octa interleaved with the narrower
   data directives so that any miscount of the 16 bytes shows up as a
   shifted neighbour rather than only as wrong .octa bytes. */
	.data
	.byte	0xaa
	.octa
	.octa	1,2,0x000102030405060708090a0b0c0d0e0f
	.byte	0xbb
	.quad	0x0011223344556677
	.octa	0xffffffffffffffffffffffffffffffff
	.long	0x89abcdef
	.octa	-1,0
	.byte	0xcc
