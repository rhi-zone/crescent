#!/usr/bin/env bash
# Check that a section's NAME decides its flags the way GNU as decides them.
# Usage: run.sh /path/to/tcc     (also passes against gcc: run.sh "$(command -v gcc)")
#
# `0004-asm-section-flags-alloc.patch` fixed a real bug -- upstream tcc forced
# SHF_ALLOC into every section the .section directive created, and never parsed
# `a' out of the flags string at all -- by making the default flags 0. That is
# right for a name GNU as has no opinion about, and wrong for one it does:
# real as derives flags from the section NAME first (binutils
# bfd_elf_special_sections, bfd/elf.c), and the flags string only gets to add
# to them. So after `0004', the ordinary hand-written spelling
#
#     .section .rodata
#
# produced a section with no SHF_ALLOC -- dropped from every linked image.
# Four of crescent's own seven vendored libressl `*-elf-x86_64.S` files spell
# it exactly that way. It also broke tcc's own `make test1`/`test3`, by a less
# obvious route: tests/tcctest.c pushes into `.data.ignore` (a `.data.` name,
# so allocatable to as) and puts a `.long 661b - .` in it. Non-allocated
# sections get no sh_addr under `-run`, so that PC32 relocation computed
# `symbol - 0`, which overflows int32 when -run's addresses are real heap
# pointers: `tcc: error: relocation '2' out of range`.
#
# `0021-asm-section-name-attrs.patch` adds the name table and as's precedence
# rule. Note what that rule is -- it is not "default when no flags string":
#
#   * name-implied flags win outright, so `.section .text,"w"' is still AX
#     and `.section .rodata,""' is still A;
#   * UNLESS the flags string is a strict superset of them, in which case the
#     flags string wins, so `.section .rodata,"aw"' is WA.
#
# The subset case is why the patch also subsumes upstream's hand-written
# `.init`/`.fini` -> SHF_EXECINSTR special case: `.section .init,"a"' has to
# stay executable, and a plain default-if-absent rule would have dropped it.
#
# Every expectation below was measured against binutils 2.44 `as` before being
# written down, and the whole script passes unchanged against a real gcc --
# which is what makes the table a reference, not this patch's own opinion.
#
# Needs `readelf` on PATH. The cases differ only in the section name and flags
# string, so they are generated here rather than committed as ~30 near-
# identical one-line .S files: the table IS the test.
set -u
TCC="${1:?usage: run.sh /path/to/tcc}"

# All intermediates go to a temp directory, never next to the sources: this
# script lives under dep/tcc/, and tooling/scripts/vendor-verify.sh hashes the
# committed source tree.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0

# Flag string for section $2 in object $1, "-" when the section has no flags.
# Parsed from the end of the readelf -S -W line, not by field number: the Flg
# column is printed only for a section that has flags. Trailing layout is
# always [ES] [Flg] Lk Inf Al, and ES is a two-hex-digit field, which is what
# tells "no flags" from a flag string.
secflags() {
  readelf -S -W "$1" 2>/dev/null | sed 's/^ *\[[ 0-9]*\] //' | awk -v n="$2" '
    $1 == n {
      if ($(NF-3) ~ /^[0-9a-f][0-9a-f]$/) print "-"; else print $(NF-3)
      found = 1
    }
    END { if (!found) print "<missing>" }'
}

# check <directive-tail> <expected-flags>
#   <directive-tail> is everything after ".section ", i.e. a name, optionally
#   followed by ,"flags".
check() {
  local spec="$1" want="$2" name got
  name="${spec%%,*}"
  printf '.section %s\n.skip 4\n' "$spec" > "$WORK/t.S"
  if ! "$TCC" -c "$WORK/t.S" -o "$WORK/t.o" 2>"$WORK/err"; then
    printf '  FAIL  .section %-24s (assembly failed)\n' "$spec"
    sed 's/^/          /' "$WORK/err" | head -3
    fail=$((fail + 1))
    return
  fi
  got="$(secflags "$WORK/t.o" "$name")"
  if [ "$got" = "$want" ]; then
    printf '  PASS  .section %-24s %s\n' "$spec" "$got"
    pass=$((pass + 1))
  else
    printf '  FAIL  .section %-24s got %s, wanted %s\n' "$spec" "$got" "$want"
    fail=$((fail + 1))
  fi
}

echo "== section-name-implied flags ($TCC)"

# -- names as recognizes, no flags string. Every one of these was 0 after
#    `0004' and before `0021'.
check '.text'            AX
check '.text.foo'        AX
check '.text.hot.x'      AX
check '.data'            WA
check '.data.foo'        WA
check '.data.ignore'     WA      # the tcctest.c shape that broke -run
check '.data1'           WA
check '.rodata'          A       # the libressl perlasm shape
check '.rodata.foo'      A
check '.rodata.str1.8'   A
check '.rodata1'         A
check '.bss'             WA
check '.bss.foo'         WA
check '.tdata'           WAT
check '.tdata.foo'       WAT
check '.tbss'            WAT
check '.tbss.foo'        WAT
check '.init_array'      WA
check '.init_array.1'    WA
check '.fini_array'      WA
check '.preinit_array'   WA
check '.init'            AX
check '.fini'            AX
check '.plt'             AX
check '.got'             WA
check '.dynamic'         A

# -- the boundary of the match. `-2' in binutils' table means "exactly, or
#    followed by a dot", and `0' means "exactly". Getting this wrong in either
#    direction is silent: too loose marks unrelated sections allocatable, too
#    tight puts the original bug back for `.text.hot' and friends.
check '.textfoo'         -
check '.datafoo'         -
check '.init.foo'        -       # .init is exact-match only, unlike .text
check '.fini.foo'        -
check '.got.plt'         -       # .got is exact-match only

# -- names as has no opinion about. These must still take the flags string
#    verbatim, which is the whole point of `0004' and must not regress.
check 'mystuff'          -
check '__bug_table'      -
check '.foo.bar'         -
check '.note'            -
check '.note.foo'        -
check '.comment'         -
check '.debug_info'      -
check '.eh_frame'        -
check '.gcc_except_table' -
check '.interp'          -
check 'mystuff,"w"'      W
check 'mystuff,"a"'      A
check 'mystuff,"awx"'    WAX
check '.foo.bar,"aw"'    WA
check '.note.GNU-stack,""' -

# -- precedence. Name-implied flags win unless the flags string is a strict
#    superset of them.
check '.text,"ax"'       AX      # equal: unchanged
check '.text,"a"'        AX      # subset: name wins
check '.text,"w"'        AX      # disjoint-ish: name wins
check '.rodata,""'       A       # empty: name wins
check '.rodata,"a"'      A
check '.rodata,"aw"'     WA      # superset: flags string wins
check '.rodata,"awx"'    WAX
check '.data,"a"'        WA
check '.data,"ax"'       WA      # not a superset of WA: name wins
check '.data,"aw"'       WA
check '.bss,"aw"'        WA
check '.got,"aw"'        WA
check '.init,"a"'        AX      # upstream's .init/.fini case, subsumed
check '.init_array,"a"'  WA
check '.tdata,"aw"'      WAT

echo "----- pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
