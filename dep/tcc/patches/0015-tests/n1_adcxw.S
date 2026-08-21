// Likewise for adcx: the 66 in its encoding is the mandatory prefix that
// distinguishes it from adox, so there is no operand-size slot left for a
// 16-bit form and gas rejects the w suffix.
        .text
        adcxw   %ax, %bx
