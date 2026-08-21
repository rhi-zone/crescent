// BMI2 defines no 16-bit mulx.  gas rejects this; so must tcc, rather than
// quietly emitting the 32-bit encoding under an operand-size prefix.
        .text
        mulxw   %dx, %ax, %cx
