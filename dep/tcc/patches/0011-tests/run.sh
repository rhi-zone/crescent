#!/usr/bin/env bash
# Compare a tcc build against real GNU as on the mov{ups,aps,hps} operand types.
# Usage: run.sh /path/to/tcc
#
# t*.S are positive cases: gas must accept them and tcc must produce the same
# bytes and relocations. n*.S are negative cases: gas must REJECT them, and so
# must tcc. The negative half is the point of this patch as much as the
# positive half -- the operand types being wrong did not only reject valid
# input, it silently accepted invalid input and encoded something else.
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
    printf "%-20s SKIP (gas rejects)\n" "$b"; continue
  fi
  if ! "$TCC" -c -o "$b.tcc.o" "$f" 2>"$b.err"; then
    printf "%-20s FAIL tcc: %s\n" "$b" "$(sed 's/.*error: //' "$b.err" | head -1)"
    fail=$((fail+1)); continue
  fi
  dump "$b.gas.o" > "$b.gas.txt"
  dump "$b.tcc.o" > "$b.tcc.txt"
  if diff -q "$b.gas.txt" "$b.tcc.txt" >/dev/null; then
    printf "%-20s OK (matches gas)\n" "$b"; pass=$((pass+1))
  else
    printf "%-20s MISMATCH vs gas\n" "$b"
    diff "$b.gas.txt" "$b.tcc.txt" | head -12 | sed 's/^/      /'
    fail=$((fail+1))
  fi
done

for f in "$SRCDIR"/n*.S; do
  b="$(basename "${f%.S}")"
  if as --nocompress-debug-sections -o "$b.gas.o" "$f" 2>/dev/null; then
    printf "%-20s BROKEN CASE (gas accepts it; not a negative case)\n" "$b"
    fail=$((fail+1)); continue
  fi
  if "$TCC" -c -o "$b.tcc.o" "$f" 2>/dev/null; then
    printf "%-20s FAIL tcc accepts what gas rejects, emitting: %s\n" "$b" \
      "$(objdump -d "$b.tcc.o" | tail -1 | sed 's/^ *[0-9a-f]*:\t//')"
    fail=$((fail+1))
  else
    printf "%-20s OK (rejected, as gas does)\n" "$b"; pass=$((pass+1))
  fi
done

echo "-----"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
