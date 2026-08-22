/* __ELF__ must be visible while preprocessing C, as it is under gcc and
   clang on every ELF target. Compiling this file at all is the assertion. */
#ifndef __ELF__
#error "__ELF__ is not defined when preprocessing C on an ELF target"
#endif
#if __ELF__ != 1
#error "__ELF__ is defined but not to 1, which is the value gcc and clang use"
#endif
int c_probe(void) { return __ELF__; }
