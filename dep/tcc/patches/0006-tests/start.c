/* -nostdlib link-to-file variant of main.c: needs _start, not main.
   Exits with foreign_fn(&g_obj) == 8 via the raw exit syscall. */
struct mytype { int a; double b; char c[8]; };
extern struct mytype g_obj;
int foreign_fn(struct mytype *p);
void _start(void) {
    int r = foreign_fn(&g_obj);
    __asm__ volatile("mov $60,%%eax; syscall" :: "D"(r) : "eax");
}
