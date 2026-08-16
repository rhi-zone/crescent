/* Compiled by gcc to produce the foreign debug sections under test.
   With -fdebug-types-section this yields a .debug_types whose relocations
   point at .debug_abbrev/.debug_str/.debug_line -- the shape that the
   dwlo..dwhi index-range check mishandled. */
struct mytype { int a; double b; char c[8]; };
struct mytype g_obj = { 7, 2.5, "hi" };
int foreign_fn(struct mytype *p) { return p->a + 1; }
