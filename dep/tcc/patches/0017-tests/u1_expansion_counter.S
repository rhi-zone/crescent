// GAS's per-expansion counter \@, used to make labels unique across
// expansions.  Not implemented; must be rejected rather than emitted as a
// stray backslash into the middle of a label.
        .text
.macro m
1\@:
        nop
.endm
f:
        m
        m
