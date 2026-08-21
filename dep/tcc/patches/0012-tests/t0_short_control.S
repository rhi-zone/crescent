/* Control: the same operand shapes written with .short, which tcc already
   had. Real "as" assembles this and the .value file next to it to identical
   objects, so a pass on both is the equivalence being checked, not assumed.
   A bare symbol operand (.short sym) is absent deliberately: tcc's 2-byte
   data directives reject one ("constant expected", no R_X86_64_16), which is
   a pre-existing limitation of .short/.word that .value inherits by being an
   alias -- a different gap, tracked separately, not this patch's subject. */
	.data
	.short	0x1234
	.short	0x0000,0x01C2,0x0384,0x0246
	.short	-1
	.short	1+2*3
	.short	65535
	.short	0
lbl:
	.short	lbl-.
