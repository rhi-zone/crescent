#!/usr/bin/env bash
# Compare a tcc build against real GNU as on '$' immediates reached through a
# preprocessor macro in an asm file.
# Usage: run.sh /path/to/tcc
#
# These inputs need the C preprocessor, so the reference side is
# `gcc -x assembler-with-cpp` (cpp + as) rather than bare `as`, which does not
# preprocess. tcc assembles .S files through its own integrated preprocessor,
# so it is invoked directly -- running the input through `tcc -E` first would
# assemble already-expanded text and step around the very thing under test.
#
# The comparison has to be on bytes, not on exit status: before this patch the
# shift/rotate cases failed loudly ("bad operand"), but the mov/add cases
# ASSEMBLED, silently emitting an absolute-address load instead of an
# immediate. A pass/fail harness would have called those green.
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
  if ! gcc -c -x assembler-with-cpp -o "$b.gas.o" "$f" 2>/dev/null; then
    printf "%-24s SKIP (gas rejects)\n" "$b"; continue
  fi
  if ! "$TCC" -c -o "$b.tcc.o" "$f" 2>"$b.err"; then
    printf "%-24s FAIL tcc: %s\n" "$b" "$(sed 's/.*error: //' "$b.err" | head -1)"
    fail=$((fail+1)); continue
  fi
  dump "$b.gas.o" > "$b.gas.txt"
  dump "$b.tcc.o" > "$b.tcc.txt"
  if diff -q "$b.gas.txt" "$b.tcc.txt" >/dev/null; then
    printf "%-24s OK (matches gas)\n" "$b"; pass=$((pass+1))
  else
    printf "%-24s MISMATCH vs gas\n" "$b"
    diff "$b.gas.txt" "$b.tcc.txt" | head -12 | sed 's/^/      /'
    fail=$((fail+1))
  fi
done

# The equivalence the patch rests on, stated directly rather than inferred from
# three independent comparisons: an immediate does not change meaning by being
# reached through a macro. t0, t1 and t2 carry the same instruction sequence
# written literally, through object-like macros, and through function-like
# macros, so all three must produce identical output -- in gas (the premise)
# and in tcc (the claim).
for who in gas tcc; do
  for variant in t1_object_macro_imm t2_function_macro_imm; do
    if [ -f "t0_literal_control.$who.txt" ] && [ -f "$variant.$who.txt" ]; then
      if diff -q "t0_literal_control.$who.txt" "$variant.$who.txt" >/dev/null; then
        printf "%-24s OK (%s == literal in %s)\n" "equiv/$who/${variant%%_*}" "$variant" "$who"
        pass=$((pass+1))
      else
        printf "%-24s MISMATCH (%s != literal in %s)\n" "equiv/$who/${variant%%_*}" "$variant" "$who"
        diff "t0_literal_control.$who.txt" "$variant.$who.txt" | head -8 | sed 's/^/      /'
        fail=$((fail+1))
      fi
    else
      printf "%-24s FAIL (missing dump for %s; an earlier case did not get far enough)\n" "equiv/$who/${variant%%_*}" "$who"
      fail=$((fail+1))
    fi
  done
done

echo "-----"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
