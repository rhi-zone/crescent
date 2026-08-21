// Differential runtime check: call every gas-assembled bignum routine and its
// tcc-assembled twin on identical inputs, in the same process, and compare
// outputs byte for byte.
//
// The tcc-assembled objects are linked in with every symbol prefixed `T_`
// (objcopy --prefix-symbols), so both versions of each routine coexist. This
// also exercises the part a disassembly comparison cannot: tcc defers
// same-section branches to R_X86_64_PLT32 relocations against local symbols,
// so whether the *linker* turns those back into the right destinations is
// only observable by running the linked code.
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define DECL(rt, name, args) extern rt name args; extern rt T_##name args;
DECL(uint64_t, bignum_add, (uint64_t, uint64_t *, uint64_t, const uint64_t *, uint64_t, const uint64_t *))
DECL(uint64_t, bignum_sub, (uint64_t, uint64_t *, uint64_t, const uint64_t *, uint64_t, const uint64_t *))
DECL(uint64_t, bignum_cmadd, (uint64_t, uint64_t *, uint64_t, uint64_t, const uint64_t *))
DECL(uint64_t, bignum_cmul, (uint64_t, uint64_t *, uint64_t, uint64_t, const uint64_t *))
DECL(void, bignum_modadd, (uint64_t, uint64_t *, const uint64_t *, const uint64_t *, const uint64_t *))
DECL(void, bignum_modsub, (uint64_t, uint64_t *, const uint64_t *, const uint64_t *, const uint64_t *))
DECL(void, bignum_mul, (uint64_t, uint64_t *, uint64_t, const uint64_t *, uint64_t, const uint64_t *))
DECL(void, bignum_sqr, (uint64_t, uint64_t *, uint64_t, const uint64_t *))
DECL(void, bignum_mul_4_8_alt, (uint64_t *, const uint64_t *, const uint64_t *))
DECL(void, bignum_mul_6_12_alt, (uint64_t *, const uint64_t *, const uint64_t *))
DECL(void, bignum_mul_8_16_alt, (uint64_t *, const uint64_t *, const uint64_t *))
DECL(void, bignum_sqr_4_8_alt, (uint64_t *, const uint64_t *))
DECL(void, bignum_sqr_6_12_alt, (uint64_t *, const uint64_t *))
DECL(void, bignum_sqr_8_16_alt, (uint64_t *, const uint64_t *))
// The non-`_alt' forms of the same six routines. They compute the same
// functions, from ADX and BMI2 instructions (adcx/adox/mulx) instead of the
// base-ISA sequence, which is why they are worth running twice over: once
// against their own tcc-assembled twin, and once against the `_alt' routine
// beside them, which is an independent implementation of the same spec.
DECL(void, bignum_mul_4_8, (uint64_t *, const uint64_t *, const uint64_t *))
DECL(void, bignum_mul_6_12, (uint64_t *, const uint64_t *, const uint64_t *))
DECL(void, bignum_mul_8_16, (uint64_t *, const uint64_t *, const uint64_t *))
DECL(void, bignum_sqr_4_8, (uint64_t *, const uint64_t *))
DECL(void, bignum_sqr_6_12, (uint64_t *, const uint64_t *))
DECL(void, bignum_sqr_8_16, (uint64_t *, const uint64_t *))
DECL(uint64_t, word_clz, (uint64_t))

static uint64_t st = 0x243F6A8885A308D3ULL;
static uint64_t rnd(void) { st ^= st << 13; st ^= st >> 7; st ^= st << 17; return st; }

static int fails, checks;
static void cmp(const char *who, const uint64_t *a, const uint64_t *b, int n,
                uint64_t ra, uint64_t rb) {
  checks++;
  if (memcmp(a, b, (size_t)n * 8) != 0 || ra != rb) { fails++; printf("MISMATCH %s\n", who); }
}

int main(void) {
  uint64_t x[16], y[16], m[16], za[32], zb[32], zc[32];
  uint64_t ra, rb;
  const int ITERS = 4000;

  // The non-`_alt' routines execute adcx/adox/mulx unconditionally, so on a
  // host without ADX and BMI2 calling them is SIGILL, not a wrong answer.
  // Report the skip rather than crashing or silently passing.
  int adx = __builtin_cpu_supports("bmi2") && __builtin_cpu_supports("adx");
  if (!adx) printf("SKIP adx/bmi2 routines: host lacks ADX or BMI2\n");

  for (int it = 0; it < ITERS; it++) {
    for (int i = 0; i < 16; i++) { x[i] = rnd(); y[i] = rnd(); m[i] = rnd() | 0x8000000000000000ULL; }
    // Exercise short/degenerate lengths too, not just the max.
    uint64_t k = 1 + (rnd() % 8), mm = 1 + (rnd() % 8), nn = 1 + (rnd() % 8), p = 1 + (rnd() % 12);
    uint64_t c = rnd();

    memset(za, 0xAA, sizeof za); memset(zb, 0xAA, sizeof zb);
    ra = bignum_add(p, za, mm, x, nn, y); rb = T_bignum_add(p, zb, mm, x, nn, y);
    cmp("bignum_add", za, zb, 16, ra, rb);

    memset(za, 0xAA, sizeof za); memset(zb, 0xAA, sizeof zb);
    ra = bignum_sub(p, za, mm, x, nn, y); rb = T_bignum_sub(p, zb, mm, x, nn, y);
    cmp("bignum_sub", za, zb, 16, ra, rb);

    memset(za, 0xAA, sizeof za); memset(zb, 0xAA, sizeof zb);
    ra = bignum_cmadd(k, za, c, nn, y); rb = T_bignum_cmadd(k, zb, c, nn, y);
    cmp("bignum_cmadd", za, zb, 16, ra, rb);

    memset(za, 0xAA, sizeof za); memset(zb, 0xAA, sizeof zb);
    ra = bignum_cmul(k, za, c, nn, y); rb = T_bignum_cmul(k, zb, c, nn, y);
    cmp("bignum_cmul", za, zb, 16, ra, rb);

    memset(za, 0xAA, sizeof za); memset(zb, 0xAA, sizeof zb);
    bignum_modadd(k, za, x, y, m); T_bignum_modadd(k, zb, x, y, m);
    cmp("bignum_modadd", za, zb, 16, 0, 0);

    memset(za, 0xAA, sizeof za); memset(zb, 0xAA, sizeof zb);
    bignum_modsub(k, za, x, y, m); T_bignum_modsub(k, zb, x, y, m);
    cmp("bignum_modsub", za, zb, 16, 0, 0);

    memset(za, 0xAA, sizeof za); memset(zb, 0xAA, sizeof zb);
    bignum_mul(p, za, mm, x, nn, y); T_bignum_mul(p, zb, mm, x, nn, y);
    cmp("bignum_mul", za, zb, 16, 0, 0);

    memset(za, 0xAA, sizeof za); memset(zb, 0xAA, sizeof zb);
    bignum_sqr(p, za, nn, x); T_bignum_sqr(p, zb, nn, x);
    cmp("bignum_sqr", za, zb, 16, 0, 0);

    memset(za, 0xAA, sizeof za); memset(zb, 0xAA, sizeof zb);
    bignum_mul_4_8_alt(za, x, y); T_bignum_mul_4_8_alt(zb, x, y);
    cmp("bignum_mul_4_8_alt", za, zb, 8, 0, 0);

    memset(za, 0xAA, sizeof za); memset(zb, 0xAA, sizeof zb);
    bignum_mul_6_12_alt(za, x, y); T_bignum_mul_6_12_alt(zb, x, y);
    cmp("bignum_mul_6_12_alt", za, zb, 12, 0, 0);

    memset(za, 0xAA, sizeof za); memset(zb, 0xAA, sizeof zb);
    bignum_mul_8_16_alt(za, x, y); T_bignum_mul_8_16_alt(zb, x, y);
    cmp("bignum_mul_8_16_alt", za, zb, 16, 0, 0);

    memset(za, 0xAA, sizeof za); memset(zb, 0xAA, sizeof zb);
    bignum_sqr_4_8_alt(za, x); T_bignum_sqr_4_8_alt(zb, x);
    cmp("bignum_sqr_4_8_alt", za, zb, 8, 0, 0);

    memset(za, 0xAA, sizeof za); memset(zb, 0xAA, sizeof zb);
    bignum_sqr_6_12_alt(za, x); T_bignum_sqr_6_12_alt(zb, x);
    cmp("bignum_sqr_6_12_alt", za, zb, 12, 0, 0);

    memset(za, 0xAA, sizeof za); memset(zb, 0xAA, sizeof zb);
    bignum_sqr_8_16_alt(za, x); T_bignum_sqr_8_16_alt(zb, x);
    cmp("bignum_sqr_8_16_alt", za, zb, 16, 0, 0);

    if (adx) {
#define ADX_MUL(name, nz)                                                    \
      memset(za, 0xAA, sizeof za); memset(zb, 0xAA, sizeof zb);              \
      memset(zc, 0xAA, sizeof zc);                                           \
      name(za, x, y); T_##name(zb, x, y); name##_alt(zc, x, y);              \
      cmp(#name, za, zb, nz, 0, 0);                                          \
      cmp(#name " vs " #name "_alt", za, zc, nz, 0, 0);
#define ADX_SQR(name, nz)                                                    \
      memset(za, 0xAA, sizeof za); memset(zb, 0xAA, sizeof zb);              \
      memset(zc, 0xAA, sizeof zc);                                           \
      name(za, x); T_##name(zb, x); name##_alt(zc, x);                       \
      cmp(#name, za, zb, nz, 0, 0);                                          \
      cmp(#name " vs " #name "_alt", za, zc, nz, 0, 0);
      ADX_MUL(bignum_mul_4_8, 8)
      ADX_MUL(bignum_mul_6_12, 12)
      ADX_MUL(bignum_mul_8_16, 16)
      ADX_SQR(bignum_sqr_4_8, 8)
      ADX_SQR(bignum_sqr_6_12, 12)
      ADX_SQR(bignum_sqr_8_16, 16)
    }

    // word_clz: cover every leading-zero count plus random words, since the
    // routine is 7 instructions and a random-only sweep would miss 0.
    uint64_t w[66]; int nw = 0;
    w[nw++] = 0; w[nw++] = ~0ULL;
    for (int i = 0; i < 64; i++) w[nw++] = (it & 1) ? (1ULL << i) : (rnd() >> i);
    for (int i = 0; i < nw; i++) {
      uint64_t a = word_clz(w[i]), b = T_word_clz(w[i]);
      checks++;
      if (a != b) { fails++; printf("MISMATCH word_clz(%llx): %llu vs %llu\n",
                                    (unsigned long long)w[i],
                                    (unsigned long long)a, (unsigned long long)b); }
    }
  }
  printf("checks=%d mismatches=%d\n", checks, fails);
  return fails != 0;
}
