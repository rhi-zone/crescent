/* `1f' lexes as one PPNUM, same as a number does, and it is a forward local
   label reference rather than a literal -- so the digit-string parser must
   reject the trailing `f' instead of reading it as a hex digit. */
	.data
	.octa	1f
