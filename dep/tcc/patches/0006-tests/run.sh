#!/usr/bin/env bash
# Checks for 0006-dwarf-section-flag-and-debug-retention.patch.
# Usage: run.sh /path/to/tcc [-B<tccdir>]
#
# Needs gcc, readelf and objcopy on PATH to build the foreign objects.
set -u
TCC="${1:?usage: run.sh /path/to/tcc [-Btccdir]}"
BFLAG="${2:--B$(dirname "$TCC")}"
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
ok()   { echo "PASS  $1"; pass=$((pass+1)); }
bad()  { echo "FAIL  $1"; fail=$((fail+1)); }
skip() { echo "SKIP  $1"; }

debug_count() { readelf -SW "$1" | grep -cE '\.debug_[a-z_]+'; }

# --- fixtures -------------------------------------------------------------
gcc -gdwarf-4 -fdebug-types-section -gz=none -c "$SRCDIR/foreign.c" -o types.o 2>/dev/null \
  || { echo "cannot build .debug_types fixture (needs gcc)"; exit 77; }
gcc -gdwarf-4 -gz=none                -c "$SRCDIR/foreign.c" -o dbg.o 2>/dev/null
gcc -g0                               -c "$SRCDIR/foreign.c" -o nodbg.o 2>/dev/null
gcc -gdwarf-4 -gz=zlib                -c "$SRCDIR/foreign.c" -o zdbg.o 2>/dev/null
gcc -c "$SRCDIR/fstab.S" -o fstab_raw.o 2>/dev/null \
  && objcopy --rename-section .xstab=.stab --rename-section .xstabstr=.stabstr \
       fstab_raw.o fstab.o 2>/dev/null

readelf -SW types.o | grep -q '\.debug_types' \
  || { echo "fixture lacks .debug_types -- this gcc ignored -fdebug-types-section"; exit 77; }

# --- 1. the bug: .debug_types must link and produce the right answer ------
# main() returns g_obj.a + 1 == 8. Before the patch this printed six
# "relocation 'R_X86_64_32[S]' out of range" errors and exited 1.
"$TCC" "$BFLAG" -gdwarf -nostdlib "$SRCDIR/main.c" types.o -run >/dev/null 2>err1
rc=$?
if [ "$rc" = 8 ]; then ok ".debug_types links under -gdwarf and runs correctly (exit 8)"
else bad ".debug_types under -gdwarf: expected exit 8, got $rc -- $(head -1 err1)"; fi

# --- 2. same object must still work at every other -g level ---------------
for g in -g0 -g -gstabs; do
  "$TCC" "$BFLAG" $g -nostdlib "$SRCDIR/main.c" types.o -run >/dev/null 2>&1
  [ $? = 8 ] && ok ".debug_types under $g (exit 8)" || bad ".debug_types under $g"
done

# --- 3. retention without -g ---------------------------------------------
if "$TCC" "$BFLAG" -g0 -nostdlib "$SRCDIR/start.c" dbg.o -o ret.out 2>/dev/null; then
  n=$(debug_count ret.out)
  [ "$n" -gt 0 ] && ok "debug sections retained without -g ($n present)" \
                 || bad "debug sections not retained without -g"
  # retained info must be real, not just present
  readelf --debug-dump=info ret.out 2>/dev/null | grep -q 'DW_AT_name.*foreign\.c' \
    && ok "retained debug info parses and names the foreign CU" \
    || bad "retained debug info does not parse"
else bad "link with foreign debug object at -g0"; fi

# an object with no debug sections must gain none
if "$TCC" "$BFLAG" -g0 -nostdlib "$SRCDIR/start.c" nodbg.o -o non.out 2>/dev/null; then
  [ "$(debug_count non.out)" = 0 ] && ok "no debug sections invented for a -g0 object" \
                                   || bad "debug sections appeared from a -g0 object"
else bad "link with non-debug object at -g0"; fi

# --- 4. compressed debug sections are skipped, not mishandled -------------
# Documented limitation: tcc cannot decompress SHF_COMPRESSED, so it skips
# retention for the whole object. This must stay a silent skip, not an error.
if [ -f zdbg.o ] && readelf -SW zdbg.o | grep -qE '\.debug_.* +C'; then
  if "$TCC" "$BFLAG" -g0 -nostdlib "$SRCDIR/start.c" zdbg.o -o z.out 2>/dev/null; then
    [ "$(debug_count z.out)" = 0 ] \
      && ok "compressed debug sections skipped without error (known limitation)" \
      || bad "compressed debug sections unexpectedly retained"
  else bad "link with compressed debug object errored"; fi
else skip "compressed-debug fixture unavailable"; fi

# --- 5. foreign .stab must keep working where it worked before ------------
# .stab is deliberately NOT retained without -g: x86_64-link.c's
# out-of-range suppression is scoped to tcc's own stab_section, so retaining
# a foreign .stab would turn these working links into hard errors.
if [ -f fstab.o ]; then
  for g in -g0 -gstabs; do
    "$TCC" "$BFLAG" $g -nostdlib "$SRCDIR/mainstab.c" fstab.o -run >/dev/null 2>&1
    [ $? = 42 ] && ok "foreign .stab still links and runs under $g (exit 42)" \
                || bad "foreign .stab regressed under $g"
  done
else skip "foreign .stab fixture unavailable"; fi

echo "---- $pass passed, $fail failed ----"
[ "$fail" = 0 ]
