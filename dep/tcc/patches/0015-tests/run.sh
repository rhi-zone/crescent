#!/usr/bin/env bash
# Compare a tcc build against real GNU as on the ADX and BMI2 instructions
# added by patch 0015: adcx, adox and mulx.
# Usage: run.sh /path/to/tcc
#
# Two kinds of case:
#
#   t*.S  gas accepts them, and tcc must produce the same bytes.  Byte
#         identity is the right bar here, unlike for whole translated
#         routines: these files contain no branches and no relocations, so
#         there is no encoding freedom left for the two assemblers to
#         disagree within.  A VEX prefix that had, say, the vvvv field
#         un-inverted would still disassemble to a plausible instruction, so
#         comparing mnemonics would not be enough -- the bytes are compared.
#
#   n*.S  gas REJECTS them (no 16-bit form exists for any of the three), and
#         tcc must reject them too.  Without this half, a template that
#         silently assembled `adcxw' as the 32-bit form would pass every
#         positive case above.
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
