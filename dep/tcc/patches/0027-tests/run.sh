#!/usr/bin/env bash
# Compare a tcc build against real GNU as on base-less SIB memory operands,
# `(,%reg,scale)'.
# Usage: run.sh /path/to/tcc     (also passes against gcc: run.sh "$(command -v gcc)")
#
# Before 0027 tcc rejected the form outright, at parse time, with
# `bad expression syntax [,]' -- the operand parser saw `(' and then, on
# anything other than `%', tried to read a parenthesised displacement
# expression, and an expression cannot start with a comma. The encoder
# underneath already handled a missing base (asm_modrm() substitutes
# SIB.base=101 with mod=00 and a forced disp32), so the gap was parser-only
# and not specific to any instruction.
#
# What `as' does with the form, measured against the binutils on the machine
# the patch was written on, before writing it:
#
#     mov (,%rax,8),%rbx  ->  48 8b 1c c5 00 00 00 00
#     mov (,%rax,1),%rbx  ->  48 8b 1c 05 00 00 00 00
#     mov (,%rax),%rbx    ->  48 8b 1c 05 00 00 00 00   (scale omitted == 1)
#     mov 0x10(,%rax,8),%rbx -> 48 8b 1c c5 10 00 00 00
#
# Two things there are worth stating because they are the parts an
# implementation gets wrong: the displacement is always four bytes, so a
# small one does NOT shrink to the disp8 form the base-ful encoding would
# use; and omitting the scale is scale 1, not an error.
#
# Comparison is on the bytes and the relocations, because that is the whole
# claim -- these cases are not run, and several would fault if they were.
# t0 is the control: base-ful SIB forms that tcc accepted before 0027, which
# pass on both sides of the patch and pin that nothing else in operand
# parsing moved.
#
# Deliberately absent: %rsp (and %esp) in the index slot. `as' rejects
# `(,%rsp,8)' as "not a valid base/index expression"; tcc accepts it -- both
# base-less and, already before 0027, base-ful (`(%rax,%rsp,4)' assembles to
# an encoding objdump reads back as `%riz') because SIB.index=100 is the
# architectural "no index" code and tcc never validates against it. That is a
# pre-existing missing-diagnostic gap in tcc, unrelated to which spellings
# parse, and it is recorded separately in TODO.md. A case here would test
# neither assembler's agreement nor 0027's change.
#
# Also absent: 32-bit (`-m32') targets. The parser change is in the shared
# i386-asm.c and applies to both, but the vendored build is x86_64-only, so
# there is nothing to run a comparison against. The 32-bit *index* forms
# (`(,%eax,4)', which take a 0x67 address-size prefix) are covered in t2 and
# do exercise the same code.
#
# Needs `as`, `readelf` on PATH.
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

# Instruction bytes plus relocations. Sections are compared by content, not
# by the section table: these cases put everything in `.text' (and a single
# `.quad' in `.data' as a relocation target), and tcc's own section
# bookkeeping -- an always-present empty `.data.ro', for one -- differs from
# gas's for reasons that have nothing to do with operand parsing.
dump() {
  local obj="$1"
  for s in .text .data; do
    readelf -S -W "$obj" | grep -q " $s  *PROGBITS" || continue
    echo "== section $s"
    readelf -x "$s" "$obj" 2>/dev/null | tail -n +3 | grep -v '^ NOTE:'
  done
  echo "== relocations"
  readelf -r -W "$obj" 2>/dev/null \
    | awk '/^[0-9a-f]{6,}/ {print $1, $3, $5, $6, $7}' | sort
}

for f in "$SRCDIR"/t*.S; do
  b="$(basename "${f%.S}")"
  if ! as --nocompress-debug-sections -o "$b.gas.o" "$f" 2>"$b.gaserr"; then
    printf "%-26s SKIP (gas rejects)\n" "$b"; continue
  fi
  if ! "$TCC" -c -o "$b.tcc.o" "$f" 2>"$b.err"; then
    printf "%-26s FAIL tcc: %s\n" "$b" "$(sed 's/.*error: //' "$b.err" | head -1)"
    fail=$((fail+1)); continue
  fi
  dump "$b.gas.o" > "$b.gas.txt"
  dump "$b.tcc.o" > "$b.tcc.txt"
  if diff -q "$b.gas.txt" "$b.tcc.txt" >/dev/null; then
    printf "%-26s OK (matches gas)\n" "$b"; pass=$((pass+1))
  else
    printf "%-26s MISMATCH vs gas\n" "$b"
    diff "$b.gas.txt" "$b.tcc.txt" | head -20 | sed 's/^/      /'
    fail=$((fail+1))
  fi
done

# The equivalence the encoding rests on, stated rather than inferred: with no
# base register, an omitted scale is scale 1. Same instruction, two
# spellings, one set of bytes -- asserted in gas (the premise) and in tcc
# (what 0027 has to reproduce).
cat > eq_scale1.S <<'EOF'
	.text
	movq	(,%rax,1), %rbx
	movq	(,%rcx,1), %rdx
EOF
cat > eq_noscale.S <<'EOF'
	.text
	movq	(,%rax), %rbx
	movq	(,%rcx), %rdx
EOF
for who in gas tcc; do
  ok=1
  for v in eq_scale1 eq_noscale; do
    case "$who" in
      gas) as -o "$v.$who.o" "$v.S" 2>/dev/null || ok=0 ;;
      tcc) "$TCC" -c -o "$v.$who.o" "$v.S" 2>/dev/null || ok=0 ;;
    esac
    [ "$ok" -eq 1 ] && dump "$v.$who.o" > "$v.$who.txt"
  done
  if [ "$ok" -eq 0 ]; then
    printf "%-26s FAIL (%s did not assemble both spellings)\n" "equivalence/$who" "$who"
    fail=$((fail+1)); continue
  fi
  if diff -q "eq_scale1.$who.txt" "eq_noscale.$who.txt" >/dev/null; then
    printf "%-26s OK (omitted scale == ,1 in %s)\n" "equivalence/$who" "$who"
    pass=$((pass+1))
  else
    printf "%-26s MISMATCH (omitted scale != ,1 in %s)\n" "equivalence/$who" "$who"
    diff "eq_scale1.$who.txt" "eq_noscale.$who.txt" | head -12 | sed 's/^/      /'
    fail=$((fail+1))
  fi
done

# The displacement in a base-less SIB is always four bytes. The base-ful
# encoding of the same small displacement is shorter, so if tcc ever routed
# the base-less form through the disp8 path the two would come out the same
# length -- this asserts they do not, on both sides.
cat > sz_nobase.S <<'EOF'
	.text
	movq	8(,%rax,8), %rbx
EOF
cat > sz_base.S <<'EOF'
	.text
	movq	8(%rax,%rcx,8), %rbx
EOF
textsize() {
  readelf -S -W "$1" | sed -n 's/.*\.text  *PROGBITS *[0-9a-f]* *[0-9a-f]* *\([0-9a-f]*\).*/\1/p'
}
for who in gas tcc; do
  case "$who" in
    gas) as -o "sz_nobase.$who.o" sz_nobase.S 2>/dev/null && as -o "sz_base.$who.o" sz_base.S 2>/dev/null ;;
    tcc) "$TCC" -c -o "sz_nobase.$who.o" sz_nobase.S 2>/dev/null && "$TCC" -c -o "sz_base.$who.o" sz_base.S 2>/dev/null ;;
  esac
  if [ $? -ne 0 ]; then
    printf "%-26s FAIL (%s did not assemble both forms)\n" "disp32/$who" "$who"
    fail=$((fail+1)); continue
  fi
  n="$(textsize "sz_nobase.$who.o")"; m="$(textsize "sz_base.$who.o")"
  if [ "$((0x$n))" -eq "$((0x$m + 3))" ]; then
    printf "%-26s OK (forced disp32 in %s)\n" "disp32/$who" "$who"
    pass=$((pass+1))
  else
    printf "%-26s MISMATCH (%s: base-less .text=0x%s, base-ful .text=0x%s; expected +3)\n" \
      "disp32/$who" "$who" "$n" "$m"
    fail=$((fail+1))
  fi
done

echo "-----"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
