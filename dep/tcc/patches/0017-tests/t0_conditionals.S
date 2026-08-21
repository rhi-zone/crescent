// .if / .elseif / .else / .endif on their own, before any macro is involved.
//
// The expressions are the ones GAS conditionals are normally written with --
// %, ==, <, and parenthesised combinations -- and the arms deliberately
// differ in length, so an arm that was assembled when it should have been
// skipped (or the reverse) changes .text size and not just its contents.
        .text
conditionals:
        .if 1
        nop
        .else
        ret
        ret
        .endif

        .if 0
        ret
        .elseif (2 % 4 == 2)
        cld
        cld
        .elseif 1
        ret
        .else
        ret
        .endif

        .if 0
        ret
        .elseif 0
        ret
        .else
        std
        .endif

// A taken arm containing a whole conditional of its own, and a skipped arm
// containing one too -- the skip has to match .endif to .if rather than
// stopping at the first .endif it meets.
        .if 1
        .if 0
        ret
        .else
        nop
        .endif
        .else
        .if 1
        ret
        .endif
        ret
        .endif

        .if (3 < 2)
        ret
        .endif
        ret
