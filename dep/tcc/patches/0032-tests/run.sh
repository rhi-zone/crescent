#!/usr/bin/env bash
# Check that %rsp / %esp written in the SIB *index* slot is rejected, and that
# nothing else about index or base parsing moved.
# Usage: run.sh /path/to/tcc     (also passes against gcc: run.sh "$(command -v gcc)")
#
# SIB.index == 100b is the architectural "no index" code, so register 4 has no
# encoding as an index. `as' refuses the operand outright; tcc encoded it as
# the index-less form, which objdump reads back as `%riz' -- different code
# than was written, with no diagnostic:
#
#     mov (%rax,%rsp,4),%rbx   ->  48 8b 1c a0   mov (%rax,%riz,4),%rbx
#
# REX.X extends the index field upwards (%r12 is 12, and its low three bits
# reaching 100b is what REX.X is for), so nothing legitimate ever arrives at
# the parser as register 4 in this position. That is what makes the whole
# check `op->reg2 == 4'.
#
# ## What this harness does and does not pin
#
# It pins the *set of inputs refused*, against `as' as the reference, and the
# byte-for-byte encoding of everything still accepted. It deliberately does
# NOT pin the message text.
#
# `as' echoes the operand as written in the source, unevaluated: `2*4(...)'
# keeps its arithmetic, `(%rax,%RSP,4)' keeps its case, `%fs:' prefixes are
# included. By the time tcc knows the operand is invalid it has folded the
# arithmetic and dropped every one of those distinctions, and nothing in
# i386-asm.c echoes operand source text at all -- matching `as' literally
# would mean new source-span substrate, which has a hole of its own under
# `.macro'/`.rept' replay where there is no backing text to quote. Owner call
# (2026-08-22), recorded in TODO.md: diagnose in tcc's own idiom instead.
#
# So `bad' below asserts only what both assemblers say and what a user needs:
# assembly fails, the message names the offending register, and it says the
# problem is the index. tcc's sentence is
#
#     error: %rsp cannot be used as an index register
#
# and as's is "`(%rax,%rsp,4)' is not a valid base/index expression"; the two
# overlap on exactly those two words, which is why the whole script still
# passes unchanged against a real gcc and is a reference rather than this
# patch's own opinion.
#
# Needs `as`, `readelf` on PATH.
set -u
TCC="${1:?usage: run.sh /path/to/tcc}"

# All intermediates go to a temp directory, never next to the sources: this
# script lives under dep/tcc/, and tooling/scripts/vendor-verify.sh hashes the
# committed source tree with no gitignore awareness.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok_()  { printf '  PASS  %-52s %s\n' "$1" "${2-}"; pass=$((pass + 1)); }
bad_() { printf '  FAIL  %-52s %s\n' "$1" "${2-}"; fail=$((fail + 1)); }

one_line_() { printf '%s' "$1" | tr '\n' ' ' | cut -c1-64; }

# bad <label> <reg> <line>...
#   Assembly must FAIL, and the message must name <reg> and call out the index.
bad() {
  local label="$1" reg="$2"; shift 2
  local out rc
  printf '%s\n' "$@" > "$WORK/t.S"
  out="$("$TCC" -c "$WORK/t.S" -o "$WORK/t.o" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    bad_ "$label" "assembled; expected a diagnostic"
  elif ! printf '%s' "$out" | grep -qF "$reg"; then
    bad_ "$label" "message does not name $reg: $(one_line_ "$out")"
  elif ! printf '%s' "$out" | grep -qF "index"; then
    bad_ "$label" "message does not mention the index: $(one_line_ "$out")"
  else
    ok_ "$label" "rejected"
  fi
}

# refused <label> <line>...
#   Assembly must FAIL, for any stated reason. Used where tcc and `as' refuse
#   the same input on different grounds, so there is no shared wording to
#   match -- the claim is only that neither one quietly assembles it.
refused() {
  local label="$1"; shift
  local out rc
  printf '%s\n' "$@" > "$WORK/t.S"
  out="$("$TCC" -c "$WORK/t.S" -o "$WORK/t.o" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then bad_ "$label" "assembled; expected a diagnostic"
  else ok_ "$label" "refused: $(one_line_ "$out")"; fi
}

# Section contents plus relocations. `.text' only: these cases are pure
# addressing forms, and tcc's own section bookkeeping (an always-present empty
# `.data.ro', for one) differs from gas's for reasons unrelated to operands.
dump_() {
  readelf -x .text "$1" 2>/dev/null | tail -n +3 | grep -v '^ NOTE:'
  echo "== relocations"
  readelf -r -W "$1" 2>/dev/null \
    | awk '/^[0-9a-f]{6,}/ {print $1, $3, $5, $6, $7}' | sort
}

# parity <label> <line>...
#   Assembly must SUCCEED and produce byte-identical `.text' to real `as'.
#   This is the half that pins nothing legitimate got caught: every case here
#   either uses a real index register or uses %rsp/%esp as a *base*, which is
#   a different field and always valid.
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

echo "-- %rsp in the index slot, across the spellings of the operand"
bad 'base + index + scale 4'     rsp '.text' 'mov (%rax,%rsp,4),%rbx'
bad 'scale 1'                    rsp '.text' 'mov (%rax,%rsp,1),%rbx'
bad 'scale 2'                    rsp '.text' 'mov (%rax,%rsp,2),%rbx'
bad 'scale 8'                    rsp '.text' 'mov (%rax,%rsp,8),%rbx'
bad 'scale omitted'              rsp '.text' 'mov (%rax,%rsp),%rbx'
bad 'disp8'                      rsp '.text' 'mov 8(%rax,%rsp,2),%rbx'
bad 'disp32'                     rsp '.text' 'mov 4096(%rax,%rsp,2),%rbx'
bad 'negative disp'              rsp '.text' 'mov -16(%rax,%rsp,4),%rbx'
bad 'folded disp arithmetic'     rsp '.text' 'mov 2*4(%rax,%rsp,4),%rbx'
bad 'symbolic disp'              rsp '.text' 'foo:' 'mov foo+8(%rax,%rsp,4),%rbx'
bad 'no base'                    rsp '.text' 'mov (,%rsp,8),%rbx'
bad 'no base, scale omitted'     rsp '.text' 'mov (,%rsp),%rbx'
bad 'no base, with disp'         rsp '.text' 'mov 8(,%rsp,8),%rbx'
bad 'segment prefix'             rsp '.text' 'mov %fs:(%rax,%rsp,4),%rbx'
bad 'index is also the base'     rsp '.text' 'mov (%rsp,%rsp,4),%rbx'
bad 'odd whitespace'             rsp '.text' 'mov -16(  %rax , %rsp , 4 ),%rbx'

echo "-- and in every operand position an EA can occupy"
bad 'memory destination'         rsp '.text' 'mov %rbx,(%rax,%rsp,4)'
bad 'immediate group opcode'     rsp '.text' 'addq $1,(%rax,%rsp,8)'
bad 'lea'                        rsp '.text' 'lea (%rax,%rsp,1),%rbx'
bad 'indirect branch'            rsp '.text' 'jmp *(%rax,%rsp,8)'
bad 'legacy SSE'                 rsp '.text' 'movaps (%rax,%rsp,4),%xmm0'
bad 'VEX (0015 opcodes)'         rsp '.text' 'mulx (%rax,%rsp,4),%rbx,%rcx'
bad 'single-operand group'       rsp '.text' 'incq (%rax,%rsp,8)'

echo "-- 32-bit addressing (the 0x67 forms) is the same field"
bad '32-bit base + index'        esp '.text' 'mov (%eax,%esp,4),%ebx'
bad '32-bit, scale omitted'      esp '.text' 'mov (%eax,%esp),%ebx'
bad '32-bit, no base'            esp '.text' 'mov (,%esp,4),%ebx'
bad '32-bit lea'                 esp '.text' 'lea 4(%eax,%esp,2),%ebx'

echo "-- reached through macro replay, where there is no source line to quote"
bad 'inside .macro'              rsp '.text' '.macro M i' '	mov (%rax,\i,4),%rbx' '.endm' 'M %rsp'
bad 'inside .rept'               rsp '.text' '.rept 2' '	mov (%rax,%rsp,4),%rbx' '.endr'

echo "-- refused by both assemblers, on grounds each words its own way"
refused '%riz written out'       '.text' 'mov (%rax,%riz,4),%rbx'
refused '%r4, the numeric spelling of %rsp' '.text' 'mov (%rax,%r4,4),%rbx'

echo "-- real index registers still assemble, byte-identically to gas"
parity '%rax as index'           '.text' 'mov (%rbx,%rax,4),%rcx'
parity '%rbp as index'           '.text' 'mov (%rax,%rbp,8),%rbx'
parity '%r12 as index (REX.X, low bits 100b)' '.text' 'mov (%rax,%r12,4),%rbx'
parity '%r13 as index'           '.text' 'mov (%rax,%r13,2),%rbx'
parity '%r12 as index, no base'  '.text' 'mov (,%r12,4),%rbx'
parity '%r12 as both base and index' '.text' 'mov (%r12,%r12,8),%rbx'
parity '%ebp as 32-bit index'    '.text' 'mov (%eax,%ebp,4),%ebx'
parity '%eax as 32-bit index'    '.text' 'mov (%ebx,%eax,8),%ebx'

echo "-- %rsp / %esp as a BASE is a different field and stays valid"
parity '(%rsp)'                  '.text' 'mov (%rsp),%rbx'
parity '8(%rsp)'                 '.text' 'mov 8(%rsp),%rbx'
parity '(%rsp,%rax,4)'           '.text' 'mov (%rsp,%rax,4),%rbx'
parity '(%rsp,%rbp,8)'           '.text' 'mov (%rsp,%rbp,8),%rbx'
parity '(%rsp,%r12,1)'           '.text' 'mov (%rsp,%r12,1),%rbx'
parity 'lea 16(%rsp,%rcx,8)'     '.text' 'lea 16(%rsp,%rcx,8),%rdx'
parity 'SSE off %rsp'            '.text' 'movaps (%rsp,%rax,4),%xmm0'
parity 'push/pop still fine'     '.text' 'push %rbp' 'mov %rsp,%rbp' 'pop %rbp'
parity '(%esp)'                  '.text' 'mov (%esp),%ebx'
parity '(%esp,%eax,2)'           '.text' 'mov (%esp,%eax,2),%ebx'

echo "-- ordinary prologue/epilogue code, unchanged end to end"
parity 'a whole frame'           '.text' 'f:' '	push %rbp' '	mov %rsp,%rbp' \
                                 '	sub $32,%rsp' '	mov %rdi,-8(%rbp)' \
                                 '	mov -8(%rbp),%rax' '	mov (%rax,%rcx,8),%rdx' \
                                 '	mov %rdx,-16(%rsp)' '	leave' '	ret'

echo "-----"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
