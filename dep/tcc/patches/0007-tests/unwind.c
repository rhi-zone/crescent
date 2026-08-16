/* Compiled C, so tcc generates FDEs for it.  Linked together with ehref.o it
   forces the SHARED case: tcc's own CIE/FDEs and an input .eh_frame have to
   end up in one section, with the chain still walkable. */
int ehrefval(void);
int addone(int x) { return x + 1; }
void _start(void) {
    int r = addone(ehrefval());   /* 43 */
    __asm__ volatile("mov $60,%%eax; syscall" :: "D"(r) : "eax");
}
