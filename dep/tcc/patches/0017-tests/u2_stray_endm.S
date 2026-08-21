// .endm with no .macro open.  GAS warns and carries on; this tcc treats it
// as an error, since a file containing one is malformed and continuing would
// assemble something nobody wrote.  Recorded here as a deliberate
// strictness difference rather than left to be discovered.
        .text
        .endm
