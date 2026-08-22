/* 2^64 and 2^65 written in octal.  binutils 2.44 emits zero for both, and
   emits the correct value for the same numbers written in hex or decimal,
   and for octal literals one digit longer -- an `as' artifact in a narrow
   band of octal widths, not a rule to follow.  Pinned to the value. */
	.data
	.octa	02000000000000000000000
	.octa	04000000000000000000000
