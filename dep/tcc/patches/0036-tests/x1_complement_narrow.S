/* `~' on a value that fits in 64 bits.  This is a true 128-bit complement.
   What `as' puts in the upper half comes from the same X_extrabit flag that
   makes `.octa -0' disagree, so it is pinned to the 128-bit answer rather
   than compared against whichever `as' is installed -- binutils 2.44 agrees
   with both of these lines, and that agreement is not something to depend
   on given how that flag behaves elsewhere. */
	.data
	.octa	~0
	.octa	~0xffffffffffffffff
