if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

-- Virtual register IR builder for SIMD kernels.
-- Sits above ra.lua (produces live intervals for it) and below emit/ (consumes
-- the instruction list).
--
-- ir.kernel(arg_types, ret_types) -> kernel
--   arg_types: array of IR type strings for arguments
--   ret_types: array of IR type strings for return values
--
-- kernel:vreg(type_str)      -> vreg handle {id, type}
-- kernel:arg(n)              -> vreg handle for argument n (1-indexed)
-- ir.imm(value)              -> immediate handle {imm=value}
-- kernel:emit(op, ...)       -> dst vreg | nil
-- kernel:label()             -> label handle {position}
-- kernel:loop(lbl)           -> (void)
-- kernel:ret(vreg)           -> (void)
-- kernel:finalize()          -> descriptor (see below)

--:: VReg  = { id: integer, type: string }
--:: Imm   = { imm: unknown }
--:: Label = { position: integer }
--:: Insn  = { op: string, dst: VReg|nil, operands: { [integer]: unknown, ... }, pos: integer }

--:: IRDescriptor = {
--::   instructions: { [integer]: Insn, ... },
--::   intervals:    { [integer]: { id: integer, first: integer, last: integer, type: string }, ... },
--::   args:         { [integer]: { vreg_id: integer, type: string }, ... },
--::   rets:         { [integer]: { vreg_id: integer, type: string }, ... },
--::   arg_types:    { [integer]: string, ... },
--::   ret_types:    { [integer]: string, ... },
--::   num_labels:   integer,
-- }

local M = {}

-- ---------------------------------------------------------------------------
-- Type helpers
-- ---------------------------------------------------------------------------

-- All valid IR types.
local SCALAR_TYPES = {
  i8 = true, i16 = true, i32 = true, i64 = true,
  f32 = true, f64 = true, ptr = true,
}

local SIMD_TYPES = {
  i8x16 = true, i16x8 = true, i32x4 = true, i64x2 = true,
  f32x4 = true, f64x2 = true,
  i8x32 = true, i16x16 = true, i32x8 = true, i64x4 = true,
  f32x8 = true, f64x4 = true,
}

-- Type byte widths.
local TYPE_WIDTHS = {
  i8  = 1, i16 = 2, i32 = 4, i64 = 8,
  f32 = 4, f64 = 8, ptr = 8,
  i8x16  = 16, i16x8  = 16, i32x4  = 16, i64x2  = 16, f32x4  = 16, f64x2 = 16,
  i8x32  = 32, i16x16 = 32, i32x8  = 32, i64x4  = 32, f32x8  = 32, f64x4 = 32,
}

-- Instructions that produce no destination vreg (no value defined).
-- store and control-flow ops.
local NO_DST_OPS = {
  store = true,
  cmp   = true,
  loop  = true, -- loop is handled separately but listed for completeness
}

-- ir.is_simd(type_str) -> bool
M.is_simd = function(t)
  --: string
  local t = t
  return SIMD_TYPES[t] == true
end

-- ir.is_scalar(type_str) -> bool
M.is_scalar = function(t)
  --: string
  local t = t
  return SCALAR_TYPES[t] == true
end

-- ir.reg_class(type_str) -> "gpr" | "simd"
M.reg_class = function(t)
  --: string
  local t = t
  if SIMD_TYPES[t] then return "simd" end
  return "gpr"
end

-- ir.type_width(type_str) -> integer (bytes)
M.type_width = function(t)
  --: string
  local t = t
  return TYPE_WIDTHS[t] or 0
end

-- ---------------------------------------------------------------------------
-- Immediate value
-- ---------------------------------------------------------------------------

-- ir.imm(value) -> {imm=value}
M.imm = function(value)
  return { imm = value }
end

-- ---------------------------------------------------------------------------
-- Kernel
-- ---------------------------------------------------------------------------

-- ir.kernel(arg_types, ret_types) -> kernel object
M.kernel = function(arg_types, ret_types)
  --: { [integer]: string, ... }
  local arg_types = arg_types
  --: { [integer]: string, ... }
  local ret_types = ret_types

  local k = {}
  k._next_id  = 0       -- vreg id counter (0 = first arg slot)
  k._insns    = {}      -- array of Insn
  k._args     = {}      -- array of {vreg_id, type} in order
  k._rets     = {}      -- array of {vreg_id, type}
  k._arg_vregs = {}     -- vreg handles for arguments, indexed 1..#arg_types
  k._arg_types = arg_types
  k._ret_types = ret_types
  k._num_labels = 0

  -- Pre-allocate vregs for each argument.  Arguments are defined before
  -- instruction 0 (first = 0) so they must be allocated before emit() is
  -- ever called.
  for i = 1, #arg_types do
    local id = k._next_id
    k._next_id = k._next_id + 1
    local v = { id = id, type = arg_types[i] }
    k._arg_vregs[i] = v
    k._args[i] = { vreg_id = id, type = arg_types[i] }
  end

  -- kernel:vreg(type_str) -> vreg handle
  k.vreg = function(self, type_str)
    --: string
    local type_str = type_str
    local id = self._next_id
    self._next_id = self._next_id + 1
    return { id = id, type = type_str }
  end

  -- kernel:arg(n) -> vreg handle for argument n (1-indexed)
  k.arg = function(self, n)
    --: integer
    local n = n
    return self._arg_vregs[n]
  end

  -- kernel:emit(op, operand1, ...) -> dst vreg | nil
  -- The first operand whose type field matches a vreg (has .id and .type) is
  -- treated as dst when the op produces a value.  For ops with no dst the
  -- caller omits a dst vreg as the first argument (all operands are sources).
  --
  -- Calling convention:
  --   k:emit("load",  dst_vreg, ptr_vreg, offset_imm?)
  --   k:emit("store", ptr_vreg, src_vreg, offset_imm?)
  --   k:emit("add",   dst_vreg, a_vreg, b_vreg)
  --   k:emit("cmp",   a_vreg, b_vreg)
  -- i.e. the first argument to emit (after op) is dst when applicable.
  k.emit = function(self, op, ...)
    --: string
    local op = op
    local args = { ... }
    local pos = #self._insns + 1

    local dst = nil
    local operands = {}

    if NO_DST_OPS[op] then
      -- All args are operands (sources / immediates).
      for i = 1, #args do
        operands[i] = args[i]
      end
    else
      -- First arg is dst vreg; remaining are operands.
      dst = args[1]
      for i = 2, #args do
        operands[i - 1] = args[i]
      end
    end

    local insn = {
      op       = op,
      dst      = dst,
      operands = operands,
      pos      = pos,
    }
    self._insns[pos] = insn
    return dst
  end

  -- kernel:label() -> label handle {position}
  -- The label records the position of the *next* instruction that will be
  -- emitted (i.e. the loop header is the instruction at that index).
  k.label = function(self)
    self._num_labels = self._num_labels + 1
    -- position = index of the next instruction to be emitted (1-based).
    -- any: self is a dynamic table; _insns is known to be an array of Insn.
    local insns = self._insns --: any
    local n = #insns
    local lbl = { position = n + 1 }
    return lbl
  end

  -- kernel:loop(lbl) -> (void)
  -- Emits a backward branch to lbl.  Also extends liveness of any vreg whose
  -- interval spans the loop body (handled in finalize).
  k.loop = function(self, lbl)
    --: Label
    local lbl = lbl
    local pos = #self._insns + 1
    local insn = {
      op       = "loop",
      dst      = nil,
      operands = { lbl },
      pos      = pos,
    }
    self._insns[pos] = insn
  end

  -- kernel:ret(vreg) -> (void)
  -- Mark a vreg as a return value (in order of calls).
  k.ret = function(self, v)
    --: VReg
    local v = v
    self._rets[#self._rets + 1] = { vreg_id = v.id, type = v.type }
  end

  -- kernel:finalize() -> IRDescriptor
  k.finalize = function(self)
    -- any: self is a dynamic table; _insns is known to be an array of Insn.
    local insns = self._insns --: any
    local n = #insns

    -- live_first[id] and live_last[id]: instruction indices.
    -- Use 0-based definition index for arg vregs (they are live from "before
    -- instruction 1").
    local live_first = {} --: { [integer]: integer, ... }
    local live_last  = {} --: { [integer]: integer, ... }

    -- Initialise arg intervals: first = 0.
    -- any: self is a dynamic table; _args is known to be an array of arg entries.
    local self_args = self._args --: any
    for i = 1, #self_args do
      local entry = self_args[i] --: { vreg_id: integer, type: string }
      local id = entry.vreg_id
      live_first[id] = 0
      -- last defaults to 0; will be updated on first use or forced to 1 below.
      live_last[id] = 0
    end

    -- Collect all loop instructions for liveness extension.
    local loop_insns = {} --: { [integer]: Insn, ... }

    -- Walk instructions forward.
    for idx = 1, n do
      local insn = insns[idx] --: Insn
      local op = insn.op

      -- Definition: dst vreg is defined here.
      if insn.dst then
        local id = insn.dst.id
        if live_first[id] == nil then
          live_first[id] = idx
          live_last[id]  = idx
        end
      end

      -- Uses: each operand that is a vreg updates last.
      local ops = insn.operands
      for i = 1, #ops do
        local o = ops[i]
        -- A vreg operand has .id and .type (no .imm, no .position).
        if type(o) == "table" and o.id ~= nil and o.imm == nil and o.position == nil then
          local id = o.id
          if live_last[id] == nil then
            -- Referenced but not previously seen as dst (e.g. arg used first time here).
            if live_first[id] == nil then
              live_first[id] = idx
            end
            live_last[id] = idx
          else
            if idx > live_last[id] then
              live_last[id] = idx
            end
          end
        end
      end

      if op == "loop" then
        loop_insns[#loop_insns + 1] = insn
      end
    end

    -- Extend liveness across loop backedges.
    -- A vreg must survive the backedge (and thus be live until the loop
    -- instruction) only if it was defined *before* the loop header and is
    -- still live somewhere inside the body.  Vregs defined inside the body
    -- are loop-local: they are redefined on each iteration and do not need
    -- to survive the backedge.
    for _, linsn in ipairs(loop_insns) do
      local loop_pos = linsn.pos
      -- The label handle is operands[1].
      local lbl = linsn.operands[1] --: Label
      local header = lbl.position

      for id, first in pairs(live_first) do
        local last = live_last[id]
        -- Defined strictly before the header (pre-loop) and used inside body.
        if first < header and last >= header then
          if loop_pos > last then
            live_last[id] = loop_pos
          end
        end
      end
    end

    -- Build interval array.  Force last >= first + 1 for defined-but-never-used
    -- vregs so they get a register slot.
    local intervals = {} --: { [integer]: { id: integer, first: integer, last: integer, type: string }, ... }
    local vreg_types = {} --: { [integer]: string, ... }

    -- Collect type for each vreg from arg list.
    -- any: self is a dynamic table; see self_args annotation above.
    local self_args2 = self._args --: any
    for i = 1, #self_args2 do
      local ae = self_args2[i] --: { vreg_id: integer, type: string }
      vreg_types[ae.vreg_id] = ae.type
    end

    -- Collect type for each vreg from instructions (dst).
    for idx = 1, n do
      local insn = insns[idx] --: Insn
      if insn.dst then
        vreg_types[insn.dst.id] = insn.dst.type
      end
    end

    for id, first in pairs(live_first) do
      local last = live_last[id] or first
      if last <= first then
        last = first + 1
      end
      local t = vreg_types[id] or "i64"
      intervals[#intervals + 1] = {
        id    = id,
        first = first,
        last  = last,
        type  = M.reg_class(t),
      }
    end

    -- Build the finalized instruction list (copy, stripping internal pos field
    -- is not required but we keep pos for downstream consumers).
    local instructions = {} --: { [integer]: Insn, ... }
    for i = 1, n do
      instructions[i] = insns[i]
    end

    return {
      instructions = instructions,
      intervals    = intervals,
      args         = self._args,
      rets         = self._rets,
      arg_types    = self._arg_types,
      ret_types    = self._ret_types,
      num_labels   = self._num_labels,
    }
  end

  return k
end

return M
