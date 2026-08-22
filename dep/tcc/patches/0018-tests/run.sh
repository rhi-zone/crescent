#!/usr/bin/env bash
# Check that tcc predefines __ELF__ on an ELF target, in both C and assembler
# preprocessing.  Usage: run.sh /path/to/tcc
#
# gcc and clang define __ELF__ whenever the target's object format is ELF.
# tcc defined it in exactly one place -- include/tccdefs.h, inside the
# `#elif defined __NetBSD__` arm -- so on Linux and on every other ELF target
# tcc supports it was simply absent.
#
# The absence is not cosmetic.  The commonest real-world use of __ELF__ is
#
#     #if defined(__linux__) && defined(__ELF__)
#     .section .note.GNU-stack,"",%progbits
#     #endif
#
# in hand-written assembler.  Under tcc that guard evaluated false, the
# directive was preprocessed away, and the object came out with no marker --
# which GNU ld reads as "this object requires an executable stack".  So a file
# that had correctly declared it does not need one silently got the opposite
# outcome.  t2 and t3 measure that end to end rather than trusting the macro's
# presence to imply it.
#
# tccdefs.h would have been the wrong home for the fix even so: tcc_predefs()
# pulls tccdefs.h in only when !is_asm, so nothing defined there is visible
# while preprocessing a .S file -- exactly the mode the idiom above lives in.
# t1 is the test that discriminates the two possible fixes.
#
# Every case here also passes when run against a real gcc
# (`run.sh "$(command -v gcc)"`), which pins the behaviour to a reference
# toolchain rather than to this patch's own opinion.
set -u
TCC="${1:?usage: run.sh /path/to/tcc}"
SRCDIR="$(cd "$(dirname "$0")" && pwd)"

# All intermediates go to a temp directory, never into SRCDIR: this script
# lives under dep/tcc/, and tooling/scripts/vendor-verify.sh hashes the
# committed source tree -- build artifacts left next to the sources would
# show up in a dirty working tree and confuse that check.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

pass=0; fail=0

ok()   { printf "%-32s OK   %s\n" "$1" "${2-}"; pass=$((pass+1)); }
bad()  { printf "%-32s FAIL %s\n" "$1" "$2"; fail=$((fail+1)); }
skip() { printf "%-32s SKIP %s\n" "$1" "$2"; }

# Count of .note.GNU-stack sections, and its flag string ("" when unflagged).
# Parsed from the end of the readelf -S -W line, not by field number: the Flg
# column is printed only for a section that has flags, so a fixed offset from
# the left lands on a different column depending on the section. Trailing
# layout is always [ES] [Flg] Lk Inf Al, and ES is a two-hex-digit field,
# which is what tells "no flags" from a flag string.
marker() {
  readelf -S -W "$1" | awk '
    /\.note\.GNU-stack/ {
      n++
      if ($(NF-3) ~ /^[0-9a-f][0-9a-f]$/) flags = ""; else flags = $(NF-3)
    }
    END { printf "%d %s", n+0, flags }'
}

# t0 -- __ELF__ reaches C preprocessing, and its value is 1.  The #error
# directives inside the source are the assertion; compiling at all is the pass.
if "$TCC" -c -o t0.o "$SRCDIR/t0_elf_defined.c" 2>t0.err; then
  ok t0_elf_defined_c "compiles: __ELF__ defined, value 1"
else
  bad t0_elf_defined_c "$(sed 's/.*error: //' t0.err | head -1)"
fi

# t1 -- and reaches ASSEMBLER preprocessing, which tccdefs.h does not.  The
# source exports elf_was_defined_in_asm only inside `#ifdef __ELF__`, so the
# symbol's presence in the object is the measurement.  This is the case that
# separates a fix in tccpp.c's predefine table from one in tccdefs.h.
if ! "$TCC" -c -o t1.o "$SRCDIR/t1_elf_defined.S" 2>t1.err; then
  bad t1_elf_defined_asm "$(sed 's/.*error: //' t1.err | head -1)"
elif nm t1.o 2>/dev/null | grep -q 'elf_was_defined_in_asm'; then
  ok t1_elf_defined_asm "visible while preprocessing .S"
else
  bad t1_elf_defined_asm "__ELF__ undefined in assembler mode"
fi

# t2 -- the real-world idiom, end to end: a .S that guards its own
# .note.GNU-stack directive on `defined(__linux__) && defined(__ELF__)` must
# come out of the assembler carrying that marker, unflagged.  This is the
# shape every dep/libressl AT&T bignum_*.S ends with.
if [ "$(uname -s)" != Linux ]; then
  skip t2_guarded_marker "the guard also tests __linux__; not Linux here"
elif ! "$TCC" -c -o t2.o "$SRCDIR/t2_guarded_marker.S" 2>t2.err; then
  bad t2_guarded_marker "$(sed 's/.*error: //' t2.err | head -1)"
else
  read -r n flags <<<"$(marker t2.o)"
  if [ "$n" -ne 1 ]; then
    bad t2_guarded_marker "expected 1 .note.GNU-stack section, found $n -- the guard was preprocessed away"
  elif [ -n "$flags" ]; then
    bad t2_guarded_marker "marker flags '$flags', expected none -- the source asked for an unflagged marker"
  else
    ok t2_guarded_marker "self-guarded marker survives, flags 'none'"
  fi
fi

# t3 -- the outcome that actually matters.  A real GNU ld, never tcc's own
# linker, decides PT_GNU_STACK, and it decides it from the marker alone.  An
# object whose guard was preprocessed away makes the whole link RWE and draws
# binutils' "missing .note.GNU-stack section implies executable stack".
if [ "$(uname -s)" != Linux ]; then
  skip t3_link_gnu_stack "not Linux"
elif [ ! -f t2.o ]; then
  skip t3_link_gnu_stack "t2 did not produce an object"
elif ! command -v gcc >/dev/null 2>&1; then
  skip t3_link_gnu_stack "no gcc to drive a real ld"
elif ! "$TCC" -fno-asynchronous-unwind-tables -c -o t3main.o "$SRCDIR/t3_link_main.c" 2>t3.err; then
  bad t3_link_gnu_stack "$(sed 's/.*error: //' t3.err | head -1)"
elif ! gcc t3main.o t2.o -o t3 2>t3.link; then
  skip t3_link_gnu_stack "link failed in this environment: $(head -1 t3.link)"
else
  perms="$(readelf -l -W t3 | awk '/GNU_STACK/ { print $7 }')"
  case "$perms" in
    *E*) bad t3_link_gnu_stack "GNU_STACK is $perms -- executable stack" ;;
    "")  skip t3_link_gnu_stack "link produced no GNU_STACK segment" ;;
    *)   ok  t3_link_gnu_stack "GNU_STACK $perms" ;;
  esac
  if grep -q 'missing .note.GNU-stack' t3.link; then
    bad t3_link_no_warning "ld still warns about a missing marker on the .S object"
  else
    ok t3_link_no_warning
  fi
fi

printf "\n%d passed, %d failed\n" "$pass" "$fail"
[ "$fail" -eq 0 ]
