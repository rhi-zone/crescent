#!/usr/bin/env bash
# Verify dep/libressl/crypto/bn/arch/amd64/att/*.S under the patched vendored
# tcc, against GNU as as ground truth.
#
# This answers a different question from the 84/84 byte-identity check
# described in docs/native-tiers.md. That one asks "did attrofy.sed translate
# faithfully", and compares two objects both produced by GNU as, where raw
# byte identity is the right bar. This one asks "does tcc's own assembler
# emit the same program", where byte identity is the WRONG bar: tcc does not
# always pick the shortest encoding, and it defers same-section forward
# branches to relocations rather than resolving them. Both change the bytes
# without changing the program.
#
# So the comparison is on the instruction stream: mnemonics, operand values
# (registers, immediates, memory base/index/scale/displacement), branch
# destinations, and relocations against symbols the object does not define.
#
# Three things are deliberately normalized away, each with a reason:
#
#  1. Addresses. A single longer encoding shifts every later address, so
#     instructions are identified by POSITION (index) and addresses are never
#     compared directly.
#  2. objdump's guessed labels. objdump annotates a jump target with the
#     nearest PRECEDING symbol it can find. tcc emits a sparser local symbol
#     table than gas, so the same target address gets a different guessed
#     `<name+off>` in each -- a display artifact, and the specific thing that
#     produced a false "these differ" report in an earlier investigation.
#     All `<...>` annotations are dropped; targets are resolved through the
#     real ELF symbol table instead.
#  3. Branch form. gas resolves a same-section branch itself (bare
#     displacement, no relocation); tcc emits rel32 plus R_X86_64_PLT32
#     against the local label. Both name the same destination, so both are
#     reduced to "branch to instruction index N". The form difference is
#     still reported, separately, on FORM lines -- normalized for comparison,
#     not hidden.
#
# Usage: verify-bignum-att-tcc.sh /path/to/patched/tcc
# Build that tcc from dep/tcc/ with dep/tcc/patches/*.patch applied in numeric
# order (`git apply` from the repo root).

set -u
TCC="${1:?usage: verify-bignum-att-tcc.sh /path/to/tcc}"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$REPO/dep/libressl/crypto/bn/arch/amd64/att"
INC="$REPO/dep/libressl/crypto/bn"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/norm.awk" <<'AWK'
BEGIN {
  while ((getline l < SYMS) > 0) {
    # readelf -sW rows are indented; strip that before splitting or every
    # column lands one off and the map silently comes out empty.
    gsub(/^[ \t]+/, "", l)
    if (split(l, s, /[ \t]+/) < 8) continue      # "idx:" value size type bind vis ndx name
    if (s[2] !~ /^[0-9a-f]+$/) continue
    if (s[7] != TEXTNDX) continue
    v = s[2]; sub(/^0+/, "", v); if (v == "") v = "0"
    symaddr[s[8]] = "0x" v
  }
  close(SYMS)
}
# The disassembly is passed twice: first traversal numbers instructions,
# second emits.
{ P = (NR == FNR) ? 1 : 2 }
/file format/ || /Disassembly of section/ || /^$/ { next }
/^[0-9a-f]+ <.*>:$/ { next }                     # symbol lines: compared separately
# A relocation line shares the leading `<hex>:` shape of an instruction line,
# so it must be excluded here or it is counted as an instruction and shifts
# every later index.
/^[ \t]*[0-9a-f]+:[ \t]/ && !/R_X86_64/ {
  line = $0; sub(/[ \t]*#.*$/, "", line)
  match(line, /^[ \t]*[0-9a-f]+:/)
  addr = substr(line, RSTART, RLENGTH - 1); gsub(/[ \t]/, "", addr)
  if (P == 1) { addr2idx["0x" addr] = n; n++; next }
  rest = substr(line, RSTART + RLENGTH)
  gsub(/^[ \t]+|[ \t]+$/, "", rest); gsub(/[ \t]+/, " ", rest)
  i = index(rest, " ")
  if (i == 0) { mn = rest; ops = "" } else { mn = substr(rest, 1, i-1); ops = substr(rest, i+1) }
  sub(/[ \t]*<[^>]*>[ \t]*$/, "", ops); gsub(/^[ \t]+|[ \t]+$/, "", ops)
  flush()
  cur = addr2idx["0x" addr]
  if (mn ~ /^(j[a-z]+|call|loop[a-z]*)$/ && ops ~ /^[0-9a-f]+$/) {
    # Assembler-resolved branch. Hold one line, in case a relocation follows
    # (tcc's deferred form of the same branch).
    pendbranch = 1; brcur = cur; brmn = mn; brops = ops
  } else printf "i%d %s %s\n", cur, mn, ops
  next
}
function flush(   key) {
  if (!pendbranch) return
  key = "0x" brops
  if (key in addr2idx) printf "i%d %s @i%d\n", brcur, brmn, addr2idx[key]
  else                 printf "i%d %s @OUTSIDE:%s\n", brcur, brmn, key
  printf "  FORM i%d %s resolved-by-assembler\n", brcur, brmn
  pendbranch = 0
}
# objdump -dr prints each relocation directly after the instruction it patches.
/R_X86_64/ {
  if (P == 1) next
  line = $0; gsub(/^[ \t]+/, "", line); split(line, f, /[ \t]+/)
  typ = f[2]; sym = f[3]; add = ""
  if (match(sym, /[-+]0x[0-9a-f]+$/)) { add = substr(sym, RSTART); sym = substr(sym, 1, RSTART-1) }
  if (pendbranch && (sym in symaddr) && (symaddr[sym] in addr2idx) && add == "-0x4") {
    printf "i%d %s @i%d\n", brcur, brmn, addr2idx[symaddr[sym]]
    printf "  FORM i%d %s deferred-to-linker-as-%s-against-local-%s\n", brcur, brmn, typ, sym
    pendbranch = 0; next
  }
  flush()
  printf "  RELOC in=i%d type=%s sym=%s%s\n", cur, typ, sym, add
  next
}
{ if (P == 2) print "UNPARSED: " $0 }
END { if (P == 2) flush() }
AWK

norm() { # norm <obj> <out>
  local obj="$1" out="$2" ndx
  ndx=$(readelf -SW "$obj" | sed -n 's/.*\[ *\([0-9]*\)\] \.text .*/\1/p' | head -1)
  readelf -sW "$obj" > "$obj.syms"
  objdump -d -r --no-show-raw-insn "$obj" > "$obj.dis"
  awk -v SYMS="$obj.syms" -v TEXTNDX="$ndx" -f "$WORK/norm.awk" "$obj.dis" "$obj.dis" > "$out"
}

equal=0; differ=0; rejected=0; noref=0
for cfg in "" "-DWINDOWS_ABI=1" "-DNO_IBT=1" "-DS2N_BN_HIDE_SYMBOLS=1"; do
  echo "== config ${cfg:-<default>}"
  for f in "$SRC"/*.S; do
    b="$(basename "$f" .S)"
    if ! gcc -c -x assembler-with-cpp $cfg -I"$INC" -o "$WORK/$b.g.o" "$f" 2>/dev/null; then
      printf "  %-22s GAS-REJECTS (no reference to compare against)\n" "$b"
      noref=$((noref+1)); continue
    fi
    if ! "$TCC" -c $cfg -I"$INC" -o "$WORK/$b.t.o" "$f" 2>"$WORK/$b.err"; then
      printf "  %-22s TCC-REJECTS: %s\n" "$b" "$(sed 's/.*error: //' "$WORK/$b.err" | head -1)"
      rejected=$((rejected+1)); continue
    fi
    norm "$WORK/$b.g.o" "$WORK/$b.g.n"; norm "$WORK/$b.t.o" "$WORK/$b.t.n"
    grep -v '^  FORM' "$WORK/$b.g.n" > "$WORK/$b.g.s"
    grep -v '^  FORM' "$WORK/$b.t.n" > "$WORK/$b.t.s"
    # Global symbols must match exactly; tcc's extra local symbols (and its
    # FILE symbol) are not a semantic difference and are not compared.
    readelf -sW "$WORK/$b.g.o" | awk '$5=="GLOBAL"||$5=="WEAK"{print $2,$4,$5,$6,$8}' | sort > "$WORK/$b.g.gs"
    readelf -sW "$WORK/$b.t.o" | awk '$5=="GLOBAL"||$5=="WEAK"{print $2,$4,$5,$6,$8}' | sort > "$WORK/$b.t.gs"
    sym=$(diff -q "$WORK/$b.g.gs" "$WORK/$b.t.gs" >/dev/null && echo "globals-match" || echo "GLOBALS-DIFFER")
    forms=$(diff -q <(grep '^  FORM' "$WORK/$b.g.n" | sed 's/ i[0-9]*//' | sort) \
                    <(grep '^  FORM' "$WORK/$b.t.n" | sed 's/ i[0-9]*//' | sort) >/dev/null \
              && echo "same-branch-forms" || echo "branch-forms-differ")
    ni=$(grep -c '^i' "$WORK/$b.g.s")
    if diff -q "$WORK/$b.g.s" "$WORK/$b.t.s" >/dev/null && [ "$sym" = "globals-match" ]; then
      printf "  %-22s EQUAL   (%4s insns) %s %s\n" "$b" "$ni" "$sym" "$forms"
      equal=$((equal+1))
    else
      printf "  %-22s DIFFERS (%4s insns) %s %s\n" "$b" "$ni" "$sym" "$forms"
      diff "$WORK/$b.g.s" "$WORK/$b.t.s" | head -20 | sed 's/^/        /'
      differ=$((differ+1))
    fi
  done
done
echo "-----"
echo "equal=$equal differs=$differ tcc-rejects=$rejected no-reference=$noref"

# A disassembly comparison cannot observe what the LINKER does with tcc's
# deferred branches (rel32 + R_X86_64_PLT32 against a local label). So: link
# both assemblers' objects into one program -- tcc's with every symbol renamed
# `T_` so both copies of each routine coexist -- and call them side by side on
# identical inputs. Default config only: -DWINDOWS_ABI=1 changes the calling
# convention, so those objects cannot be called from this ABI.
echo "== runtime differential (default config, gas vs tcc, same process)"
RT="$(dirname "$0")/verify-bignum-att-tcc-runtime.c"
FILES="bignum_add bignum_sub bignum_cmadd bignum_cmul bignum_modadd bignum_modsub
       bignum_mul bignum_sqr bignum_mul_4_8_alt bignum_mul_6_12_alt bignum_mul_8_16_alt
       bignum_sqr_4_8_alt bignum_sqr_6_12_alt bignum_sqr_8_16_alt word_clz"
rtok=1
for b in $FILES; do
  gcc -c -x assembler-with-cpp -I"$INC" -o "$WORK/rt_$b.g.o" "$SRC/$b.S" 2>/dev/null || rtok=0
  "$TCC" -c -I"$INC" -o "$WORK/rt_$b.t.o" "$SRC/$b.S" 2>/dev/null || rtok=0
  objcopy --prefix-symbols=T_ "$WORK/rt_$b.t.o" "$WORK/rt_$b.p.o" 2>/dev/null || rtok=0
done
if [ "$rtok" = 1 ] && gcc -O1 -o "$WORK/rt" "$RT" \
     $(for b in $FILES; do echo "$WORK/rt_$b.g.o"; done) \
     $(for b in $FILES; do echo "$WORK/rt_$b.p.o"; done) 2>/dev/null; then
  "$WORK/rt" | sed 's/^/  /' || { echo "  runtime differential FAILED"; differ=$((differ+1)); }
else
  echo "  runtime differential could not be built"; differ=$((differ+1))
fi

# tcc emits no `.note.GNU-stack` section in its object output, which makes
# GNU ld mark the linked program's stack executable. Reported, not silently
# tolerated -- see TODO.md.
echo "== .note.GNU-stack in object output"
g=$(readelf -SW "$WORK/rt_word_clz.g.o" 2>/dev/null | grep -c 'GNU-stack')
t=$(readelf -SW "$WORK/rt_word_clz.t.o" 2>/dev/null | grep -c 'GNU-stack')
echo "  gas=$g tcc=$t (tcc=0 means GNU ld marks the stack executable; tcc-wide, not specific to these files)"

[ "$differ" -eq 0 ]
