#!/usr/bin/env bash
# Compare a tcc build against real GNU as on the .macro/.endm and
# .if/.elseif/.else/.endif assembler directives added by patch 0017.
# Usage: run.sh /path/to/tcc
#
# Three kinds of case:
#
#   t*.S  gas accepts them, and tcc must produce the same bytes.  Byte
#         identity is the right bar: every file is straight-line, so there is
#         no branch-form freedom for the two assemblers to disagree within,
#         and what is being checked -- which arm was taken, how many times a
#         body was expanded, what an argument turned into -- is exactly what
#         .text ends up containing.
#
#   n*.S  gas REJECTS them, and tcc must too.  A macro system that quietly
#         accepted a malformed definition would pass every positive case.
#
#   u*.S  gas ACCEPTS them and this tcc deliberately does not: parameter
#         defaults, the \@ counter, a stray .endm.  What is asserted is that
#         each is refused with a diagnostic rather than misread -- the
#         failure mode that matters is silently assembling something else.
#         These are the known edges of what is implemented, written down.
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
    printf "%-24s FAIL (gas rejects a case it is supposed to accept)\n" "$b"
    fail=$((fail+1)); continue
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
    diff <(objdump -d --no-show-raw-insn "$b.gas.o" | tail -n +4) \
         <(objdump -d --no-show-raw-insn "$b.tcc.o" | tail -n +4) \
      | head -16 | sed 's/^/      /'
    fail=$((fail+1))
  fi
done

for f in "$SRCDIR"/n*.S; do
  b="$(basename "${f%.S}")"
  if as --nocompress-debug-sections -o "$b.gas.o" "$f" 2>/dev/null; then
    printf "%-24s FAIL (gas ACCEPTS it: the premise of this case is wrong)\n" "$b"
    fail=$((fail+1)); continue
  fi
  if "$TCC" -c -o "$b.tcc.o" "$f" 2>/dev/null; then
    printf "%-24s FAIL (tcc accepted what gas rejects)\n" "$b"
    fail=$((fail+1))
  else
    printf "%-24s OK (rejected, as gas does)\n" "$b"; pass=$((pass+1))
  fi
done

for f in "$SRCDIR"/u*.S; do
  b="$(basename "${f%.S}")"
  if ! as --nocompress-debug-sections -o "$b.gas.o" "$f" 2>/dev/null; then
    printf "%-24s FAIL (gas rejects it too: this is not an unimplemented-feature case)\n" "$b"
    fail=$((fail+1)); continue
  fi
  if "$TCC" -c -o "$b.tcc.o" "$f" 2>"$b.err"; then
    printf "%-24s FAIL (tcc accepted an unimplemented feature: it is being misread)\n" "$b"
    fail=$((fail+1))
  else
    printf "%-24s OK (unimplemented, diagnosed: %s)\n" "$b" \
      "$(sed 's/.*error: //' "$b.err" | head -1)"
    pass=$((pass+1))
  fi
done

echo "-----"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
