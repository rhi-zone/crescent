/* `-run -g' is the case the fix had to not break. tcc's own backtrace reads
   debug information at runtime, which is why tccdbg.c's tcc_debug_new() marks
   the sections it reads SHF_ALLOC when do_backtrace is on -- so those get
   runtime addresses and go on being relocated normally. `0023' skips
   relocations only in sections that got no address, and keeps running the one
   relocation that means something without one (the dwarf-to-dwarf
   R_DATA_32DW, which subtracts the target section's own sh_addr back out).

   If that reasoning is wrong, it shows up here as a backtrace that has lost
   its file:line and prints raw addresses instead. run.sh checks the frames,
   not just the exit status. */
#include <stdio.h>

static void inner(void)
{
    int *p = 0;
    *p = 1;
}

static void middle(void)
{
    inner();
}

int main(void)
{
    printf("before\n");
    fflush(stdout);
    middle();
    return 0;
}
