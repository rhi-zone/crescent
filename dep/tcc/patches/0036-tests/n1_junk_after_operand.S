/* Two literals with no comma between them.  A parser that stopped at the
   first operand and let the statement loop resume would silently drop the
   second; as calls it junk at end of line. */
	.data
	.octa	1 2
