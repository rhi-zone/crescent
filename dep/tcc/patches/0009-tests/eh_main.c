/* Compiled C, so tcc emits FDEs and creates .eh_frame at the first one --
   before foreign_eh.o is merged.  Exits with the value read out of the input
   object's .eh_frame, so a correct run proves the SHARED merge still happened
   in the ordering 0009 newly inspects. */
int eh_value(void);
void _start(void) {
    int r = eh_value();   /* 42 */
    __asm__ volatile("mov $60,%%eax; syscall" :: "D"(r) : "eax");
}
