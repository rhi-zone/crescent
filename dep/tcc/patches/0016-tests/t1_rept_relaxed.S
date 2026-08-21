// .rept in a unit that needs a second layout pass.
//
// `.uleb128 L2-L1' where neither label is defined yet cannot be encoded when
// it is parsed, so the assembler guesses a width, and if the guess was too
// small it rewinds and assembles the whole unit again from the token stream
// it recorded on the way through (patch 0005).  The .space here makes the
// difference wide enough to force exactly that.
//
// The recorded stream contains the .rept directive AND its body, so the
// second pass repeats the body itself.  If the first pass had also recorded
// the tokens it replayed, the body would come out four times instead of
// three -- and, in this file, as a syntax error before it got that far.
        .text
relaxed:
        .rept 3
        nop
        .endr
        .uleb128 L2-L1
L1:
        .space 200
L2:
        ret
