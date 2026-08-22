#!/usr/bin/env bash
# Check that .eh_frame_hdr's binary-search table indexes every FDE in the
# image, whatever augmentation the FDE's CIE carries.
# Usage: run.sh /path/to/tcc     (also passes against gcc: run.sh "$(command -v gcc)")
#
# tccdbg.c's tcc_eh_frame_hdr() walks .eh_frame to build the sorted table that
# _Unwind_Find_FDE binary-searches. The walk recognised exactly one CIE shape --
# version 1 or 3, augmentation string exactly "zR", augmentation data exactly
# one byte equal to FDE_ENCODING -- and `goto next'd past anything else without
# recording it. The header still came out well-formed, with a count field and a
# sorted table; it was just silently short. Nothing in the output says which
# frames are missing, and readelf reports the section as present either way.
#
# The shape that matters is a CIE naming a personality routine. gcc writes
# "zPR" for those, and `.cfi_personality' in hand-written assembly produces the
# same; add an LSDA and it is "zPLR". LuaJIT's interpreter CIE is one of these
# -- it names lj_err_unwind_dwarf -- so the one frame LuaJIT's error handling
# needs was exactly the one the table left out.
#
# ## What this harness pins
#
# The property is: for every FDE in .eh_frame there is a table entry naming it,
# the entries agree with the FDE start addresses, and the table is sorted --
# which is what makes it binary-searchable at all. That holds for gcc + GNU ld
# as well, which is what makes it a reference property rather than a
# restatement of this patch.
#
# It also pins the negative half, which is not a detail: a CIE whose FDE
# pointer encoding this table cannot express must still be *skipped*, not
# guessed at. A table entry computed from a misread encoding is worse than a
# missing one -- the unwinder would follow it. So the unrepresentable case
# below asserts that the surviving entries stay correct and sorted, not that
# the count went up.
#
# It does NOT pin: the byte layout of .eh_frame, the number or ordering of
# CIEs, which augmentation characters a compiler chooses to emit, the table's
# own encoding bytes, or whether a link-only invocation emits a header at all
# (it does not, as of this patch -- see TODO.md; every case here therefore
# compiles and links in one step, which is the path that reaches the
# generator).
#
# Needs `gcc`, `ld` (via gcc), `readelf` on PATH, and a libgcc unwinder
# (`_Unwind_Backtrace`) plus `dladdr` for the end-to-end group.
set -u
CC="${1:?usage: run.sh /path/to/tcc}"
CCDIR="$(cd "$(dirname "$CC")" && pwd)"
# The vendored tcc is configured with absolute sysinclude/lib/crt paths, but it
# still wants -B at its own directory to find libtcc1.a and its include/. gcc
# treats -B as a harmless extra prefix, so the same invocation serves both.
cc_() { "$CC" -B"$CCDIR" "$@"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok_()  { printf '  PASS  %-52s %s\n' "$1" "${2-}"; pass=$((pass + 1)); }
bad_() { printf '  FAIL  %-52s %s\n' "$1" "${2-}"; fail=$((fail + 1)); }
one_line_() { printf '%s' "$1" | tr '\n' ' ' | cut -c1-96; }

# ---------------------------------------------------------------------------
# sources
#
# Each assembly file below is a *producer of CIE shapes*, not a program of
# interest: what varies between them is the augmentation string GNU as is made
# to emit, which is the axis this patch is about.
# ---------------------------------------------------------------------------

gen_main() {   # links against whatever the assembly file defines
  cat > "$1" <<EOF
$(for f in $2; do echo "extern int $f(void);"; done)
int local1(void) { return 1; }
int local2(void) { return 1; }
int main(void) {
    int n = local1() + local2();
$(for f in $2; do echo "    n += $f();"; done)
    return n - $(( $(printf '%s\n' $2 | wc -l) + 2 ));
}
EOF
}

# "zR": the only shape the walk used to accept.
gen_plain_s() {
  cat > "$1" <<'EOF'
	.text
	.globl	p1
	.type	p1,@function
p1:	.cfi_startproc
	movl	$1, %eax
	ret
	.cfi_endproc
	.globl	p2
	.type	p2,@function
p2:	.cfi_startproc
	movl	$1, %eax
	ret
	.cfi_endproc
EOF
}

# "zPR" and "zPLR": a personality routine, and a personality routine with an
# LSDA. This is the shape the walk dropped.
gen_pers_s() {
  cat > "$1" <<'EOF'
	.text
	.globl	q1
	.type	q1,@function
q1:	.cfi_startproc
	.cfi_personality 0x1b, eh_personality
	movl	$1, %eax
	ret
	.cfi_endproc
	.globl	q2
	.type	q2,@function
q2:	.cfi_startproc
	.cfi_personality 0x1b, eh_personality
	.cfi_lsda 0x1b, .LLSDA_q2
	movl	$1, %eax
	ret
	.cfi_endproc
	.section .gcc_except_table,"a",@progbits
.LLSDA_q2:
	.byte	0xff
	.text
	.globl	eh_personality
	.type	eh_personality,@function
eh_personality:
	xorl	%eax, %eax
	ret
EOF
}

# "zRS": a signal frame. 'S' carries no augmentation data at all, so it is the
# case that catches a walk which assumes every augmentation character consumes
# bytes.
gen_signal_s() {
  cat > "$1" <<'EOF'
	.text
	.globl	s1
	.type	s1,@function
s1:	.cfi_startproc
	.cfi_signal_frame
	movl	$1, %eax
	ret
	.cfi_endproc
EOF
}

# A hand-written CIE whose 'R' entry names an encoding the table cannot
# express (DW_EH_PE_udata8|DW_EH_PE_absptr: an 8-byte absolute initial
# location, where the table's own entries are 4-byte pc-relative). Its FDE
# must be skipped, and the rest of the table must be unharmed. Written out
# by hand because no .cfi_* directive asks gas for this.
gen_widenc_s() {
  cat > "$1" <<'EOF'
	.text
	.globl	w1
	.type	w1,@function
w1:	movl	$1, %eax
	ret
.Lw1_end:
	.section .eh_frame,"a",@progbits
.Lwcie:
	.long	.Lwcie_end-.Lwcie_start
.Lwcie_start:
	.long	0
	.byte	1
	.string	"zR"
	.uleb128 1
	.sleb128 -8
	.byte	16
	.uleb128 1
	.byte	0x04			/* DW_EH_PE_udata8|DW_EH_PE_absptr */
	.byte	0x0c
	.uleb128 7
	.uleb128 8
	.align	8
.Lwcie_end:
.Lwfde:
	.long	.Lwfde_end-.Lwfde_start
.Lwfde_start:
	.long	.Lwfde_start-.Lwcie
	.quad	w1
	.quad	.Lw1_end-w1
	.uleb128 0
	.align	8
.Lwfde_end:
EOF
}

# An unwinder walking through a frame whose CIE names a personality routine.
# This is the end-to-end half: _Unwind_Find_FDE reaches the search table
# through PT_GNU_EH_FRAME, so a frame missing from the table is a frame the
# unwinder cannot walk past, however correct .eh_frame itself is.
gen_unwind_c() {
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

extern int through_personality_frame(int (*)(int), int);

static unsigned long ips[64];
static int n;
static int cb(struct _Unwind_Context *c, void *d) {
    (void)d;
    if (n < 64) ips[n++] = _Unwind_GetIP(c);
    return 0;
}
static int deep(int x) { _Unwind_Backtrace(cb, 0); return x; }
int outer(int x) { return through_personality_frame(deep, x); }

/* The assertion is that the walk gets *past* through_personality_frame, not
   that any particular frame can be named: reaching main means every frame
   below it was found, and the personality-bearing one is in between.  If its
   FDE were missing from the search table, _Unwind_Find_FDE would come up
   empty there and the walk would stop short of main.  Naming frames by
   dladdr is not usable as the assertion -- static functions never reach
   .dynsym at all, and which of the intermediate frames do is a linker's
   choice, not a property either compiler owes. */
int main(void) {
    int i;
    outer(1);
    for (i = 0; i < n; i++) {
        Dl_info_ di;
        /* Return addresses point after the call, so step back one byte for
           every frame but the innermost. */
        void *p = (void *)(ips[i] - (i ? 1 : 0));
        if (dladdr(p, &di) && di.sname && !strcmp(di.sname, "main")) {
            printf("unwound %d frames, through the personality frame to main\n",
                   i + 1);
            return 0;
        }
    }
    printf("walk stopped after %d frames without reaching main\n", n);
    return 1;
}
EOF
}

# The frame in the middle of that walk, with a personality routine on it.
gen_unwind_s() {
  cat > "$1" <<'EOF'
	.text
	.globl	through_personality_frame
	.type	through_personality_frame,@function
through_personality_frame:
	.cfi_startproc
	.cfi_personality 0x1b, eh_personality2
	pushq	%rbp
	.cfi_def_cfa_offset 16
	.cfi_offset 6, -16
	movq	%rsp, %rbp
	.cfi_def_cfa_register 6
	movq	%rdi, %rax
	movl	%esi, %edi
	call	*%rax
	popq	%rbp
	.cfi_def_cfa 7, 8
	ret
	.cfi_endproc
	.globl	eh_personality2
	.type	eh_personality2,@function
eh_personality2:
	xorl	%eax, %eax
	ret
EOF
}

# ---------------------------------------------------------------------------
# readers
# ---------------------------------------------------------------------------

hex_() { printf '%d' "$((16#${1#0x}))"; }

# sec_ <bin> <name>   -- "<addr> <size>", decimal; empty if the section is absent
sec_() {
  readelf -SW "$1" 2>/dev/null | sed 's/^ *\[[ 0-9]*\] *//' \
    | awk -v n="$2" '$1 == n { print $3, $5; exit }' \
    | while read -r a s; do
        printf '%d %d\n' "$(hex_ "$a")" "$(hex_ "$s")"
      done
}

# sec_bytes_ <bin> <name> <size>   -- the section's contents, one decimal byte
#   per line. `readelf -x' is what the other harnesses here read raw bytes
#   with, so it is what this one uses too. Its rows carry up to four 8-digit
#   hex groups followed by an ASCII gutter that can itself look like hex on a
#   short final row, so the read is bounded by the section size rather than by
#   guessing which field the gutter starts at.
sec_bytes_() {
  readelf -x "$2" "$1" 2>/dev/null \
    | awk -v want=$(( $3 * 2 )) '
        /^  0x[0-9a-f]+ / {
          for (i = 2; i <= NF && got < want; i++) {
            if ($i !~ /^[0-9a-f]+$/ || length($i) % 2) break
            n = length($i)
            if (got + n > want) n = want - got
            s = s substr($i, 1, n); got += n
          }
        }
        END { for (i = 1; i <= got; i += 2) print substr(s, i, 2) }' \
    | while read -r b; do printf '%d\n' "$(hex_ "$b")"; done
}

# hdr_table_ <bin>
#   The .eh_frame_hdr binary-search table, decoded: one "<pc> <fde>" line per
#   entry, absolute addresses, decimal, in stored order. Prints nothing if the
#   section is absent. Assumes the encoding bytes tcc and GNU ld both write --
#   version 1, table entries DW_EH_PE_sdata4|DW_EH_PE_datarel -- and says so
#   rather than silently mis-decoding if it meets anything else.
hdr_table_() {
  local info addr size
  info="$(sec_ "$1" .eh_frame_hdr)"
  [ -n "$info" ] || return 0
  addr="${info%% *}"; size="${info##* }"
  sec_bytes_ "$1" .eh_frame_hdr "$size" \
    | awk -v base="$addr" '
      { b[NR - 1] = $1 }
      function u32(i,   v) { v = b[i] + b[i+1]*256 + b[i+2]*65536 + b[i+3]*16777216; return v }
      function s32(i,   v) { v = u32(i); return v >= 2147483648 ? v - 4294967296 : v }
      END {
        if (b[0] != 1)    { print "BADVERSION " b[0]; exit }
        if (b[3] != 0x3b) { print "BADTABLEENC " b[3]; exit }
        cnt = u32(8)
        for (i = 0; i < cnt; i++) {
          o = 12 + i * 8
          if (o + 8 > NR) { print "TRUNCATED"; exit }
          printf "%d %d\n", base + s32(o), base + s32(o + 4)
        }
      }'
}


# fde_pcs_ <bin>   -- start pc of every FDE, decimal, sorted
fde_pcs_() {
  readelf --debug-dump=frames "$1" 2>/dev/null \
    | sed -n 's/.* FDE cie=[0-9a-f]* pc=\([0-9a-f]*\)\.\..*/\1/p' \
    | while read -r v; do hex_ "$v"; echo; done | sort -n
}

# fde_addrs_ <bin>   -- address of every FDE record itself, decimal, sorted.
#   readelf prints the FDE's offset within .eh_frame; add the section address.
fde_addrs_() {
  local info base
  info="$(sec_ "$1" .eh_frame)"
  [ -n "$info" ] || return 0
  base="${info%% *}"
  readelf --debug-dump=frames "$1" 2>/dev/null \
    | sed -n 's/^\([0-9a-f]*\) [0-9a-f]* [0-9a-f]* FDE .*/\1/p' \
    | while read -r v; do echo $(( base + $(hex_ "$v") )); done | sort -n
}

# aug_strings_ <obj-or-bin>   -- augmentation string of every CIE, sorted
aug_strings_() {
  readelf --debug-dump=frames-interp "$1" 2>/dev/null \
    | sed -n 's/.* CIE "\([^"]*\)".*/\1/p' | sort -u
}

# ---------------------------------------------------------------------------
# checks
# ---------------------------------------------------------------------------

# table_indexes_all <label> <binary> [expected augmentation strings...]
#   Every FDE in the image is named by exactly one table entry, every entry
#   points at a real FDE, and the entries are sorted by pc. That last part is
#   not cosmetic: the header declares a binary-searchable table, so an
#   unsorted one is a wrong answer, not a slow one.
table_indexes_all() {
  local label="$1" bin="$2"; shift 2
  local aug
  if [ "$#" -gt 0 ]; then
    aug="$(aug_strings_ "$bin" | tr '\n' ' ')"
    for want in "$@"; do
      case " $aug " in
        *" $want "*) ;;
        *) bad_ "$label" "the image has no $want CIE (got: $aug) -- case is not testing what it says"
           return ;;
      esac
    done
  fi

  hdr_table_ "$bin" > "$WORK/tab.txt"
  if [ ! -s "$WORK/tab.txt" ]; then
    bad_ "$label" "no .eh_frame_hdr table"; return
  fi
  case "$(head -1 "$WORK/tab.txt")" in
    BAD*|TRUNCATED*) bad_ "$label" "undecodable header: $(head -1 "$WORK/tab.txt")"; return ;;
  esac

  fde_pcs_ "$bin" > "$WORK/pcs.txt"
  fde_addrs_ "$bin" > "$WORK/fdes.txt"
  awk '{ print $1 }' "$WORK/tab.txt" | sort -n > "$WORK/tab-pcs.txt"
  awk '{ print $2 }' "$WORK/tab.txt" | sort -n > "$WORK/tab-fdes.txt"

  local nf nt
  nf="$(wc -l < "$WORK/pcs.txt")"; nt="$(wc -l < "$WORK/tab.txt")"
  if [ "$nf" -ne "$nt" ]; then
    bad_ "$label" "$nt of $nf FDEs indexed"; return
  fi
  if ! diff -q "$WORK/pcs.txt" "$WORK/tab-pcs.txt" >/dev/null; then
    bad_ "$label" "table pcs are not the FDE start addresses"
    diff "$WORK/pcs.txt" "$WORK/tab-pcs.txt" | head -8 | sed 's/^/          /'
    return
  fi
  if ! diff -q "$WORK/fdes.txt" "$WORK/tab-fdes.txt" >/dev/null; then
    bad_ "$label" "table entries do not point at the FDE records"; return
  fi
  awk '{ print $1 }' "$WORK/tab.txt" > "$WORK/tab-order.txt"
  if ! diff -q "$WORK/tab-order.txt" "$WORK/tab-pcs.txt" >/dev/null; then
    bad_ "$label" "table is not sorted by pc -- not binary-searchable"; return
  fi
  ok_ "$label" "$nt/$nf FDEs indexed, sorted"
}

# table_skips_but_stays_sound <label> <binary> <how many FDEs may be skipped>
#   For a CIE this table cannot represent, the entries that *are* present must
#   still be real, sorted FDE starts, and at most the named number of FDEs may
#   be missing. Asserting soundness rather than completeness is deliberate: a
#   guessed entry is worse than an absent one.
table_skips_but_stays_sound() {
  local label="$1" bin="$2" allowed="$3"
  hdr_table_ "$bin" > "$WORK/tab.txt"
  if [ ! -s "$WORK/tab.txt" ]; then
    bad_ "$label" "no .eh_frame_hdr table at all"; return
  fi
  case "$(head -1 "$WORK/tab.txt")" in
    BAD*|TRUNCATED*) bad_ "$label" "undecodable header: $(head -1 "$WORK/tab.txt")"; return ;;
  esac
  fde_pcs_ "$bin" > "$WORK/pcs.txt"
  awk '{ print $1 }' "$WORK/tab.txt" > "$WORK/tab-order.txt"
  sort -n "$WORK/tab-order.txt" > "$WORK/tab-pcs.txt"

  local nf nt missing
  nf="$(wc -l < "$WORK/pcs.txt")"; nt="$(wc -l < "$WORK/tab.txt")"
  missing=$(( nf - nt ))
  if [ "$missing" -lt 0 ] || [ "$missing" -gt "$allowed" ]; then
    bad_ "$label" "$nt of $nf FDEs indexed, expected at least $(( nf - allowed ))"; return
  fi
  local pc
  while read -r pc; do
    grep -qx "$pc" "$WORK/pcs.txt" || {
      bad_ "$label" "table names $pc, which is not any FDE's start"; return; }
  done < "$WORK/tab-pcs.txt"
  if diff -q "$WORK/tab-order.txt" "$WORK/tab-pcs.txt" >/dev/null; then
    ok_ "$label" "$nt/$nf indexed, every entry a real FDE start, sorted"
  else
    bad_ "$label" "table is not sorted by pc"
  fi
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

# build_ <out> <asm generator> <extern function names> -- compile + link in one
#   step, which is the invocation that reaches the .eh_frame_hdr generator.
build_() {
  local out="$1" gen="$2" funcs="$3"
  "$gen" "$WORK/aux.s"
  gen_main "$WORK/m.c" "$funcs"
  gcc -c "$WORK/aux.s" -o "$WORK/aux.o" 2>/dev/null || return 1
  cc_ -o "$out" "$WORK/m.c" "$WORK/aux.o" 2>"$WORK/err.txt"
}

# ---------------------------------------------------------------------------

echo "-- every FDE reaches the table, whatever its CIE's augmentation"

if build_ "$WORK/plain.prog" gen_plain_s "p1 p2"; then
  table_indexes_all 'zR: the shape that always worked' "$WORK/plain.prog" zR
  runs 'and that program runs' "$WORK/plain.prog"
else
  bad_ 'zR: the shape that always worked' "build failed: $(one_line_ "$(cat "$WORK/err.txt")")"
fi

if build_ "$WORK/pers.prog" gen_pers_s "q1 q2"; then
  table_indexes_all 'zPR and zPLR: a personality routine' "$WORK/pers.prog" zPR zPLR
  runs 'and that program runs' "$WORK/pers.prog"
else
  bad_ 'zPR and zPLR: a personality routine' "build failed: $(one_line_ "$(cat "$WORK/err.txt")")"
fi

if build_ "$WORK/sig.prog" gen_signal_s "s1"; then
  table_indexes_all 'zRS: a signal frame, an entry of no width' "$WORK/sig.prog" zRS
  runs 'and that program runs' "$WORK/sig.prog"
else
  bad_ 'zRS: a signal frame, an entry of no width' "build failed: $(one_line_ "$(cat "$WORK/err.txt")")"
fi

echo "-- shapes the table cannot represent are skipped, not guessed at"

if build_ "$WORK/wide.prog" gen_widenc_s "w1"; then
  table_skips_but_stays_sound 'an 8-byte absolute FDE encoding' "$WORK/wide.prog" 1
else
  bad_ 'an 8-byte absolute FDE encoding' "build failed: $(one_line_ "$(cat "$WORK/err.txt")")"
fi

echo "-- the compiler's own C, alongside all of it"

gen_plain_s "$WORK/a1.s"; gen_pers_s "$WORK/a2.s"; gen_signal_s "$WORK/a3.s"
gcc -c "$WORK/a1.s" -o "$WORK/a1.o" 2>/dev/null
gcc -c "$WORK/a2.s" -o "$WORK/a2.o" 2>/dev/null
gcc -c "$WORK/a3.s" -o "$WORK/a3.o" 2>/dev/null
gen_main "$WORK/all.c" "p1 p2 q1 q2 s1"
if out="$(cc_ -o "$WORK/all.prog" "$WORK/all.c" "$WORK/a1.o" "$WORK/a2.o" "$WORK/a3.o" 2>&1)"; then
  table_indexes_all 'all four augmentations in one image' "$WORK/all.prog" zR zPR zPLR zRS
  runs 'and that program runs' "$WORK/all.prog"
else
  bad_ 'all four augmentations in one image' "build failed: $(one_line_ "$out")"
fi

if out="$(cc_ -g -o "$WORK/allg.prog" "$WORK/all.c" "$WORK/a1.o" "$WORK/a2.o" "$WORK/a3.o" 2>&1)"; then
  table_indexes_all 'the same with -g' "$WORK/allg.prog" zR zPR zPLR zRS
else
  bad_ 'the same with -g' "build failed: $(one_line_ "$out")"
fi

echo "-- end to end: an unwinder finding a personality-bearing frame"

gen_unwind_c "$WORK/u.c"; gen_unwind_s "$WORK/u.s"
gcc -c "$WORK/u.s" -o "$WORK/u.o" 2>/dev/null
# The unwinder itself has to come from somewhere, and where it lives differs by
# toolchain layout: tcc has no -lgcc default and does not know gcc's private
# library directory, so the name that resolves is the one this loop finds.
# -rdynamic so dladdr can see the executable's own symbols.
uwlib=
for cand in -lgcc_eh -lgcc_s -lgcc; do
  if cc_ -rdynamic -o "$WORK/u.prog" "$WORK/u.c" "$WORK/u.o" "$cand" -ldl >/dev/null 2>&1; then
    uwlib="$cand"; break
  fi
done
if [ -n "$uwlib" ]; then
  table_indexes_all 'the unwind case indexes its zPR frame' "$WORK/u.prog" zPR
  runs "_Unwind_Backtrace walks through it ($uwlib)" "$WORK/u.prog"
else
  # Not a failure: no libgcc unwinder was linkable here, so the runtime half
  # cannot run at all. The structural half of the same property is still
  # asserted by every table_indexes_all case above, which did run.
  printf '  SKIP  %-52s %s\n' 'the end-to-end unwind case' 'no linkable libgcc unwinder'
fi

echo "-----"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
