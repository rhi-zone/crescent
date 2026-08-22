/* 0024's rule at .octa's width: a NOBITS section has a size and no bytes,
   so a non-zero value has nowhere to live.  as reports exactly the message
   0024 adopted. */
	.bss
	.octa	0x000102030405060708090a0b0c0d0e0f
