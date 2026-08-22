#!/usr/bin/env bash
# Check that content written into a SHT_NOBITS section is diagnosed the way
# GNU as diagnoses it.
# Usage: run.sh /path/to/tcc     (also passes against gcc: run.sh "$(command -v gcc)")
#
# A SHT_NOBITS section has a size in the object file and no bytes: it says
# "reserve this much zeroed space". A non-zero byte therefore cannot be
# represented in one at all. GNU as rejects the attempt; tcc reserved the
# space, threw the value away, and said nothing.
#
# `.bss' has derived NOBITS in tcc forever, so the silent drop predates
# `0022-asm-section-type.patch'. What 0022 changed is the reach: once the
# section TYPE is derived from the name and from `@type', every name as
# calls NOBITS -- `.bss.foo', `.tbss*', `.gnu.linkonce.b*', and anything
# declared `,@nobits' -- lands on the same silent drop that only `.bss' used
# to. Widening a gap is a reason to close it, which is what 0024 does.
#
# as does not have one message here, it has three errors and a warning, and
# which one you get depends on the directive rather than on the value:
#
#   .byte/.word/.short/.value/.int/.long/.quad/.uleb128/.sleb128
#       "attempt to store non-zero value in section `NAME'", once per
#       offending value in the directive.
#   .ascii/.asciz/.string
#       "attempt to store non-empty string in section `NAME'", once per
#       non-zero BYTE of the string.
#   .fill
#       "attempt to fill section `NAME' with non-zero value", once for the
#       directive however many bytes it would have written.
#   .skip/.space/.align/.balign/.p2align with an explicit fill value
#       "ignoring fill value in section `NAME'" -- a WARNING. The size is
#       legitimate, only the fill byte has nowhere to go, so as drops the
#       byte and carries on. This asymmetry is the easiest thing here to get
#       wrong in the direction of a spurious error, so it is pinned below.
#
# Two details of as's test are worth stating because guessing them the
# obvious way gets them backwards:
#
#   * as tests the value as WRITTEN, before truncation to the field. So
#     `.byte 256' is an error even though the byte it would store is zero,
#     and so is `.fill 4,1,256'.
#   * Constant folding happens first, and a relocation is always non-zero as
#     far as as is concerned. `foo: .long foo-foo' and `.long 1-1' fold to
#     nothing and pass; `foo: .long foo' needs a relocation and fails even
#     though foo sits at offset 0.
#
# And what stays legal, because it is the entire point of a NOBITS section:
# `.byte 0', `.long 0', `.skip N', `.zero N', `.space N', `.fill N,M,0',
# `.asciz ""', `.uleb128 0', `.align N' -- all silent, all still reserving
# exactly as much space as before. Machine instructions are not checked by
# as at all: `nop' in `.bss' assembles, grows the section, and warns about
# nothing, so tcc must leave that path alone too.
#
# Every expectation below was measured against binutils 2.44 `as` before
# being written down, and the whole script passes unchanged against a real
# gcc -- which is what makes it a reference rather than this patch's own
# opinion. The messages are matched on the part as and tcc share, since the
# two spell their line prefixes differently.
#
# Needs `readelf` on PATH. The cases differ only in a directive or two, so
# they are generated here rather than committed as ~50 near-identical .S
# files.
set -u
TCC="${1:?usage: run.sh /path/to/tcc}"

# All intermediates go to a temp directory, never next to the sources: this
# script lives under dep/tcc/, and tooling/scripts/vendor-verify.sh hashes the
# committed source tree.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0

# Size readelf reports for section $2 of object $1, in decimal. readelf prints
# it in hex; the conversion is shell arithmetic rather than awk's strtonum,
# which is a gawk extension and absent from the awk in an alpine container --
# where this has to run, since that is one of the two libcs CI builds on.
secsize() {
  local hex
  hex="$(readelf -S -W "$1" 2>/dev/null | sed 's/^ *\[[ 0-9]*\] //' \
         | awk -v n="$2" '$1 == n { print $5; exit }')"
  if [ -z "$hex" ]; then echo "<missing>"; else echo "$((0x$hex))"; fi
}

# report <verdict> <label> [detail...]
ok_()   { printf '  PASS  %-44s %s\n' "$1" "${2-}"; pass=$((pass + 1)); }
bad_()  { printf '  FAIL  %-44s %s\n' "$1" "${2-}"; fail=$((fail + 1)); }

# run <label> <expectation> <line>...
#
#   expectation is one of
#     ok:<size>            assembles silently; named section is <size> bytes
#     err:<n>:<phrase>     assembly fails; <phrase> appears <n> times
#     warn:<n>:<phrase>    assembly succeeds; <phrase> appears <n> times
#
# The first body line must be the .section directive; its name is the
# section whose size `ok:' checks.
run() {
  local label="$1" expect="$2"; shift 2
  local kind want phrase name out rc got sec
  kind="${expect%%:*}"

  printf '%s\n' "$@" > "$WORK/t.S"
  sec="$(printf '%s' "$1" | sed 's/^\.section  *//; s/,.*//')"

  out="$("$TCC" -c "$WORK/t.S" -o "$WORK/t.o" 2>&1)"; rc=$?

  case "$kind" in
  ok)
    want="${expect#ok:}"
    if [ "$rc" -ne 0 ]; then
      bad_ "$label" "assembly failed, wanted silent success"
      printf '%s\n' "$out" | sed 's/^/          /' | head -3
      return
    fi
    # "silent" means silent about NOBITS. Nothing else should be reported
    # either, but only these phrases would be this patch's doing.
    if printf '%s' "$out" | grep -qiE 'attempt to (store|fill)|ignoring fill value'; then
      bad_ "$label" "wanted silence, got: $(printf '%s' "$out" | tr '\n' ' ')"
      return
    fi
    got="$(secsize "$WORK/t.o" "$sec")"
    if [ "$got" = "$want" ]; then
      ok_ "$label" "$sec size=$got"
    else
      bad_ "$label" "$sec size=$got, wanted $want"
    fi
    ;;
  err|warn)
    want="${expect#*:}"; phrase="${want#*:}"; want="${want%%:*}"
    got="$(printf '%s\n' "$out" | grep -cF "$phrase")"
    if [ "$kind" = err ] && [ "$rc" -eq 0 ]; then
      bad_ "$label" "assembly succeeded, wanted an error"
      return
    fi
    if [ "$kind" = warn ] && [ "$rc" -ne 0 ]; then
      bad_ "$label" "assembly failed, wanted a warning and success"
      printf '%s\n' "$out" | sed 's/^/          /' | head -3
      return
    fi
    if [ "$got" = "$want" ]; then
      ok_ "$label" "${kind} x$got"
    else
      bad_ "$label" "matched $got, wanted $want -- $(printf '%s' "$out" | tr '\n' ' ')"
    fi
    ;;
  *)
    bad_ "$label" "bad expectation '$expect' in this script"
    ;;
  esac
}

NZ='attempt to store non-zero value in section'
NS='attempt to store non-empty string in section'
NF='with non-zero value'
IF='ignoring fill value in section'

BSS='.section .bss,"aw",@nobits'

echo "== content in a SHT_NOBITS section ($TCC)"

echo "-- data directives: a non-zero value is an error, one per value"
run '.byte 5'                "err:1:$NZ \`.bss'"   "$BSS" '.byte 5'
run '.byte 5,6'              "err:2:$NZ \`.bss'"   "$BSS" '.byte 5,6'
run '.byte 0,5,0'            "err:1:$NZ \`.bss'"   "$BSS" '.byte 0,5,0'
run '.word 1'                "err:1:$NZ \`.bss'"   "$BSS" '.word 1'
run '.short 1'               "err:1:$NZ \`.bss'"   "$BSS" '.short 1'
run '.value 1'               "err:1:$NZ \`.bss'"   "$BSS" '.value 1'
run '.int 1'                 "err:1:$NZ \`.bss'"   "$BSS" '.int 1'
run '.long 1'                "err:1:$NZ \`.bss'"   "$BSS" '.long 1'
run '.quad 1'                "err:1:$NZ \`.bss'"   "$BSS" '.quad 1'
run '.uleb128 5'             "err:1:$NZ \`.bss'"   "$BSS" '.uleb128 5'
run '.sleb128 -1'            "err:1:$NZ \`.bss'"   "$BSS" '.sleb128 -1'

echo "-- ... tested before truncation to the field, as as does"
run '.byte 256'              "err:1:$NZ \`.bss'"   "$BSS" '.byte 256'

echo "-- ... and after constant folding, so a value that folds to 0 passes"
run '.long 2-1'              "err:1:$NZ \`.bss'"   "$BSS" '.long 2-1'
run '.long 1-1'              'ok:4'                "$BSS" '.long 1-1'
run '.long foo-foo'          'ok:4'                "$BSS" 'foo: .long foo-foo'

echo "-- ... a relocation is never zero, whatever the symbol's address"
run '.long defined-at-0'     "err:1:$NZ \`.bss'"   "$BSS" 'foo: .long foo'
run '.long undefined'        "err:1:$NZ \`.bss'"   "$BSS" '.long nowhere_at_all'

echo "-- strings: one error per non-zero byte; an empty one is fine"
run '.ascii "hi"'            "err:2:$NS \`.bss'"   "$BSS" '.ascii "hi"'
run '.ascii "abc"'           "err:3:$NS \`.bss'"   "$BSS" '.ascii "abc"'
run '.asciz "hi"'            "err:2:$NS \`.bss'"   "$BSS" '.asciz "hi"'
run '.ascii "a\0b"'          "err:2:$NS \`.bss'"   "$BSS" '.ascii "a\000b"'
run '.ascii "\0"'            'ok:1'                "$BSS" '.ascii "\000"'
run '.asciz ""'              'ok:1'                "$BSS" '.asciz ""'
run '.string ""'             'ok:1'                "$BSS" '.string ""'

echo "-- .fill: its own wording, said once for the whole directive"
run '.fill 4,1,7'            "err:1:$NF"           "$BSS" '.fill 4,1,7'
run '.fill 4,4,7'            "err:1:$NF"           "$BSS" '.fill 4,4,7'
run '.fill 4,1,256'          "err:1:$NF"           "$BSS" '.fill 4,1,256'
run '.fill 0,1,7 (emits 0)'  'ok:0'                "$BSS" '.fill 0,1,7'
run '.fill 4,0,7 (emits 0)'  'ok:0'                "$BSS" '.fill 4,0,7'
run '.fill 4,1,0'            'ok:4'                "$BSS" '.fill 4,1,0'
run '.fill 4 (implicit 0)'   'ok:4'                "$BSS" '.fill 4'

echo "-- reserving space is the point of NOBITS: all silent, sizes intact"
run '.byte 0'                'ok:1'                "$BSS" '.byte 0'
run '.byte 0,0,0'            'ok:3'                "$BSS" '.byte 0,0,0'
run '.long 0'                'ok:4'                "$BSS" '.long 0'
run '.quad 0'                'ok:8'                "$BSS" '.quad 0'
run '.uleb128 0'             'ok:1'                "$BSS" '.uleb128 0'
run '.sleb128 0'             'ok:1'                "$BSS" '.sleb128 0'
run '.skip 8'                'ok:8'                "$BSS" '.skip 8'
run '.skip 8,0'              'ok:8'                "$BSS" '.skip 8,0'
run '.space 8'               'ok:8'                "$BSS" '.space 8'
# `.zero N' -- as's third spelling of this, alongside .skip and .space -- is
# absent from the check above because tcc does not implement the directive at
# ALL: `.zero 8' is "unknown opcode" in `.text' just as much as in `.bss'. A
# missing directive is not a NOBITS diagnostic, so it is not 0024's to fix;
# it is recorded in TODO.md on its own.
run '.align 16'              'ok:16'               "$BSS" '.byte 0' '.align 16'
run '.balign 16'             'ok:16'               "$BSS" '.byte 0' '.balign 16'
run '.p2align 4'             'ok:16'               "$BSS" '.byte 0' '.p2align 4'
run '.org 16'                'ok:16'               "$BSS" '.org 16'

echo "-- an explicit non-zero fill is a WARNING, not an error: size stands"
run '.skip 8,5'              "warn:1:$IF \`.bss'"  "$BSS" '.skip 8,5'
run '.space 8,5'             "warn:1:$IF \`.bss'"  "$BSS" '.space 8,5'
run '.align 16,5'            "warn:1:$IF \`.bss'"  "$BSS" '.byte 0' '.align 16,5'
run '.balign 16,5'           "warn:1:$IF \`.bss'"  "$BSS" '.byte 0' '.balign 16,5'
run '.p2align 4,5'           "warn:1:$IF \`.bss'"  "$BSS" '.byte 0' '.p2align 4,5'
# as warns whatever the resulting size, including when it aligns to nothing.
run '.align 1,5 (size 0)'    "warn:1:$IF \`.bss'"  "$BSS" '.byte 0' '.align 1,5'

echo "-- as does not police instructions: nop in .bss assembles, silently"
run 'nop in .bss'            'ok:1'                "$BSS" 'nop'

echo "-- every name as derives NOBITS from, which is 0022's widening"
run '.bss.foo'               "err:1:$NZ \`.bss.foo'" '.section .bss.foo,"aw"' '.byte 5'
run '.tbss.x'                "err:1:$NZ \`.tbss.x'" '.section .tbss.x,"awT"' '.byte 5'
run '.gnu.linkonce.b.x'      "err:1:$NZ \`.gnu.linkonce.b.x'" '.section .gnu.linkonce.b.x,"aw"' '.byte 5'
run 'bare .bss directive'    "err:1:$NZ \`.bss'"   '.bss' '.byte 5'
run '@nobits on any name'    "err:1:$NZ \`.mybss'" '.section .mybss,"aw",@nobits' '.byte 5'
run '%nobits spelling'       "err:1:$NZ \`.mybss'" '.section .mybss,"aw",%nobits' '.byte 5'

echo "-- and a PROGBITS section is untouched: none of this applies there"
run 'progbits .byte 5'       'ok:1'                '.section .foo,"a",@progbits' '.byte 5'
run 'progbits .ascii'        'ok:2'                '.section .foo,"a",@progbits' '.ascii "hi"'
run 'progbits .fill 4,1,7'   'ok:4'                '.section .foo,"a",@progbits' '.fill 4,1,7'
run 'progbits .skip 8,5'     'ok:8'                '.section .foo,"a",@progbits' '.skip 8,5'
# 0022's precedence rule the other way: an @progbits argument beats the name,
# so this really is a writable PROGBITS section despite being called .bss.foo.
run '.bss.foo,@progbits'     'ok:1'                '.section .bss.foo,"aw",@progbits' '.byte 5'

echo "----- pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
