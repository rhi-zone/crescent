/* Links against foreign.o and returns 8 (g_obj.a == 7, foreign_fn adds 1),
   so a run proves the link produced working code, not merely no error. */
struct mytype { int a; double b; char c[8]; };
extern struct mytype g_obj;
int foreign_fn(struct mytype *p);
int main(void) { return foreign_fn(&g_obj); }
