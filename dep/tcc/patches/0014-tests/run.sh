#!/usr/bin/env bash
# Check the .note.GNU-stack marker in the objects a tcc build emits.
# Usage: run.sh /path/to/tcc
#
# The marker is what GNU ld reads to decide PT_GNU_STACK permissions for the
# final link. Its absence is not a warning-level detail: ld's documented
# default is that an input object without the section requires an executable
# stack, and one such object makes the whole executable's stack RWE. t4
# measures that outcome directly rather than trusting presence to imply it.
#
# Two cases here are about NOT acting, and they are the reason this is not
# simply "always create the section":
#
#   t1  assembled input that said nothing about the stack must come out with
#       no marker, matching as/gcc/clang -- speaking for hand-written asm
#       means answering for code the compiler did not generate.
#   t3  assembled input that declared the marker EXECUTABLE is stating a real
#       requirement, and overwriting it produces a binary that crashes at
#       runtime.
#
# Every case here also passes when run against a real gcc
# (`run.sh "$(command -v gcc)"`), which is what pins the behaviour to a
# reference rather than to this patch's own opinion.
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

# "<count> <size-hex> <align> <flags>" for the marker, flags empty when none.
#
# Parsed from the end of the line, not by field number: readelf -S -W prints
# the Flg column only when a section has flags, so a fixed offset from the
# left lands on Size for one section and on Lk for the next. Trailing layout
# is always [ES] [Flg] Lk Inf Al, and ES is a two-hex-digit field, which is
# what distinguishes "no flags" from a flag string.
marker() {
  readelf -S -W "$1" | awk '
    /\.note\.GNU-stack/ {
      n++; align = $NF
      if ($(NF-3) ~ /^[0-9a-f][0-9a-f]$/) { flags = ""; size = $(NF-4) }
      else                                { flags = $(NF-3); size = $(NF-5) }
    }
    END { printf "%d %s %s %s", n+0, size, align, flags }'
}

# name expected-flags ("" = unflagged, "X" = executable) source-file
expect_marker() {
  local name="$1" want_flags="$2" src="$3"
  if ! "$TCC" -c -o "$name.o" "$src" 2>"$name.err"; then
    bad "$name" "tcc: $(sed 's/.*error: //' "$name.err" | head -1)"; return
  fi
  read -r n size align flags <<<"$(marker "$name.o")"
  if [ "$n" -ne 1 ]; then
    bad "$name" "expected exactly 1 .note.GNU-stack section, found $n"
  elif [ "$size" != "000000" ]; then
    bad "$name" "marker is $size bytes, expected empty"
  elif [ "$flags" != "$want_flags" ]; then
    bad "$name" "marker flags '$flags', expected '${want_flags:-none}'"
  elif [ "$align" != "1" ]; then
    bad "$name" "marker addralign $align, expected 1"
  else
    ok "$name" "empty, align 1, flags '${flags:-none}'"
  fi
}

expect_no_marker() {
  local name="$1" src="$2"
  if ! "$TCC" -c -o "$name.o" "$src" 2>"$name.err"; then
    bad "$name" "tcc: $(sed 's/.*error: //' "$name.err" | head -1)"; return
  fi
  read -r n _ _ _ <<<"$(marker "$name.o")"
  if [ "$n" -ne 0 ]; then
    bad "$name" "marker injected into asm that did not ask for one"
  else
    ok "$name" "no marker, as as/gcc/clang leave it"
  fi
}

# `-r` merges several inputs into one object, so their separate statements
# about the stack have to be reconciled into the single marker the object
# carries. GNU ld -r is the incumbent: it upgrades, so an unmarked input's
# implicit "I need an executable stack" survives rather than being dropped.
# These three cases are run against gcc too, which is what pins them to
# measured ld behaviour rather than to this patch's reading of it.
expect_marker_r() {
  local name="$1" want_flags="$2"; shift 2
  if ! "$TCC" -r -nostdlib "$@" -o "$name.o" 2>"$name.err"; then
    bad "$name" "tcc -r: $(sed 's/.*error: //' "$name.err" | head -1)"; return
  fi
  read -r n size align flags <<<"$(marker "$name.o")"
  if [ "$n" -ne 1 ]; then
    bad "$name" "expected exactly 1 .note.GNU-stack section, found $n"
  elif [ "$flags" != "$want_flags" ]; then
    bad "$name" "merged marker flags '$flags', expected '${want_flags:-none}'"
  else
    ok "$name" "merged marker flags '${flags:-none}'"
  fi
}

expect_marker    t0_plain_c              ""  "$SRCDIR/t0_plain_c.c"
expect_no_marker t1_plain_asm                "$SRCDIR/t1_plain_asm.S"
expect_marker    t2_asm_declares_marker  ""  "$SRCDIR/t2_asm_declares_marker.S"
expect_marker    t3_asm_requests_exec_stack "X" "$SRCDIR/t3_asm_requests_exec_stack.S"

# Same reconciliation, reached through a prebuilt object rather than a
# source. An input object with no marker makes the identical statement an
# undeclared .S source makes, and keying only on sources would let
# `-r file.c unmarked.o` mark the object non-executable on the object's
# behalf -- worse than emitting nothing, since it converts an implicit
# requirement into an explicit denial of it.
expect_marker_r_obj() {
  local name="$1" want_flags="$2" csrc="$3" objsrc="$4"
  if ! "$TCC" -c -o "$name.dep.o" "$objsrc" 2>"$name.err"; then
    bad "$name" "tcc -c: $(sed 's/.*error: //' "$name.err" | head -1)"; return
  fi
  expect_marker_r "$name" "$want_flags" "$csrc" "$name.dep.o"
}

expect_marker_r t5_r_c_plus_undeclared_asm "X" \
    "$SRCDIR/t0_plain_c.c" "$SRCDIR/t1_plain_asm.S"
expect_marker_r t6_r_c_plus_declared_asm   ""  \
    "$SRCDIR/t0_plain_c.c" "$SRCDIR/t2_asm_declares_marker.S"
expect_marker_r t7_r_c_plus_exec_asm       "X" \
    "$SRCDIR/t0_plain_c.c" "$SRCDIR/t3_asm_requests_exec_stack.S"

expect_marker_r_obj t8_r_c_plus_unmarked_object "X" \
    "$SRCDIR/t0_plain_c.c" "$SRCDIR/t1_plain_asm.S"
expect_marker_r_obj t9_r_c_plus_marked_object   ""  \
    "$SRCDIR/t0_plain_c.c" "$SRCDIR/t2_asm_declares_marker.S"

# The end result: a real GNU ld, never tcc's linker, decides these
# permissions, and it decides them from the marker alone.
if ! "$TCC" -fno-asynchronous-unwind-tables -c -o t4.o "$SRCDIR/t4_link_main.c" 2>t4.err; then
  bad t4_link_gnu_stack "tcc: $(sed 's/.*error: //' t4.err | head -1)"
elif ! command -v gcc >/dev/null 2>&1; then
  skip t4_link_gnu_stack "no gcc to drive a real ld"
elif ! gcc t4.o -o t4 2>t4.link; then
  skip t4_link_gnu_stack "link failed in this environment: $(head -1 t4.link)"
else
  perms="$(readelf -l -W t4 | awk '/GNU_STACK/ { print $7 }')"
  case "$perms" in
    *E*) bad t4_link_gnu_stack "GNU_STACK is $perms -- executable stack" ;;
    "")  skip t4_link_gnu_stack "link produced no GNU_STACK segment" ;;
    *)   ok  t4_link_gnu_stack "GNU_STACK $perms" ;;
  esac
  if grep -q 'missing .note.GNU-stack' t4.link; then
    bad t4_link_no_warning "ld still warns about a missing marker"
  else
    ok t4_link_no_warning
  fi
fi

printf "\n%d passed, %d failed\n" "$pass" "$fail"
[ "$fail" -eq 0 ]
