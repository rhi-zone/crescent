/* as refuses to relocate at this width: "cannot do unsigned 16 byte
   relocation".  There is no R_X86_64_* for a 128-bit absolute, so this is
   not a tcc limitation being papered over -- the encoding does not exist. */
	.data
foo:
	.octa	foo
