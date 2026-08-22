/* The control. `allocated' is just as unrecognized a name, but its flags
   string asks for SHF_ALLOC, so tccrun.c does give it a runtime address and
   its relocations are real work that must still happen.

   The program dereferences the relocated pointer, so this fails loudly if
   `0023' ever widened into "skip relocations under -run" generally: an
   unrelocated .quad here is the section-relative offset 1, and reading
   address 1 is a segfault, not a wrong number. */
#include <stdio.h>

extern char *aptr;

asm(".data\n"
    ".byte 41\n"
    "771:\n"
    ".byte 42\n"
    /* "aw" rather than "a": the pointer needs a load-time relocation, and a
       real linker warns about one landing in a read-only section. */
    ".pushsection allocated,\"aw\"\n"
    ".balign 8\n"
    ".globl aptr\n"
    "aptr:\n"
    ".quad 771b\n"
    ".popsection\n");

int main(void)
{
    printf("%d\n", *aptr);
    return 0;
}
