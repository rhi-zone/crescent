# AT&T-syntax mirror of `../` (Intel syntax)

These 21 files are AT&T-syntax translations of the Intel-syntax s2n-bignum
`.S` files vendored one directory up (`dep/libressl/crypto/bn/arch/amd64/`).
They are **not** an independent source import — each file here is generated
from its Intel-syntax counterpart via `attrofy.sed` and proven
instruction/relocation/symbol-identical to it (see verification methodology
in `docs/native-tiers.md`, "libressl bignum: AT&T mirror for tcc").

The Intel-syntax originals in `../` remain the canonical, primary vendored
source. gcc and clang builds always use `../` directly (via
`.intel_syntax noprefix`, which they both support). This `att/` directory
exists only because tcc's assembler is AT&T-only and does not implement
`.intel_syntax` — see `TODO.md` ("New tcc assembler gap"). **These files are
not yet wired into any build** — that is a separate step, gated on closing
the remaining tcc opcode/macro gaps described below.

## Provenance

- `attrofy.sed` is AWS's own upstream translator, vendored unmodified from
  `awslabs/s2n-bignum`, path `x86_att/attrofy.sed`. Confirmed byte-identical
  to that file as of upstream commit `0f2140569318222f27c852fc4e3c0f32c60e8afe`
  (2026-08-05, the last commit to touch that path) through `main` HEAD
  `ac31a43db30953037abd1b64b540e65cf31f4c67` (2026-08-18) — the file has not
  changed across that range.
- The 21 `.S` files here were produced by running that script, unmodified,
  against the current Intel-syntax files in `../` (`sed -E -f attrofy.sed`;
  `-E` because the script relies on GNU extended-regex group syntax).

## Regenerating

```bash
cd dep/libressl/crypto/bn/arch/amd64
for f in *.S; do sed -E -f att/attrofy.sed "$f" > att/"$f"; done
```

Then re-run the verification described in `docs/native-tiers.md` before
trusting the output — this is a translator, not a proof; each regeneration
needs re-checking against a real assembler.

## Current verification status

All 21 files: proven byte-identical to their Intel-syntax originals when
assembled by GNU `as` (via `gcc -c`), across 4 preprocessor configs
(default, `-DWINDOWS_ABI=1`, `-DNO_IBT=1`, `-DS2N_BN_HIDE_SYMBOLS=1`) —
`.text` bytes, relocations, and symbols all match. 84/84 checks pass.

Buildability under the vendored tcc (separate from the above, and **not**
fully verified — see `TODO.md`):

- 6 files (`bignum_mul_4_8.S`, `bignum_mul_6_12.S`, `bignum_mul_8_16.S`,
  `bignum_sqr_4_8.S`, `bignum_sqr_6_12.S`, `bignum_sqr_8_16.S` — the ADX
  fast-path routines) are rejected outright by the vendored tcc: it lacks
  `mulx`/`adcx`/`adox` opcode support and `.macro`/`.endm`. Confirmed by
  direct assembly attempt.
- The other 15 assemble under tcc without error. Whether their instruction
  stream is equivalent to the gcc/gas ground truth is tracked as separate,
  in-progress work, not independently re-derived here.
