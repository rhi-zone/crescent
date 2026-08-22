#!/usr/bin/env bash
# Check that suffix-less `bswap' accepts a 64-bit register, and that nothing
# else about bswap or its neighbours in the opcode table moved.
# Usage: run.sh /path/to/tcc     (also passes against gcc: run.sh "$(command -v gcc)")
#
# The x86_64 opcode table gave `bswap' only an OPT_REG32 form, alongside
# explicit `bswapl' and `bswapq'. So the suffix-less 64-bit spelling --
#
#     bswap %rax
#
# -- which GNU as assembles as `48 0f c8', was answered with
#
#     error: bad operand with opcode 'bswap'
#
# This is not a hypothetical spelling. luajit's lj_def.h defines lj_bswap64 as
#
#     __asm__("bswap %0" : "=r"(r) : "0"(x))
#
# on x86_64, and gcc substitutes a 64-bit register into `%0' there, so the
# operand reaches the assembler with no suffix and a `%r..' register. luajit
# did not compile under tcc until this was fixed, which is why the C rows at
# the bottom of this script are part of the harness and not decoration.
#
# ## What this harness does and does not pin
#
# It pins the *byte-for-byte encoding of everything accepted*, with `as' as
# the reference, and the *set of inputs refused*. It deliberately does NOT pin
# any message text, in either direction.
#
# For the accepted half there is nothing to argue about: an encoding either
# matches gas or it does not, and `parity' compares section bytes and
# relocations rather than any disassembly rendering.
#
# For the refused half the two assemblers agree on which inputs are invalid
# and disagree on every word used to say so -- `bswap %ax' is "operand size
# mismatch for `bswap'" in as and "bad operand with opcode 'bswap'" in tcc,
# and `bswapw %ax' is "invalid instruction suffix" in as against "unknown
# opcode 'bswapw'" in tcc, which is not even the same *kind* of complaint.
# Nothing in this patch touches diagnostics, so `refused' asserts only that
# neither assembler quietly emits something -- which is the property that
# matters, since a wrong encoding here is a silent miscompile and a wrong
# sentence is not. Matching as's wording would be a separate patch about
# messages, and this one is about a missing table entry.
#
# That is what lets the whole script pass unchanged against a real gcc
# (`./run.sh "$(command -v gcc)"'), making `as' the reference rather than this
# patch's own opinion.
#
# The comment above the entry in x86_64-asm.h says bswap cannot apply to
# 16-bit registers. That was measured rather than taken on trust: as and tcc
# both refuse `bswap %ax', `bswap %r8w' and `bswapw %ax', before and after
# this patch, and those rows are here to keep it that way.
#
# Needs `as`, `readelf` on PATH. The cases are an instruction or two each, so
# they are generated here rather than committed as near-identical .S files.
set -u
TCC="${1:?usage: run.sh /path/to/tcc}"
TCCDIR="$(cd "$(dirname "$TCC")" && pwd)"

# All intermediates go to a temp directory, never next to the sources: this
# script lives under dep/tcc/, and tooling/scripts/vendor-verify.sh hashes the
# committed source tree with no gitignore awareness.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok_()  { printf '  PASS  %-48s %s\n' "$1" "${2-}"; pass=$((pass + 1)); }
bad_() { printf '  FAIL  %-48s %s\n' "$1" "${2-}"; fail=$((fail + 1)); }

one_line_() { printf '%s' "$1" | tr '\n' ' ' | cut -c1-64; }

# Section contents plus relocations. `.text' only: every case here is a bare
# instruction sequence, and tcc's own section bookkeeping (an always-present
# empty `.data.ro', for one) differs from gas's for reasons unrelated to
# opcodes.
dump_() {
  readelf -x .text "$1" 2>/dev/null | tail -n +3 | grep -v '^ NOTE:'
  echo "== relocations"
  readelf -r -W "$1" 2>/dev/null \
    | awk '/^[0-9a-f]{6,}/ {print $1, $3, $5, $6, $7}' | sort
}

# parity <label> <line>...
#   Assembly must SUCCEED and produce byte-identical `.text' to real `as'.
#   This is the half that carries the claim: the new table entry encodes the
#   same instruction gas encodes, and the entries around it still encode what
#   they did.
parity() {
  local label="$1"; shift
  local out
  printf '%s\n' "$@" > "$WORK/t.S"
  if ! as -o "$WORK/t.gas.o" "$WORK/t.S" 2>"$WORK/t.gaserr"; then
    bad_ "$label" "gas rejects this case: $(one_line_ "$(cat "$WORK/t.gaserr")")"
    return
  fi
  out="$("$TCC" -c "$WORK/t.S" -o "$WORK/t.tcc.o" 2>&1)" || {
    bad_ "$label" "rejected, but is valid: $(one_line_ "$out")"; return; }
  dump_ "$WORK/t.gas.o" > "$WORK/t.gas.txt"
  dump_ "$WORK/t.tcc.o" > "$WORK/t.tcc.txt"
  if diff -q "$WORK/t.gas.txt" "$WORK/t.tcc.txt" >/dev/null; then
    ok_ "$label" "matches gas"
  else
    bad_ "$label" "bytes differ from gas"
    diff "$WORK/t.gas.txt" "$WORK/t.tcc.txt" | head -12 | sed 's/^/          /'
  fi
}

# refused <label> <line>...
#   Assembly must FAIL, for any stated reason, and `as' must refuse it too --
#   so a row cannot silently become a claim about tcc alone. No wording is
#   asserted; see the header for why.
refused() {
  local label="$1"; shift
  local out rc
  printf '%s\n' "$@" > "$WORK/t.S"
  if as -o "$WORK/t.gas.o" "$WORK/t.S" >/dev/null 2>&1; then
    bad_ "$label" "gas accepts this case; it is not an invalid input"
    return
  fi
  out="$("$TCC" -c "$WORK/t.S" -o "$WORK/t.o" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then bad_ "$label" "assembled; expected a diagnostic"
  else ok_ "$label" "refused: $(one_line_ "$out")"; fi
}

# crun <label> <c-source-line>...
#   Compile and RUN a C program whose inline asm reaches the same table entry.
#   The program returns 0 only when every byte-swap it performs is right, so
#   this pins the value computed, not merely that compilation succeeded.
#   -B<tccdir> so a tcc invoked from its build directory finds its own
#   libtcc1.a and headers; gcc reads the same flag as a harmless prefix.
crun() {
  local label="$1"; shift
  local out rc
  printf '%s\n' "$@" > "$WORK/t.c"
  out="$("$TCC" -B"$TCCDIR" -o "$WORK/t.exe" "$WORK/t.c" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    bad_ "$label" "compile failed: $(one_line_ "$out")"; return
  fi
  if "$WORK/t.exe"; then ok_ "$label" "compiles and computes the right bytes"
  else bad_ "$label" "ran, wrong answer (exit $?)"; fi
}

echo "-- the gap: suffix-less bswap on a 64-bit register, every GPR"
parity 'bswap %rax'          '.text' 'bswap %rax'
parity 'bswap %rcx'          '.text' 'bswap %rcx'
parity 'bswap %rdx'          '.text' 'bswap %rdx'
parity 'bswap %rbx'          '.text' 'bswap %rbx'
parity 'bswap %rsp'          '.text' 'bswap %rsp'
parity 'bswap %rbp'          '.text' 'bswap %rbp'
parity 'bswap %rsi'          '.text' 'bswap %rsi'
parity 'bswap %rdi'          '.text' 'bswap %rdi'

echo "-- and the extended half, where REX.B rides alongside REX.W"
parity 'bswap %r8'           '.text' 'bswap %r8'
parity 'bswap %r9'           '.text' 'bswap %r9'
parity 'bswap %r10'          '.text' 'bswap %r10'
parity 'bswap %r11'          '.text' 'bswap %r11'
parity 'bswap %r12'          '.text' 'bswap %r12'
parity 'bswap %r13'          '.text' 'bswap %r13'
parity 'bswap %r14'          '.text' 'bswap %r14'
parity 'bswap %r15'          '.text' 'bswap %r15'

echo "-- the 32-bit form the table already had, unregressed"
parity 'bswap %eax'          '.text' 'bswap %eax'
parity 'bswap %ecx'          '.text' 'bswap %ecx'
parity 'bswap %ebx'          '.text' 'bswap %ebx'
parity 'bswap %esp'          '.text' 'bswap %esp'
parity 'bswap %ebp'          '.text' 'bswap %ebp'
parity 'bswap %edi'          '.text' 'bswap %edi'
parity 'bswap %r8d'          '.text' 'bswap %r8d'
parity 'bswap %r12d'         '.text' 'bswap %r12d'
parity 'bswap %r15d'         '.text' 'bswap %r15d'

echo "-- the explicit suffixes, which the new ALT sits between"
parity 'bswapl %eax'         '.text' 'bswapl %eax'
parity 'bswapl %r13d'        '.text' 'bswapl %r13d'
parity 'bswapq %rbx'         '.text' 'bswapq %rbx'
parity 'bswapq %rax'         '.text' 'bswapq %rax'
parity 'bswapq %r13'         '.text' 'bswapq %r13'
parity 'bswapq %r12'         '.text' 'bswapq %r12'
parity 'suffixed and not, same encoding' '.text' 'bswap %rax' 'bswapq %rax' \
                             'bswap %eax' 'bswapl %eax'

echo "-- reached through macro replay, the same as any other operand"
parity 'inside .macro'       '.text' '.macro M r' '	bswap \r' '.endm' \
                             'M %rax' 'M %r12' 'M %eax'
parity 'inside .rept'        '.text' '.rept 3' '	bswap %rdx' '.endr'

echo "-- adding an ALT shifts the table; the 486 neighbours are unmoved"
parity 'xadd'                '.text' 'xadd %eax,%ebx'
parity 'xaddq to memory'     '.text' 'xaddq %rax,(%rbx)'
parity 'cmpxchg'             '.text' 'cmpxchg %rax,%rbx'
parity 'cmpxchg8b'           '.text' 'cmpxchg8b (%rax)'
parity 'cmpxchg16b'          '.text' 'cmpxchg16b (%rax)'
parity 'invlpg'              '.text' 'invlpg (%rax)'
# `str' is the ALT chain immediately above bswap in the table, so it is the
# one most likely to be disturbed by inserting an entry. Its 64-bit row is
# left out on purpose -- see "Deliberately absent" in the README: tcc and gas
# already disagree there, identically before and after this patch.
parity 'str, the ALT chain just above' '.text' 'str %ax' 'str %eax'
parity 'bsf/bsr/bt, the other bit ops' '.text' 'bsf %rax,%rbx' 'bsr %eax,%ebx' \
                             'bt $3,%rax'

echo "-- 16-bit and 8-bit stay refused by both, as the table comment claims"
refused 'bswap %ax'          '.text' 'bswap %ax'
refused 'bswap %bx'          '.text' 'bswap %bx'
refused 'bswap %r8w'         '.text' 'bswap %r8w'
refused 'bswapw %ax'         '.text' 'bswapw %ax'
refused 'bswapl %ax'         '.text' 'bswapl %ax'
refused 'bswapq %ax'         '.text' 'bswapq %ax'
refused 'bswap %al'          '.text' 'bswap %al'
refused 'bswap %r8b'         '.text' 'bswap %r8b'

echo "-- and so does everything that is not a plain GPR"
refused 'no operand'         '.text' 'bswap'
refused 'two operands'       '.text' 'bswap %rax,%rbx'
refused 'memory operand'     '.text' 'bswap (%rax)'
refused 'memory, suffixed'   '.text' 'bswapq (%rax)'
refused 'immediate'          '.text' 'bswap $1'
refused 'xmm register'       '.text' 'bswap %xmm0'
refused 'segment register'   '.text' 'bswap %fs'
refused 'control register'   '.text' 'bswap %cr0'

echo "-- the suffix must still agree with the register it was written for"
refused 'bswapq on a 32-bit reg' '.text' 'bswapq %eax'
refused 'bswapl on a 64-bit reg' '.text' 'bswapl %rax'

echo "-- the real-world trigger: inline asm from C, compiled and run"
crun 'luajit lj_bswap64, verbatim' \
  'static unsigned long long bswap64(unsigned long long x) {' \
  '  register unsigned long long r;' \
  '  __asm__("bswap %0" : "=r"(r) : "0"(x));' \
  '  return r;' \
  '}' \
  'int main(void) {' \
  '  if (bswap64(0x0123456789abcdefULL) != 0xefcdab8967452301ULL) return 1;' \
  '  if (bswap64(0ULL) != 0ULL) return 2;' \
  '  if (bswap64(0xffULL) != 0xff00000000000000ULL) return 3;' \
  '  if (bswap64(bswap64(0xdeadbeefcafef00dULL)) != 0xdeadbeefcafef00dULL) return 4;' \
  '  return 0;' \
  '}'

crun 'the 32-bit sibling, same source spelling' \
  'static unsigned int bswap32(unsigned int x) {' \
  '  register unsigned int r;' \
  '  __asm__("bswap %0" : "=r"(r) : "0"(x));' \
  '  return r;' \
  '}' \
  'int main(void) {' \
  '  if (bswap32(0x01234567u) != 0x67452301u) return 1;' \
  '  if (bswap32(0xffu) != 0xff000000u) return 2;' \
  '  if (bswap32(bswap32(0xcafef00du)) != 0xcafef00du) return 3;' \
  '  return 0;' \
  '}'

crun 'both widths in one translation unit' \
  'static unsigned long long b64(unsigned long long x) {' \
  '  register unsigned long long r;' \
  '  __asm__("bswap %0" : "=r"(r) : "0"(x)); return r; }' \
  'static unsigned int b32(unsigned int x) {' \
  '  register unsigned int r;' \
  '  __asm__("bswap %0" : "=r"(r) : "0"(x)); return r; }' \
  'int main(void) {' \
  '  unsigned long long v = 0x1122334455667788ULL;' \
  '  if (b64(v) != 0x8877665544332211ULL) return 1;' \
  '  if (b32((unsigned int)v) != 0x88776655u) return 2;' \
  '  return 0;' \
  '}'

crun 'explicit suffixes from C, unregressed' \
  'int main(void) {' \
  '  unsigned long long a = 0x0102030405060708ULL;' \
  '  unsigned int b = 0x01020304u;' \
  '  __asm__("bswapq %0" : "+r"(a));' \
  '  __asm__("bswapl %0" : "+r"(b));' \
  '  if (a != 0x0807060504030201ULL) return 1;' \
  '  if (b != 0x04030201u) return 2;' \
  '  return 0;' \
  '}'

crun 'run through a loop, so the value is not a constant fold' \
  'static unsigned long long b64(unsigned long long x) {' \
  '  register unsigned long long r;' \
  '  __asm__("bswap %0" : "=r"(r) : "0"(x)); return r; }' \
  'int main(void) {' \
  '  unsigned long long acc = 0, i;' \
  '  for (i = 0; i < 64; i++) {' \
  '    unsigned long long bit = 1ULL << i;' \
  '    if (b64(bit) != (1ULL << (((63 - i) & ~7u) | (i & 7u)))) return 1;' \
  '    acc += b64(bit);' \
  '  }' \
  '  return acc == 0xffffffffffffffffULL ? 0 : 2;' \
  '}'

echo "-----"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
