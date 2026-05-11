-- lib/vm/init.lua
-- Stack-based bytecode virtual machine for crescent.
--
-- Instruction set:
--   Stack:      PUSH val, POP, DUP, SWAP, ROT
--   Arithmetic: ADD, SUB, MUL, DIV, MOD, NEG
--   Comparison: EQ, NEQ, LT, LE, GT, GE  (push 1 or 0)
--   Logic:      AND, OR, NOT
--   Memory:     LOAD name, STORE name
--   Control:    JMP target, JMP_IF target, JMP_IFNOT target
--               CALL target, RET
--   I/O:        PRINT
--   Special:    HALT, NOP

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- ---------------------------------------------------------------------------
-- Program builder: resolve labels → instruction indices
-- ---------------------------------------------------------------------------

-- Build a program from an instruction list.
-- Label entries { label = "name" } are removed; jumps with { target = "name" }
-- get their target field replaced with an absolute instruction index (1-based).
-- Returns a program table: { instrs = {...}, size = n }
function M.program(instrs)
  -- First pass: collect label positions (labels are not counted as instructions)
  local labels = {}
  local code = {}
  for _, entry in ipairs(instrs) do
    if entry.label then
      labels[entry.label] = #code + 1  -- next instruction index
    else
      code[#code + 1] = entry
    end
  end

  -- Second pass: resolve targets
  for i, instr in ipairs(code) do
    if instr.target then
      local idx = labels[instr.target]
      if not idx then
        error("vm.program: undefined label '" .. tostring(instr.target) .. "'")
      end
      -- Build a new instr table with target resolved to an integer index
      local resolved = {}
      for k, v in pairs(instr) do resolved[k] = v end
      resolved.target = idx
      code[i] = resolved
    end
  end

  return { instrs = code, size = #code }
end

-- ---------------------------------------------------------------------------
-- Machine constructor
-- ---------------------------------------------------------------------------

--:: Machine = { _prog: { [integer]: unknown }, _size: integer, _stack: { [integer]: unknown }, _sp: integer, _pc: integer, _env: { [string]: unknown }, _halted: boolean, _call_stack: { [integer]: integer }, step: (Machine) -> boolean }

local Machine = {}
Machine.__index = Machine

-- Create a new machine for the given program.
-- opts (optional): { env = {...} } to pre-populate variables.
function M.new(prog, opts)
  opts = opts or {}
  local self = setmetatable({}, Machine)
  self._prog    = prog.instrs
  self._size    = prog.size
  self._stack   = {}
  self._sp      = 0          -- stack pointer; _stack[_sp] is top
  self._pc      = 1          -- program counter; next instruction to execute
  self._env     = opts.env and setmetatable({}, { __index = opts.env }) or {}
  self._halted  = false
  self._call_stack = {}      -- return addresses for CALL/RET
  return self
end

-- ---------------------------------------------------------------------------
-- Stack helpers
-- ---------------------------------------------------------------------------

local function push(self, v)
  local sp = self._sp + 1
  self._sp = sp
  self._stack[sp] = v
end

local function pop(self)
  local sp = self._sp
  if sp < 1 then
    error("vm: stack underflow")
  end
  local v = self._stack[sp]
  self._stack[sp] = nil
  self._sp = sp - 1
  return v
end

local function peek(self)
  if self._sp < 1 then
    error("vm: stack underflow")
  end
  return self._stack[self._sp]
end

-- ---------------------------------------------------------------------------
-- Instruction handlers
-- ---------------------------------------------------------------------------

local handlers = {}

-- Stack ops
handlers.PUSH = function(self, instr)
  push(self, instr.value)
end

handlers.POP = function(self, _instr)
  pop(self)
end

handlers.DUP = function(self, _instr)
  push(self, peek(self))
end

handlers.SWAP = function(self, _instr)
  local sp = self._sp
  if sp < 2 then error("vm: SWAP requires 2 stack values") end
  local a = self._stack[sp]
  local b = self._stack[sp - 1]
  self._stack[sp]     = b
  self._stack[sp - 1] = a
end

-- ROT: rotate top 3 — ( a b c -- b c a )
handlers.ROT = function(self, _instr)
  local sp = self._sp
  if sp < 3 then error("vm: ROT requires 3 stack values") end
  local c = self._stack[sp]
  local b = self._stack[sp - 1]
  local a = self._stack[sp - 2]
  self._stack[sp]     = a
  self._stack[sp - 1] = c
  self._stack[sp - 2] = b
end

-- Arithmetic
handlers.ADD = function(self, _instr)
  local b = pop(self); local a = pop(self); push(self, a + b)
end
handlers.SUB = function(self, _instr)
  local b = pop(self); local a = pop(self); push(self, a - b)
end
handlers.MUL = function(self, _instr)
  local b = pop(self); local a = pop(self); push(self, a * b)
end
handlers.DIV = function(self, _instr)
  local b = pop(self); local a = pop(self)
  if b == 0 then error("vm: division by zero") end
  push(self, a / b)
end
handlers.MOD = function(self, _instr)
  local b = pop(self); local a = pop(self)
  if b == 0 then error("vm: modulo by zero") end
  push(self, a % b)
end
handlers.NEG = function(self, _instr)
  push(self, -pop(self))
end

-- Comparison: result is 1 (true) or 0 (false)
handlers.EQ = function(self, _instr)
  local b = pop(self); local a = pop(self); push(self, a == b and 1 or 0)
end
handlers.NEQ = function(self, _instr)
  local b = pop(self); local a = pop(self); push(self, a ~= b and 1 or 0)
end
handlers.LT = function(self, _instr)
  local b = pop(self); local a = pop(self); push(self, a < b and 1 or 0)
end
handlers.LE = function(self, _instr)
  local b = pop(self); local a = pop(self); push(self, a <= b and 1 or 0)
end
handlers.GT = function(self, _instr)
  local b = pop(self); local a = pop(self); push(self, a > b and 1 or 0)
end
handlers.GE = function(self, _instr)
  local b = pop(self); local a = pop(self); push(self, a >= b and 1 or 0)
end

-- Logic (operands treated as truthy/falsy; result is 1/0)
handlers.AND = function(self, _instr)
  local b = pop(self); local a = pop(self)
  push(self, (a ~= 0 and a ~= false and b ~= 0 and b ~= false) and 1 or 0)
end
handlers.OR = function(self, _instr)
  local b = pop(self); local a = pop(self)
  push(self, (a ~= 0 and a ~= false or b ~= 0 and b ~= false) and 1 or 0)
end
handlers.NOT = function(self, _instr)
  local a = pop(self)
  push(self, (a == 0 or a == false) and 1 or 0)
end

-- Memory
handlers.LOAD = function(self, instr)
  local v = self._env[instr.name]
  if v == nil then
    error("vm: undefined variable '" .. tostring(instr.name) .. "'")
  end
  push(self, v)
end
handlers.STORE = function(self, instr)
  self._env[instr.name] = pop(self)
end

-- Control flow
handlers.JMP = function(self, instr)
  self._pc = instr.target
end
handlers.JMP_IF = function(self, instr)
  local v = pop(self)
  if v ~= 0 and v ~= false then
    self._pc = instr.target
  end
end
handlers.JMP_IFNOT = function(self, instr)
  local v = pop(self)
  if v == 0 or v == false then
    self._pc = instr.target
  end
end

-- CALL: push return address (current pc, already incremented past CALL),
--       then jump to target
handlers.CALL = function(self, instr)
  local cs = self._call_stack
  cs[#cs + 1] = self._pc  -- return address = instruction after CALL
  self._pc = instr.target
end

-- RET: pop return address and jump
handlers.RET = function(self, _instr)
  local cs = self._call_stack
  local n = #cs
  if n < 1 then
    error("vm: RET with empty call stack")
  end
  local addr = cs[n]
  cs[n] = nil
  self._pc = addr
end

-- I/O
handlers.PRINT = function(self, _instr)
  print(pop(self))
end

-- Special
handlers.HALT = function(self, _instr)
  self._halted = true
end
handlers.NOP = function(_self, _instr)
  -- nothing
end

-- ---------------------------------------------------------------------------
-- Execution engine
-- ---------------------------------------------------------------------------

-- Execute one instruction.  Returns false if halted, true otherwise.
function Machine:step()
  local self_ = self --[[:! Machine]]
  if self_._halted then return false end
  local pc = self_._pc
  if pc > self_._size then
    self_._halted = true
    return false
  end
  local instr = self_._prog[pc]
  self_._pc = pc + 1
  local h = handlers --[[: unknown]]
  local hfn = h[instr --[[: unknown]]]
  if not hfn then
    error("vm: unknown opcode '" .. tostring(instr --[[: unknown]]) .. "'")
  end
  hfn(self_, instr)
  return not self_._halted
end

-- Execute n instructions (or until halted).
function Machine:steps(n)
  local self_ = self --[[:! Machine]]
  for _ = 1, n do
    if not self_:step() then break end
  end
end

-- Run until HALT or end of program.
function Machine:run()
  local self_ = self --[[:! Machine]]
  while not self_._halted do
    if not self_:step() then break end
  end
end

-- ---------------------------------------------------------------------------
-- Inspection API
-- ---------------------------------------------------------------------------

-- Return the value on top of the stack (without popping).
function Machine:top()
  if self._sp < 1 then
    error("vm: stack is empty")
  end
  return self._stack[self._sp]
end

-- Return a copy of the current stack as an array (index 1 = bottom).
function Machine:stack()
  local s = {}
  for i = 1, self._sp do
    s[i] = self._stack[i]
  end
  return s
end

-- Return a copy of the variable environment.
function Machine:env()
  local e = {}
  for k, v in pairs(self._env) do e[k] = v end
  return e
end

-- Return the current program counter (next instruction index, 1-based).
function Machine:pc()
  return self._pc
end

-- Return true if the machine has halted.
function Machine:is_halted()
  return self._halted
end

return M
