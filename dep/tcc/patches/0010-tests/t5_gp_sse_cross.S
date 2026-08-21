/* Operands drawn from two different register files at once: the GP number
   and the SSE number are extended by different REX bits depending on which
   ModRM field each lands in, so a fix that keyed off operand position
   rather than field would break here. */
	.text
t5:
	movd	%eax,%xmm0
	movd	%xmm0,%eax
	pinsrw	$2,%eax,%xmm0
	movd	%eax,%xmm8
	movd	%xmm8,%eax
	pinsrw	$2,%eax,%xmm8
	movd	%eax,%xmm15
	movd	%xmm15,%eax
	pinsrw	$2,%eax,%xmm15
	movd	%edi,%xmm0
	movd	%xmm0,%edi
	pinsrw	$2,%edi,%xmm0
	movd	%edi,%xmm8
	movd	%xmm8,%edi
	pinsrw	$2,%edi,%xmm8
	movd	%edi,%xmm15
	movd	%xmm15,%edi
	pinsrw	$2,%edi,%xmm15
	movd	%r8d,%xmm0
	movd	%xmm0,%r8d
	pinsrw	$2,%r8d,%xmm0
	movd	%r8d,%xmm8
	movd	%xmm8,%r8d
	pinsrw	$2,%r8d,%xmm8
	movd	%r8d,%xmm15
	movd	%xmm15,%r8d
	pinsrw	$2,%r8d,%xmm15
	movd	%r15d,%xmm0
	movd	%xmm0,%r15d
	pinsrw	$2,%r15d,%xmm0
	movd	%r15d,%xmm8
	movd	%xmm8,%r15d
	pinsrw	$2,%r15d,%xmm8
	movd	%r15d,%xmm15
	movd	%xmm15,%r15d
	pinsrw	$2,%r15d,%xmm15
	movq	%rax,%xmm0
	movq	%xmm0,%rax
	movq	%rax,%xmm8
	movq	%xmm8,%rax
	movq	%rax,%xmm15
	movq	%xmm15,%rax
	movq	%r8,%xmm0
	movq	%xmm0,%r8
	movq	%r8,%xmm8
	movq	%xmm8,%r8
	movq	%r8,%xmm15
	movq	%xmm15,%r8
	movq	%r15,%xmm0
	movq	%xmm0,%r15
	movq	%r15,%xmm8
	movq	%xmm8,%r15
	movq	%r15,%xmm15
	movq	%xmm15,%r15
