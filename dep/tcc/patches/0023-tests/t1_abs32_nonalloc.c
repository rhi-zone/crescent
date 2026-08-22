/* The same section, with an absolute 32-bit relocation instead of a
   PC-relative one. This is a different relocation type reaching the same
   dead end from the other side: R_X86_64_32 does not need the section's own
   address at all, it just writes the symbol's -- but under -run the symbol's
   address is a real heap pointer, which does not fit in 32 bits either, so
   before `0023' this failed with `relocation 'R_X86_64_32[S]' out of range'.

   Worth having as its own case: a fix that only skipped PC-relative
   relocations would pass t0 and still fail here. */
#include <stdio.h>

extern char blob[];

asm(".data\n"
    ".byte 41\n"
    "blob:\n"
    "771:\n"
    ".byte 42\n"
    "772:\n"
    ".pushsection notspecial\n"
    ".long 771b\n"
    ".popsection\n"
    ".byte 772b - 771b\n");

int main(void)
{
    printf("%d %d\n", blob[0], blob[1]);
    return 0;
}
