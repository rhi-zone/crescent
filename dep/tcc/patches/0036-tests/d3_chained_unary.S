/* Chained unary operators are where as's extrabit flag becomes visible even
   on operands that are otherwise literals: it emits `- -1' as 1 with the
   whole upper half set.  One operator is unambiguous on a literal; two are
   not, so only one is accepted. */
	.data
	.octa	- -1
