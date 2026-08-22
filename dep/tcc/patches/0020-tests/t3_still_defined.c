/* Guard, not a discriminator: __TINYC__ must still be *defined* at all.
   Passes against base and patched alike. It is here because the cheapest
   wrong way to silence the `#if __TINYC__` error would be to stop predefining
   __TINYC__, which would break every `#ifdef __TINYC__` in the wild -- and in
   tcc's own tcc.h, tests/, and lib/. */
#ifndef __TINYC__
#error "__TINYC__ is not defined at all"
#endif
#if !defined(__TINYC__)
#error "defined(__TINYC__) is false"
#endif

int main(void) { return 0; }
