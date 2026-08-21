// Several .rept blocks in one relaxed unit, on both sides of the .uleb128
// site: the capture has to be suppressed and restored once per directive,
// so a suppression that leaked (never restored) would lose the tokens after
// the first block, and one that was never applied would duplicate all three.
//
// Nested .rept is deliberately not tested here: tcc's .rept scan stops at
// the first .endr rather than counting depth, so nesting has never worked,
// before this patch or after it.  See TODO.md.
        .text
around:
        .rept 3
        nop
        .endr
        .uleb128 L2-L1
        .rept 2
        cld
        .endr
L1:
        .space 200
L2:
        .rept 4
        nop
        .endr
        ret
