/* The one operand form that both assemblers accept and disagree on.  as
   emits a zero low half and an all-ones upper half -- its extrabit flag,
   not a sign extension of any value.  A 128-bit negate of zero is zero,
   which is what this emits.  Pinned so that a later change to either side
   is noticed rather than absorbed. */
	.data
	.octa	-0
