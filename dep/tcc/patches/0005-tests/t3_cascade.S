	.section .test,"",@progbits
	.uleb128 .Le1 - .Ls1
.Ls1:
	.space 130, 0x11
.Le1:
	.uleb128 .Le2 - .Ls2
.Ls2:
	.space 130, 0x22
.Le2:
