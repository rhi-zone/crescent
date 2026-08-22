#!/usr/bin/env bash
# Compare a tcc build against real GNU as on the .octa directive added by
# patch 0036.
#
# Four kinds of case:
#
#   t*.S  as accepts them and tcc must emit the same data bytes.  Byte
#         identity is the bar: .octa carries a constant with no encoding
#         freedom at all, so any difference is a wrong answer, and the
#         difference that matters most (a 16-byte operand assembled at the
#         wrong width, or with its halves swapped) is invisible in anything
#         but the bytes.
#
#   n*.S  as REJECTS them and tcc must reject them too.
#
#   d*.S  as ACCEPTS them and tcc rejects them on purpose.  .octa's operand
#         grammar here is what as documents -- "zero or more bignums" --
#         plus one unary operator; every other form as takes is refused
#         rather than assembled, because the upper half as emits for an
#         expression operand comes from its X_extrabit flag rather than
#         from the value (`.octa 2-1' is 1 there with the whole upper half
#         set).  Each file says which form it is and why.  These are the
#         cases that would silently start emitting bytes if someone later
#         routed the operand through asm_expr, so they are checked, not
#         just documented.
#
#   x*.S  both accept, and what `as` emits is an artifact of its own rather
#         than a specification: the X_extrabit flag behind `~' and `-0',
#         and a number-lexer artifact that makes binutils 2.44 emit zero
#         for 2^64 written in octal while emitting the right value for the
#         same number written in hex.  The tcc bytes are pinned in a matching .expect
#         file; whether this `as' agrees is reported and never asserted,
#         because asserting it either way would make the harness track the
#         installed binutils rather than tcc.
#
# Usage: run.sh /path/to/tcc
set -u
TCC="${1:?usage: run.sh /path/to/tcc}"
SRCDIR="$(cd "$(dirname "$0")" && pwd)"

# All intermediates go to a temp directory, never into SRCDIR:
# tooling/scripts/vendor-verify.sh hashes every file under dep/tcc with no
# gitignore awareness, so build artifacts left next to the sources would
# break the vendored-source hash check for anyone who ran the tests.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

# The data bytes of an object, as a plain hex string: every allocated
# content section this suite uses, in a form that does not depend on
# readelf's column layout or on the two assemblers agreeing about section
# order, alignment padding or symbol tables.
data_bytes() {
  local obj="$1" sec out=""
  for sec in .data .rodata; do
    if objdump -h "$obj" | grep -q " $sec "; then
      out="$out$(objdump -s -j "$sec" "$obj" \
                 | sed -n 's/^ [0-9a-f]\{4,\} \(\([0-9a-f]\{2,8\} \)\{1,4\}\).*/\1/p' \
                 | tr -d ' \n')"
    fi
  done
  printf '%s\n' "$out"
}

pass=0; fail=0

for f in "$SRCDIR"/t*.S; do
  b="$(basename "${f%.S}")"
  if ! as -o "$b.gas.o" "$f" 2>/dev/null; then
    printf "%-24s FAIL (as rejects a case it is supposed to accept)\n" "$b"
    fail=$((fail+1)); continue
  fi
  if ! "$TCC" -c -o "$b.tcc.o" "$f" 2>"$b.err"; then
    printf "%-24s FAIL tcc: %s\n" "$b" "$(sed 's/.*error: //' "$b.err" | head -1)"
    fail=$((fail+1)); continue
  fi
  g="$(data_bytes "$b.gas.o")"; t="$(data_bytes "$b.tcc.o")"
  if [ "$g" = "$t" ]; then
    printf "%-24s OK (bytes match as)\n" "$b"; pass=$((pass+1))
  else
    printf "%-24s MISMATCH vs as\n" "$b"
    printf "      as : %s\n      tcc: %s\n" "$g" "$t"
    fail=$((fail+1))
  fi
done

for f in "$SRCDIR"/n*.S; do
  b="$(basename "${f%.S}")"
  if as -o "$b.gas.o" "$f" 2>/dev/null; then
    printf "%-24s FAIL (as ACCEPTS it: the premise of this case is wrong)\n" "$b"
    fail=$((fail+1)); continue
  fi
  if "$TCC" -c -o "$b.tcc.o" "$f" 2>/dev/null; then
    printf "%-24s FAIL (tcc accepted what as rejects)\n" "$b"
    fail=$((fail+1))
  else
    printf "%-24s OK (rejected, as as does)\n" "$b"; pass=$((pass+1))
  fi
done

for f in "$SRCDIR"/d*.S; do
  b="$(basename "${f%.S}")"
  if ! as -o "$b.gas.o" "$f" 2>/dev/null; then
    printf "%-24s FAIL (as rejects it too: this is an n-case, not a d-case)\n" "$b"
    fail=$((fail+1)); continue
  fi
  if "$TCC" -c -o "$b.tcc.o" "$f" 2>/dev/null; then
    printf "%-24s FAIL (tcc assembled an operand form it should refuse)\n" "$b"
    fail=$((fail+1))
  else
    printf "%-24s OK (refused by design; as accepts)\n" "$b"; pass=$((pass+1))
  fi
done

for f in "$SRCDIR"/x*.S; do
  b="$(basename "${f%.S}")"
  if ! as -o "$b.gas.o" "$f" 2>/dev/null || ! "$TCC" -c -o "$b.tcc.o" "$f" 2>/dev/null; then
    printf "%-24s FAIL (both assemblers are supposed to accept it)\n" "$b"
    fail=$((fail+1)); continue
  fi
  g="$(data_bytes "$b.gas.o")"; t="$(data_bytes "$b.tcc.o")"
  want="$(cat "${f%.S}.expect")"
  if [ "$t" != "$want" ]; then
    printf "%-24s FAIL (tcc bytes moved off the pin)\n      want: %s\n      got : %s\n" "$b" "$want" "$t"
    fail=$((fail+1))
  else
    # Whether `as' agrees is reported, never asserted.  These are the
    # operand forms where `as' answers from its X_extrabit flag or from an
    # artifact of its own number lexer -- an answer that is not even
    # consistent between bases within one release, never mind between
    # releases.  Asserting
    # either agreement or disagreement would make this harness pass or fail
    # on the version of `as' that happens to be installed rather than on
    # anything tcc does.
    if [ "$g" = "$t" ]; then
      printf "%-24s OK (pinned; this as agrees)\n" "$b"
    else
      printf "%-24s OK (pinned; this as differs, knowingly)\n" "$b"
    fi
    pass=$((pass+1))
  fi
done

echo "-----"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
