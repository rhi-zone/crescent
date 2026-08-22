// The same instructions interleaved with unrelated ones.
//
// Every case in t0-t3 is a run of instructions of the same family, which
// means a prefix byte emitted one position early or late would land inside
// another instruction of that same family and might still decode plausibly.
// Here each new instruction is bracketed by instructions of a different shape
// -- a prefix-free SHA-NI instruction next to a 66-prefixed SSE one, an
// extended-register instruction that needs REX next to one that does not, and
// ordinary integer instructions with no prefix at all -- so a misplaced byte
// changes a NEIGHBOUR and shows up in the diff against gas.
//
// The pairing of prefix-free SHA-NI with 66-prefixed SSE4 is the point: the
// two kinds sit in the same escape maps and differ only in whether a prefix
// byte precedes them.
        .text
prefix_neighbours:
        movdqa  %xmm1, %xmm2
        sha256msg1 %xmm3, %xmm4
        pshufb  %xmm11, %xmm12
        sha1msg1 %xmm13, %xmm14
        addq    $8, %rsi
        sha1nexte %xmm5, %xmm6
        palignr $8, %xmm7, %xmm8
        sha256rnds2 %xmm0, %xmm2, %xmm1
        pblendw $0xf0, %xmm9, %xmm10
        sha256msg2 %xmm15, %xmm0
        movdqu  (%rdi), %xmm3
        sha1rnds4 $2, %xmm4, %xmm5
        pinsrd  $3, %eax, %xmm6
        sha256rnds2 %xmm0, %xmm11, %xmm12
        pextrd  $1, %xmm7, %r8d
        sha1msg2 %xmm8, %xmm9
        paddd   %xmm10, %xmm11
        sha256msg1 (%rsi), %xmm12
        cmpq    %rbx, %rsi
        jb      prefix_neighbours
