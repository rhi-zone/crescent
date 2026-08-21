#!/usr/bin/env bash
# Compare a tcc build against real GNU as on .rept, including .rept in a unit
# that needs a second layout pass.
# Usage: run.sh /path/to/tcc
#
# Each t*.S must assemble to the same bytes as gas produces.  Byte identity
# is the right bar: these files are straight-line, so there is no branch-form
# freedom for the two assemblers to disagree within, and the whole question
# here is how many copies of a body end up in .text -- which is exactly what
# the bytes say.
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

for f in "$SRCDIR"/t*.S; do
  b="$(basename "${f%.S}")"
  if ! as --nocompress-debug-sections -o "$b.gas.o" "$f" 2>/dev/null; then
    printf "%-24s FAIL (gas rejects it)\n" "$b"; fail=$((fail+1)); continue
  fi
  if ! "$TCC" -c -o "$b.tcc.o" "$f" 2>"$b.err"; then
    printf "%-24s FAIL tcc: %s\n" "$b" "$(sed 's/.*error: //' "$b.err" | head -1)"
    fail=$((fail+1)); continue
  fi
  readelf -x .text "$b.gas.o" > "$b.gas.hex"
  readelf -x .text "$b.tcc.o" > "$b.tcc.hex"
  if diff -q "$b.gas.hex" "$b.tcc.hex" >/dev/null; then
    printf "%-24s OK (matches gas)\n" "$b"; pass=$((pass+1))
  else
    printf "%-24s MISMATCH vs gas\n" "$b"
    diff "$b.gas.hex" "$b.tcc.hex" | head -12 | sed 's/^/      /'
    # Say how many bodies came out, since that is the failure this file is
    # looking for and the hex dump does not read that way.
    for who in gas tcc; do
      printf "      %s: %d nop bytes in .text\n" "$who" \
        "$(objdump -d --no-show-raw-insn "$b.$who.o" | grep -c '\bnop$')"
    done
    fail=$((fail+1))
  fi
done

echo "-----"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
