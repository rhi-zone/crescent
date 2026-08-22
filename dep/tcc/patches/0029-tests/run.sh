#!/usr/bin/env bash
# Check that a zero repeat count on .skip/.space/.zero is diagnosed the way
# GNU as diagnoses it.
# Usage: run.sh /path/to/tcc     (also passes against gcc: run.sh "$(command -v gcc)")
#
# GNU as gives `.skip 0' / `.space 0' / `.zero 0' a warning --
#
#     Warning: .space repeat count is zero, ignored
#
# -- in every section type, and takes that exit ahead of everything else it
# would otherwise check about the directive. tcc said nothing at all.
#
# The one place the omission was already visible: `.skip 0,<non-zero>' in a
# SHT_NOBITS section got 0024's `ignoring fill value in section' warning,
# because tcc reached the fill-value test as never gets to. Two assemblers
# warning about two different things on the same input is worse than one of
# them being quiet, which is what makes this a fix and not a nicety.
#
# What decides which warning applies is the DIRECTIVE, not the size:
#
#   .skip 0,7   in NOBITS  ->  zero repeat count      (size is 0 AND from s_space)
#   .skip 4,7   in NOBITS  ->  ignoring fill value    (from s_space, size not 0)
#   .align 1,5  in NOBITS  ->  ignoring fill value    (size is 0, but NOT s_space)
#
# That last row is the discriminator, and the reason the fix cannot be
# "warn when size works out to zero". `.align`/`.balign`/`.p2align` are a
# different handler in as and have no repeat count to be zero; `.align 1` at
# an already-aligned offset contributes nothing and is silent, while
# `.align 1,5' in a NOBITS section still reports the fill it cannot store.
# Every row above was measured against binutils 2.44 before being written
# down, and the whole script passes unchanged against a real gcc -- which is
# what makes it a reference rather than this patch's own opinion.
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

# The two phrases this patch's area can produce. A case names the ones it
# expects; any of the others turning up is a failure, which is what pins
# "as takes the zero-count exit FIRST" rather than merely "as says this
# somewhere".
P_ZERO='repeat count is zero, ignored'
P_FILL='ignoring fill value in section'

# run <label> <want> <line>...
#
#   want is one of
#     -            assembles with neither phrase
#     zero         the zero-repeat-count warning, and not the fill one
#     fill         the fill-value warning, and not the zero one
#
# Assembly must succeed in every case here: both of these are warnings.
run() {
  local label="$1" want="$2"; shift 2
  local out rc n_zero n_fill got

  printf '%s\n' "$@" > "$WORK/t.S"
  out="$("$TCC" -c "$WORK/t.S" -o "$WORK/t.o" 2>&1)"; rc=$?

  if [ "$rc" -ne 0 ]; then
    bad_ "$label" "assembly failed: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-70)"
    return
  fi

  n_zero="$(printf '%s\n' "$out" | grep -cF "$P_ZERO")"
  n_fill="$(printf '%s\n' "$out" | grep -cF "$P_FILL")"
  case "$n_zero:$n_fill" in
    0:0) got=- ;;
    1:0) got=zero ;;
    0:1) got=fill ;;
    *)   got="zero x$n_zero + fill x$n_fill" ;;
  esac

  if [ "$got" = "$want" ]; then
    ok_ "$label" "$got"
  else
    bad_ "$label" "got '$got', wanted '$want'"
  fi
}

# size <label> <section> <want-decimal> <line>...
# The warning says the directive is IGNORED; this is that word taken
# literally, so a fix that warns and then still reserved space would fail.
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

echo "-- zero repeat count warns, in every section type"
run '.skip 0 in .text'          zero '.text' '.skip 0'
run '.skip 0 in .data'          zero '.data' '.skip 0'
run '.skip 0 in .bss'           zero '.bss'  '.skip 0'
run '.skip 0 in named PROGBITS' zero '.section .rodata.z,"a",@progbits' '.skip 0'
run '.skip 0 in named NOBITS'   zero '.section .bss.z,"aw",@nobits'     '.skip 0'

echo "-- all three spellings are the same directive in as"
run '.space 0 in .text'         zero '.text' '.space 0'
run '.zero 0 in .text'          zero '.text' '.zero 0'
run '.space 0 in named NOBITS'  zero '.section .bss.z,"aw",@nobits' '.space 0'
run '.zero 0 in named NOBITS'   zero '.section .bss.z,"aw",@nobits' '.zero 0'

echo "-- the count is the folded value, not the literal"
run '.skip 4-4'                 zero '.text' '.skip 4-4'
run '.skip label difference'    zero '.text' 'a:' 'b:' '.skip b-a'
run '.skip 2*0'                 zero '.text' '.skip 2*0'

echo "-- the fill operand is still consumed, then dropped with the rest"
run '.skip 0,7 in .text'        zero '.text' '.skip 0,7'
run '.skip 0,7 in .data'        zero '.data' '.skip 0,7'
run '.zero 0,7 in .text'        zero '.text' '.zero 0,7'

echo "-- the case the omission was visible in: zero count beats fill value"
run '.skip 0,7 in .bss'         zero '.bss' '.skip 0,7'
run '.skip 0,7 in named NOBITS' zero '.section .bss.z,"aw",@nobits' '.skip 0,7'
run '.space 0,255 in .tbss'     zero '.section .tbss,"awT",@nobits'  '.space 0,255'

echo "-- 0024's warning still fires where as still fires it"
run '.skip 4,7 in named NOBITS' fill '.section .bss.z,"aw",@nobits' '.skip 4,7'
run '.zero 4,7 in named NOBITS' fill '.section .bss.z,"aw",@nobits' '.zero 4,7'

echo "-- .align is a different handler in as and has no repeat count"
run '.align 1,5 in named NOBITS (size 0)' fill '.section .bss.z,"aw",@nobits' '.align 1,5'
run '.align 1 in .text'         -    '.text' '.align 1'
run '.balign 1 in .text'        -    '.text' '.balign 1'
run '.p2align 0 in .text'       -    '.text' '.p2align 0'
run '.align 1 in named NOBITS'  -    '.section .bss.z,"aw",@nobits' '.align 1'

echo "-- a non-zero count says nothing, before and after this patch"
run '.skip 4 in .text'          -    '.text' '.skip 4'
run '.space 4 in .text'         -    '.text' '.space 4'
run '.zero 4 in .text'          -    '.text' '.zero 4'
run '.skip 4 in named NOBITS'   -    '.section .bss.z,"aw",@nobits' '.skip 4'
run '.skip 4,0 in named NOBITS' -    '.section .bss.z,"aw",@nobits' '.skip 4,0'

echo "-- .org contributing nothing is not a repeat count either"
run '.org to current offset'    -    '.text' '.byte 1' '.org 1'

echo "-- \"ignored\" means ignored: no space is reserved"
size '.skip 0 reserves nothing'      .bss     0 '.bss' '.skip 0'
size '.skip 0,7 reserves nothing'    .bss     0 '.bss' '.skip 0,7'
size '.skip 0 between two bytes'     .data    2 '.data' '.byte 1' '.skip 0' '.byte 2'
size '.zero 0 leaves .text alone'    .text    1 '.text' 'nop' '.zero 0'
size 'a non-zero count still counts' .bss    16 '.bss' '.skip 16'

echo "-----"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
