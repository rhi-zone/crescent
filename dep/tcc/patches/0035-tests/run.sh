#!/usr/bin/env bash
# Check that each FDE's PC-Begin offset is carried in the relocation's r_addend
# on a RELA target, so that GNU ld resolves it.
# Usage: run.sh /path/to/tcc     (also passes against gcc: run.sh "$(command -v gcc)")
#
# tccdbg.c's tcc_debug_frame_end() wrote the FDE's PC-Begin as an in-place word
# (`dwarf_data4(eh_frame_section, func_ind)') and emitted the accompanying
# relocation with r_addend == 0. tcc's own linker adds the in-place word back
# in, so tcc-linked output came out right and nothing looked wrong from inside
# tcc. On a RELA target GNU ld ignores the in-place word entirely, so every FDE
# in a tcc object resolved to .text+0 -- they all overlap, and ld refuses the
# object outright:
#
#     ld: .eh_frame_hdr refers to overlapping FDEs
#
# ## What this harness does and does not pin
#
# The reference is a real reference toolchain -- GNU ld's *acceptance*, and the
# semantic content of the tables it and tcc produce -- not tcc's own opinion of
# what it should have emitted.
#
# Unlike the pure-assembler harnesses next door, this one is NOT a
# byte-for-byte comparison against the reference. gcc and tcc generate
# structurally different `.eh_frame': different CIE augmentation, different CFI
# programs, and gcc puts `main' in `.text.startup' while tcc puts everything in
# `.text'. Byte equality is not a property either compiler owes the other. So
# every assertion below is stated as a property of the table -- which offsets
# the FDEs name, whether they are distinct, whether they agree with the symbol
# table, whether an unwinder can walk them -- and every one of them holds for
# gcc as well, which is what makes them a reference rather than a restatement
# of this patch.
#
# It does NOT pin: byte layout of `.eh_frame', the number or contents of CIEs,
# CFI opcode choice, which section a function lands in, the FDE ordering within
# `.eh_frame', or ld's error wording beyond the one phrase asserted in
# `rejects_overlap_free' -- that phrase is asserted only in the negative sense
# (it must NOT appear), so a future ld that words it differently still passes.
#
# Needs `gcc`, `ld` (via gcc), `readelf`, `nm`, `ar` on PATH, and a libgcc
# unwinder (`_Unwind_Backtrace`) plus `dladdr` for the end-to-end group.
set -u
CC="${1:?usage: run.sh /path/to/tcc}"
CCDIR="$(cd "$(dirname "$CC")" && pwd)"
# The vendored tcc is configured with absolute sysinclude/lib/crt paths, but it
# still wants -B at its own directory to find libtcc1.a and its include/. gcc
# treats -B as a harmless extra prefix, so the same invocation serves both.
cc_() { "$CC" -B"$CCDIR" "$@"; }

# All intermediates go to a temp directory, never next to the sources: this
# script lives under dep/tcc/, and tooling/scripts/vendor-verify.sh hashes the
# committed source tree with no gitignore awareness.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok_()  { printf '  PASS  %-52s %s\n' "$1" "${2-}"; pass=$((pass + 1)); }
bad_() { printf '  FAIL  %-52s %s\n' "$1" "${2-}"; fail=$((fail + 1)); }
one_line_() { printf '%s' "$1" | tr '\n' ' ' | cut -c1-96; }
hex_() { printf '%d' "$((16#${1#0x}))"; }

# ---------------------------------------------------------------------------
# sources
# ---------------------------------------------------------------------------

gen_four() {   # four ordinary functions in one TU
  cat > "$1" <<'EOF'
int f1(int x) { return x + 1; }
int f2(int x) { return x + 2; }
int f3(int x) { return x + 3; }
int main(void) { return f1(0) + f2(0) + f3(0) - 6; }
EOF
}

gen_one() {    # a single function: the case where the bug is invisible
  cat > "$1" <<'EOF'
int only(int x) { return x; }
EOF
}

gen_static() { # file-local functions get FDEs too
  cat > "$1" <<'EOF'
static int s1(int x) { return x + 1; }
static int s2(int x) { return x + 2; }
int main(void) { return s1(0) + s2(0) - 3; }
EOF
}

gen_wide() {   # functions far enough apart that the offset needs real width
  {
    for i in $(seq 1 12); do
      echo "int w$i(int x) { int a[512]; a[0] = x; a[511] = x; return a[0] + a[511] + $i; }"
    done
    echo 'int main(void) { return w1(0) + w12(0) - 13; }'
  } > "$1"
}

gen_lib() {
  cat > "$1" <<'EOF'
int la(int x) { return x * 2; }
int lb(int x) { return x * 3; }
EOF
}

gen_libmain() {
  cat > "$1" <<'EOF'
extern int la(int), lb(int);
int main(void) { return la(1) + lb(1) - 5; }
EOF
}

# An unwinder walking four frames that the compiler under test produced, and
# naming each one through dladdr -- so the check is layout-independent and does
# not assume the compiler emits functions in source order.
gen_unwind() {
  cat > "$1" <<'EOF'
#include <stdio.h>
#include <string.h>
struct _Unwind_Context;
typedef int (*trace_fn)(struct _Unwind_Context *, void *);
extern int _Unwind_Backtrace(trace_fn, void *);
extern unsigned long _Unwind_GetIP(struct _Unwind_Context *);
/* Declared locally rather than via <dlfcn.h>: Dl_info's layout is stable ABI
   and this keeps the case free of feature-test-macro differences. */
typedef struct { const char *fname; void *fbase; const char *sname; void *saddr; } Dl_info_;
extern int dladdr(void *addr, Dl_info_ *info);

static unsigned long ips[64];
static int n;
static int cb(struct _Unwind_Context *c, void *d) {
    (void)d;
    if (n < 64) ips[n++] = _Unwind_GetIP(c);
    return 0;
}
int deep(int x)  { _Unwind_Backtrace(cb, 0); return x; }
int mid(int x)   { return deep(x) + 1; }
int outer(int x) { return mid(x) + 1; }

static const char *want[4] = { "deep", "mid", "outer", "main" };
int main(void) {
    int i, bad = 0;
    outer(1);
    if (n < 5) { printf("only %d frames\n", n); return 1; }
    for (i = 0; i < 4; i++) {
        Dl_info_ di;
        /* Return addresses point after the call, so step back one byte for
           every frame but the innermost. */
        void *p = (void *)(ips[i] - (i ? 1 : 0));
        if (!dladdr(p, &di) || !di.sname) { printf("frame %d unresolved\n", i); bad = 1; continue; }
        if (strcmp(di.sname, want[i]) != 0) {
            printf("frame %d is %s, wanted %s\n", i, di.sname, want[i]);
            bad = 1;
        }
    }
    if (!bad) printf("unwound deep mid outer main\n");
    return bad;
}
EOF
}

# ---------------------------------------------------------------------------
# readers
# ---------------------------------------------------------------------------

# fde_relocs_ <obj>
#   One line per relocation in `.rela.eh_frame': "<symbol> <decimal addend>".
#   With no LSDA or personality routine in play -- no C++ here, and neither
#   compiler emits one for plain C -- there is exactly one such relocation per
#   FDE, and it is the PC-Begin one. `count_matches_funcs' below is what holds
#   that assumption to account.
fde_relocs_() {
  readelf -rW "$1" 2>/dev/null | awk "
    /^Relocation section '\\.rela\\.eh_frame'/ { f = 1; next }
    /^Relocation section/                     { f = 0 }
    f && /^[0-9a-f][0-9a-f]+ / { print \$5, \$6 \$7 }
  " | while read -r sym add; do
    case "$add" in
      +*) printf '%s %s\n'  "$sym" "$(hex_ "${add#+}")" ;;
      -*) printf '%s -%s\n' "$sym" "$(hex_ "${add#-}")" ;;
      *)  printf '%s %s\n'  "$sym" "$add" ;;
    esac
  done
}

# func_offsets_ <obj>   -- offsets of every defined FUNC symbol, decimal, sorted
func_offsets_() {
  readelf -sW "$1" 2>/dev/null \
    | awk '$4 == "FUNC" && $7 != "UND" { print $2 }' \
    | while read -r v; do hex_ "$v"; echo; done | sort -n
}

# fde_pcs_ <linked binary>   -- start pc of every FDE, decimal, sorted
fde_pcs_() {
  readelf --debug-dump=frames "$1" 2>/dev/null \
    | sed -n 's/.* FDE cie=[0-9a-f]* pc=\([0-9a-f]*\)\.\..*/\1/p' \
    | while read -r v; do hex_ "$v"; echo; done | sort -n
}

# sym_addr_ <binary> <name>   -- decimal address of a text symbol.
#   `nm -D' as well as `nm': tcc's linker writes no `.symtab' into an
#   executable, so the linked-image cases build with -rdynamic and the names
#   are read out of `.dynsym'.
sym_addr_() {
  local a
  a="$( { nm "$1" 2>/dev/null; nm -D "$1" 2>/dev/null; } \
        | awk -v n="$2" 'toupper($2) == "T" && $3 == n { print $1; exit }')"
  [ -n "$a" ] || return 1
  hex_ "$a"
}

# ---------------------------------------------------------------------------
# checks
# ---------------------------------------------------------------------------

# addends_match_funcs <label> <source generator>
#   The object's PC-Begin addends must, as a multiset, be exactly the offsets
#   of its function symbols -- and the (symbol, addend) pairs must be pairwise
#   distinct, which is the property ld's overlap test is really about.
#
#   Distinctness is on the *pair*, not on the addend alone, because a compiler
#   is free to spread functions across several sections: gcc puts `main' in
#   `.text.startup', so two different FDEs legitimately carry addend 0 against
#   two different section symbols. Note also that the first function of a
#   section sits at offset 0, so "nonzero" is not the property -- "distinct,
#   and equal to the function offsets" is.
addends_match_funcs() {
  local label="$1" gen="$2" src="$WORK/a.c" obj="$WORK/a.o" out
  "$gen" "$src"
  out="$(cc_ -c "$src" -o "$obj" 2>&1)" || {
    bad_ "$label" "compile failed: $(one_line_ "$out")"; return; }

  fde_relocs_ "$obj" > "$WORK/rel.txt"
  if [ ! -s "$WORK/rel.txt" ]; then
    bad_ "$label" "no .rela.eh_frame relocations at all"; return
  fi

  local nrel ndistinct nfunc
  nrel="$(wc -l < "$WORK/rel.txt")"
  ndistinct="$(sort -u < "$WORK/rel.txt" | wc -l)"
  nfunc="$(func_offsets_ "$obj" | wc -l)"

  if [ "$nrel" -ne "$ndistinct" ]; then
    bad_ "$label" "$((nrel - ndistinct)) of $nrel FDEs share a (symbol, addend) -- overlapping"
    sed 's/^/          /' "$WORK/rel.txt" | head -8
    return
  fi
  if [ "$nrel" -ne "$nfunc" ]; then
    bad_ "$label" "$nrel eh_frame relocations for $nfunc functions"; return
  fi

  awk '{ print $2 }' "$WORK/rel.txt" | sort -n > "$WORK/rel-off.txt"
  func_offsets_ "$obj" > "$WORK/fun-off.txt"
  if diff -q "$WORK/rel-off.txt" "$WORK/fun-off.txt" >/dev/null; then
    ok_ "$label" "$nrel FDEs, addends = function offsets"
  else
    bad_ "$label" "addends are not the function offsets"
    diff "$WORK/fun-off.txt" "$WORK/rel-off.txt" | head -12 | sed 's/^/          /'
  fi
}

# links_under_gnu_ld <label> <ld arguments...>
#   GNU ld must accept the object, and specifically must not report overlapping
#   FDEs. The phrase is asserted in the negative only, so a differently-worded
#   future ld still passes; the exit status is the real gate.
links_under_gnu_ld() {
  local label="$1"; shift
  local out rc
  out="$(gcc "$@" 2>&1)"; rc=$?
  if printf '%s' "$out" | grep -qF 'overlapping FDEs'; then
    bad_ "$label" "ld: overlapping FDEs"
  elif [ "$rc" -ne 0 ]; then
    bad_ "$label" "link failed: $(one_line_ "$out")"
  else
    ok_ "$label" "linked"
  fi
}

# fdes_cover_funcs <label> <binary> <function>...
#   In a *linked* image, every named function must have an FDE starting exactly
#   at its address, and no two FDEs in the image may start at the same address.
#   Run against both linkers: tcc's own linker adds the in-place word, so this
#   is the half that pins tcc-linked output did not regress.
fdes_cover_funcs() {
  local label="$1" bin="$2"; shift 2
  fde_pcs_ "$bin" > "$WORK/pcs.txt"
  if [ ! -s "$WORK/pcs.txt" ]; then
    bad_ "$label" "no FDEs in the linked image"; return
  fi
  local n u
  n="$(wc -l < "$WORK/pcs.txt")"; u="$(sort -un < "$WORK/pcs.txt" | wc -l)"
  if [ "$n" -ne "$u" ]; then
    bad_ "$label" "$((n - u)) of $n FDEs share a start address"; return
  fi
  local fn a
  for fn in "$@"; do
    a="$(sym_addr_ "$bin" "$fn")" || { bad_ "$label" "no symbol $fn"; return; }
    grep -qx "$a" "$WORK/pcs.txt" || { bad_ "$label" "no FDE starts at $fn"; return; }
  done
  ok_ "$label" "$n distinct FDEs, one at each of $*"
}

# runs <label> <argv...>
runs() {
  local label="$1"; shift
  local out rc
  [ -x "$1" ] || { bad_ "$label" "not built"; return; }
  out="$("$@" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then ok_ "$label" "$(one_line_ "$out")"
  else bad_ "$label" "exit $rc: $(one_line_ "$out")"; fi
}

# ---------------------------------------------------------------------------

echo "-- the object: PC-Begin lives in r_addend and names the right function"
addends_match_funcs 'four functions in one TU'      gen_four
addends_match_funcs 'a lone function (addend 0 is correct here)' gen_one
addends_match_funcs 'file-local functions'          gen_static
addends_match_funcs 'twelve functions, offsets past 0xff'            gen_wide

echo "-- the same, with debug info on, where tccdbg.c has more to do"
gen_four "$WORK/g.c"
if out="$(cc_ -g -c "$WORK/g.c" -o "$WORK/g.o" 2>&1)"; then
  fde_relocs_ "$WORK/g.o" | sort -u > "$WORK/g-rel.txt"
  if [ "$(wc -l < "$WORK/g-rel.txt")" -eq 4 ]; then
    awk '{print $2}' "$WORK/g-rel.txt" | sort -n > "$WORK/g-a.txt"
    func_offsets_ "$WORK/g.o" > "$WORK/g-f.txt"
    if diff -q "$WORK/g-a.txt" "$WORK/g-f.txt" >/dev/null; then
      ok_ '-g does not disturb the addends' 'addends = function offsets'
    else
      bad_ '-g does not disturb the addends' 'addends are not the function offsets'
    fi
  else
    bad_ '-g does not disturb the addends' "expected 4 distinct FDE relocations"
  fi
else
  bad_ '-g does not disturb the addends' "compile failed: $(one_line_ "$out")"
fi

echo "-- GNU ld accepts what it used to refuse"
gen_four "$WORK/four.c"
cc_ -c "$WORK/four.c" -o "$WORK/four.o" 2>/dev/null
links_under_gnu_ld 'a single object'  "$WORK/four.o" -o "$WORK/four.prog"
runs 'and the program runs' "$WORK/four.prog"

gen_lib "$WORK/lib.c"; gen_libmain "$WORK/libmain.c"
cc_ -c "$WORK/lib.c" -o "$WORK/lib.o" 2>/dev/null
cc_ -c "$WORK/libmain.c" -o "$WORK/libmain.o" 2>/dev/null
links_under_gnu_ld 'two objects'      "$WORK/lib.o" "$WORK/libmain.o" -o "$WORK/two.prog"
runs 'and that program runs' "$WORK/two.prog"

gcc -c "$WORK/libmain.c" -o "$WORK/libmain.gcc.o" 2>/dev/null
links_under_gnu_ld 'mixed with a gcc object' "$WORK/lib.o" "$WORK/libmain.gcc.o" -o "$WORK/mix.prog"
runs 'and that program runs' "$WORK/mix.prog"

rm -f "$WORK/lib.a"; ar rcs "$WORK/lib.a" "$WORK/lib.o" 2>/dev/null
links_under_gnu_ld 'out of a static archive' "$WORK/libmain.o" "$WORK/lib.a" -o "$WORK/ar.prog"
runs 'and that program runs' "$WORK/ar.prog"

links_under_gnu_ld 'a shared object'  -shared "$WORK/lib.o" -o "$WORK/lib.so"

gen_wide "$WORK/wide.c"
cc_ -c "$WORK/wide.c" -o "$WORK/wide.o" 2>/dev/null
links_under_gnu_ld 'twelve functions, offsets past 0xff' "$WORK/wide.o" -o "$WORK/wide.prog"
runs 'and that program runs' "$WORK/wide.prog"

echo "-- the linked table, under GNU ld"
# -rdynamic only so that the function names survive into a symbol table both
# linkers write; it has nothing to do with what is being checked.
links_under_gnu_ld 'GNU ld links it -rdynamic' -rdynamic "$WORK/four.o" -o "$WORK/dyn.prog"
fdes_cover_funcs 'GNU ld: an FDE at each function' "$WORK/dyn.prog" f1 f2 f3 main

echo "-- and under the compiler's own linker, which must not have regressed"
if out="$(cc_ -rdynamic "$WORK/four.c" -o "$WORK/own.prog" 2>&1)"; then
  ok_ "the compiler links it itself" 'linked'
  runs 'and that program runs' "$WORK/own.prog"
  fdes_cover_funcs "own linker: an FDE at each function" "$WORK/own.prog" f1 f2 f3 main
else
  bad_ "the compiler links it itself" "$(one_line_ "$out")"
fi

echo "-- end to end: an unwinder walking frames this compiler produced"
gen_unwind "$WORK/u.c"
if out="$(cc_ -c "$WORK/u.c" -o "$WORK/u.o" 2>&1)"; then
  # -rdynamic so dladdr can see the executable's own symbols.
  links_under_gnu_ld 'GNU ld links the unwind case' -rdynamic "$WORK/u.o" -ldl -o "$WORK/u.prog"
  runs '_Unwind_Backtrace names all four frames' "$WORK/u.prog"
else
  bad_ 'the unwind case compiles' "$(one_line_ "$out")"
fi

echo "-----"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
