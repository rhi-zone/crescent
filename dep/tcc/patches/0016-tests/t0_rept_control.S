// Control: .rept on its own, with nothing that makes the assembler run a
// second layout pass.  This one already worked before patch 0016, and is
// here so that a regression in .rept itself is told apart from a regression
// in its interaction with the relaxation replay.
        .text
control:
        .rept 3
        nop
        .endr
        ret
