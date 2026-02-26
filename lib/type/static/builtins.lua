-- lib/type/static/builtins.lua
-- Type signatures for Lua globals and stdlib.

local types = require("lib.type.static.types")
local env = require("lib.type.static.env")

local T = types

local M = {}

-- Helpers
local function fn(params, returns, vararg)
  return T.func(params, returns, vararg)
end

local function method(self_ty, params, returns)
  local all_params = { self_ty }
  for i = 1, #params do all_params[#all_params + 1] = params[i] end
  return T.func(all_params, returns)
end

function M.create_env()
  local scope = env.new(0)

  -- Global functions
  env.bind(scope, "print", fn({}, {}, T.ANY()))
  env.bind(scope, "tostring", fn({ T.ANY() }, { T.STRING() }))
  env.bind(scope, "tonumber", fn({ T.ANY() }, { T.optional(T.NUMBER()) }))
  env.bind(scope, "type", fn({ T.ANY() }, { T.STRING() }))
  env.bind(scope, "error", fn({ T.ANY() }, {}))
  env.bind(scope, "assert", fn({ T.ANY() }, { T.ANY() }, T.ANY()))
  env.bind(scope, "pcall", fn({ T.func({}, { T.ANY() }, T.ANY()) }, { T.BOOLEAN(), T.ANY() }, T.ANY()))
  env.bind(scope, "xpcall", fn({ T.func({}, { T.ANY() }, T.ANY()), T.func({ T.ANY() }, { T.ANY() }) }, { T.BOOLEAN(), T.ANY() }, T.ANY()))
  env.bind(scope, "require", fn({ T.STRING() }, { T.ANY() }))
  env.bind(scope, "select", fn({ T.union({ T.NUMBER(), T.STRING() }) }, { T.ANY() }, T.ANY()))
  env.bind(scope, "rawget", fn({ T.table(), T.ANY() }, { T.ANY() }))
  env.bind(scope, "rawset", fn({ T.table(), T.ANY(), T.ANY() }, { T.table() }))
  env.bind(scope, "rawequal", fn({ T.ANY(), T.ANY() }, { T.BOOLEAN() }))
  env.bind(scope, "rawlen", fn({ T.ANY() }, { T.INTEGER() }))
  env.bind(scope, "unpack", fn({ T.table() }, { T.ANY() }, T.ANY()))
  env.bind(scope, "pairs", fn({ T.table() }, { T.func({}, { T.ANY(), T.ANY() }), T.table(), T.NIL() }))
  env.bind(scope, "ipairs", fn({ T.table() }, { T.func({}, { T.INTEGER(), T.ANY() }), T.table(), T.NUMBER() }))
  env.bind(scope, "next", fn({ T.table() }, { T.ANY(), T.ANY() }))
  env.bind(scope, "setmetatable", fn({ T.table(), T.optional(T.table()) }, { T.table() }))
  env.bind(scope, "getmetatable", fn({ T.ANY() }, { T.optional(T.table()) }))
  env.bind(scope, "collectgarbage", fn({}, { T.ANY() }))
  env.bind(scope, "dofile", fn({ T.optional(T.STRING()) }, { T.ANY() }))
  env.bind(scope, "loadfile", fn({ T.optional(T.STRING()) }, { T.ANY(), T.optional(T.STRING()) }))
  env.bind(scope, "load", fn({ T.union({ T.STRING(), T.func({}, { T.optional(T.STRING()) }) }) }, { T.ANY(), T.optional(T.STRING()) }))
  env.bind(scope, "loadstring", fn({ T.STRING() }, { T.ANY(), T.optional(T.STRING()) }))

  -- table.*
  local tbl = T.table({
    concat = { type = fn({ T.table(), T.optional(T.STRING()), T.optional(T.INTEGER()), T.optional(T.INTEGER()) }, { T.STRING() }), optional = false },
    insert = { type = fn({ T.table(), T.ANY() }, {}), optional = false },
    remove = { type = fn({ T.table(), T.optional(T.INTEGER()) }, { T.ANY() }), optional = false },
    sort = { type = fn({ T.table(), T.optional(T.func({ T.ANY(), T.ANY() }, { T.BOOLEAN() })) }, {}), optional = false },
    move = { type = fn({ T.table(), T.INTEGER(), T.INTEGER(), T.INTEGER(), T.optional(T.table()) }, { T.table() }), optional = false },
  }, {})
  env.bind(scope, "table", tbl)

  -- string.*
  local str = T.table({
    byte = { type = fn({ T.STRING(), T.optional(T.INTEGER()), T.optional(T.INTEGER()) }, { T.INTEGER() }, T.INTEGER()), optional = false },
    char = { type = fn({}, { T.STRING() }, T.INTEGER()), optional = false },
    find = { type = fn({ T.STRING(), T.STRING(), T.optional(T.INTEGER()), T.optional(T.BOOLEAN()) }, { T.optional(T.INTEGER()), T.optional(T.INTEGER()) }), optional = false },
    format = { type = fn({ T.STRING() }, { T.STRING() }, T.ANY()), optional = false },
    gmatch = { type = fn({ T.STRING(), T.STRING() }, { T.func({}, { T.ANY() }) }), optional = false },
    gsub = { type = fn({ T.STRING(), T.STRING(), T.union({ T.STRING(), T.table(), T.func({ T.STRING() }, { T.STRING() }) }), T.optional(T.INTEGER()) }, { T.STRING(), T.INTEGER() }), optional = false },
    len = { type = fn({ T.STRING() }, { T.INTEGER() }), optional = false },
    lower = { type = fn({ T.STRING() }, { T.STRING() }), optional = false },
    upper = { type = fn({ T.STRING() }, { T.STRING() }), optional = false },
    match = { type = fn({ T.STRING(), T.STRING(), T.optional(T.INTEGER()) }, { T.optional(T.STRING()) }), optional = false },
    rep = { type = fn({ T.STRING(), T.INTEGER(), T.optional(T.STRING()) }, { T.STRING() }), optional = false },
    reverse = { type = fn({ T.STRING() }, { T.STRING() }), optional = false },
    sub = { type = fn({ T.STRING(), T.INTEGER(), T.optional(T.INTEGER()) }, { T.STRING() }), optional = false },
    dump = { type = fn({ T.func({}, {}, T.ANY()) }, { T.STRING() }), optional = false },
  }, {})
  env.bind(scope, "string", str)

  -- math.*
  local math_t = T.table({
    abs = { type = fn({ T.NUMBER() }, { T.NUMBER() }), optional = false },
    ceil = { type = fn({ T.NUMBER() }, { T.INTEGER() }), optional = false },
    floor = { type = fn({ T.NUMBER() }, { T.INTEGER() }), optional = false },
    sqrt = { type = fn({ T.NUMBER() }, { T.NUMBER() }), optional = false },
    sin = { type = fn({ T.NUMBER() }, { T.NUMBER() }), optional = false },
    cos = { type = fn({ T.NUMBER() }, { T.NUMBER() }), optional = false },
    tan = { type = fn({ T.NUMBER() }, { T.NUMBER() }), optional = false },
    log = { type = fn({ T.NUMBER(), T.optional(T.NUMBER()) }, { T.NUMBER() }), optional = false },
    exp = { type = fn({ T.NUMBER() }, { T.NUMBER() }), optional = false },
    max = { type = fn({ T.NUMBER() }, { T.NUMBER() }, T.NUMBER()), optional = false },
    min = { type = fn({ T.NUMBER() }, { T.NUMBER() }, T.NUMBER()), optional = false },
    random = { type = fn({ T.optional(T.INTEGER()), T.optional(T.INTEGER()) }, { T.NUMBER() }), optional = false },
    randomseed = { type = fn({ T.NUMBER() }, {}), optional = false },
    huge = { type = T.NUMBER(), optional = false },
    pi = { type = T.NUMBER(), optional = false },
    maxinteger = { type = T.INTEGER(), optional = false },
    mininteger = { type = T.INTEGER(), optional = false },
  }, {})
  env.bind(scope, "math", math_t)

  -- io.* (simplified)
  local io_file = T.table({
    read = { type = fn({ T.ANY() }, { T.optional(T.STRING()) }), optional = false },
    write = { type = fn({}, { T.ANY() }, T.ANY()), optional = false },
    close = { type = fn({}, { T.optional(T.BOOLEAN()), T.optional(T.STRING()) }), optional = false },
    lines = { type = fn({}, { T.func({}, { T.optional(T.STRING()) }) }), optional = false },
    seek = { type = fn({ T.optional(T.STRING()), T.optional(T.INTEGER()) }, { T.optional(T.INTEGER()), T.optional(T.STRING()) }), optional = false },
    flush = { type = fn({}, {}), optional = false },
  }, {})
  local io_t = T.table({
    open = { type = fn({ T.STRING(), T.optional(T.STRING()) }, { T.optional(io_file), T.optional(T.STRING()) }), optional = false },
    close = { type = fn({ T.optional(io_file) }, { T.optional(T.BOOLEAN()), T.optional(T.STRING()) }), optional = false },
    read = { type = fn({}, { T.optional(T.STRING()) }, T.ANY()), optional = false },
    write = { type = fn({}, { T.ANY() }, T.ANY()), optional = false },
    lines = { type = fn({ T.optional(T.STRING()) }, { T.func({}, { T.optional(T.STRING()) }) }), optional = false },
    stdin = { type = io_file, optional = false },
    stdout = { type = io_file, optional = false },
    stderr = { type = io_file, optional = false },
  }, {})
  env.bind(scope, "io", io_t)

  -- os.* (simplified)
  local os_t = T.table({
    time = { type = fn({ T.optional(T.table()) }, { T.INTEGER() }), optional = false },
    date = { type = fn({ T.optional(T.STRING()), T.optional(T.INTEGER()) }, { T.union({ T.STRING(), T.table() }) }), optional = false },
    clock = { type = fn({}, { T.NUMBER() }), optional = false },
    execute = { type = fn({ T.optional(T.STRING()) }, { T.optional(T.BOOLEAN()), T.optional(T.STRING()), T.optional(T.INTEGER()) }), optional = false },
    getenv = { type = fn({ T.STRING() }, { T.optional(T.STRING()) }), optional = false },
    remove = { type = fn({ T.STRING() }, { T.optional(T.BOOLEAN()), T.optional(T.STRING()) }), optional = false },
    rename = { type = fn({ T.STRING(), T.STRING() }, { T.optional(T.BOOLEAN()), T.optional(T.STRING()) }), optional = false },
    exit = { type = fn({ T.optional(T.union({ T.BOOLEAN(), T.INTEGER() })) }, {}), optional = false },
    tmpname = { type = fn({}, { T.STRING() }), optional = false },
  }, {})
  env.bind(scope, "os", os_t)

  -- LuaJIT: ffi.*
  local ffi_t = T.table({
    cdef = { type = fn({ T.STRING() }, {}), optional = false },
    new = { type = fn({ T.union({ T.STRING(), T.ANY() }) }, { T.ANY() }, T.ANY()), optional = false },
    cast = { type = fn({ T.union({ T.STRING(), T.ANY() }), T.ANY() }, { T.ANY() }), optional = false },
    typeof = { type = fn({ T.STRING() }, { T.ANY() }), optional = false },
    sizeof = { type = fn({ T.ANY() }, { T.INTEGER() }), optional = false },
    string = { type = fn({ T.ANY(), T.optional(T.INTEGER()) }, { T.STRING() }), optional = false },
    copy = { type = fn({ T.ANY(), T.ANY(), T.INTEGER() }, {}), optional = false },
    fill = { type = fn({ T.ANY(), T.INTEGER(), T.optional(T.INTEGER()) }, {}), optional = false },
    istype = { type = fn({ T.ANY(), T.ANY() }, { T.BOOLEAN() }), optional = false },
    C = { type = T.table({}, {}, types.rowvar(0)), optional = false },
    os = { type = T.STRING(), optional = false },
    arch = { type = T.STRING(), optional = false },
  }, {})
  env.bind(scope, "ffi", ffi_t)

  -- LuaJIT: bit.*
  local bit_t = T.table({
    tobit = { type = fn({ T.NUMBER() }, { T.INTEGER() }), optional = false },
    tohex = { type = fn({ T.NUMBER(), T.optional(T.INTEGER()) }, { T.STRING() }), optional = false },
    bnot = { type = fn({ T.NUMBER() }, { T.INTEGER() }), optional = false },
    band = { type = fn({ T.NUMBER() }, { T.INTEGER() }, T.NUMBER()), optional = false },
    bor = { type = fn({ T.NUMBER() }, { T.INTEGER() }, T.NUMBER()), optional = false },
    bxor = { type = fn({ T.NUMBER() }, { T.INTEGER() }, T.NUMBER()), optional = false },
    lshift = { type = fn({ T.NUMBER(), T.NUMBER() }, { T.INTEGER() }), optional = false },
    rshift = { type = fn({ T.NUMBER(), T.NUMBER() }, { T.INTEGER() }), optional = false },
    arshift = { type = fn({ T.NUMBER(), T.NUMBER() }, { T.INTEGER() }), optional = false },
    rol = { type = fn({ T.NUMBER(), T.NUMBER() }, { T.INTEGER() }), optional = false },
    ror = { type = fn({ T.NUMBER(), T.NUMBER() }, { T.INTEGER() }), optional = false },
    bswap = { type = fn({ T.NUMBER() }, { T.INTEGER() }), optional = false },
  }, {})
  env.bind(scope, "bit", bit_t)

  -- Special values
  env.bind(scope, "true", T.literal("boolean", true))
  env.bind(scope, "false", T.literal("boolean", false))
  env.bind(scope, "nil", T.NIL())
  env.bind(scope, "_G", T.table({}, {}, types.rowvar(0)))
  env.bind(scope, "_VERSION", T.STRING())
  env.bind(scope, "arg", T.array(T.STRING()))

  return scope
end

return M
