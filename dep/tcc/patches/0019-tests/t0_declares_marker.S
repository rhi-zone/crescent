/* An assembled input that states its own requirement: it does not need an
   executable stack. Merging this with an input that stated nothing must not
   let this file's claim silently answer for the other one. */
.text
.globl declares_probe
declares_probe:
	ret
.section .note.GNU-stack,"",%progbits
