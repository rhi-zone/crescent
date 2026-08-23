# 0039 — `_LP64` on LP64 targets

## The defect

`include/tccdefs.h` predefined `__LP64__` on LP64 targets and not `_LP64`.
gcc and clang define both — verified directly against gcc 15.2 on x86-64,
which emits `__LP64__ 1` and `_LP64 1`, and (from the other side) `__ILP32__ 1`
and `_ILP32 1` under `-m32`.

The two spellings are a pair, not alternatives with a preferred form. Portable
code tests whichever one it was written against, and neither is more correct.

What makes a missing one dangerous rather than merely incomplete is that it
does not produce an error. `#if defined(_LP64)` on a compiler that omits it is
not a diagnostic — it is a silent selection of the 32-bit branch on a 64-bit
target. The build succeeds, the program runs, and the data model is wrong.

## How it was found

Building libressl 4.3.2 with tcc, with assembly enabled for the first time
(`dep/libressl/patches/0003`), `make check` came out 92/136. All 44 failures
were bignum-rooted: every `bn_*` test, and rsa, dsa, ec, dh, cms and tls behind
them, with symptoms ranging from `BN_add` dropping high words to `bn_div_words`
asserting to glibc aborting on a corrupted heap.

`include/openssl/bn.h:143` selects the bignum limb type with

    #if defined(_LP64) || defined(_WIN64)
    #define BN_ULONG        uint64_t
    #define BN_BITS2        64
    #else
    #define BN_ULONG        uint32_t
    #define BN_BITS2        32
    #endif

`__LP64__` is not consulted. So amd64 libressl under tcc was building its whole
bignum layer on 32-bit limbs while the vendored s2n-bignum assembly it calls
reads and writes 64-bit ones. Adding `-D_LP64` and changing nothing else took
the same tree to 136/136.

The assembly was never at fault, and neither was the AT&T mirror selection that
`0003` wires up: calling `bignum_add` directly out of the tcc-built
`libcrypto.a` on a failing vector returned the correct result.

Two things are worth keeping in view. The `--disable-asm` tcc build that has
been reported as 136/136 in this effort was passing with 32-bit bignum limbs on
x86-64 — self-consistent pure C, hence green, but not the configuration anyone
intended. And fixing the one header check downstream would have left the trap
armed for the next consumer that spells it `_LP64`.

## The fix

One line in `include/tccdefs.h`, beside the `__LP64__` it pairs with.

It lands in the branch that already establishes LP64: the surrounding
conditional selects on `__SIZEOF_POINTER__ == 4` (ILP32), then
`__SIZEOF_LONG__ == 4` (LLP64, 64-bit Windows), and the `#else` this sits in is
reached only when pointer and long are both 64-bit. Win64 — where neither gcc
nor MSVC defines `_LP64` — is untouched, as is the 32-bit branch.

Indentation is load-bearing in that file: only lines indented four or more
columns reach the compiled-in predefs, and column-1 lines are conditionals
whose platform macros are substituted at conversion time. The new line matches
its neighbour.

## Not fixed here

The 32-bit branch defines `__ILP32__` without `_ILP32` — the mirror image of
this gap, and confirmed real against gcc, which defines both. Nothing in this
effort builds a 32-bit target, so closing it would be an unmeasured change to
a configuration nothing here exercises. It is recorded in `TODO.md` instead.

## What `run.sh` pins

Reference behaviour measured against gcc, not assumed: an LP64 target
predefines both spellings; a non-LP64 target predefines neither; and — the
check that makes the first two more than a naming convention — the macros agree
with the code actually being generated, compared against `sizeof` rather than
against a hardcoded 8.

Plus one reduction of the real failure: a `bn.h`-shaped, `_LP64`-gated limb
selection must pick a limb as wide as the machine word. On an unpatched tcc
that check fails with `invalid array size`, for the same reason libressl
failed, without needing libressl.

A negative control asserts that the static-assertion machinery can actually
reject something, so an all-green run means the checks ran rather than that
they were vacuous.

Every check is compile-only — no linking, no libc, no headers — so the harness
runs against a partially-installed or cross-configured tcc, and on hosts where
linking needs an explicit interpreter and crt path irrelevant to what is being
measured.

Measured results: gcc 8/8. Unpatched tcc 3 pass, 4 fail — including the bn.h
reduction. Patched tcc 7/7, with the 32-bit leg skipped (this build has no
i386 cross binary; the harness reports that rather than failing, since the LP64
half is what the patch changes).

    ./run.sh /path/to/tcc
    ./run.sh "$(command -v gcc)"
