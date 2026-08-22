/* The two operands that motivated the patch, copied from
   dep/libressl/crypto/sha/sha1_amd64_shani.S:165 and
   sha256_amd64_shani.S:180 -- the byte-shuffle masks, in the same
   .rodata/.align context the originals sit in. */
	.section .rodata
	.align 16
K_shuffle_mask_sha1:
	.octa	0x000102030405060708090a0b0c0d0e0f
K_shuffle_mask_sha256:
	.octa	0x0c0d0e0f08090a0b0405060700010203
