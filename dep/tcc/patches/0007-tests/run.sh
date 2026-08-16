#!/usr/bin/env bash
# Checks for 0007-reserved-section-gate-and-eh-frame-retention.patch.
# Usage: run.sh /path/to/tcc [-B<tccdir>]
#
# Needs gcc and readelf on PATH: several cases assert equality with GNU as
# output rather than against a hardcoded expectation.
set -u
TCC="${1:?usage: run.sh /path/to/tcc [-Btccdir]}"
BFLAG="${2:--B$(dirname "$TCC")}"
SRCDIR="$(cd "$(dirname "$0")" && pwd)"

# All intermediates go to a temp directory, never into SRCDIR: this script
# lives under dep/tcc/, and tooling/scripts/vendor-verify.sh hashes every file
# `find` turns up there with no gitignore awareness, so build artifacts left
# beside the sources would break the vendored-source hash check.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

pass=0; fail=0
ok()   { echo "PASS  $1"; pass=$((pass+1)); }
bad()  { echo "FAIL  $1"; fail=$((fail+1)); }
skip() { echo "SKIP  $1"; }

# count sections whose name is exactly $2 -- an exact match on the name field,
# so .eh_frame never counts .eh_frame_hdr
count_sec() {
  readelf -SW "$1" 2>/dev/null \
    | sed -nE 's/^ *\[[ 0-9]+\] +([^ ]+).*/\1/p' \
    | grep -cxF -- "$2"
}
sec_digest() { readelf -x "$2" "$1" 2>/dev/null | tail -n +3 | md5sum | cut -d' ' -f1; }

command -v gcc >/dev/null || { echo "needs gcc for the GNU as comparisons"; exit 77; }

# --- 1. the orphan CIE ----------------------------------------------------
# Pure asm, no FDEs from tcc: GNU as emits no .eh_frame at all, and neither
# should tcc. Before the patch tcc emitted one containing only its own CIE.
"$TCC" "$BFLAG" -c "$SRCDIR/plain.S" -o plain_tcc.o 2>/dev/null
gcc -c "$SRCDIR/plain.S" -o plain_gas.o 2>/dev/null
if [ -f plain_tcc.o ] && [ -f plain_gas.o ]; then
  n=$(count_sec plain_tcc.o .eh_frame); g=$(count_sec plain_gas.o .eh_frame)
  [ "$n" = 0 ] && ok "no .eh_frame emitted for pure asm (GNU as: $g)" \
               || bad "orphan .eh_frame still emitted for pure asm ($n present, GNU as: $g)"
  [ "$(sec_digest plain_tcc.o .text)" = "$(sec_digest plain_gas.o .text)" ] \
    && ok ".text identical to GNU as for pure asm" \
    || bad ".text diverged from GNU as for pure asm"
else bad "could not assemble plain.S"; fi

# --- 2. asm carrying its own .eh_frame (the lj_vm.S shape) ----------------
# tcc must contribute nothing to it, so the section must match GNU as byte
# for byte. Before the patch tcc's own CIE was prepended.
"$TCC" "$BFLAG" -c "$SRCDIR/ehown.S" -o ehown_tcc.o 2>/dev/null
gcc -c "$SRCDIR/ehown.S" -o ehown_gas.o 2>/dev/null
if [ -f ehown_tcc.o ] && [ -f ehown_gas.o ]; then
  dt=$(sec_digest ehown_tcc.o .eh_frame); dg=$(sec_digest ehown_gas.o .eh_frame)
  [ -n "$dg" ] && [ "$dt" = "$dg" ] \
    && ok ".eh_frame byte-identical to GNU as for asm-supplied unwind data" \
    || bad ".eh_frame differs from GNU as (tcc contributed its own records)"
  [ "$(count_sec ehown_tcc.o .eh_frame)" = 1 ] \
    && ok "exactly one .eh_frame section (no duplicate)" \
    || bad "duplicate .eh_frame sections"
else bad "could not assemble ehown.S"; fi

# --- 3. input .eh_frame retained with unwind generation off ---------------
# The hard failure: a relocation into the object's own .eh_frame, linked with
# -fno-asynchronous-unwind-tables, used to fail "Invalid relocation entry".
"$TCC" "$BFLAG" -c "$SRCDIR/ehref.S" -o ehref.o 2>/dev/null
if [ -f ehref.o ]; then
  if "$TCC" "$BFLAG" -fno-asynchronous-unwind-tables -nostdlib \
        "$SRCDIR/start.c" ehref.o -o ret.out 2>err3; then
    ok "links with -fno-asynchronous-unwind-tables (was: Invalid relocation entry)"
    [ "$(count_sec ret.out .eh_frame)" -gt 0 ] \
      && ok "input .eh_frame retained with unwind generation off" \
      || bad "input .eh_frame dropped with unwind generation off"
    ./ret.out; [ $? = 42 ] && ok "retained .eh_frame readable at runtime (exit 42)" \
                           || bad "retained .eh_frame unusable at runtime"
  else bad "link with -fno-asynchronous-unwind-tables: $(head -1 err3)"; fi
  # and the same link with unwind generation on must keep working
  if "$TCC" "$BFLAG" -nostdlib "$SRCDIR/start.c" ehref.o -o ret2.out 2>/dev/null; then
    ./ret2.out; [ $? = 42 ] && ok "same link with unwind generation on (exit 42)" \
                            || bad "unwind-on link produced wrong result"
  else bad "unwind-on link failed"; fi
else bad "could not assemble ehref.S"; fi

# --- 4. SHARED: tcc's own unwind records coexist with an input .eh_frame ---
if [ -f ehref.o ]; then
  if "$TCC" "$BFLAG" -nostdlib "$SRCDIR/unwind.c" ehref.o -o mix.out 2>/dev/null; then
    [ "$(count_sec mix.out .eh_frame)" = 1 ] \
      && ok "tcc records and input content share one .eh_frame section" \
      || bad "tcc created a second .eh_frame instead of binding to the input one"
    ./mix.out; [ $? = 43 ] && ok "mixed-producer .eh_frame link runs correctly (exit 43)" \
                           || bad "mixed-producer link produced wrong result"
    if readelf --debug-dump=frames mix.out >frames.txt 2>/dev/null \
       && grep -qE 'CIE|FDE' frames.txt && ! grep -qi 'error\|corrupt' frames.txt; then
      ok "merged CIE/FDE chain parses cleanly"
    else bad "merged CIE/FDE chain does not parse"; fi
  else bad "mixed-producer link failed"; fi
fi

# --- 5. reserved names are refused, not silently duplicated ---------------
# Before the patch each of these produced an executable containing TWO
# sections of that name, with no diagnostic at all.
# Each fixture is self-contained (its own _start), so the reserved-name
# diagnostic is the only thing that can fail the link.
for n in got interp dynamic dynsym; do
  cat > "res_$n.S" <<EOF
        .section .$n,"a",@progbits
        .long 0x41414141
        .text
        .globl _start
_start:
        movl \$60, %eax
        xorl %edi, %edi
        syscall
EOF
  "$TCC" "$BFLAG" -c "res_$n.S" -o "res_$n.o" 2>/dev/null || { skip ".$n fixture"; continue; }
  rm -f "res_$n.out"
  err=$("$TCC" "$BFLAG" -nostdlib "res_$n.o" -o "res_$n.out" 2>&1)
  if echo "$err" | grep -q "section '.$n' is reserved for internal use"; then
    [ -f "res_$n.out" ] && bad ".$n reported but output still written" \
                        || ok ".$n claimed by input is refused, no output written"
  else
    bad ".$n claimed by input was not refused (got: ${err:-no diagnostic})"
  fi
done

# .plt only comes into being when a JMP_SLOT relocation needs it, i.e. on a
# real dynamic link, so it needs libc rather than the -nostdlib path above.
cat > res_plt.S <<'EOF'
        .section .plt,"a",@progbits
        .long 0x41414141
EOF
cat > pltmain.c <<'EOF'
extern int puts(const char *);
int main(void) { return puts("x") < 0; }
EOF
if "$TCC" "$BFLAG" -c res_plt.S -o res_plt.o 2>/dev/null \
   && "$TCC" "$BFLAG" pltmain.c -o plt_ctl.out 2>/dev/null; then
  rm -f plt.out
  err=$("$TCC" "$BFLAG" pltmain.c res_plt.o -o plt.out 2>&1)
  if echo "$err" | grep -q "section '.plt' is reserved for internal use"; then
    [ -f plt.out ] && bad ".plt reported but output still written" \
                   || ok ".plt claimed by input is refused, no output written"
  else
    bad ".plt claimed by input was not refused (got: ${err:-no diagnostic})"
  fi
else
  skip ".plt (no working dynamic link in this environment)"
fi

# --- 6. guard: ordinary compilation is unaffected -------------------------
cat > hello.c <<'EOF'
int val(void) { return 5; }
void _start(void) { int r = val(); __asm__ volatile("mov $60,%%eax; syscall" :: "D"(r) : "eax"); }
EOF
if "$TCC" "$BFLAG" -nostdlib hello.c -o hello.out 2>/dev/null; then
  ./hello.out; [ $? = 5 ] && ok "ordinary compile+link+run unaffected (exit 5)" \
                          || bad "ordinary link produced wrong result"
  [ "$(count_sec hello.out .eh_frame)" = 1 ] \
    && ok "tcc still emits its own .eh_frame when it has FDEs" \
    || bad "tcc stopped emitting .eh_frame for compiled C"
else bad "ordinary link failed"; fi

echo "---- $pass passed, $fail failed ----"
[ "$fail" = 0 ]
