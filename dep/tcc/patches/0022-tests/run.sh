#!/usr/bin/env bash
# Check that a section's sh_type comes out the way GNU as decides it.
# Usage: run.sh /path/to/tcc     (also passes against gcc: run.sh "$(command -v gcc)")
#
# `0021-asm-section-name-attrs.patch' taught tcc that a section NAME carries
# flags, and said in as many words that it was leaving sh_type alone. This is
# that other half. Before it, tcc left every section it created SHT_PROGBITS:
# it derived the type from neither the name nor the directive's `@type'
# argument, which it parsed and threw away (two bare `next()' calls).
#
# GNU as decides the type from two places, and the interaction between them is
# not the same as the flags one, so it is worth stating exactly:
#
#   * The NAME implies a type, out of binutils' bfd_elf_special_sections
#     (bfd/elf.c) -- `.bss*' and `.tbss*' are SHT_NOBITS, `.note*' SHT_NOTE,
#     `.init_array*' SHT_INIT_ARRAY, `.dynamic' SHT_DYNAMIC, and so on.
#   * The `@type' / `%type' argument names one outright, or gives a number.
#
# When both apply and disagree, as honours the argument -- warning "setting
# incorrect section type" -- with one exception it spells out in
# gas/config/obj-elf.c: for the three array types it keeps the NAME's type and
# warns "ignoring incorrect section type" instead, because older gcc emitted
#
#     .section .init_array,"aw",@progbits
#
# for __attribute__((section(".init_array"))) and as refuses to believe it.
# So `.section .bss.foo,"aw",@progbits' really is PROGBITS, while
# `.section .init_array.1,"aw",@progbits' really is still INIT_ARRAY. Both
# directions are exercised below; a rule of "argument always wins" and a rule
# of "name always wins" each get one of them wrong.
#
# `.note.GNU-stack' is its own row for the same reason binutils gives it its
# own table entry: the bare name is SHT_PROGBITS, and only a name with a
# further suffix falls through to `.note' and SHT_NOTE. tcc records stack
# requirements against that section, so a wrong type there would be visible.
#
# Every expectation below was measured against binutils 2.44 `as` before being
# written down, and the whole script passes unchanged against a real gcc --
# which is what makes it a reference rather than this patch's own opinion.
#
# Needs `readelf` on PATH. The cases differ only in the directive, so they are
# generated here rather than committed as ~40 near-identical one-line .S files.
set -u
TCC="${1:?usage: run.sh /path/to/tcc}"

# All intermediates go to a temp directory, never next to the sources: this
# script lives under dep/tcc/, and tooling/scripts/vendor-verify.sh hashes the
# committed source tree.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0

# Type name readelf prints for section $2 of object $1.
sectype() {
  readelf -S -W "$1" 2>/dev/null | sed 's/^ *\[[ 0-9]*\] //' | awk -v n="$2" '
    $1 == n { print $2; found = 1 }
    END { if (!found) print "<missing>" }'
}

# check <directive-tail> <expected-type>
#   <directive-tail> is everything after ".section ".
check() {
  local spec="$1" want="$2" name got
  name="${spec%%,*}"
  # .skip rather than .byte: a section that comes out SHT_NOBITS may not hold
  # a non-zero value, and as rejects the attempt outright.
  printf '.section %s\n.skip 4\n' "$spec" > "$WORK/t.S"
  if ! "$TCC" -c "$WORK/t.S" -o "$WORK/t.o" 2>"$WORK/err"; then
    printf '  FAIL  .section %-34s (assembly failed)\n' "$spec"
    sed 's/^/          /' "$WORK/err" | head -3
    fail=$((fail + 1))
    return
  fi
  got="$(sectype "$WORK/t.o" "$name")"
  if [ "$got" = "$want" ]; then
    printf '  PASS  .section %-34s %s\n' "$spec" "$got"
    pass=$((pass + 1))
  else
    printf '  FAIL  .section %-34s got %s, wanted %s\n' "$spec" "$got" "$want"
    fail=$((fail + 1))
  fi
}

echo "== section-name-implied sh_type ($TCC)"

# -- names as recognizes, no `@type' argument. Every one of these was
#    PROGBITS before `0022'.
check '.bss.foo'              NOBITS
check '.bss.foo.bar'          NOBITS
check '.tbss.x'               NOBITS
check '.gnu.linkonce.b'       NOBITS
check '.gnu.linkonce.b.x'     NOBITS
check '.note.mine'            NOTE
check '.notefoo'              NOTE
check '.init_array.1'         INIT_ARRAY
check '.fini_array.9'         FINI_ARRAY
check '.preinit_array'        PREINIT_ARRAY
check '.dynamic'              DYNAMIC

# -- names that imply PROGBITS, so that a wrong table row would show up here
#    rather than silently agreeing with the default.
check '.text.hot'             PROGBITS
check '.data.foo'             PROGBITS
check '.rodata.str1.8'        PROGBITS
check '.tdata.x'              PROGBITS
check '.init'                 PROGBITS
check '.got'                  PROGBITS

# -- the boundary of the match, per binutils' suffix_length. `.bss' and
#    `.gnu.linkonce.b' take a dotted suffix only; `.note' takes any suffix at
#    all; `.note.GNU-stack' is exact and PROGBITS, and only a longer name
#    falls through to `.note'.
check '.bssxyz'               PROGBITS
check '.gnu.linkonce.bX'      PROGBITS
check '.note.GNU-stack'       PROGBITS
check '.note.GNU-stack.x'     NOTE
check '.note.GNU-stackX'      NOTE
check 'notspecial'            PROGBITS
check '__bug_table'           PROGBITS

# -- the `@type' argument on a name as has no opinion about. tcc parsed and
#    discarded all of these.
check 'foo,"a",@progbits'      PROGBITS
check 'foo,"a",@nobits'        NOBITS
check 'foo,"a",@note'          NOTE
check 'foo,"a",@init_array'    INIT_ARRAY
check 'foo,"aw",@fini_array'   FINI_ARRAY
check 'foo,"a",@preinit_array' PREINIT_ARRAY
check 'foo,"a",%nobits'        NOBITS       # `%' spelling, for non-@ targets
check 'foo,"a",@0x70000001'    X86_64_UNWIND # a bare number is legal too
check 'foo,"a",@bogus'         PROGBITS     # as warns and carries on

# -- precedence, both directions. The argument wins ...
check '.bss.foo,"aw",@progbits'   PROGBITS
check '.rodata.x,"a",@nobits'     NOBITS
check '.text.a,"ax",@nobits'      NOBITS
check '.dynamic,"a",@progbits'    PROGBITS
check '.note.foo,"aw",@progbits'  PROGBITS
check '.bss.foo,"aw",@nobits'     NOBITS    # agreeing, for completeness
# -- ... except for the three array types, where the name does.
check '.init_array.1,"aw",@progbits'   INIT_ARRAY
check '.init_array.1,"a",@progbits'    INIT_ARRAY
check '.fini_array.1,"aw",@progbits'   FINI_ARRAY
check '.preinit_array,"aw",@progbits'  PREINIT_ARRAY
check '.init_array.1,"aw",@init_array' INIT_ARRAY

echo "----- pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
