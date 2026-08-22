/* An explicit "I really do need an executable stack". Never weakened. */
.text
.globl exec_probe
exec_probe:
	ret
.section .note.GNU-stack,"x",%progbits
