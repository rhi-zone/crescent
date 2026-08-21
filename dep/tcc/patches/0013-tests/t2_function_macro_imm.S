/* t0's sequence again, this time with every immediate inside a function-like
   macro body -- the shape reported from the libressl build.

   Both halves of the bug are covered. The shift/rotate lines failed loudly
   before this patch ("bad operand with opcode 'roll'"), because those opcodes
   need an 8-bit immediate and the operand had turned into an address. The
   mov/add/and lines did NOT fail: they accept a 32-bit immediate, so the
   operand parsed as an absolute address and assembled silently to the wrong
   instruction. That is why this harness compares bytes rather than exit
   status. */
#define rot_l(a)	roll $5, a
#define rot_r(a)	rorl $7, a
#define sh_l(a)		shll $2, a
#define sh_r(a)		shrl $31, a
#define sar_by(n, a)	sarl $n, a
#define set(a)		movl $5, a
#define bump(a)		addl $5, a
#define mask(a)		andl $255, a
#define setq()		movq $4660, %rax
#define shlq_by(n)	shlq $n, %rdi
	.text
	.globl	control
control:
	rot_l(%ebx)
	rot_r(%ecx)
	sh_l(%edx)
	sh_r(%esi)
	sar_by(3, %edi)
	set(%ebx)
	bump(%ebx)
	mask(%edx)
	setq()
	shlq_by(8)
	ret
