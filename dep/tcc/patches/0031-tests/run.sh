#!/usr/bin/env bash
# Check that a negative repeat count on .skip/.space/.zero is diagnosed the
# way GNU as diagnoses it.
# Usage: run.sh /path/to/tcc     (also passes against gcc: run.sh "$(command -v gcc)")
#
# GNU as gives `.skip -1' / `.space -1' / `.zero -1' a warning --
#
#     Warning: .space repeat count is negative, ignored
#
# -- which is a DIFFERENT message from the zero-count one 0029 closed, for a
# different input. tcc clamped the count to zero and said nothing at all.
#
# The two counts are separate exits in as, not one message with two
# spellings, and both outrank everything else as checks about the directive:
#
#   .skip -1,7  in NOBITS  ->  negative repeat count   (not the fill warning)
#   .skip  0,7  in NOBITS  ->  zero repeat count       (0029's case)
#   .skip  4,7  in NOBITS  ->  ignoring fill value     (0024's case)
#
# All three rows were measured against binutils 2.44 before being written
# down, and the whole script passes unchanged against a real gcc -- which is
# what makes it a reference rather than this patch's own opinion. The middle
# row is here as a guard: the fix must add a message, not widen the existing
# one, and a build that reported "negative" for a zero count would fail here
# even though it warns.
#
# The messages are matched on the part as and tcc share, since the two spell
# their line prefixes differently.
#
# Needs `readelf` on PATH. The cases differ only in a directive or two, so
# they are generated here rather than committed as near-identical .S files.
set -u
TCC="${1:?usage: run.sh /path/to/tcc}"

# All intermediates go to a temp directory, never next to the sources: this
# script lives under dep/tcc/, and tooling/scripts/vendor-verify.sh hashes the
# committed source tree.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0

ok_()  { printf '  PASS  %-48s %s\n' "$1" "${2-}"; pass=$((pass + 1)); }
bad_() { printf '  FAIL  %-48s %s\n' "$1" "${2-}"; fail=$((fail + 1)); }

# The three phrases this patch's area can produce. A case names the one it
# expects; any of the others turning up is a failure, which is what pins
# "as takes the negative-count exit FIRST, and it is its own message" rather
# than merely "as says something here".
P_NEG='repeat count is negative, ignored'
P_ZERO='repeat count is zero, ignored'
P_FILL='ignoring fill value in section'

# run <label> <want> <line>...
#
#   want is one of
#     -            assembles with none of the three phrases
#     neg          the negative-repeat-count warning, and neither other
#     zero         the zero-repeat-count warning, and neither other
#     fill         the fill-value warning, and neither other
#
# Assembly must succeed in every case here: all three are warnings.
run() {
  local label="$1" want="$2"; shift 2
  local out rc n_neg n_zero n_fill got

  printf '%s\n' "$@" > "$WORK/t.S"
  out="$("$TCC" -c "$WORK/t.S" -o "$WORK/t.o" 2>&1)"; rc=$?

  if [ "$rc" -ne 0 ]; then
    bad_ "$label" "assembly failed: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-70)"
    return
  fi

  n_neg="$(printf '%s\n' "$out" | grep -cF "$P_NEG")"
  n_zero="$(printf '%s\n' "$out" | grep -cF "$P_ZERO")"
  n_fill="$(printf '%s\n' "$out" | grep -cF "$P_FILL")"
  case "$n_neg:$n_zero:$n_fill" in
    0:0:0) got=- ;;
    1:0:0) got=neg ;;
    0:1:0) got=zero ;;
    0:0:1) got=fill ;;
    *)     got="neg x$n_neg + zero x$n_zero + fill x$n_fill" ;;
  esac

  if [ "$got" = "$want" ]; then
    ok_ "$label" "$got"
  else
    bad_ "$label" "got '$got', wanted '$want'"
  fi
}

# size <label> <section> <want-decimal> <line>...
# The warning says the directive is IGNORED; this is that word taken
# literally, so a fix that warned and then still reserved space -- or one
# that let a negative count through to the size arithmetic -- would fail.
size() {
  local label="$1" sec="$2" want="$3"; shift 3
  local hex got
  printf '%s\n' "$@" > "$WORK/t.S"
  if ! "$TCC" -c "$WORK/t.S" -o "$WORK/t.o" >/dev/null 2>&1; then
    bad_ "$label" "assembly failed"; return
  fi
  # readelf prints the size in hex; the conversion is shell arithmetic rather
  # than awk's strtonum, which is a gawk extension and absent from the awk in
  # an alpine container -- where this has to run, since that is one of the
  # two libcs CI builds on.
  hex="$(readelf -S -W "$WORK/t.o" 2>/dev/null | sed 's/^ *\[[ 0-9]*\] //' \
         | awk -v n="$sec" '$1 == n { print $5; exit }')"
  if [ -z "$hex" ]; then got='<missing>'; else got="$((0x$hex))"; fi
  if [ "$got" = "$want" ]; then ok_ "$label" "$sec size=$got"
  else bad_ "$label" "$sec size=$got, wanted $want"; fi
}

echo "-- negative repeat count warns, in every section type"
run '.skip -1 in .text'          neg '.text' '.skip -1'
run '.skip -1 in .data'          neg '.data' '.skip -1'
run '.skip -1 in .bss'           neg '.bss'  '.skip -1'
run '.skip -1 in named PROGBITS' neg '.section .rodata.z,"a",@progbits' '.skip -1'
run '.skip -1 in named NOBITS'   neg '.section .bss.z,"aw",@nobits'     '.skip -1'

echo "-- all three spellings are the same directive in as"
run '.space -1 in .text'         neg '.text' '.space -1'
run '.zero -1 in .text'          neg '.text' '.zero -1'
run '.space -1 in named NOBITS'  neg '.section .bss.z,"aw",@nobits' '.space -1'
run '.zero -1 in named NOBITS'   neg '.section .bss.z,"aw",@nobits' '.zero -1'

echo "-- the count is the folded value, not a literal minus sign"
run '.skip 1-2'                  neg '.text' '.skip 1-2'
run '.skip label difference'     neg '.text' 'a:' 'b:' '.skip a-b-1'
run '.skip 2*-1'                 neg '.text' '.skip 2*-1'
run '.skip -4 far from zero'     neg '.text' '.skip -4096'

echo "-- the fill operand is still consumed, then dropped with the rest"
run '.skip -1,7 in .text'        neg '.text' '.skip -1,7'
run '.skip -1,7 in .data'        neg '.data' '.skip -1,7'
run '.zero -2,7 in .text'        neg '.text' '.zero -2,7'

echo "-- a negative count beats the fill-value warning, as zero does"
run '.skip -1,7 in .bss'         neg '.bss' '.skip -1,7'
run '.skip -1,7 in named NOBITS' neg '.section .bss.z,"aw",@nobits' '.skip -1,7'
run '.space -3,255 in .tbss'     neg '.section .tbss,"awT",@nobits' '.space -3,255'

echo "-- zero is still the zero message, not this one (0029 unregressed)"
run '.skip 0 in .text'           zero '.text' '.skip 0'
run '.zero 0 in named NOBITS'    zero '.section .bss.z,"aw",@nobits' '.zero 0'
run '.skip 0,7 in .bss'          zero '.bss' '.skip 0,7'
run '.skip 4-4 in .text'         zero '.text' '.skip 4-4'

echo "-- 0024's warning still fires where as still fires it"
run '.skip 4,7 in named NOBITS'  fill '.section .bss.z,"aw",@nobits' '.skip 4,7'
run '.zero 4,7 in named NOBITS'  fill '.section .bss.z,"aw",@nobits' '.zero 4,7'
run '.align 1,5 in named NOBITS' fill '.section .bss.z,"aw",@nobits' '.align 1,5'

echo "-- a positive count says nothing, before and after this patch"
run '.skip 4 in .text'           -    '.text' '.skip 4'
run '.space 4 in .text'          -    '.text' '.space 4'
run '.zero 4 in .text'           -    '.text' '.zero 4'
run '.skip 4 in named NOBITS'    -    '.section .bss.z,"aw",@nobits' '.skip 4'
run '.skip 4,0 in named NOBITS'  -    '.section .bss.z,"aw",@nobits' '.skip 4,0'
run '.align 1 in .text'          -    '.text' '.align 1'
run '.p2align 0 in .text'        -    '.text' '.p2align 0'

echo "-- \"ignored\" means ignored: nothing is reserved, nothing is rewound"
size '.skip -1 reserves nothing'      .bss     0 '.bss' '.skip -1'
size '.skip -1,7 reserves nothing'    .bss     0 '.bss' '.skip -1,7'
size '.skip -1 between two bytes'     .data    2 '.data' '.byte 1' '.skip -1' '.byte 2'
size '.zero -8 leaves .text alone'    .text    1 '.text' 'nop' '.zero -8'
size 'a positive count still counts'  .bss    16 '.bss' '.skip 16'

echo "-----"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
