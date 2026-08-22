/* as accepts this and emits 3 -- but the upper half it emits comes from its
   own X_extrabit flag rather than from the value, which is why `.octa 2-1'
   there is 1 with every bit of the upper half set.  tcc rejects arithmetic
   operands rather than choosing between copying that or disagreeing with
   it silently.  See the TOK_ASMDIR_octa comment in tccasm.c. */
	.data
	.octa	1+2
