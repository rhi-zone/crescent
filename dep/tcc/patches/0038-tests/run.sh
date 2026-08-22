#!/usr/bin/env bash
# Check that .eh_frame_hdr is emitted by whichever links produce it in a real
# linker, and by no others -- independently of whether the same invocation also
# compiled anything.
# Usage: run.sh /path/to/tcc     (also passes against gcc: run.sh "$(command -v gcc)")
#
# ## The defect
#
# tcc has full .eh_frame_hdr generation, but the generator reads
# s1->eh_frame_section, and tcc_eh_frame_start() only ever sets that field while
# COMPILING -- it is the handle the code generator appends its own CIE and FDEs
# to. So `tcc -c a.c` followed by `tcc -o exe a.o`, the shape every multi-file
# build uses, left the field NULL and the generator returned on its first line,
# even though the merge loop had built a complete, correct output .eh_frame out
# of the input objects.
#
# Separately, the call site sat inside `if (!s1->static_link)`, so a static link
# produced no header either, one-shot or not.
#
# ## The reference behaviour this pins
#
# Measured against GNU ld 2.44 and GNU gold on x86-64, not assumed:
#
#   * a final link, executable or shared, emits .eh_frame_hdr and
#     PT_GNU_EH_FRAME whenever the merged output has .eh_frame content -- and
#     gcc's link driver passes --eh-frame-hdr by default for both -o exe and
#     -shared, so this is what a normal build gets;
#   * whether unwind-table GENERATION happened at compile time does not enter
#     into it. What decides the header is whether .eh_frame content reached the
#     link, from wherever. Objects built with -fno-asynchronous-unwind-tables
#     still get a header if any other input (crt files, a library) carried
#     .eh_frame;
#   * a link whose inputs carry no .eh_frame at all gets no .eh_frame_hdr and no
#     PT_GNU_EH_FRAME -- ld emits neither even when --eh-frame-hdr is passed
#     explicitly. An empty header is not the answer; no header is;
#   * a relocatable/partial link (-r) never gets one, even with --eh-frame-hdr
#     passed explicitly, from either linker. -r output is not a runnable
#     artifact and has no program headers at all; the real link that follows is
#     where the runtime-facing header belongs.
#
# ## What this harness pins
#
# Those four behaviours, plus -- for every case that should have a header --
# that the header's binary-search table names every FDE in the image, agrees
# with the FDE addresses, and is sorted, which is what makes it searchable at
# all. Those table properties hold for gcc + GNU ld too, which is what makes
# this a reference property rather than a restatement of the patch.
#
# It does NOT pin: the byte layout of .eh_frame, section ordering or indices,
# how many CIEs a compiler emits, the header's own encoding bytes, or the
# addresses anything lands at.
#
# ## The one case this deliberately does not pin: -static
#
# The two references disagree there, so nothing here asserts either answer.
# GNU ld emits the header for a static link when asked (`ld -static
# --eh-frame-hdr` produces .eh_frame_hdr and PT_GNU_EH_FRAME, bfd and gold
# alike). gcc's driver does not ask: its link spec reads
# `%{!static|static-pie:--eh-frame-hdr}`, so `gcc -static` gets no header while
# `gcc -static-pie` does. tcc is both driver and linker and would have to pick
# one. It currently behaves like gcc's driver -- no header under -static -- and
# this patch leaves that untouched; the open call is recorded in TODO.md.
#
# The -nostdlib group below is not that case: -nostdlib is an ordinary dynamic
# link with no libc inputs. It checks ELF structure only and does not run its
# binary, which has a stub _start and no exit sequence. The end-to-end group is
# what proves the header is usable at runtime.
#
# Needs `gcc`, `ld` (via gcc), `readelf` on PATH. The end-to-end group also
# needs a libgcc unwinder (`_Unwind_Backtrace`); it reports SKIP if none of
# -lgcc_eh/-lgcc_s/-lgcc links, exactly as 0037's harness does.
set -u
CC="${1:?usage: run.sh /path/to/tcc}"
CCDIR="$(cd "$(dirname "$CC")" && pwd)"
# The vendored tcc is configured with absolute sysinclude/lib/crt paths, but it
# still wants -B at its own directory to find libtcc1.a and its include/. gcc
# treats -B as a harmless extra prefix, so the same invocation serves both.
cc_() { "$CC" -B"$CCDIR" "$@"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0; skip=0
ok_()   { printf '  PASS  %-52s %s\n' "$1" "${2-}"; pass=$((pass + 1)); }
bad_()  { printf '  FAIL  %-52s %s\n' "$1" "${2-}"; fail=$((fail + 1)); }
skip_() { printf '  SKIP  %-52s %s\n' "$1" "${2-}"; skip=$((skip + 1)); }
one_line_() { printf '%s' "$1" | tr '\n' ' ' | cut -c1-96; }

# ---------------------------------------------------------------------------
# sources
# ---------------------------------------------------------------------------

cat > "$WORK/a.c" <<'EOF'
int add2(int x) { return x + 2; }
int add3(int x) { return x + 3; }
EOF

cat > "$WORK/b.c" <<'EOF'
extern int add2(int);
extern int add3(int);
int mul2(int x) { return x * 2; }
int main(void) { return add2(add3(0)) + mul2(0) - 5; }
EOF

# A translation unit with no libc dependency and its own entry point, for the
# -nostdlib groups. _start is never called: these binaries are inspected, not
# run, so it needs no exit sequence and stays architecture-neutral.
cat > "$WORK/n.c" <<'EOF'
int n_add(int x) { return x + 1; }
int n_mul(int x) { return x * 3; }
void _start(void) { }
EOF

# ---------------------------------------------------------------------------
# ELF readers.  Same shape as 0037-tests/run.sh, which is where they came from;
# each harness here is self-contained by convention.
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
#   per line. `readelf -x' rows carry up to four 8-digit hex groups followed by
#   an ASCII gutter that can itself look like hex on a short final row, so the
#   read is bounded by the section size rather than by guessing which field the
#   gutter starts at.
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

# hdr_table_ <bin>   -- one "<pc> <fde>" line per search-table entry, absolute
#   addresses, decimal, in stored order. Empty if the section is absent.
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

# fde_addrs_ <bin>   -- address of every FDE record itself, decimal, sorted
fde_addrs_() {
  local info base
  info="$(sec_ "$1" .eh_frame)"
  [ -n "$info" ] || return 0
  base="${info%% *}"
  readelf --debug-dump=frames "$1" 2>/dev/null \
    | sed -n 's/^\([0-9a-f]*\) [0-9a-f]* [0-9a-f]* FDE .*/\1/p' \
    | while read -r v; do echo $(( base + $(hex_ "$v") )); done | sort -n
}

has_phdr_() { readelf -lW "$1" 2>/dev/null | grep -q "^  $2 "; }

# ---------------------------------------------------------------------------
# checks
# ---------------------------------------------------------------------------

# header_present <label> <binary>
#   The section exists, the PT_GNU_EH_FRAME segment exists, and the segment
#   covers the section. A section nothing points at is unreachable at runtime:
#   _Unwind_Find_FDE finds the header through dl_iterate_phdr, never by name.
header_present() {
  local label="$1" bin="$2" info addr size seg
  info="$(sec_ "$bin" .eh_frame_hdr)"
  if [ -z "$info" ]; then bad_ "$label" "no .eh_frame_hdr section"; return; fi
  addr="${info%% *}"; size="${info##* }"
  if ! has_phdr_ "$bin" GNU_EH_FRAME; then
    bad_ "$label" "section present but no PT_GNU_EH_FRAME"; return
  fi
  seg="$(readelf -lW "$bin" 2>/dev/null \
         | awk '/^  GNU_EH_FRAME /{ print $3, $5; exit }')"
  local svaddr ssize
  svaddr="$(hex_ "${seg%% *}")"; ssize="$(hex_ "${seg##* }")"
  if [ "$svaddr" != "$addr" ] || [ "$ssize" != "$size" ]; then
    bad_ "$label" "segment $svaddr/$ssize != section $addr/$size"; return
  fi
  ok_ "$label" "$size bytes at $addr"
}

# no_header <label> <binary>
#   Neither the section nor the segment. An empty header is not the answer that
#   real ld gives here, so "absent" is checked rather than "harmless".
no_header() {
  local label="$1" bin="$2"
  if [ -n "$(sec_ "$bin" .eh_frame_hdr)" ]; then
    bad_ "$label" ".eh_frame_hdr section present"; return
  fi
  if has_phdr_ "$bin" GNU_EH_FRAME; then
    bad_ "$label" "PT_GNU_EH_FRAME present"; return
  fi
  ok_ "$label"
}

# table_indexes_all <label> <binary>
#   Every FDE in the image is named by exactly one table entry, every entry
#   points at a real FDE, and the entries are sorted by pc. Sortedness is not
#   cosmetic: the header declares a binary-searchable table, so an unsorted one
#   is a wrong answer rather than a slow one.
table_indexes_all() {
  local label="$1" bin="$2" tbl pcs addrs t_pcs t_fdes n_t n_f
  tbl="$(hdr_table_ "$bin")"
  case "$tbl" in
    BAD*|TRUNCATED*) bad_ "$label" "$(one_line_ "$tbl")"; return ;;
    "")              bad_ "$label" "no search table"; return ;;
  esac
  t_pcs="$(printf '%s\n' "$tbl" | awk '{print $1}')"
  t_fdes="$(printf '%s\n' "$tbl" | awk '{print $2}' | sort -n)"
  pcs="$(fde_pcs_ "$bin")"
  addrs="$(fde_addrs_ "$bin")"
  n_t="$(printf '%s\n' "$t_fdes" | grep -c .)"
  n_f="$(printf '%s\n' "$addrs" | grep -c .)"
  if [ "$n_t" != "$n_f" ]; then
    bad_ "$label" "table has $n_t entries, image has $n_f FDEs"; return
  fi
  if [ "$t_fdes" != "$addrs" ]; then
    bad_ "$label" "table FDE pointers do not match the FDEs in .eh_frame"; return
  fi
  if [ "$(printf '%s\n' "$t_pcs" | sort -n)" != "$pcs" ]; then
    bad_ "$label" "table pcs do not match the FDE start pcs"; return
  fi
  if [ "$t_pcs" != "$(printf '%s\n' "$t_pcs" | sort -n)" ]; then
    bad_ "$label" "table is not sorted by pc"; return
  fi
  ok_ "$label" "$n_t/$n_f FDEs indexed, sorted"
}

build_() {   # build_ <outfile> <args...>; records the failure itself
  local out="$1"; shift
  local err
  if err="$(cc_ -o "$out" "$@" 2>&1)"; then return 0; fi
  bad_ "build $(basename "$out")" "$(one_line_ "$err")"
  return 1
}

# ---------------------------------------------------------------------------
# 1. link-only: the shape every multi-file build uses, and the defect's home
# ---------------------------------------------------------------------------
echo "-- link-only (compile and link as separate invocations)"
if cc_ -c "$WORK/a.c" -o "$WORK/a.o" 2>/dev/null &&
   cc_ -c "$WORK/b.c" -o "$WORK/b.o" 2>/dev/null; then
  if build_ "$WORK/sep.prog" "$WORK/a.o" "$WORK/b.o"; then
    header_present    "link-only exe has a header"        "$WORK/sep.prog"
    table_indexes_all "link-only table indexes every FDE" "$WORK/sep.prog"
    if "$WORK/sep.prog"; then ok_ "link-only exe runs"; else bad_ "link-only exe runs" "exit $?"; fi
  fi
else
  bad_ "compile a.o/b.o" "compilation failed"
fi

# ---------------------------------------------------------------------------
# 2. one-shot: unchanged behaviour, the path that already worked
# ---------------------------------------------------------------------------
echo "-- one-shot (compile and link in one invocation)"
if build_ "$WORK/one.prog" "$WORK/a.c" "$WORK/b.c"; then
  header_present    "one-shot exe has a header"        "$WORK/one.prog"
  table_indexes_all "one-shot table indexes every FDE" "$WORK/one.prog"
fi

# ---------------------------------------------------------------------------
# 3. mixed: one object, one source.  The generator must see the merged section,
#    not just the part this invocation compiled.
# ---------------------------------------------------------------------------
echo "-- mixed (one input object, one input source)"
if build_ "$WORK/mix.prog" "$WORK/b.c" "$WORK/a.o"; then
  header_present    "mixed exe has a header"        "$WORK/mix.prog"
  table_indexes_all "mixed table indexes every FDE" "$WORK/mix.prog"
fi

# ---------------------------------------------------------------------------
# 4. shared library, link-only
# ---------------------------------------------------------------------------
echo "-- shared library"
if cc_ -c -fPIC "$WORK/a.c" -o "$WORK/apic.o" 2>/dev/null &&
   build_ "$WORK/lib.so" -shared "$WORK/apic.o"; then
  header_present    "shared lib has a header"        "$WORK/lib.so"
  table_indexes_all "shared lib table indexes every FDE" "$WORK/lib.so"
fi

# ---------------------------------------------------------------------------
# 5. -nostdlib link-only: no libc in the picture, so the only .eh_frame in the
#    output is the one the merge loop built out of the input object.  Structure
#    only -- this binary is not run; see the header comment.
#
#    `-static` is deliberately NOT covered here: the two references disagree on
#    it and tcc's behaviour there is an open question, not a pinned one. See
#    the header comment and TODO.md.
# ---------------------------------------------------------------------------
echo "-- -nostdlib link (structure only)"
if cc_ -c "$WORK/n.c" -o "$WORK/n.o" 2>/dev/null; then
  if build_ "$WORK/nd.prog" -nostdlib "$WORK/n.o"; then
    header_present    "-nostdlib exe has a header"        "$WORK/nd.prog"
    table_indexes_all "-nostdlib table indexes every FDE" "$WORK/nd.prog"
  fi
else
  bad_ "compile n.o" "compilation failed"
fi

# ---------------------------------------------------------------------------
# 6. no .eh_frame content anywhere -> no header at all, not an empty one
# ---------------------------------------------------------------------------
echo "-- no unwind info in any input"
if cc_ -c -fno-asynchronous-unwind-tables "$WORK/n.c" -o "$WORK/nn.o" 2>/dev/null; then
  if [ -n "$(sec_ "$WORK/nn.o" .eh_frame)" ]; then
    skip_ "no-unwind-info inputs" "compiler emitted .eh_frame anyway"
  elif build_ "$WORK/none.prog" -nostdlib "$WORK/nn.o"; then
    if [ -n "$(sec_ "$WORK/none.prog" .eh_frame)" ]; then
      skip_ "no-unwind-info link" "link pulled in .eh_frame from elsewhere"
    else
      no_header "no .eh_frame in -> no header out" "$WORK/none.prog"
    fi
  fi
else
  bad_ "compile nn.o" "-fno-asynchronous-unwind-tables not accepted"
fi

# ---------------------------------------------------------------------------
# 7. -r partial link: never a header, on any real linker
# ---------------------------------------------------------------------------
echo "-- relocatable (-r) partial link"
if build_ "$WORK/part.o" -r "$WORK/a.o" "$WORK/b.o"; then
  if [ -z "$(sec_ "$WORK/part.o" .eh_frame)" ]; then
    bad_ "-r keeps .eh_frame" "input .eh_frame did not survive -r"
  else
    ok_ "-r keeps .eh_frame"
  fi
  no_header "-r emits no header" "$WORK/part.o"
  if readelf -lW "$WORK/part.o" 2>/dev/null | grep -q 'no program headers'; then
    ok_ "-r output has no program headers"
  else
    bad_ "-r output has no program headers"
  fi
  # and a real link of that partial object still gets one
  if build_ "$WORK/frompart.prog" "$WORK/part.o"; then
    header_present    "relink of -r output has a header"        "$WORK/frompart.prog"
    table_indexes_all "relink of -r output indexes every FDE"   "$WORK/frompart.prog"
  fi
fi

# ---------------------------------------------------------------------------
# 8. end-to-end: the unwinder actually reaches the table in a link-only binary.
#    Without the header, _Unwind_Find_FDE's dl_iterate_phdr search finds
#    nothing and the backtrace stops dead at the innermost frame.
# ---------------------------------------------------------------------------
echo "-- end to end (_Unwind_Backtrace through a link-only binary)"
cat > "$WORK/u.c" <<'EOF'
struct _Unwind_Context;
typedef int (*trace_fn)(struct _Unwind_Context *, void *);
extern int _Unwind_Backtrace(trace_fn, void *);
extern unsigned long _Unwind_GetIP(struct _Unwind_Context *);

static int n;
static int cb(struct _Unwind_Context *c, void *d) {
    (void)d;
    if (_Unwind_GetIP(c)) n++;
    return 0;
}
int level3(void) { _Unwind_Backtrace(cb, 0); return n; }
EOF
cat > "$WORK/um.c" <<'EOF'
extern int level3(void);
static int level2(void) { return level3(); }
static int level1(void) { return level2(); }
/* Five distinct frames must be walkable: main, level1, level2, level3 and at
   least the unwinder's own. Fewer than four means the search table did not
   answer for frames that are in .eh_frame. */
int main(void) { return level1() >= 4 ? 0 : 1; }
EOF
uwlib=""
if cc_ -c "$WORK/u.c" -o "$WORK/u.o" 2>/dev/null &&
   cc_ -c "$WORK/um.c" -o "$WORK/um.o" 2>/dev/null; then
  for cand in -lgcc_eh -lgcc_s -lgcc; do
    if cc_ -o "$WORK/u.prog" "$WORK/u.o" "$WORK/um.o" "$cand" >/dev/null 2>&1; then
      uwlib="$cand"; break
    fi
  done
  if [ -z "$uwlib" ]; then
    skip_ "_Unwind_Backtrace walks a link-only binary" "no libgcc unwinder links here"
  else
    header_present "link-only unwinder binary has a header" "$WORK/u.prog"
    if "$WORK/u.prog"; then
      ok_ "_Unwind_Backtrace walks a link-only binary ($uwlib)"
    else
      bad_ "_Unwind_Backtrace walks a link-only binary ($uwlib)" "exit $?"
    fi
  fi
else
  bad_ "compile u.o/um.o" "compilation failed"
fi

printf '  ---- %d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ]
