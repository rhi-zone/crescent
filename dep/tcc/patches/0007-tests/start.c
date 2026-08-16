/* -nostdlib entry point: exits with ehrefval() == 42, so a successful run
   proves the retained .eh_frame content is actually readable at runtime,
   not merely that the link stopped erroring. */
int ehrefval(void);
void _start(void) {
    int r = ehrefval();
    __asm__ volatile("mov $60,%%eax; syscall" :: "D"(r) : "eax");
}
