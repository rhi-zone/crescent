if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

-- x64 ABI register files for ra.allocate().
--
-- Two calling conventions:
--   sysv  — System V AMD64 ABI (Linux, macOS, BSDs)
--   win64 — Microsoft x64 ABI (Windows)
--
-- GPR pool order: caller-saved first, then callee-saved.
-- This lets ra.allocate prefer caller-saved registers and only touch
-- callee-saved ones when the cheaper ones are exhausted.
--
-- rbp and rsp are excluded from all allocation pools:
--   rsp — stack pointer, always reserved
--   rbp — frame pointer; RA must not touch it

local M = {}

-- Build ymm/zmm bidirectional aliases for xmm0–xmm15.
local function make_x64_aliases()
  local aliases = {} --: { [string]: string, ... }
  for i = 0, 15 do
    local xmm = "xmm" .. i
    local ymm = "ymm" .. i
    local zmm = "zmm" .. i
    -- ymm <-> xmm (bidirectional)
    aliases[ymm] = xmm
    aliases[xmm] = ymm
    -- zmm <-> ymm (bidirectional)
    -- ra.lua build_alias_pairs only handles one alias per key, so we chain:
    -- zmm blocks ymm (via alias), ymm blocks xmm (via alias).
    -- Store zmm->ymm; the caller can walk the chain if needed.
    aliases[zmm] = ymm
  end
  return aliases
end

local x64_aliases = make_x64_aliases()

-- ── System V AMD64 ABI ──────────────────────────────────────────────────────
--
-- Caller-saved GPR:  rax rcx rdx rsi rdi r8 r9 r10 r11
-- Callee-saved GPR:  rbx r12 r13 r14 r15  (rbp excluded — frame pointer)
-- Arg GPR:           rdi rsi rdx rcx r8 r9
-- Return GPR:        rax rdx
--
-- Caller-saved SIMD: xmm0–xmm15 (all)
-- Arg SIMD:          xmm0–xmm7
-- Return SIMD:       xmm0 xmm1

local sysv_callee_saved = {} --: { [string]: boolean, ... }
do
  -- Caller-saved GPR.
  for _, r in ipairs({ "rax","rcx","rdx","rsi","rdi","r8","r9","r10","r11" }) do
    sysv_callee_saved[r] = false
  end
  -- Callee-saved GPR.
  for _, r in ipairs({ "rbx","r12","r13","r14","r15" }) do
    sysv_callee_saved[r] = true
  end
  -- All SIMD are caller-saved under SysV.
  for i = 0, 15 do
    sysv_callee_saved["xmm" .. i] = false
  end
end

M.sysv = {
  -- Caller-saved first so RA prefers them; callee-saved appended at the end.
  gpr  = {
    "rax", "rcx", "rdx", "rsi", "rdi", "r8", "r9", "r10", "r11",
    "rbx", "r12", "r13", "r14", "r15",
  },
  simd = {
    "xmm0",  "xmm1",  "xmm2",  "xmm3",
    "xmm4",  "xmm5",  "xmm6",  "xmm7",
    "xmm8",  "xmm9",  "xmm10", "xmm11",
    "xmm12", "xmm13", "xmm14", "xmm15",
  },

  callee_saved = sysv_callee_saved,
  aliases      = x64_aliases,

  -- Calling convention metadata (used by emit/, not ra.lua).
  arg_gpr  = { "rdi", "rsi", "rdx", "rcx", "r8", "r9" },
  arg_simd = {
    "xmm0", "xmm1", "xmm2", "xmm3",
    "xmm4", "xmm5", "xmm6", "xmm7",
  },
  ret_gpr  = { "rax", "rdx" },
  ret_simd = { "xmm0", "xmm1" },
}

-- ── Microsoft x64 ABI ───────────────────────────────────────────────────────
--
-- Caller-saved GPR:  rax rcx rdx r8 r9 r10 r11
-- Callee-saved GPR:  rbx rdi rsi r12 r13 r14 r15  (rbp excluded — frame pointer)
-- Arg GPR:           rcx rdx r8 r9
-- Return GPR:        rax
--
-- Caller-saved SIMD: xmm0–xmm5
-- Callee-saved SIMD: xmm6–xmm15 (lower 128 bits; upper 128 bits of ymm6–ymm15 volatile)
-- Arg SIMD:          xmm0–xmm3
-- Return SIMD:       xmm0

local win64_callee_saved = {} --: { [string]: boolean, ... }
do
  -- Caller-saved GPR.
  for _, r in ipairs({ "rax", "rcx", "rdx", "r8", "r9", "r10", "r11" }) do
    win64_callee_saved[r] = false
  end
  -- Callee-saved GPR (rdi and rsi are callee-saved under Win64, unlike SysV).
  for _, r in ipairs({ "rbx", "rdi", "rsi", "r12", "r13", "r14", "r15" }) do
    win64_callee_saved[r] = true
  end
  for i = 0, 5  do win64_callee_saved["xmm" .. i] = false end
  for i = 6, 15 do win64_callee_saved["xmm" .. i] = true  end
end

M.win64 = {
  -- Caller-saved first (rax,rcx,rdx,r8-r11), then callee-saved.
  -- rdi and rsi are callee-saved under Win64 (unlike SysV).
  gpr  = {
    "rax", "rcx", "rdx", "r8",  "r9",  "r10", "r11",
    "rbx", "rdi", "rsi", "r12", "r13", "r14", "r15",
  },
  simd = {
    "xmm0",  "xmm1",  "xmm2",  "xmm3",
    "xmm4",  "xmm5",  "xmm6",  "xmm7",
    "xmm8",  "xmm9",  "xmm10", "xmm11",
    "xmm12", "xmm13", "xmm14", "xmm15",
  },

  callee_saved = win64_callee_saved,
  aliases      = x64_aliases,

  arg_gpr  = { "rcx", "rdx", "r8", "r9" },
  arg_simd = { "xmm0", "xmm1", "xmm2", "xmm3" },
  ret_gpr  = { "rax" },
  ret_simd = { "xmm0" },
}

return M
