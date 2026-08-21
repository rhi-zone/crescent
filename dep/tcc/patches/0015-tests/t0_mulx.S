// mulx operand forms.  The point of interest is the VEX prefix: the source
// is r/m, the middle operand is VEX.vvvv (which exists nowhere else in the
// encoding), the destination is modrm.reg, and %rdx is an implicit source
// that is not written down.  Every field that can name %r8-%r15 is exercised
// on both sides of 8, since each is a separate inverted bit of the prefix.
        .text
mulx_forms:
        mulxq   %rdx, %rax, %rcx
        mulxq   %rbx, %rcx, %rdx
        mulxq   %r15, %r12, %r13
        mulxq   %rax, %r8, %rbx
        mulxq   %r9, %rax, %r10
        mulxq   (%rsi), %rax, %rbx
        mulxq   8(%rsi), %rax, %rbx
        mulxq   -8(%rsi), %r8, %r9
        mulxq   1024(%r14), %rax, %rcx
        mulxq   8(%r14,%r15,8), %r10, %r11
        mulxq   8(%rsi,%rdi,4), %rax, %rbx
        mulxl   %edx, %eax, %ecx
        mulxl   %r15d, %r12d, %r13d
        mulxl   4(%rsi), %eax, %ebx
        mulxl   4(%r14,%r15,8), %r10d, %r11d
