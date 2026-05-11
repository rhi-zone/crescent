-- lib/asm/init.lua
-- Assembly/SIMD support: CPU feature detection and kernel compilation.
--
-- High-level API:
--   asm.compile(opts, build_fn) -> fn | (nil, errmsg)
--     opts.args  : array of IR type strings e.g. { "ptr", "f32x8", "i64" }
--     opts.ret   : array of IR type strings for return values (usually {})
--     opts.ctype : FFI ctype string e.g. "void(*)(float*,float*,float*,int)"
--   build_fn(k)  : receives the ir.kernel object; add IR instructions here.
--                  k.arg(i) returns the i-th argument vreg.
--
-- Example:
--   local fn = asm.compile(
--     { args = { "ptr", "ptr", "ptr", "i64" }, ret = {}, ctype = "void(*)(float*,float*,float*,int)" },
--     function(k)
--       local a, b, c, n = k.arg(1), k.arg(2), k.arg(3), k.arg(4)
--       k.vmulps(c, a, b, n)
--     end)
--
-- The wrapper selects the ABI and emit module based on jit.arch.
-- Returns nil, errmsg when the current architecture has no emit backend.

if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local M = {}
M.cpu = require("lib.asm.cpu")

-- Lazy-load IR and RA so non-JIT hosts that never call compile() don't pay the cost.
local function load_ir() return require("lib.asm.ir") end
local function load_ra() return require("lib.asm.ra") end

-- Select the ABI and emit module for the running CPU+OS.
-- Returns abi_def, regfile, emit_mod | (nil, nil, errmsg).
local function select_backend()
  local arch = jit and jit.arch or nil
  if arch == "x64" then
    local abi  = require("lib.asm.abi.x64")
    local emit = require("lib.asm.emit.x64")
    local abi_def = (jit and jit.os == "Windows") and abi.win64 or abi.sysv
    return abi_def, abi_def, emit
  end
  if arch == "arm64" then
    local ok, abi = pcall(require, "lib.asm.abi.arm64")
    local ok2, emit = pcall(require, "lib.asm.emit.arm64")
    if ok and ok2 then
      return abi.aapcs64, abi.aapcs64, emit
    end
    return nil, nil, "arm64 emit backend not yet implemented"
  end
  return nil, nil, "unsupported arch: " .. tostring(arch)
end

-- asm.compile(opts, build_fn) -> fn | (nil, errmsg)
M.compile = function(opts, build_fn)
  if type(opts) ~= "table" then
    return nil, "asm.compile: opts must be a table"
  end
  if type(build_fn) ~= "function" then
    return nil, "asm.compile: build_fn must be a function"
  end
  local arg_types = opts.args or {}
  local ret_types = opts.ret  or {}
  local ctype     = opts.ctype
  if not ctype then
    return nil, "asm.compile: opts.ctype is required"
  end

  local abi_def, regfile, emit_mod = select_backend()
  if not abi_def then
    return nil, emit_mod  -- emit_mod holds errmsg in error path
  end

  local ir = load_ir()
  local ra = load_ra()

  local k = ir.kernel(arg_types, ret_types)
  local ok, err = pcall(build_fn, k)
  if not ok then
    return nil, "asm.compile: build_fn error: " .. tostring(err)
  end

  local desc = k:finalize()
  local alloc = ra.allocate(desc.intervals --[[:! { [integer]: { id: integer, first: integer, last: integer, type: string, phys: string, ... }, ... }]], regfile)
  return (emit_mod --[[:! { compile: (unknown, unknown, unknown, string) -> (unknown, string | nil) }]]).compile(desc, alloc, abi_def, ctype --[[:! string]])
end

return M
