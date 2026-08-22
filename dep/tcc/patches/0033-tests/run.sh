#!/usr/bin/env bash
# Compare a tcc build against real GNU as on the SSSE3, SSE4.1 and SHA-NI
# instructions added by patch 0033.
# Usage: run.sh /path/to/tcc
#
# Two kinds of case:
#
#   t*.S  gas accepts them, and tcc must produce the same bytes.  Byte
#         identity is the right bar here, unlike for whole translated
#         routines: these files are straight-line, with no relocations, so
#         there is no encoding freedom left for the two assemblers to
#         disagree within.  It also has to be the bytes rather than the
#         disassembly: an omitted mandatory 0x66, or a ModRM byte whose two
#         register fields were filled from the wrong operands, still
#         disassembles to a perfectly plausible instruction of the right
#         mnemonic.
#
#   n*.S  gas REJECTS them, and tcc must reject them too.  Each one names an
#         encoding that does not exist but that a too-permissive template
#         would assemble as some neighbouring instruction -- a wrong answer
#         at runtime rather than a build failure, which no positive case can
#         catch.
#
# t4_prefix_neighbours.S ends in a branch, which is the one place the two
# assemblers have a free choice (short against near displacement).  It is
# a backward branch to a label in the same file, so both resolve it at
# assembly time and neither emits a relocation; gas and tcc both pick the
# short form, and the bytes still compare equal.
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
    printf "%-22s FAIL (gas rejects a case it is supposed to accept)\n" "$b"
    fail=$((fail+1)); continue
  fi
  if ! "$TCC" -c -o "$b.tcc.o" "$f" 2>"$b.err"; then
    printf "%-22s FAIL tcc: %s\n" "$b" "$(sed 's/.*error: //' "$b.err" | head -1)"
    fail=$((fail+1)); continue
  fi
  objdump -d --no-show-raw-insn "$b.gas.o" | tail -n +4 > "$b.gas.dis"
  objdump -d --no-show-raw-insn "$b.tcc.o" | tail -n +4 > "$b.tcc.dis"
  readelf -x .text "$b.gas.o" > "$b.gas.hex"
  readelf -x .text "$b.tcc.o" > "$b.tcc.hex"
  if diff -q "$b.gas.hex" "$b.tcc.hex" >/dev/null; then
    printf "%-22s OK (bytes match gas)\n" "$b"; pass=$((pass+1))
  else
    printf "%-22s MISMATCH vs gas\n" "$b"
    # The disassembly diff is the readable form of the same disagreement;
    # the hex is what was actually compared.
    diff "$b.gas.dis" "$b.tcc.dis" | head -12 | sed 's/^/      /'
    fail=$((fail+1))
  fi
done

for f in "$SRCDIR"/n*.S; do
  b="$(basename "${f%.S}")"
  if as --nocompress-debug-sections -o "$b.gas.o" "$f" 2>/dev/null; then
    printf "%-22s FAIL (gas ACCEPTS it: the premise of this case is wrong)\n" "$b"
    fail=$((fail+1)); continue
  fi
  if "$TCC" -c -o "$b.tcc.o" "$f" 2>/dev/null; then
    printf "%-22s FAIL (tcc accepted what gas rejects)\n" "$b"
    fail=$((fail+1))
  else
    printf "%-22s OK (rejected, as gas does)\n" "$b"; pass=$((pass+1))
  fi
done

echo "-----"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
