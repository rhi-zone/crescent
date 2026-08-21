/* movhps has no register-to-register form: 0f16/0f17 with mod=11 are
   movlhps/movhlps, different instructions. Real "as" rejects this;
   before this patch tcc silently emitted movlhps for it. */
	.text
n0_movhps_reg:
	movhps	%xmm0,%xmm1
