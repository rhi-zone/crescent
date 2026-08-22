// pextrd reads an xmm register and writes r/m32, in that order.  Swapping
// the two operands is not another spelling of the instruction -- there is no
// encoding for it -- and gas rejects it.
//
// The pairing with pinsrd is what makes this worth pinning: pinsrd takes
// exactly these operand classes in exactly this order, and its opcode differs
// from pextrd's only in the final byte.  An assembler that matched on operand
// classes without also matching the mnemonic's direction could accept this
// line as the pinsrd it resembles.
        .text
        pextrd  $3, %eax, %xmm0
