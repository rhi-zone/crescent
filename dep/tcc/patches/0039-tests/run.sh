#!/usr/bin/env bash
# Check that a compiler's LP64 data-model predefines are complete and agree
# with the target it is actually generating code for.
# Usage: run.sh /path/to/tcc     (also passes against gcc: run.sh "$(command -v gcc)")
#
# ## The defect
#
# tcc predefined `__LP64__` on LP64 targets but not `_LP64`. gcc and clang
# define both. The two are not alternatives with a preferred spelling -- they
# are a pair, and portable code tests whichever one it was written against.
#
# Code that tests only the missing one does not fail to compile. It silently
# takes the compiler's 32-bit branch on a 64-bit target, which is strictly
# worse than an error, because it produces a program that builds and runs and
# is wrong.
#
# That is exactly how it was found. libressl's include/openssl/bn.h selects its
# bignum limb type with `#if defined(_LP64) || defined(_WIN64)` and never
# consults `__LP64__`, so amd64 libressl built by tcc used 32-bit limbs while
# the s2n-bignum assembly it calls uses 64-bit ones. `make check` was 92/136,
# with every bn_* test failing and rsa/dsa/ec/dh/cms/tls failing behind them.
# Defining `_LP64` and changing nothing else took it to 136/136.
#
# ## The reference behaviour this pins
#
# Measured against gcc 15.2 on x86-64, not assumed:
#
#   * an LP64 target predefines BOTH `__LP64__` and `_LP64`;
#   * neither is predefined on a non-LP64 target. gcc -m32 defines
#     `__ILP32__` and `_ILP32` instead -- also both spellings, which is the
#     same pairing rule seen from the other side;
#   * the macros agree with the code actually being generated: on the target
#     that defines them, long and pointer are both 8 bytes.
#
# The third is what makes the first two more than a spelling convention. A
# predefine that disagrees with the generated code is the bug; the harness
# checks the macro against `sizeof`, not against a hardcoded expectation.
#
# ## What this harness pins
#
# Those properties, plus one reduction of the real failure: a bn.h-shaped
# type selection written against `_LP64` must pick a limb as wide as the
# machine word. That check is what actually fails on an unpatched tcc, and it
# fails for the same reason libressl did, without needing libressl.
#
# It does NOT pin: which spelling any given consumer uses, the values of the
# macros (gcc uses 1; nothing should test the value), any other predefine, or
# anything about ILP32 code generation beyond the absence of the LP64 pair.
#
# Every check is compile-only -- no linking, no libc, no headers. That keeps it
# runnable against a cross-configured or partially-installed tcc, and on hosts
# (NixOS among them) where linking needs an explicit interpreter and crt path
# that have nothing to do with what is being measured.
#
# ## The 32-bit leg is conditional
#
# It runs only if the compiler can produce a 32-bit object at all. A tcc built
# without its i386 cross binary cannot, and reports that rather than failing:
# the LP64 half is the part this patch changes, and it is checked
# unconditionally.

set -u
CC="${1:?usage: run.sh /path/to/cc}"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0; skip=0

# ok <name> <expect-compile: yes|no> <source>
#
# Compile-only, -nostdinc so no header search can influence the result. The
# `no` direction matters as much as the `yes` one: several checks are written
# as a static assertion that must FAIL to compile when the property is absent,
# which is how a missing predefine is detected rather than inferred.
ok() {
  local name="$1" expect="$2" src="$3" out rc
  printf '%s\n' "$src" > "$WORK/t.c"
  out="$("$CC" -nostdinc -c -o "$WORK/t.o" "$WORK/t.c" 2>&1)"; rc=$?
  if [ "$expect" = yes ] && [ $rc -eq 0 ]; then
    printf '  ok    %s\n' "$name"; pass=$((pass+1))
  elif [ "$expect" = no ] && [ $rc -ne 0 ]; then
    printf '  ok    %s (rejected, as it must be)\n' "$name"; pass=$((pass+1))
  else
    printf '  FAIL  %s (expected compile=%s, got rc=%s)\n' "$name" "$expect" "$rc"
    printf '%s\n' "$out" | head -5 | sed 's/^/          /'
    fail=$((fail+1))
  fi
}

echo "== $CC : LP64 predefines (native target)"

ok "_LP64 is predefined" yes '
#if !defined(_LP64)
#error _LP64 not predefined on an LP64 target
#endif
int probe;'

ok "__LP64__ is predefined" yes '
#if !defined(__LP64__)
#error __LP64__ not predefined on an LP64 target
#endif
int probe;'

# The pairing rule, stated as one property rather than two independent ones:
# whichever spelling a consumer reaches for, it must get the same answer.
ok "the two spellings agree with each other" yes '
#if defined(_LP64) != defined(__LP64__)
#error _LP64 and __LP64__ disagree
#endif
int probe;'

ok "no ILP32/LLP64 marker on an LP64 target" yes '
#if defined(__ILP32__) || defined(_ILP32) || defined(__LLP64__)
#error a non-LP64 data-model marker is set on an LP64 target
#endif
int probe;'

# The check that makes the above more than a naming convention: the macro is
# compared against the code being generated, via a negative-array-size static
# assertion, not against a hardcoded 8.
ok "the macros agree with generated code (long and pointer are 8)" yes '
#if defined(_LP64)
typedef int assert_long_is_8[sizeof(long) == 8 ? 1 : -1];
typedef int assert_ptr_is_8[sizeof(void *) == 8 ? 1 : -1];
typedef int assert_long_is_word[sizeof(long) == sizeof(void *) ? 1 : -1];
#else
#error _LP64 absent; the preceding check should already have failed
#endif
int probe;'

echo "== $CC : the libressl bn.h failure, reduced"

# This is include/openssl/bn.h:143 with the names changed. On an unpatched tcc
# LIMB comes out 32-bit on a 64-bit target and the third assertion fires --
# which is precisely the mismatch that made the s2n-bignum assembly read and
# write the wrong width.
ok "a _LP64-gated limb selection picks a machine-word limb" yes '
#if defined(_LP64) || defined(_WIN64)
typedef unsigned long LIMB;
#define LIMB_BITS 64
#else
typedef unsigned int LIMB;
#define LIMB_BITS 32
#endif
typedef int assert_limb_bits[sizeof(LIMB) * 8 == LIMB_BITS ? 1 : -1];
typedef int assert_limb_is_word[sizeof(LIMB) == sizeof(void *) ? 1 : -1];
typedef int assert_limb_is_64[LIMB_BITS == 64 ? 1 : -1];
int probe;'

# Negative control: the same assertion machinery must actually be capable of
# rejecting something. Without this, a compiler that silently ignored bad array
# sizes would show all-green above and mean nothing.
ok "negative control: static assertions are load-bearing" no '
typedef int deliberately_broken[-1];
int probe;'

echo "== $CC : non-LP64 target (32-bit)"

if printf 'int probe;\n' > "$WORK/m32.c" && "$CC" -m32 -nostdinc -c -o "$WORK/m32.o" "$WORK/m32.c" >/dev/null 2>&1; then
  m32ok() {
    local name="$1" src="$2" out rc
    printf '%s\n' "$src" > "$WORK/t32.c"
    out="$("$CC" -m32 -nostdinc -c -o "$WORK/t32.o" "$WORK/t32.c" 2>&1)"; rc=$?
    if [ $rc -eq 0 ]; then printf '  ok    %s\n' "$name"; pass=$((pass+1))
    else printf '  FAIL  %s\n' "$name"; printf '%s\n' "$out" | head -5 | sed 's/^/          /'; fail=$((fail+1)); fi
  }
  m32ok "neither LP64 spelling is set on a 32-bit target" '
#if defined(_LP64) || defined(__LP64__)
#error an LP64 marker is set on a 32-bit target
#endif
typedef int assert_long_is_4[sizeof(long) == 4 ? 1 : -1];
int probe;'
else
  echo "  skip  32-bit leg: $CC cannot produce a 32-bit object here"
  echo "        (a tcc built without its i386 cross binary; not a failure --"
  echo "         the LP64 half above is what this patch changes)"
  skip=$((skip+1))
fi

echo "-----"
echo "pass=$pass fail=$fail skip=$skip"
[ "$fail" -eq 0 ]
