// pinsrd moves four bytes.  Its 64-bit sibling is a different mnemonic,
// pinsrq, reached by REX.W -- so a 64-bit register operand under the `d'
// mnemonic has no encoding and gas rejects it.
//
// The failure mode this rules out is the quiet one: an assembler whose
// operand-width autodetection saw %rax and set REX.W would assemble this line
// as pinsrq, writing eight bytes of the xmm register where the source asked
// for four.  Nothing about the resulting instruction looks wrong on its own.
        .text
        pinsrd  $1, %rax, %xmm0
