#!/usr/bin/env bash
# Check that `tcc -run' copes with a section that has no runtime address.
# Usage: run.sh /path/to/tcc
#
# Unlike 0021-tests and 0022-tests this one cannot be pointed at gcc: `-run'
# is tcc's own mode and has no gcc equivalent. What it does instead is check
# every expectation twice -- once through `-run', once by building the same
# source into an ordinary executable with $CC (gcc unless overridden) and
# running that. The -run answer and the linked answer have to agree, which is
# what makes the numbers below a reference rather than this patch's opinion.
# If no $CC is available the reference arm is skipped, loudly.
#
# What is being fixed: tccrun.c hands out runtime addresses to SHF_ALLOC
# sections only. Everything else keeps sh_addr == 0 and is never copied into
# the run memory at all. relocate_sections() relocated those sections anyway,
# so a relocation inside one computed against an address the section does not
# have, while the symbols it referred to had real heap addresses -- garbage in
# the 64-bit case and, in the 32-bit cases, a value that does not fit at all:
#
#   tcc: error: relocation '2' out of range
#   tcc: error: relocation 'R_X86_64_32[S]' out of range
#
# and the program did not run. `0021' fixed the case where a section was
# WRONGLY non-allocated (`.data.ignore' and `.rodata', which as considers
# allocatable and tcc did not). This is the case underneath it: a section that
# is CORRECTLY non-allocated, which no name table can make go away.
#
# t3 is the control in the other direction -- an allocated section whose
# relocation is still real work -- and t4 is `-run -g', where tcc's own
# backtrace reads debug information at runtime.
set -u
TCC="${1:?usage: run.sh /path/to/tcc}"
CC="${CC:-gcc}"
HERE="$(cd "$(dirname "$0")" && pwd)"

# Unlike the sibling suites this one actually RUNS the compiled programs, so
# tcc has to find its own runtime (libtcc1.a, runmain.o). An uninstalled build
# tree keeps those next to the binary, so point -B there when they are there;
# an installed tcc finds them itself and needs nothing.
TCCB=
if [ -f "$(dirname "$TCC")/libtcc1.a" ]; then
  TCCB="-B$(dirname "$TCC")"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0

ok()   { printf '  PASS  %-28s %s\n' "$1" "$2"; pass=$((pass + 1)); }
bad()  { printf '  FAIL  %-28s %s\n' "$1" "$2"; fail=$((fail + 1)); }

# runcase <name> <expected-stdout>
runcase() {
  local t="$1" want="$2" got
  got="$("$TCC" $TCCB -run "$HERE/$t.c" 2>&1)"
  if [ "$got" = "$want" ]; then ok "$t -run" "$got"
  else bad "$t -run" "got [$got], wanted [$want]"; fi

  if command -v "$CC" >/dev/null 2>&1; then
    if "$CC" -o "$WORK/$t" "$HERE/$t.c" 2>"$WORK/cc.err"; then
      got="$("$WORK/$t" 2>&1)"
      if [ "$got" = "$want" ]; then ok "$t via $CC" "$got"
      else bad "$t via $CC" "got [$got], wanted [$want]"; fi
    else
      bad "$t via $CC" "reference build failed: $(head -1 "$WORK/cc.err")"
    fi
  else
    printf '  SKIP  %-28s no %s to cross-check against\n' "$t" "$CC"
  fi
}

echo "== relocations in sections with no runtime address ($TCC)"
runcase t0_pc32_nonalloc  '42 1'
runcase t1_abs32_nonalloc '42 1'
runcase t2_abs64_nonalloc '42 1'
runcase t3_alloc_control  '42'

# -run -g: the backtrace has to keep resolving frames to file:line. A fix that
# skipped relocations in every non-allocated section, or that skipped them in
# allocated ones by accident, shows up here as bare addresses.
echo "== -run -g backtrace ($TCC)"
"$TCC" $TCCB -g -run "$HERE/t4_backtrace.c" > "$WORK/bt.out" 2>&1
for want in 't4_backtrace.c:17: at inner' \
            't4_backtrace.c:22: by middle' \
            't4_backtrace.c:29: by main'; do
  if grep -qF "$want" "$WORK/bt.out"; then ok "backtrace frame" "$want"
  else bad "backtrace frame" "missing [$want]"; fi
done
if grep -q '^before$' "$WORK/bt.out"; then ok "backtrace" "program ran"
else bad "backtrace" "program produced no output"; fi

echo "----- pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
