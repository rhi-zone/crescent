// The suffixless spelling, where the operand size comes from the registers.
// This goes through a different path in the matcher than a suffixed mnemonic
// -- the size is resolved after the template is chosen, not before -- and it
// is the path on which "no 16-bit form" has to be re-checked, so both the
// accepted 32/64-bit cases and the rejected 16-bit one are worth having.
        .text
suffixless:
        mulx    %rdx, %rax, %rcx
        mulx    %edx, %eax, %ecx
        mulx    8(%rsi), %r8, %r9
        adcx    %rax, %r8
        adcx    %ecx, %edx
        adox    %rcx, %rdx
        adox    %ecx, %edx
