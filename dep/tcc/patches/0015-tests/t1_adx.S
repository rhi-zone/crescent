// adcx and adox.  Both are 0F 38 F6 and are told apart only by the
// mandatory prefix, 66 against F3 -- so a file that assembles one correctly
// can still get the other wrong, and both are listed here side by side.  The
// 66 is not an operand-size prefix: the 64-bit forms below must come out as
// 66/F3 followed by REX.W, not as a 16-bit operation.
        .text
adx_forms:
        adcxq   %rax, %r8
        adcxq   %r9, %rax
        adcxq   %r15, %r14
        adcxq   %rbx, %rbx
        adcxq   (%rsi), %rax
        adcxq   8(%rsi), %r10
        adcxq   8(%r14,%r15,8), %r11
        adcxl   %ecx, %edx
        adcxl   %r9d, %eax
        adcxl   4(%rsi), %eax
        adoxq   %rcx, %rdx
        adoxq   %r11, %r12
        adoxq   %r15, %r14
        adoxq   (%rsi), %rax
        adoxq   8(%rsi), %r10
        adoxq   8(%r14,%r15,8), %r11
        adoxl   %ecx, %edx
        adoxl   %r9d, %eax
        adoxl   4(%rsi), %eax
