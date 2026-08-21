/* The reference sequence, written literally with no macro anywhere. t1 and t2
   express this exact same sequence through macros, so all three must assemble
   to identical bytes -- that equivalence is what the patch is about, and the
   harness asserts it directly on top of comparing each file to gas.

   Deliberately absent: shift-by-one (gas picks the D1 /r short form, tcc picks
   C1 /r ib) and an immediate added to %eax (gas picks 83 /0 ib, tcc picks the
   05 id accumulator form). Both are pre-existing tcc/gas encoding choices with
   nothing to do with macros -- they would make every case here mismatch for an
   unrelated reason. Recorded in TODO.md. */
	.text
	.globl	control
control:
	roll	$5, %ebx
	rorl	$7, %ecx
	shll	$2, %edx
	shrl	$31, %esi
	sarl	$3, %edi
	movl	$5, %ebx
	addl	$5, %ebx
	andl	$255, %edx
	movq	$4660, %rax
	shlq	$8, %rdi
	ret
