/* A PC-relative relocation inside a section that is genuinely, correctly
   non-allocated. `notspecial' is a name GNU as has no opinion about and no
   flags string asks for SHF_ALLOC, so as leaves it non-allocated too -- this
   is not the `0004' shape where a section was wrongly missing SHF_ALLOC.

   Under -run, tccrun.c gives runtime addresses to SHF_ALLOC sections only, so
   this section's sh_addr stays 0 while the symbol's is a real heap pointer.
   Before `0023', relocate_sections() relocated it anyway and computed
   `symbol - 0', which does not fit in the 32 bits R_X86_64_PC32 has:
   `tcc: error: relocation '2' out of range', and the program never ran.

   The .long is never read -- nothing maps the section -- so the only thing
   this program has to do is run and print its own data correctly. */
#include <stdio.h>

extern char blob[];

asm(".data\n"
    ".byte 41\n"
    "blob:\n"
    "771:\n"
    ".byte 42\n"
    "772:\n"
    ".pushsection notspecial\n"
    ".long 771b - .\n"
    ".popsection\n"
    ".byte 772b - 771b\n");

int main(void)
{
    printf("%d %d\n", blob[0], blob[1]);
    return 0;
}
