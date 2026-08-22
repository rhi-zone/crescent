/* The plain `#if __TINYC__` shape, exactly as tcc's own tests/tcctest.c:338
   writes it. This needs __TINYC__ to be a valid preprocessor NUMBER; a
   `#ifdef` would pass either way and would not discriminate. */
#if __TINYC__
int guard_taken = 1;
#else
int guard_taken = 0;
#endif

int main(void) { return guard_taken ? 0 : 1; }
