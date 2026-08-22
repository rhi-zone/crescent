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
`.intel_syntax` — see `TODO.md` ("New tcc assembler gap").

**Selected by a configure-time capability probe, not by compiler name.**
`dep/libressl/patches/0003-configure-intel-syntax-probe.patch` adds an
`AC_COMPILE_IFELSE` to `configure.ac` that assembles a `.intel_syntax
noprefix` snippet and defines `AM_CONDITIONAL([ASM_INTEL_SYNTAX])` from the
result; `crypto/Makefile.am.elf-x86_64` uses that conditional to compile
either the originals in `../` or the files here. An assembler that answers
yes — gcc and clang both do — never touches this directory, so the
originals stay the canonical path and the shipped build is unaffected.

Note that the vendored tree itself stays pristine: `0003` is applied at
build time, like `0001`/`0002`, so this selection only exists in builds
that opt into the patch stack.

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

Buildability and correctness under the vendored tcc is a separate question
with a separate answer: 15 of the 21 assemble and are verified equivalent
to the GNU `as` build; the 6 ADX fast-path routines are rejected outright.
That status is **not restated here** — this file lives under `dep/`, which
is content-hashed by `tooling/scripts/vendor-verify.sh`, so status that
changes as the tcc gaps close does not belong in it. See
`docs/native-tiers.md`, "Verifying tcc's own codegen", for the current
numbers, the methodology, and the re-run command
(`tooling/scripts/verify-bignum-att-tcc.sh <patched-tcc>`).
