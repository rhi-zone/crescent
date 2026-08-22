/* An absolute 64-bit relocation in the same non-allocated section. This one
   never errored -- a real heap pointer fits in 64 bits -- it just wrote a
   live address into bytes nobody will ever map. There is nothing to observe
   from inside the program either way, which is exactly why it is here: it
   pins down that `0023' did not turn a silently-useless case into a loud
   one. The program must still simply run. */
#include <stdio.h>

extern char blob[];

asm(".data\n"
    ".byte 41\n"
    "blob:\n"
    "771:\n"
    ".byte 42\n"
    "772:\n"
    ".pushsection notspecial\n"
    ".balign 8\n"
    ".quad 771b\n"
    ".popsection\n"
    ".byte 772b - 771b\n");

int main(void)
{
    printf("%d %d\n", blob[0], blob[1]);
    return 0;
}
