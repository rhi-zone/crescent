if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

-- x86-64 machine code emitter.
-- Takes a finalized IR descriptor (ir.finalize()) and an RA result
-- (ra.allocate()) and emits x86-64 machine code bytes into mmap'd executable
-- memory, returning a callable FFI function pointer.
--
-- emit.compile(desc, alloc, abi, ctype) -> fn | (nil, errmsg)
--   desc:  result of ir.finalize()
--   alloc: result of ra.allocate(desc.intervals, regfile)
--   abi:   require("lib.asm.abi.x64").sysv or .win64
--   ctype: FFI ctype string, e.g. "void(*)(float*,float*,float*,int)"

local ffi = require("ffi")

--:: require "lib.asm.ir"
--:: require "lib.asm.ra"
--:: ABI = { arg_gpr: { [integer]: string, ... }, arg_simd: { [integer]: string, ... }, ret_gpr: { [integer]: string, ... }, ret_simd: { [integer]: string, ... }, ... }

local M = {}

-- ---------------------------------------------------------------------------
-- OS detection and mmap constants
-- ---------------------------------------------------------------------------

local IS_OSX = jit and jit.os == "OSX"

ffi.cdef[[
  void* mmap(void* addr, size_t length, int prot, int flags, int fd, long offset);
  int   munmap(void* addr, size_t length);
  int   mprotect(void* addr, size_t len, int prot);
]]

local PROT_READ    = 1
local PROT_WRITE   = 2
local PROT_EXEC    = 4
local MAP_PRIVATE  = 0x02
local MAP_ANON     = IS_OSX and 0x1000 or 0x20

-- ---------------------------------------------------------------------------
-- Byte buffer helpers
-- ---------------------------------------------------------------------------

local function buf_new()
  return {}
end

local function emit_byte(buf, b)
  buf[#buf + 1] = b
end

local function emit_bytes(buf, ...)
  local args = { ... }
  for i = 1, #args do
    buf[#buf + 1] = args[i]
  end
end

local function emit_u32le(buf, n)
  -- n is treated as unsigned 32-bit; handle negative (signed) values.
  local v = n % 0x100000000
  buf[#buf + 1] = v % 256; v = math.floor(v / 256)
  buf[#buf + 1] = v % 256; v = math.floor(v / 256)
  buf[#buf + 1] = v % 256; v = math.floor(v / 256)
  buf[#buf + 1] = v % 256
end

-- Emit a signed 8-bit value (clamped to i8 range).
local function emit_i8(buf, n)
  if n < 0 then n = n + 256 end
  buf[#buf + 1] = n % 256
end

local function buf_len(buf)
  return #buf
end

-- Convert buffer to a binary string.
local function buf_to_string(buf)
  local t = {}
  for i = 1, #buf do
    t[i] = string.char(buf[i])
  end
  return table.concat(t)
end

-- ---------------------------------------------------------------------------
-- Register numbering
-- ---------------------------------------------------------------------------

-- GPR name → number (0–15).
local GPR_NUM = {} --: { [string]: integer, ... }
for i, name in ipairs({"rax","rcx","rdx","rbx","rsp","rbp","rsi","rdi","r8","r9","r10","r11","r12","r13","r14","r15"}) do
  GPR_NUM[name] = i - 1
end

-- SIMD name → number (0–15).  xmm and ymm share numbers.
local SIMD_NUM = {} --: { [string]: integer, ... }
for i = 0, 15 do
  SIMD_NUM["xmm" .. i] = i
  SIMD_NUM["ymm" .. i] = i
end

--: (string) -> integer
local function gpr_num(name)
  local v = GPR_NUM[name]
  return v or error("unknown GPR: " .. tostring(name))
end

--: (string) -> integer
local function simd_num(name)
  local v = SIMD_NUM[name]
  return v or error("unknown SIMD reg: " .. tostring(name))
end

-- ---------------------------------------------------------------------------
-- REX prefix
-- ---------------------------------------------------------------------------

-- Emit REX prefix.  W=1 for 64-bit operand size.
-- R: high bit of ModRM.reg (r8-r15 in that field)
-- X: high bit of SIB.index
-- B: high bit of ModRM.rm or SIB.base
local function rex(buf, W, R, X, B)
  local byte = 0x40
  if W ~= 0 then byte = byte + 0x08 end
  if R ~= 0 then byte = byte + 0x04 end
  if X ~= 0 then byte = byte + 0x02 end
  if B ~= 0 then byte = byte + 0x01 end
  buf[#buf + 1] = byte
end

-- ---------------------------------------------------------------------------
-- VEX prefix (always 3-byte form for simplicity)
-- ---------------------------------------------------------------------------

-- R, X, B are the high bits of dest/index/rm register numbers (0 or 1).
-- mmmmm: 0b00001=0F, 0b00010=0F38, 0b00011=0F3A
-- W: 0 for float, 1 for 64-bit int
-- vvvv: NDS register number (full 4-bit)
-- L: 0=XMM, 1=YMM
-- pp: 0=none, 1=0x66, 2=0xF3, 3=0xF2
local function vex3(buf, R, X, B, mmmmm, W, vvvv, L, pp)
  buf[#buf + 1] = 0xC4
  -- Byte 1: ~R ~X ~B mmmmm  (bits 7..5 are inverted R, X, B)
  local b1 = 0
  if R == 0 then b1 = b1 + 0x80 end
  if X == 0 then b1 = b1 + 0x40 end
  if B == 0 then b1 = b1 + 0x20 end
  b1 = b1 + (mmmmm % 32)
  buf[#buf + 1] = b1
  -- Byte 2: W ~vvvv L pp
  local b2 = 0
  if W ~= 0 then b2 = b2 + 0x80 end
  -- vvvv is inverted (4 bits): ~vvvv & 0xF = 15 - (vvvv % 16) for vvvv in 0..15.
  b2 = b2 + ((15 - (vvvv % 16)) * 8)
  if L ~= 0 then b2 = b2 + 0x04 end
  b2 = b2 + (pp % 4)
  buf[#buf + 1] = b2
end

-- ---------------------------------------------------------------------------
-- ModRM byte
-- ---------------------------------------------------------------------------

local function modrm(mod, reg, rm)
  --: integer
  local mod = mod
  --: integer
  local reg = reg
  --: integer
  local rm = rm
  return (mod * 64) + ((reg % 8) * 8) + (rm % 8)
end

-- ---------------------------------------------------------------------------
-- Instruction encoders
-- ---------------------------------------------------------------------------

-- PUSH r64
local function enc_push(buf, reg)
  local n = gpr_num(reg)
  if n >= 8 then
    emit_bytes(buf, 0x41, 0x50 + (n - 8))
  else
    emit_byte(buf, 0x50 + n)
  end
end

-- POP r64
local function enc_pop(buf, reg)
  local n = gpr_num(reg)
  if n >= 8 then
    emit_bytes(buf, 0x41, 0x58 + (n - 8))
  else
    emit_byte(buf, 0x58 + n)
  end
end

-- RET
local function enc_ret(buf)
  emit_byte(buf, 0xC3)
end

-- MOV r64, r64 (REX.W + 89 /r: src → dst)
-- Encodes: dst = src
local function enc_mov_rr(buf, dst_reg, src_reg)
  local d = gpr_num(dst_reg)
  local s = gpr_num(src_reg)
  rex(buf, 1, s >= 8 and 1 or 0, 0, d >= 8 and 1 or 0)
  emit_byte(buf, 0x89)
  emit_byte(buf, modrm(3, s, d))
end

-- MOV r64, imm64 (REX.W + B8+rd)
-- Uses 64-bit immediate for full range.
--: ({ [integer]: integer }, string, integer) -> nil
local function enc_mov_ri64(buf, dst_reg, imm)
  local d = gpr_num(dst_reg)
  rex(buf, 1, 0, 0, d >= 8 and 1 or 0)
  emit_byte(buf, 0xB8 + (d % 8))
  -- Emit 8 bytes little-endian.
  -- imm is expected to be a small non-negative integer for our use.
  local v = imm
  for _ = 1, 8 do
    emit_byte(buf, v % 256)
    v = math.floor(v / 256)
  end
end

-- ADD r64, imm32 (REX.W 81 /0 id)  — imm may be negative (signed 32-bit).
local function enc_add_ri(buf, reg, imm)
  local n = gpr_num(reg)
  -- Use imm8 shortform if it fits.
  if imm >= -128 and imm <= 127 then
    rex(buf, 1, 0, 0, n >= 8 and 1 or 0)
    emit_byte(buf, 0x83)
    emit_byte(buf, modrm(3, 0, n))
    emit_i8(buf, imm)
  else
    rex(buf, 1, 0, 0, n >= 8 and 1 or 0)
    emit_byte(buf, 0x81)
    emit_byte(buf, modrm(3, 0, n))
    emit_u32le(buf, imm)
  end
end

-- CMP r64, r64 (REX.W 3B /r: dst - src, sets flags)
local function enc_cmp_rr(buf, reg_a, reg_b)
  local a = gpr_num(reg_a)
  local b = gpr_num(reg_b)
  rex(buf, 1, a >= 8 and 1 or 0, 0, b >= 8 and 1 or 0)
  emit_byte(buf, 0x3B)
  emit_byte(buf, modrm(3, a, b))
end

-- JL rel8 (0x7C cb)
-- Returns the position of the offset byte so we can backpatch.
local function enc_jl_rel8(buf, rel8)
  emit_bytes(buf, 0x7C, rel8 % 256)
end

-- JL rel32 (0x0F 0x8C cd)
local function enc_jl_rel32(buf, rel32)
  emit_bytes(buf, 0x0F, 0x8C)
  emit_u32le(buf, rel32)
end

-- VMOVDQU ymm, [base+disp32]  (load 256-bit unaligned)
local function enc_vmovdqu_load(buf, ymm_reg, base_reg, disp)
  local y = simd_num(ymm_reg)
  local b = gpr_num(base_reg)
  vex3(buf,
    y >= 8 and 1 or 0,  -- R
    0,                   -- X (no SIB)
    b >= 8 and 1 or 0,  -- B
    0x01,                -- mmmmm = 0F
    0,                   -- W = 0 (float)
    0,                   -- vvvv = 0 (unused)
    1,                   -- L = 1 (YMM)
    0x02                 -- pp = F3
  )
  emit_byte(buf, 0x6F)   -- VMOVDQU opcode

  -- Handle rsp/r12 (rm=4 requires SIB) by checking the base register.
  local base_low = b % 8
  if base_low == 4 then
    -- rsp or r12: emit SIB 0x24 (index=none, base=rsp/r12)
    emit_byte(buf, modrm(2, y, 4))  -- mod=10, rm=4 → SIB follows
    emit_byte(buf, 0x24)             -- SIB: scale=0, index=4(none), base=4(rsp)
  else
    emit_byte(buf, modrm(2, y, b))
  end
  emit_u32le(buf, disp)
end

-- VMOVDQU [base+disp32], ymm  (store 256-bit unaligned)
local function enc_vmovdqu_store(buf, base_reg, ymm_reg, disp)
  local y = simd_num(ymm_reg)
  local b = gpr_num(base_reg)
  vex3(buf,
    y >= 8 and 1 or 0,
    0,
    b >= 8 and 1 or 0,
    0x01,
    0,
    0,
    1,
    0x02
  )
  emit_byte(buf, 0x7F)   -- VMOVDQU store opcode

  local base_low = b % 8
  if base_low == 4 then
    emit_byte(buf, modrm(2, y, 4))
    emit_byte(buf, 0x24)
  else
    emit_byte(buf, modrm(2, y, b))
  end
  emit_u32le(buf, disp)
end

-- Generic VEX YMM reg-reg arithmetic: dst = a op b
-- mmmmm, pp, opcode vary per instruction.
local function enc_vex_ymm_rrr(buf, dst_reg, src1_reg, src2_reg, mmmmm, pp, opcode)
  local d  = simd_num(dst_reg)
  local s1 = simd_num(src1_reg)
  local s2 = simd_num(src2_reg)
  vex3(buf,
    d  >= 8 and 1 or 0,   -- R (ModRM.reg = dst)
    0,                     -- X
    s2 >= 8 and 1 or 0,   -- B (ModRM.rm = src2)
    mmmmm,
    0,                     -- W = 0
    s1,                    -- vvvv = src1 (NDS)
    1,                     -- L = 1 (YMM)
    pp
  )
  emit_byte(buf, opcode)
  emit_byte(buf, modrm(3, d, s2))
end

-- VMULPS ymm, ymm_a, ymm_b (dst = a * b, packed float32)
local function enc_vmulps(buf, dst, src1, src2)
  enc_vex_ymm_rrr(buf, dst, src1, src2, 0x01, 0x00, 0x59)
end

-- VADDPS ymm, ymm_a, ymm_b
local function enc_vaddps(buf, dst, src1, src2)
  enc_vex_ymm_rrr(buf, dst, src1, src2, 0x01, 0x00, 0x58)
end

-- VSUBPS ymm, ymm_a, ymm_b
local function enc_vsubps(buf, dst, src1, src2)
  enc_vex_ymm_rrr(buf, dst, src1, src2, 0x01, 0x00, 0x5C)
end

-- VDIVPS ymm, ymm_a, ymm_b
local function enc_vdivps(buf, dst, src1, src2)
  enc_vex_ymm_rrr(buf, dst, src1, src2, 0x01, 0x00, 0x5E)
end

-- VFMADD213PS ymm, ymm_b, ymm_c (dst = dst*ymm_b + ymm_c)
-- In IR: fma(dst=a, b, c) → a = a*b + c
local function enc_vfmadd213ps(buf, dst, src1, src2)
  enc_vex_ymm_rrr(buf, dst, src1, src2, 0x02, 0x01, 0xA8)
end

-- ---------------------------------------------------------------------------
-- Executable memory allocation
-- ---------------------------------------------------------------------------

local function alloc_exec_mem(code_str)
  local size = #code_str + 64  -- padding

  local ptr = ffi.C.mmap(nil, size,
    PROT_READ + PROT_WRITE,
    MAP_PRIVATE + MAP_ANON,
    -1, 0)
  if ptr == nil or ptr == ffi.cast("void*", -1) then
    return nil, "mmap failed"
  end

  -- Copy code bytes.
  ffi.copy(ptr, code_str, #code_str)

  -- Make executable (RX).
  local ret = ffi.C.mprotect(ptr, size, PROT_READ + PROT_EXEC)
  if ret ~= 0 then
    ffi.C.munmap(ptr, size)
    return nil, "mprotect failed"
  end

  -- Wrap with GC finalizer to munmap when collected.
  local captured_size = size
  local gc_ptr = ffi.gc(ptr, function(p)
    ffi.C.munmap(p, captured_size)
  end)

  return gc_ptr, size
end

-- ---------------------------------------------------------------------------
-- Compiler
-- ---------------------------------------------------------------------------

-- Resolve physical register name for a vreg.
-- For SIMD vregs the RA assignment is xmm-based; for 256-bit ops we need ymm.
-- If the assigned name starts with "xmm" and the vreg type is 256-bit, upgrade.
local WIDE_TYPES = {
  f32x8 = true, f64x4 = true,
  i8x32 = true, i16x16 = true, i32x8 = true, i64x4 = true,
}

local function phys_for_vreg(vreg, assignment)
  local reg = assignment[vreg.id]
  if reg == nil then return nil end
  -- If the IR type is 256-bit SIMD and RA gave us an xmm name, upgrade to ymm.
  if WIDE_TYPES[vreg.type] and reg:sub(1, 3) == "xmm" then
    return "ymm" .. reg:sub(4)
  end
  return reg
end

-- Main compile function.
--: (IRDescriptor, AllocResult, ABI, string) -> (unknown, string | nil)
M.compile = function(desc, alloc, abi, ctype)
  -- Validate architecture.
  if jit and jit.arch ~= "x64" then
    return nil, "emit.x64 requires x86-64; current arch: " .. tostring(jit and jit.arch)
  end

  local assignment = alloc.assignment
  local buf = buf_new()

  -- ── Step 1: Map arg vregs to ABI registers ─────────────────────────────
  -- For each argument position, determine:
  --   abi_reg: the ABI calling convention register (where caller puts the arg)
  --   ra_reg:  the physical register RA assigned to that vreg
  -- If they differ, we must emit a MOV at function entry.

  local arg_moves = {}  -- array of {from=abi_reg, to=ra_reg, is_simd=bool}
  local gpr_idx  = 0
  local simd_idx = 0

  for i = 1, #desc.args do
    local arg_entry = desc.args[i]
    local vreg_id   = arg_entry.vreg_id
    local arg_type  = arg_entry.type
    local is_simd   = (arg_type == "f32" or arg_type == "f64"
                       or arg_type:find("x") ~= nil)

    -- Determine ABI register for this argument.
    local abi_reg
    if is_simd then
      simd_idx = simd_idx + 1
      abi_reg = abi.arg_simd[simd_idx]
    else
      gpr_idx = gpr_idx + 1
      abi_reg = abi.arg_gpr[gpr_idx]
    end

    -- Determine RA-assigned register.
    local ra_reg = assignment[vreg_id]

    if abi_reg and ra_reg and abi_reg ~= ra_reg then
      arg_moves[#arg_moves + 1] = {
        from    = abi_reg,
        to      = ra_reg,
        is_simd = is_simd,
      }
    end
  end

  -- ── Step 2: Emit prologue ───────────────────────────────────────────────
  local callee_saves_arr = alloc.callee_saves
  for i = 1, #callee_saves_arr do
    enc_push(buf, callee_saves_arr[i])
  end

  -- ── Step 3: Emit arg moves ─────────────────────────────────────────────
  for i = 1, #arg_moves do
    local mv = arg_moves[i]
    if mv.is_simd then
      -- SIMD args: not needed for common scalar pointer args (ptr is GPR).
      -- For now only handle GPR moves; SIMD arg moves are a future extension.
    else
      enc_mov_rr(buf, mv.to, mv.from)
    end
  end

  -- ── Step 4: Emit instructions ──────────────────────────────────────────
  -- We need two passes for jump backpatching.
  -- Pass 1: collect byte positions of each instruction, record jump sites.
  -- Pass 2 is folded into pass 1 with a two-entry list: we pre-emit all
  -- non-jump instructions and for loop ops we record the site + target then
  -- backpatch with a rel32 JL which has a fixed 6-byte size.

  -- For loop ops, we record the buffer position where the branch is emitted
  -- and the target byte position (from label.position → instruction byte offset).
  -- We build a map from instruction index → byte offset after we assign sizes.

  -- Strategy:
  --   1. Walk instructions once, tracking byte offset per IR instruction index.
  --   2. For "loop" ops, emit a 6-byte JL rel32 placeholder; backpatch after.

  -- instruction_byte_pos[ir_pos] = byte offset in buf at the START of that instruction.
  local instruction_byte_pos = {}
  local loop_patches = {}  -- array of {buf_start, buf_after, label_ir_pos}

  local instructions = desc.instructions

  for idx = 1, #instructions do
    local insn = instructions[idx] --: Insn
    instruction_byte_pos[idx] = buf_len(buf)

    local op = insn.op

    if op == "load" then
      -- load(dst, ptr_vreg, offset_imm?)
      local dst_vreg = insn.dst --[[:! VReg]]
      local ptr_vreg = insn.operands[1] --[[:! VReg]]
      local off_imm  = insn.operands[2]
      local offset   = (off_imm and off_imm.imm) or 0
      local dst_phys = phys_for_vreg(dst_vreg, assignment)
      local ptr_phys = assignment[ptr_vreg.id]
      if dst_phys == nil then
        return nil, "vreg " .. dst_vreg.id .. " has no assignment (spilled?)"
      end
      if WIDE_TYPES[dst_vreg.type] then
        -- 256-bit SIMD load: VMOVDQU ymm, [ptr+offset]
        enc_vmovdqu_load(buf, dst_phys, ptr_phys, offset)
      else
        return nil, "not yet implemented: load of type " .. tostring(dst_vreg.type)
      end

    elseif op == "store" then
      -- store(ptr_vreg, src_vreg, offset_imm?)
      local ptr_vreg = insn.operands[1] --[[:! VReg]]
      local src_vreg = insn.operands[2] --[[:! VReg]]
      local off_imm  = insn.operands[3]
      local offset   = (off_imm and off_imm.imm) or 0
      local src_phys = phys_for_vreg(src_vreg, assignment)
      local ptr_phys = assignment[ptr_vreg.id]
      if src_phys == nil then
        return nil, "vreg " .. src_vreg.id .. " has no assignment (spilled?)"
      end
      if WIDE_TYPES[src_vreg.type] then
        enc_vmovdqu_store(buf, ptr_phys, src_phys, offset)
      else
        return nil, "not yet implemented: store of type " .. tostring(src_vreg.type)
      end

    elseif op == "mul" then
      local dst_vreg  = insn.dst --[[:! VReg]]
      local src1_vreg = insn.operands[1] --[[:! VReg]]
      local src2_vreg = insn.operands[2] --[[:! VReg]]
      local dst_phys  = phys_for_vreg(dst_vreg, assignment)
      local s1_phys   = phys_for_vreg(src1_vreg, assignment)
      local s2_phys   = phys_for_vreg(src2_vreg, assignment)
      if WIDE_TYPES[dst_vreg.type] and dst_vreg.type:find("^f") then
        enc_vmulps(buf, dst_phys, s1_phys, s2_phys)
      else
        return nil, "not yet implemented: mul of type " .. tostring(dst_vreg.type)
      end

    elseif op == "add" then
      local dst_vreg  = insn.dst --[[:! VReg]]
      local src1_vreg = insn.operands[1] --[[:! VReg]]
      local src2_any  = insn.operands[2] --[[:! { [string]: unknown }]]
      -- src2 might be an immediate.
      if src2_any and src2_any.imm ~= nil then
        -- add r64, imm
        local dst_phys = assignment[dst_vreg.id]
        -- src1 must be the same register as dst (in-place add).
        -- If src1 != dst, emit a MOV first.
        if src1_vreg.id ~= dst_vreg.id then
          local s1_phys = assignment[src1_vreg.id]
          if s1_phys and dst_phys and s1_phys ~= dst_phys then
            enc_mov_rr(buf, dst_phys, s1_phys)
          end
        end
        enc_add_ri(buf, dst_phys, src2_any.imm --[[:! integer]])
      else
        local src2_vreg = src2_any --[[:! VReg]]
        local dst_phys = phys_for_vreg(dst_vreg, assignment)
        local s1_phys  = phys_for_vreg(src1_vreg, assignment)
        local s2_phys  = phys_for_vreg(src2_vreg, assignment)
        if WIDE_TYPES[dst_vreg.type] and dst_vreg.type:find("^f") then
          enc_vaddps(buf, dst_phys, s1_phys, s2_phys)
        else
          return nil, "not yet implemented: add of type " .. tostring(dst_vreg.type)
        end
      end

    elseif op == "sub" then
      local dst_vreg  = insn.dst --[[:! VReg]]
      local src1_vreg = insn.operands[1] --[[:! VReg]]
      local src2_vreg = insn.operands[2] --[[:! VReg]]
      local dst_phys  = phys_for_vreg(dst_vreg, assignment)
      local s1_phys   = phys_for_vreg(src1_vreg, assignment)
      local s2_phys   = phys_for_vreg(src2_vreg, assignment)
      if WIDE_TYPES[dst_vreg.type] and dst_vreg.type:find("^f") then
        enc_vsubps(buf, dst_phys, s1_phys, s2_phys)
      else
        return nil, "not yet implemented: sub of type " .. tostring(dst_vreg.type)
      end

    elseif op == "div" then
      local dst_vreg  = insn.dst --[[:! VReg]]
      local src1_vreg = insn.operands[1] --[[:! VReg]]
      local src2_vreg = insn.operands[2] --[[:! VReg]]
      local dst_phys  = phys_for_vreg(dst_vreg, assignment)
      local s1_phys   = phys_for_vreg(src1_vreg, assignment)
      local s2_phys   = phys_for_vreg(src2_vreg, assignment)
      if WIDE_TYPES[dst_vreg.type] and dst_vreg.type:find("^f") then
        enc_vdivps(buf, dst_phys, s1_phys, s2_phys)
      else
        return nil, "not yet implemented: div of type " .. tostring(dst_vreg.type)
      end

    elseif op == "fma" then
      -- fma(dst=a, b, c) → a = a*b + c  (VFMADD213PS)
      local dst_vreg  = insn.dst --[[:! VReg]]
      local src1_vreg = insn.operands[1] --[[:! VReg]]
      local src2_vreg = insn.operands[2] --[[:! VReg]]
      local dst_phys  = phys_for_vreg(dst_vreg, assignment)
      local s1_phys   = phys_for_vreg(src1_vreg, assignment)
      local s2_phys   = phys_for_vreg(src2_vreg, assignment)
      if WIDE_TYPES[dst_vreg.type] and dst_vreg.type:find("^f") then
        enc_vfmadd213ps(buf, dst_phys, s1_phys, s2_phys)
      else
        return nil, "not yet implemented: fma of type " .. tostring(dst_vreg.type)
      end

    elseif op == "cmp" or op == "cmp_lt" then
      -- cmp(a, b) — compare a < b (sets flags for JL).
      local a_vreg = insn.operands[1] --[[:! VReg]]
      local b_vreg = insn.operands[2] --[[:! VReg]]
      local a_phys = assignment[a_vreg.id]
      local b_phys = assignment[b_vreg.id]
      enc_cmp_rr(buf, a_phys, b_phys)

    elseif op == "loop" then
      -- Backward branch to label.  We emit a 6-byte JL rel32 placeholder.
      local lbl = insn.operands[1] --[[:! Label]]
      local patch_start = buf_len(buf)
      -- Reserve 6 bytes: 0F 8C + 4 bytes rel32.
      emit_bytes(buf, 0x0F, 0x8C, 0, 0, 0, 0)
      local patch_after = buf_len(buf)
      loop_patches[#loop_patches + 1] = {
        patch_start  = patch_start,
        patch_after  = patch_after,
        label_ir_pos = lbl.position,
      }

    elseif op == "mov" then
      -- mov(dst, src_imm_or_vreg)
      local dst_vreg = insn.dst --[[:! VReg]]
      local src_any  = insn.operands[1] --[[:! { [string]: unknown }]]
      local dst_phys = assignment[dst_vreg.id]
      if src_any.imm ~= nil then
        -- mov r64, imm
        enc_mov_ri64(buf, dst_phys, src_any.imm --[[:! integer]])
      else
        -- mov r64, r64
        local src = src_any --[[:! VReg]]
        local s_phys = assignment[src.id]
        enc_mov_rr(buf, dst_phys, s_phys)
      end

    elseif op == "broadcast" or op == "shuffle" or op == "blend"
        or op == "cvt" or op == "hadd" or op == "extract" or op == "insert"
        or op == "and" or op == "or" or op == "xor" or op == "not"
        or op == "shl" or op == "shr" then
      return nil, "not yet implemented: " .. op

    else
      return nil, "not yet implemented: " .. tostring(op)
    end
  end

  -- Record epilogue start position.
  local epilogue_pos = buf_len(buf)

  -- ── Step 5: Emit epilogue ──────────────────────────────────────────────
  for i = #callee_saves_arr, 1, -1 do
    enc_pop(buf, callee_saves_arr[i])
  end
  enc_ret(buf)

  -- ── Backpatch loop branches ────────────────────────────────────────────
  -- The loop instruction's JL should jump to the byte offset of the label's IR position.
  -- label.position is the IR instruction index of the loop header.
  -- After backpatching: rel32 = target_byte - (patch_after_byte)
  --
  -- instruction_byte_pos[label_ir_pos] is the byte offset of the first instruction
  -- of the loop body.  "loop" always branches backwards, so rel32 will be negative.

  for i = 1, #loop_patches do
    local p = loop_patches[i]
    local target_byte = instruction_byte_pos[p.label_ir_pos]
    if target_byte == nil then
      -- The label points past the end (epilogue) — shouldn't normally happen.
      target_byte = epilogue_pos
    end
    local rel32 = target_byte - p.patch_after
    -- Write signed 32-bit little-endian at buf[patch_start+2..patch_start+5].
    -- buf is 1-indexed; the rel32 occupies bytes at offsets patch_start+2 to patch_start+5.
    local v = rel32 % 0x100000000  -- treat as unsigned 32-bit for byte extraction
    buf[p.patch_start + 3] = v % 256; v = math.floor(v / 256)
    buf[p.patch_start + 4] = v % 256; v = math.floor(v / 256)
    buf[p.patch_start + 5] = v % 256; v = math.floor(v / 256)
    buf[p.patch_start + 6] = v % 256
  end

  -- ── Step 6: Allocate executable memory and return callable ─────────────
  local code_str = buf_to_string(buf)
  local code_str_any = code_str --[[: unknown]]
  local exec_ptr, err = alloc_exec_mem(code_str_any)
  if exec_ptr == nil then
    return nil, err --[[:! string | nil]]
  end

  -- Cast to the requested function type.
  -- ctype is a runtime string; exact signature is unknowable, but result is callable.
  local fn_any = ffi.cast(ctype, exec_ptr) --[[: unknown]]
  local fn = fn_any --[[:! (...unknown) -> unknown]]
  -- Keep exec_ptr alive (don't let GC collect it) by anchoring to fn table.
  -- We return a table wrapper so the GC anchor is maintained.
  -- Actually, ffi.cast returns a cdata that does NOT own the pointer;
  -- we must keep exec_ptr alive.  Store it in a upvalue via a closure.
  local anchor = exec_ptr  -- upvalue keeps exec_ptr alive as long as wrapper exists
  local wrapper = {}
  setmetatable(wrapper, {
    __call = function(_, ...)
      return fn(...)
    end,
    __index = {
      _ptr    = fn,
      _anchor = anchor,
    },
  })
  return wrapper
end

return M
