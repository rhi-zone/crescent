# Relocation offsets after a growing LEB128 site must land correctly.
# Both use .quad: tcc picks R_X86_64_32S where gas picks R_X86_64_32 for
# a 4-byte symbol reference, a pre-existing divergence unrelated to
# relaxation, which would otherwise mask what this test is checking.
	.section .test,"",@progbits
.Lstart:
	.uleb128 .Lend - .Lstart
	.space 127, 0x55
.Lend:
	.quad extsym
	.quad extsym2
.Ltail:
	.uleb128 .Ltail - .Lstart
