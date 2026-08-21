/* Linked by a real GNU ld to observe the end result the marker exists for:
   the executable GNU_STACK segment permissions.

   Built with -fno-asynchronous-unwind-tables. tcc .eh_frame output trips a
   separate, unrelated binutils error (".eh_frame_hdr refers to overlapping
   FDEs") that would abort the link before GNU_STACK could be read at all.
   That defect is tracked on its own; suppressing .eh_frame here keeps this
   harness measuring one thing. */
int main(void) { return 0; }
