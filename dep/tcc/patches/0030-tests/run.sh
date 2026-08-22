#!/usr/bin/env bash
# Check that a malformed ELF object file produces a diagnostic and a non-zero
# exit, never a signal and never an unbounded allocation.
# Usage: run.sh /path/to/tcc
#
# Unlike most harnesses here there is no `gcc'/`as' reference to run this
# against: GNU ld's wording for these inputs is its own, and matching it is
# not the point. What is pinned is weaker and more absolute -- for every
# malformation below, tcc must (a) not die of a signal, (b) exit non-zero,
# and (c) say something. The specific phrases are checked as well, so that a
# future change cannot satisfy (a)-(c) by accident with an unrelated error
# from somewhere else in the link.
#
# Every case takes an object tcc has just produced and pokes one field, so
# each differs from a working link in exactly one way. The controls at the
# end are load-bearing: the cheapest way to pass a test like this is to start
# rejecting everything, and two of the checks 0030 adds (sh_addralign, and
# the relocation offset bound) sit on paths that every legitimate object also
# takes.
#
# Needs `readelf` and `dd` on PATH.
set -u
TCC="${1:?usage: run.sh /path/to/tcc}"
TCCDIR="$(cd "$(dirname "$TCC")" && pwd)"

# All intermediates go to a temp directory, never next to the sources: this
# script lives under dep/tcc/, and tooling/scripts/vendor-verify.sh hashes the
# committed source tree.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok_()  { printf '  PASS  %-44s %s\n' "$1" "${2-}"; pass=$((pass + 1)); }
bad_() { printf '  FAIL  %-44s %s\n' "$1" "${2-}"; fail=$((fail + 1)); }

cat > "$WORK/lib.c" <<'EOF'
int gv = 7;
static int sv = 3;
const char *msg = "hello";
extern int helper(int);
int f(int x) { return helper(x) + gv + sv; }
EOF
cat > "$WORK/main.c" <<'EOF'
extern int f(int);
int helper(int x) { return x * 2; }
int main(void) { return f(3) == 16 ? 0 : 1; }
EOF

if ! "$TCC" -B"$TCCDIR" -c "$WORK/lib.c" -o "$WORK/good.o" 2>"$WORK/err"; then
  echo "cannot build the object this harness mangles:"; cat "$WORK/err"; exit 1
fi

# ELF64 field offsets. Only ELF64 little-endian is covered, which is what the
# job that runs these harnesses builds (see build-vendored.yml).
E_SHOFF=40; E_SHNUM=60; E_SHSTRNDX=62
SH_NAME=0; SH_OFFSET=24; SH_SIZE=32; SH_LINK=40; SH_ADDRALIGN=48
SHENT=64
EHDR_SIZE=64

# Section header table geometry, read back rather than assumed: the patch
# stack has changed tcc's section list before now.
hfield() { readelf -h -W "$WORK/good.o" | sed -n "s/.*$1: *\([0-9]*\).*/\1/p"; }
SHOFF="$(hfield 'Start of section headers')"
SHNUM="$(hfield 'Number of section headers')"
SHSTRNDX="$(hfield 'Section header string table index')"
if [ -z "$SHOFF" ] || [ -z "$SHNUM" ] || [ -z "$SHSTRNDX" ]; then
  echo "could not read the section header table geometry (readelf on PATH?)"; exit 1
fi

# One readelf -S listing, reused. With the bracketed index folded into the
# first field the columns are: 1 index, 2 name, 3 type, 4 address, 5 file
# offset, 6 size -- offset and size in hex. Flag letters appear after the
# entry size, so these six positions do not shift from section to section.
readelf -S -W "$WORK/good.o" | sed 's/^ *\[ *\([0-9]*\)\] */\1 /' > "$WORK/secs"
secnum()  { awk -v n="$1" '$2 == n { print $1; exit }' "$WORK/secs"; }
secoff()  { awk -v n="$1" '$2 == n { print $5; exit }' "$WORK/secs"; }
secsize() { awk -v n="$1" '$2 == n { print $6; exit }' "$WORK/secs"; }
shfield() { echo $(( SHOFF + $1 * SHENT + $2 )); }

# poke <file> <byte-offset> <width> <hex-value> -- little-endian store.
poke() {
  local f="$1" off="$2" w="$3" v="$4" i byte s=''
  for ((i = 0; i < w; i++)); do
    byte=$(( (0x$v >> (8 * i)) & 0xff ))
    s="$s\\x$(printf '%02x' "$byte")"
  done
  printf '%b' "$s" | dd of="$f" bs=1 seek="$off" conv=notrunc status=none
}

fresh() { cp "$WORK/good.o" "$WORK/bad.o"; }

# reject <label> <phrase> -- link bad.o and require a clean diagnostic.
reject() {
  local label="$1" phrase="$2" out rc
  out="$("$TCC" -B"$TCCDIR" -o "$WORK/out" "$WORK/main.c" "$WORK/bad.o" 2>&1)"; rc=$?
  # bash reports a killed child as 128+signal. That is the whole point of
  # this harness, so it is checked before anything about the message.
  if [ "$rc" -gt 128 ] && [ "$rc" -lt 160 ]; then
    bad_ "$label" "killed by signal $((rc - 128))"; return
  fi
  if [ "$rc" -eq 0 ]; then
    bad_ "$label" "link succeeded on a malformed object"; return
  fi
  if printf '%s' "$out" | grep -qF "$phrase"; then
    ok_ "$label" "rc=$rc"
  else
    bad_ "$label" "wanted \"$phrase\", got: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-80)"
  fi
}

# accept <label> -- link and run; the program returns 0 when f(3) == 16.
accept() {
  local label="$1" out rc
  out="$("$TCC" -B"$TCCDIR" -o "$WORK/out" "$WORK/main.c" "$WORK/bad.o" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    bad_ "$label" "link failed: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-80)"; return
  fi
  if "$WORK/out"; then ok_ "$label" "links and runs"; else bad_ "$label" "ran, wrong answer"; fi
}

EOF_="unexpected end of file"
NOTOBJ="unrecognized file type"
NAME_OFF="invalid section name offset"
NAME_TAB="invalid section name table"
SYM_OFF="invalid symbol name offset"
SHIDX="invalid section header index"
ALIGN="invalid section alignment"
RELOFF="relocation offset out of range"

echo "== malformed object files are diagnosed, not crashed on ($TCC)"

echo "-- truncation: the file stops before the parser is done with it"
SIZE="$(wc -c < "$WORK/good.o")"
# The boundary is the 64-byte ELF header, and it is worth being explicit
# about rather than picking percentages that might straddle it: below 64
# bytes tcc_object_type() cannot tell the file is an object at all and the
# file-type error is the correct answer; from 64 bytes up it is an object
# whose section headers are missing, which is 0030's error.
for n in "$(( SIZE * 9 / 10 ))" "$(( SIZE / 2 ))" "$(( SIZE / 4 ))" 200 65 64; do
  head -c "$n" "$WORK/good.o" > "$WORK/bad.o"
  reject "truncated to $n bytes" "$EOF_"
done
for n in 63 32 1; do
  head -c "$n" "$WORK/good.o" > "$WORK/bad.o"
  reject "truncated to $n bytes (below the header)" "$NOTOBJ"
done
# A zero-byte file is deliberately not a case here. tcc treats it as an empty
# linker script and accepts it silently, which is behaviour that predates
# 0030 and belongs to the file-type dispatch in libtcc.c, not to the object
# reader -- pinning it here would be pinning something this patch neither
# caused nor changed.

echo "-- a section header table that cannot be where the header says"
fresh; poke "$WORK/bad.o" "$E_SHOFF" 8 "7fffff00"; reject "e_shoff past the end"  "$EOF_"
fresh; poke "$WORK/bad.o" "$E_SHNUM" 2 "ff00";     reject "e_shnum far too large" "$EOF_"

echo "-- e_shstrndx: the section name table has to exist to be read"
fresh; poke "$WORK/bad.o" "$E_SHSTRNDX" 2 "$(printf '%x' $((SHNUM + 100)))"
reject "e_shstrndx past e_shnum" "$SHIDX"
fresh; poke "$WORK/bad.o" "$E_SHSTRNDX" 2 "0"
reject "e_shstrndx is the null section" "$SHIDX"

echo "-- sh_name: the offset a section's name is read from"
fresh; poke "$WORK/bad.o" "$(shfield 1 $SH_NAME)" 4 "7fffff00"
reject "sh_name far past .shstrtab" "$NAME_OFF"
# One past the end is the interesting boundary: the offset is still small, so
# only a comparison against the table's size catches it.
fresh; poke "$WORK/bad.o" "$(shfield 1 $SH_NAME)" 4 "$(secsize .shstrtab)"
# (secsize returns hex, which is what poke wants.)
reject "sh_name one past .shstrtab" "$NAME_OFF"

echo "-- .shstrtab itself: a name inside it must still end inside it"
fresh; poke "$WORK/bad.o" "$(shfield "$SHSTRNDX" $SH_SIZE)" 8 "1"
reject ".shstrtab shrunk to one byte" "$NAME_OFF"
fresh; poke "$WORK/bad.o" "$(shfield "$SHSTRNDX" $SH_SIZE)" 8 "0"
reject ".shstrtab shrunk to nothing" "$NAME_TAB"

echo "-- section contents that do not fit in the file"
TEXT="$(secnum .text)"
fresh; poke "$WORK/bad.o" "$(shfield "$TEXT" $SH_OFFSET)" 8 "7fffff00"
reject ".text sh_offset past the end" "$EOF_"
fresh; poke "$WORK/bad.o" "$(shfield "$TEXT" $SH_SIZE)" 8 "7fffff00"
reject ".text sh_size past the end" "$EOF_"

echo "-- sh_link / sh_info: section numbers that name no section"
SYMTAB="$(secnum .symtab)"
fresh; poke "$WORK/bad.o" "$(shfield "$SYMTAB" $SH_LINK)" 4 "$(printf '%x' $((SHNUM + 100)))"
reject ".symtab sh_link past e_shnum" "$SHIDX"
fresh; poke "$WORK/bad.o" "$(shfield "$SYMTAB" $SH_LINK)" 4 "0"
reject ".symtab sh_link is the null section" "$SHIDX"
fresh; poke "$WORK/bad.o" "$(shfield "$TEXT" $SH_LINK)" 4 "$(printf '%x' $((SHNUM + 100)))"
reject ".text sh_link past e_shnum" "$SHIDX"

echo "-- sh_addralign: ELF says 0 or a power of two, and section_add() agrees"
# Left unchecked this is not a wild read but an allocation: section_add()
# rounds the section's offset up to the alignment and grows the buffer to
# match. What that costs depends on the section and the value -- the case
# that surfaced it was a fuzz input with 0xffff00000008 on .data.ro, which
# hung the link with no output and no end; the same value on .text below
# merely linked, silently and wrongly, on an unpatched tcc. So
# what these two cases pin is the rejection, not any one symptom.
# A power of two can still be absurdly large; that residual is open in
# TODO.md, because the bound on it is a policy call ELF does not state.
fresh; poke "$WORK/bad.o" "$(shfield "$TEXT" $SH_ADDRALIGN)" 8 "ffff00000008"
reject "sh_addralign not a power of two" "$ALIGN"
fresh; poke "$WORK/bad.o" "$(shfield "$TEXT" $SH_ADDRALIGN)" 8 "3"
reject "sh_addralign = 3" "$ALIGN"

echo "-- symbols: st_name is an offset into .strtab, bounded by nothing"
STRTAB="$(secnum .strtab)"
fresh; poke "$WORK/bad.o" "$(shfield "$STRTAB" $SH_SIZE)" 8 "1"
reject ".strtab shrunk to one byte" "$SYM_OFF"

echo "-- relocations: r_offset says where in the target section to patch"
if [ -n "$(secnum .rela.text)" ]; then
  # r_offset is the first field of the first Elf64_Rela in .rela.text.
  fresh; poke "$WORK/bad.o" "$(( 0x$(secoff .rela.text) ))" 8 "7fffff00"
  reject "r_offset past the end of .text" "$RELOFF"
else
  bad_ "r_offset past the end of .text" "no .rela.text in the built object"
fi

echo "-- controls: nothing legitimate was rejected along the way"
fresh; accept "the unmodified object"
fresh; poke "$WORK/bad.o" "$(shfield "$TEXT" $SH_ADDRALIGN)" 8 "0"
accept "sh_addralign = 0 (no constraint)"
fresh; poke "$WORK/bad.o" "$(shfield "$TEXT" $SH_ADDRALIGN)" 8 "10"
accept "sh_addralign = 16"

echo "----- pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
