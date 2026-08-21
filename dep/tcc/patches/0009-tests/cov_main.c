/* Compiled with -ftest-coverage, so tcc creates .tcov while compiling this
   file -- before any input object is merged.  That ordering is the one the
   creation-site gate cannot see. */
int foreign_value(void);
int main(void) { return foreign_value() == 42 ? 0 : 1; }
