#!/usr/bin/env bash
# Checks for 0009-reserved-section-input-side-gate.patch.
# Usage: run.sh /path/to/tcc [-B<tccdir>]
#
# Needs readelf on PATH.  The coverage cases need a working dynamic link
# (-ftest-coverage pulls in tcc's tcov runtime, which calls into libc); where
# that is unavailable the case skips rather than failing.
set -u
TCC="${1:?usage: run.sh /path/to/tcc [-Btccdir]}"
BFLAG="${2:--B$(dirname "$TCC")}"
SRCDIR="$(cd "$(dirname "$0")" && pwd)"

# All intermediates go to a temp directory, never into SRCDIR: this script
# lives under dep/tcc/, and tooling/scripts/vendor-verify.sh hashes every file
# `find` turns up there with no gitignore awareness, so build artifacts left
# beside the sources would break the vendored-source hash check.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

pass=0; fail=0
ok()   { echo "PASS  $1"; pass=$((pass+1)); }
bad()  { echo "FAIL  $1"; fail=$((fail+1)); }
skip() { echo "SKIP  $1"; }

RESERVED="section '.tcov' is reserved for internal use"

# count sections whose name is exactly $2
count_sec() {
  readelf -SW "$1" 2>/dev/null \
    | sed -nE 's/^ *\[[ 0-9]+\] +([^ ]+).*/\1/p' \
    | grep -cxF -- "$2"
}

# $1 = case name, rest = tcc arguments producing out.bin
expect_refused() {
  local what="$1"; shift
  rm -f out.bin
  local err; err=$("$TCC" "$BFLAG" "$@" -o out.bin 2>&1)
  if echo "$err" | grep -qF "$RESERVED"; then
    [ -f out.bin ] && bad "$what: reported but output still written" \
                   || ok  "$what"
  else
    bad "$what: not refused (got: ${err:-no diagnostic})"
  fi
}

"$TCC" "$BFLAG" -c "$SRCDIR/foreign_tcov.S" -o foreign_tcov.o 2>/dev/null \
  || { echo "cannot assemble fixtures with this tcc"; exit 1; }

# Does this environment link -ftest-coverage at all?  Without that, a refusal
# cannot be told apart from an unrelated link failure, so the cases skip.
printf 'int main(void){return 0;}\n' > cov_ctl.c
if "$TCC" "$BFLAG" -ftest-coverage cov_ctl.c -o cov_ctl.out 2>/dev/null; then
  COV=1
else
  COV=0
fi

# --- 1. the gap 0009 closes: tcc creates the role first --------------------
if [ "$COV" = 1 ]; then
  # object merge.  Before 0009 this linked silently, with the input's content
  # merged into tcc's coverage table.
  expect_refused ".tcov: input object merged into tcc's section is refused" \
    -ftest-coverage "$SRCDIR/cov_main.c" foreign_tcov.o
  # the assembler's two reuse-by-name directives
  expect_refused ".tcov: asm .section naming tcc's section is refused" \
    -ftest-coverage "$SRCDIR/asm_tcov.c"
  expect_refused ".tcov: asm .pushsection naming tcc's section is refused" \
    -ftest-coverage "$SRCDIR/asm_push_tcov.c"

  # --- 2. both orderings agree ---------------------------------------------
  # Input first, tcc's creator second: refused since 0007.  Asserted here so
  # the two directions are pinned to the same verdict by one harness.
  expect_refused ".tcov: input object named before tcc's creator is refused" \
    -ftest-coverage foreign_tcov.o "$SRCDIR/cov_main.c"
else
  skip ".tcov cases (no working -ftest-coverage link in this environment)"
fi

# --- 3. guard: no role, no reservation -------------------------------------
# Without -ftest-coverage tcc creates no .tcov, so the name is nothing special
# and an input section may use it.  The reservation follows the role, not the
# name.
printf 'int foreign_value(void);\nvoid _start(void){int r=foreign_value();__asm__ volatile("mov $60,%%%%eax; syscall"::"D"(r):"eax");}\n' > plain_main.c
if "$TCC" "$BFLAG" -nostdlib plain_main.c foreign_tcov.o -o plain.out 2>/dev/null; then
  ./plain.out; [ $? = 42 ] \
    && ok "input .tcov links and runs when tcc claims no coverage role" \
    || bad "input .tcov link produced wrong result"
  [ "$(count_sec plain.out .tcov)" = 1 ] \
    && ok "input .tcov survives as an ordinary section" \
    || bad "input .tcov did not survive as an ordinary section"
else
  bad "input .tcov refused even though tcc claims no coverage role"
fi

if "$TCC" "$BFLAG" -c "$SRCDIR/asm_tcov.c" -o asm_tcov.o 2>/dev/null; then
  ok "asm .section .tcov assembles when tcc claims no coverage role"
else
  bad "asm .section .tcov refused when tcc claims no coverage role"
fi

# --- 4. guard: SHARED roles still merge in this ordering --------------------
# tcc creates .eh_frame at its first FDE while compiling eh_main.c, then
# foreign_eh.o is merged into it.  That is the same "tcc first, input second"
# ordering as case 1, on a role whose answer is yes.
if "$TCC" "$BFLAG" -c "$SRCDIR/foreign_eh.S" -o foreign_eh.o 2>/dev/null \
   && "$TCC" "$BFLAG" -nostdlib "$SRCDIR/eh_main.c" foreign_eh.o -o eh.out 2>/dev/null; then
  ./eh.out; [ $? = 42 ] \
    && ok "SHARED .eh_frame still merges input content in this ordering" \
    || bad "SHARED .eh_frame merge lost the input content"
  [ "$(count_sec eh.out .eh_frame)" = 1 ] \
    && ok "one .eh_frame, not two" \
    || bad "SHARED .eh_frame produced the wrong number of sections"
else
  bad "SHARED .eh_frame link failed"
fi

# --- 5. guard: ordinary compilation is unaffected ---------------------------
printf 'int val(void){return 5;}\nvoid _start(void){int r=val();__asm__ volatile("mov $60,%%%%eax; syscall"::"D"(r):"eax");}\n' > hello.c
if "$TCC" "$BFLAG" -nostdlib hello.c -o hello.out 2>/dev/null; then
  ./hello.out; [ $? = 5 ] && ok "ordinary compile+link+run unaffected (exit 5)" \
                          || bad "ordinary link produced wrong result"
else
  bad "ordinary link failed"
fi

echo "---- $pass passed, $fail failed ----"
[ "$fail" = 0 ]
