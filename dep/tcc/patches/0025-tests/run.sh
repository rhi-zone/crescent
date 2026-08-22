#!/usr/bin/env bash
# Compare a tcc build against real GNU as on the .zero assembler directive.
# Usage: run.sh /path/to/tcc     (also passes against gcc: run.sh "$(command -v gcc)")
#
# Before 0025, tcc had no `.zero' at all -- `unknown opcode '.zero''", in
# `.text' as much as in `.bss', so it was a missing directive and not
# anything to do with SHT_NOBITS. `.zero' is the spelling gcc emits most
# often for zero-initialised data, which is why it is worth closing.
#
# The one thing about `.zero' that reads backwards from its name, and the
# reason this harness carries fill values in its control content: `.zero' is
# NOT "`.space' with the fill fixed at zero". GNU as routes all three of
# `.skip', `.space' and `.zero' into one handler, fill operand included.
# Measured against binutils 2.44 before the patch was written:
#
#     .text
#     .zero 4,5      ->  05 05 05 05        (identical to `.skip 4,5')
#     .zero 0        ->  Warning: .space repeat count is zero, ignored
#     .zero 4,5      ->  Warning: ignoring fill value in section `.bss.foo'
#       (in a NOBITS section -- 0024's warning, reached by `.zero' too)
#
# So the accurate implementation shares `.skip''s case entirely, and the
# three-spelling agreement below is the assertion that pins it: t0, t1 and
# t2 hold byte-identical content differing only in the directive name, so
# their objects must be identical -- in gas, which is the premise, and in
# tcc, which is what 0025 implements. Two independent gas comparisons would
# not state that; this does.
#
# Diagnostics are deliberately not checked here. `.zero 0' warns in as and
# (until a later patch) not in tcc, and that gap belongs to the
# zero-repeat-count warning, not to this directive -- so no case below has a
# zero count. Adding `.zero' does not change what tcc says, only what it
# accepts.
#
# `.align' is kept out of the content on purpose: tcc's alignment padding in
# an executable section differs from gas's independently of anything here
# (recorded in TODO.md), and a case that fails for a known unrelated reason
# is worse than no case.
#
# Needs `as`, `readelf` on PATH.
set -u
TCC="${1:?usage: run.sh /path/to/tcc}"
SRCDIR="$(cd "$(dirname "$0")" && pwd)"

# All intermediates go to a temp directory, never into SRCDIR. This script
# lives under dep/tcc/, and tooling/scripts/vendor-verify.sh hashes every
# file `find` turns up there with no gitignore awareness -- so dropping
# build artifacts next to the sources would break the vendored-source hash
# check for anyone who ran the tests.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

pass=0; fail=0

# Every section's type, flags and size, plus the contents of the ones that
# have contents. The size line is what makes a NOBITS case mean anything:
# `.bss'-family sections reserve space and hold no bytes, so a hex dump
# alone would compare two empty strings and call it agreement.
#
# Empty sections are dropped from the listing because tcc always creates a
# `.data.ro' whether or not anything lands in it, and gas creates no such
# thing. That is tcc's section bookkeeping, unrelated to any directive, and
# it would otherwise fail every case here for a reason 0025 did not cause.
# Nothing this harness tests can produce a legitimately zero-size section.
dump() {
  local obj="$1"
  readelf -S -W "$obj" \
    | sed -n 's/^ *\[[ 0-9]*\] \(\.[A-Za-z0-9_.]*\) *\([A-Z]*\) *[0-9a-f]* *[0-9a-f]* *\([0-9a-f]*\) *[0-9a-f]* *\([A-Zx]*\).*/\1 \2 size=\3 flags=\4/p' \
    | grep -v '^\.comment\|^\.note\|^\.eh_frame\|^\.symtab\|^\.strtab\|^\.shstrtab\|^\.rela' \
    | grep -v ' size=000000 ' \
    | sort
  readelf -S -W "$obj" | sed -n 's/.*\] \(\.[A-Za-z0-9_.]*\) *PROGBITS *[0-9a-f]* *[0-9a-f]* *\([0-9a-f]*\).*/\1 \2/p' \
  | while read -r s sz; do
    case "$s" in .comment|.note*|.eh_frame) continue;; esac
    [ "0x$sz" = "0x000000" ] && continue
    echo "== section $s"
    readelf -x "$s" "$obj" 2>/dev/null | tail -n +3 | grep -v '^ NOTE:'
  done
  echo "== relocations"
  readelf -r -W "$obj" 2>/dev/null \
    | awk '/^[0-9a-f]{6,}/ {print $1, $3, $5, $6, $7}' | sort
}

for f in "$SRCDIR"/t*.S; do
  b="$(basename "${f%.S}")"
  if ! as --nocompress-debug-sections -o "$b.gas.o" "$f" 2>/dev/null; then
    printf "%-22s SKIP (gas rejects)\n" "$b"; continue
  fi
  if ! "$TCC" -c -o "$b.tcc.o" "$f" 2>"$b.err"; then
    printf "%-22s FAIL tcc: %s\n" "$b" "$(sed 's/.*error: //' "$b.err" | head -1)"
    fail=$((fail+1)); continue
  fi
  dump "$b.gas.o" > "$b.gas.txt"
  dump "$b.tcc.o" > "$b.tcc.txt"
  if diff -q "$b.gas.txt" "$b.tcc.txt" >/dev/null; then
    printf "%-22s OK (matches gas)\n" "$b"; pass=$((pass+1))
  else
    printf "%-22s MISMATCH vs gas\n" "$b"
    diff "$b.gas.txt" "$b.tcc.txt" | head -20 | sed 's/^/      /'
    fail=$((fail+1))
  fi
done

# The three-spelling equivalence, stated directly. Same content, three
# directive names, one object -- asserted separately in gas (the premise
# 0025 rests on) and in tcc (what 0025 implements).
for who in gas tcc; do
  ok=1
  for other in t1_zero t2_space; do
    if [ ! -f "t0_skip_control.$who.txt" ] || [ ! -f "$other.$who.txt" ]; then
      printf "%-22s FAIL (missing dump for %s; an earlier case did not get far enough)\n" "equivalence/$who" "$who"
      ok=0; break
    fi
    if ! diff -q "t0_skip_control.$who.txt" "$other.$who.txt" >/dev/null; then
      printf "%-22s MISMATCH (%s != .skip in %s)\n" "equivalence/$who" "$other" "$who"
      diff "t0_skip_control.$who.txt" "$other.$who.txt" | head -12 | sed 's/^/      /'
      ok=0
    fi
  done
  if [ "$ok" -eq 1 ]; then
    printf "%-22s OK (.zero == .space == .skip in %s)\n" "equivalence/$who" "$who"
    pass=$((pass+1))
  else
    fail=$((fail+1))
  fi
done

echo "-----"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
