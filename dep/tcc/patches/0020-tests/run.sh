#!/usr/bin/env bash
# Check that __TINYC__ is a usable preprocessor number again, and that fixing
# it did not cost the vendoring pin.
# Usage: run.sh /path/to/tcc
#
# Upstream tinycc builds __TINYC__ by slicing its own version string:
#
#     cstr_printf(cs, "#define __TINYC__ 9%.2s\n", &TCC_VERSION[4]);
#
# i.e. "0.9.XX" -> 9XX, and TCC_VERSION comes from the VERSION file that
# ./configure (and win32/build-tcc.bat) read. crescent overwrites that VERSION
# file with the vendored mob-branch commit SHA, because mob is untagged and
# rolling and a SHA is the only pin that can express "this exact source". The
# slice then ran over a SHA: offset 4 of
# 2ba12e83b3599ca8f5d50c179fe5138fe956f0c9 is "2e", so tcc predefined
# `__TINYC__ 92e` -- not a number. Every `#if __TINYC__` in every source it
# compiled died with "exponent digits expected", tcc's own tests/tcctest.c
# (line 338) included, on a pristine tree with no patches at all.
#
# `0020-tinyc-version-predefine.patch` splits the two meanings apart instead of
# picking one: TCC_VERSION stays the SHA provenance pin, and a separate
# TCC_UPSTREAM_VERSION in tcc.h carries what upstream's VERSION file actually
# says at that commit ("0.9.28rc"), which is what the slice now reads. 928 is
# therefore upstream's own number for this source, not an invented one.
#
# t4 is the reason the split matters: the tempting one-file fix is to put a
# real version back into VERSION, which silently drops the pin. t4 fails if
# anyone does that.
set -u
TCC="${1:?usage: run.sh /path/to/tcc}"
SRCDIR="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
check() { # check <name> <expected-rc> <cmd...>
  local name="$1" want="$2"; shift 2
  "$@" >"$WORK/out" 2>&1
  local got=$?
  if [ "$got" -eq "$want" ]; then
    printf '  PASS  %s\n' "$name"
    pass=$((pass + 1))
  else
    printf '  FAIL  %s (rc=%s, wanted %s)\n' "$name" "$got" "$want"
    sed 's/^/          /' "$WORK/out" | head -5
    fail=$((fail + 1))
  fi
}

echo "== __TINYC__ predefine ($TCC)"
check "t0 #if __TINYC__ compiles"        0 "$TCC" -c -o "$WORK/t0.o" "$SRCDIR/t0_if_guard.c"
check "t1 __TINYC__ == 928"              0 "$TCC" -c -o "$WORK/t1.o" "$SRCDIR/t1_exact_value.c"
check "t2 __TINYC__ == 928 in asm mode"  0 "$TCC" -c -o "$WORK/t2.o" "$SRCDIR/t2_asm_mode.S"
check "t3 __TINYC__ still defined"       0 "$TCC" -c -o "$WORK/t3.o" "$SRCDIR/t3_still_defined.c"

# t4: `tcc -v` must still report the vendoring pin verbatim. Read the expected
# value from the pin file rather than hardcoding it, so re-vendoring to a new
# commit does not turn this into a false failure.
pin="$(head -n1 "$SRCDIR/../../VERSION" 2>/dev/null || true)"
if [ -z "$pin" ]; then
  printf '  FAIL  t4 pin file dep/tcc/VERSION is missing or empty\n'
  fail=$((fail + 1))
elif "$TCC" -v 2>&1 | grep -qF -- "$pin"; then
  printf '  PASS  t4 tcc -v still reports the vendoring pin\n'
  pass=$((pass + 1))
else
  printf '  FAIL  t4 tcc -v no longer reports the pin (%s)\n' "$pin"
  printf '          %s\n' "$("$TCC" -v 2>&1 | head -1)"
  fail=$((fail + 1))
fi

echo "----- pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
