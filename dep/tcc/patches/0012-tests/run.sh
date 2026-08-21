#!/usr/bin/env bash
# Compare a tcc build against real GNU as on the .value assembler directive.
# Usage: run.sh /path/to/tcc
#
# Each t*.S must assemble to the same bytes and relocations as gas produces.
# On top of that, the .short control and the .value file carry identical
# content, so the run also asserts the two spellings agree with each other --
# in gas (the premise this patch rests on) and in tcc (what it implements).
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

dump() {
  local obj="$1"
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
    diff "$b.gas.txt" "$b.tcc.txt" | head -12 | sed 's/^/      /'
    fail=$((fail+1))
  fi
done

# The equivalence itself, stated directly rather than inferred from two
# independent comparisons: same content, two spellings, same output.
for who in gas tcc; do
  if [ -f "t0_short_control.$who.txt" ] && [ -f "t1_value.$who.txt" ]; then
    if diff -q "t0_short_control.$who.txt" "t1_value.$who.txt" >/dev/null; then
      printf "%-22s OK (.value == .short in %s)\n" "equivalence/$who" "$who"; pass=$((pass+1))
    else
      printf "%-22s MISMATCH (.value != .short in %s)\n" "equivalence/$who" "$who"
      diff "t0_short_control.$who.txt" "t1_value.$who.txt" | head -12 | sed 's/^/      /'
      fail=$((fail+1))
    fi
  else
    printf "%-22s FAIL (missing dump for %s; an earlier case did not get far enough)\n" "equivalence/$who" "$who"
    fail=$((fail+1))
  fi
done

echo "-----"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
