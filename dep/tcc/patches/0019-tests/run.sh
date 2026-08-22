#!/usr/bin/env bash
# Check that `tcc -r` reconciles .note.GNU-stack the way GNU `ld -r` does when
# the merged marker came from an INPUT rather than being created.
# Usage: run.sh /path/to/tcc
#
# `0014-note-gnu-stack-object-marker.patch` made tcc create the marker for
# objects holding its own generated code, and made the created marker
# executable when an input that declared nothing shares the object -- which is
# what ld -r does.  But it only ever *created*; when some input already
# supplied the section, tcc adopted it verbatim.  ld -r does not: it raises
# SHF_EXECINSTR on the merged marker so the undeclared input's implicit
# "I may need an executable stack" survives.  Three shapes reached that gap,
# and all three are here (t1, t2, t3): asm sources only, prebuilt objects with
# no compilation at all, and compilation alongside an input-supplied marker.
#
# The rule this encodes, and the reason it does not contradict `0014-tests` t3:
# raising the flag only ever STRENGTHENS the statement a section already
# makes, never weakens one.  An input's explicit "x" is never cleared and an
# input-supplied section is never replaced -- t0 and t8 hold that line.  The
# asymmetry is not aesthetic: a marker that is executable when it need not be
# costs a more permissive stack, while the reverse costs a segfault.
#
# Every expectation below was measured against binutils 2.44 `ld -r` before
# being written down, and the whole script also passes against a real gcc
# (`run.sh "$(command -v gcc)"`) -- gcc's `-r -nostdlib` hands the merge to
# that same ld.  The reference is a toolchain, not this patch's own opinion.
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

ok()   { printf "%-36s OK   %s\n" "$1" "${2-}"; pass=$((pass+1)); }
bad()  { printf "%-36s FAIL %s\n" "$1" "$2"; fail=$((fail+1)); }

# Count of .note.GNU-stack sections and its flag string ("" when unflagged).
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

# Build the prebuilt-object inputs once. These are what let t2 and t4 reach
# `-r` with no compilation happening at all, which is the shape where tcc
# previously had nothing to hang the decision on.
build_obj() {
  if ! "$TCC" -c -o "$1" "$SRCDIR/$2" 2>"$1.err"; then
    echo "cannot build $1: $(sed 's/.*error: //' "$1.err" | head -1)" >&2
    return 1
  fi
}
build_obj decl.o     t0_declares_marker.S     || exit 1
build_obj decl2.o    t1_declares_marker_two.S || exit 1
build_obj undecl.o   t2_undeclared.S          || exit 1
build_obj exec.o     t3_requests_exec_stack.S || exit 1

# name expected-flags ("" = unflagged, "X" = executable) inputs...
expect_r() {
  local name="$1" want="$2"; shift 2
  if ! "$TCC" -r -nostdlib "$@" -o "$name.o" 2>"$name.err"; then
    bad "$name" "-r failed: $(sed 's/.*error: //' "$name.err" | head -1)"; return
  fi
  read -r n flags <<<"$(marker "$name.o")"
  if [ "$n" -ne 1 ]; then
    bad "$name" "expected 1 .note.GNU-stack section, found $n"
  elif [ "$flags" != "$want" ]; then
    bad "$name" "merged marker flags '${flags:-none}', ld -r gives '${want:-none}'"
  else
    ok "$name" "merged marker flags '${flags:-none}'"
  fi
}

expect_r_no_marker() {
  local name="$1"; shift
  if ! "$TCC" -r -nostdlib "$@" -o "$name.o" 2>"$name.err"; then
    bad "$name" "-r failed: $(sed 's/.*error: //' "$name.err" | head -1)"; return
  fi
  read -r n _ <<<"$(marker "$name.o")"
  if [ "$n" -ne 0 ]; then
    bad "$name" "marker invented where ld -r produces none"
  else
    ok "$name" "no marker, as ld -r leaves it"
  fi
}

# t0 -- the line the raise must not cross. An explicit "x" states a real
# requirement whose violation is a runtime crash; nothing here may clear it.
read -r n flags <<<"$(marker exec.o)"
if [ "$n" -eq 1 ] && [ "$flags" = X ]; then
  ok t0_exec_marker_preserved "-c leaves the input's 'X' alone"
else
  bad t0_exec_marker_preserved "marker count $n flags '${flags:-none}', expected 1 / 'X'"
fi

# --- the three shapes that previously diverged from ld -r ------------------

# t1 -- asm sources only, one declaring and one not. No compilation happens,
# so 0014 created nothing and adopted the declaring input's unflagged marker,
# dropping the other input's implicit request.
expect_r t1_r_asm_declared_plus_undeclared X \
    "$SRCDIR/t0_declares_marker.S" "$SRCDIR/t2_undeclared.S"

# t2 -- the same reconciliation reached through prebuilt objects, with no
# source of any kind on the command line.
expect_r t2_r_obj_marked_plus_unmarked X decl.o undecl.o

# t3 -- compilation DOES happen, but a marker already exists because an input
# supplied it, so 0014's create path never ran and the raise never happened.
expect_r t3_r_c_plus_marked_plus_unmarked X "$SRCDIR/t4_plain.c" decl.o undecl.o

# --- shapes that already agreed with ld -r, held here against regression ----

# t4 -- nothing to reconcile and nothing that may be invented: ld -r over an
# unmarked object alone produces no marker, and neither may tcc. Inventing an
# unflagged one here would convert an implicit requirement into a denial of it.
expect_r_no_marker t4_r_unmarked_alone undecl.o

# t5 -- flag union across two input-supplied markers. This one worked already,
# via ordinary section merging; it is here because the raise runs on the same
# section and must not disturb it.
expect_r t5_r_exec_plus_declared X exec.o decl.o

# t6 -- no undeclared input anywhere, so no raise: a compiled input and a
# declaring object both said they need nothing. A false raise here would be
# the failure mode of an over-broad rule.
expect_r t6_r_declared_obj_plus_c "" decl.o "$SRCDIR/t4_plain.c"

# t7 -- two declaring asm sources, no compilation. Same "no raise" property
# with nothing created and nothing merged from an object.
expect_r t7_r_two_declaring_asm "" \
    "$SRCDIR/t0_declares_marker.S" "$SRCDIR/t1_declares_marker_two.S"

# t8 -- the create path meeting an explicit "x": the marker comes from the
# input, compilation also happened, and the "x" survives.
expect_r t8_r_c_plus_exec_obj X "$SRCDIR/t4_plain.c" exec.o

printf "\n%d passed, %d failed\n" "$pass" "$fail"
[ "$fail" -eq 0 ]
