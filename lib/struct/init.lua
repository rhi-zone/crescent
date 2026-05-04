if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

--- C-style struct pack/unpack for binary data.
-- Format strings follow Python's struct module convention.
-- Byte order prefix: < (LE), > (BE), ! (BE/network), = (native), none (native)
-- Format chars: b B h H i I l L q Q f d s Ns c ? x
-- Repeat count: N<char> repeats char N times (e.g. 4B, 2I)
local M = {}

M._tier = "ffi"

local ffi = require("ffi")
local bit = require("bit")

-- FFI unions for float conversion
--:: F32Union = { f: number, b: { [integer]: integer } }
--:: F64Union = { f: number, d: number, b: { [integer]: integer } }
local union_f32 = ffi.typeof("union { float f; uint8_t b[4]; }") --[[: any]]
local union_f64 = ffi.typeof("union { double d; uint8_t b[8]; }") --[[: any]]
local u32 = ffi.typeof("union { uint32_t u; int32_t i; }")
local u64 = ffi.typeof("union { uint64_t u; int64_t i; }")

-- Detect native endianness
local _ne_check = ffi.new("union { uint16_t u; uint8_t b[2]; }")
_ne_check.u = 0x0102
local NATIVE_LE = (_ne_check.b[0] == 0x02)

-- Size of each format character (in bytes)
local SIZES = {
  b = 1, B = 1,
  h = 2, H = 2,
  i = 4, I = 4,
  l = 4, L = 4,
  q = 8, Q = 8,
  f = 4,
  d = 8,
  s = 1,
  c = 1,
  x = 1,
  ["?"] = 1,
}

--:: StructOp = { char: string, count: integer, le: boolean }
-- Parse format string into a list of ops.
-- Each op: { char, count, le } where le=true means little-endian.
-- Returns ops_list, err
--: (fmt: string) -> ({ [integer]: StructOp } | nil, string | nil)
local function parse_fmt(fmt)
  local le --: boolean | nil
  local i = 1 --: integer
  local ops = {} --: { [integer]: StructOp }
  local ops_ = ops --[[: any]]

  -- Optional byte order prefix
  local first = fmt:sub(1, 1)
  if first == "<" then
    le = true
    i = 2
  elseif first == ">" or first == "!" then
    le = false
    i = 2
  elseif first == "=" then
    le = NATIVE_LE
    i = 2
  end

  local n = #fmt
  while i <= n do
    -- Consume optional repeat count
    local count = 0
    while i <= n do
      local b = fmt:byte(i)
      if b >= 48 and b <= 57 then -- '0'..'9'
        count = count * 10 + (b - 48)
        i = i + 1
      else
        break
      end
    end
    if count == 0 then count = 1 end

    if i > n then
      return nil, "struct: trailing count with no format character"
    end

    local c = fmt:sub(i, i)
    i = i + 1

    -- 'x' (pad) ignores repeat in terms of values but takes bytes
    local eff_le = (le == nil and NATIVE_LE or le) --[[:! boolean]]
    if c == "x" then
      ops_[#ops + 1] = { char = "x", count = count, le = eff_le }
    elseif c == "s" then
      -- Ns = string of N bytes; treat count as the string length, one value
      ops_[#ops + 1] = { char = "s", count = count, le = eff_le }
    elseif SIZES[c] then
      for _ = 1, count do
        ops_[#ops + 1] = { char = c, count = 1, le = eff_le }
      end
    else
      return nil, "struct: unknown format character '" .. c .. "'"
    end
  end

  return ops
end

-- Write bytes for a single op into a table of byte strings
--: (out: { [integer]: string }, op: StructOp, val: unknown) -> (boolean | nil, string | nil)
local function write_op(out, op, val)
  local out_ = out --[[: any]]
  local c = op.char
  local le = op.le

  if c == "x" then
    for _ = 1, op.count do
      out[#out + 1] = "\0"
    end
    return true

  elseif c == "?" then
    out[#out + 1] = (val and val ~= 0) and "\1" or "\0"
    return true

  elseif c == "b" then
    -- int8
    if type(val) ~= "number" then return nil, "struct: expected number for 'b'" end
    local nv = math.floor(val --[[:! number]])
    if nv < -128 or nv > 127 then return nil, "struct: value out of range for 'b'" end
    if nv < 0 then nv = nv + 256 end
    out_[#out + 1] = string.char(nv)
    return true

  elseif c == "B" then
    -- uint8
    if type(val) ~= "number" then return nil, "struct: expected number for 'B'" end
    local nv = math.floor(val --[[:! number]])
    if nv < 0 or nv > 255 then return nil, "struct: value out of range for 'B'" end
    out_[#out + 1] = string.char(nv)
    return true

  elseif c == "h" then
    -- int16
    if type(val) ~= "number" then return nil, "struct: expected number for 'h'" end
    local nv = math.floor(val --[[:! number]])
    if nv < -32768 or nv > 32767 then return nil, "struct: value out of range for 'h'" end
    if nv < 0 then nv = nv + 65536 end
    local b0 = nv % 256
    local b1 = math.floor(nv / 256) % 256
    if le then
      out_[#out + 1] = string.char(b0, b1)
    else
      out_[#out + 1] = string.char(b1, b0)
    end
    return true

  elseif c == "H" then
    -- uint16
    if type(val) ~= "number" then return nil, "struct: expected number for 'H'" end
    local nv = math.floor(val --[[:! number]])
    if nv < 0 or nv > 65535 then return nil, "struct: value out of range for 'H'" end
    local b0 = nv % 256
    local b1 = math.floor(nv / 256) % 256
    if le then
      out_[#out + 1] = string.char(b0, b1)
    else
      out_[#out + 1] = string.char(b1, b0)
    end
    return true

  elseif c == "i" or c == "l" then
    -- int32
    if type(val) ~= "number" then return nil, "struct: expected number for '" .. c .. "'" end
    local nv = math.floor(val --[[:! number]])
    if nv < -2147483648 or nv > 2147483647 then
      return nil, "struct: value out of range for '" .. c .. "'"
    end
    if nv < 0 then nv = (nv + 4294967296) --[[:! integer]] end
    local nv2 = nv --[[:! integer]]
    local b0 = nv2 % 256
    local b1 = math.floor(nv2 / 256) % 256
    local b2 = math.floor(nv2 / 65536) % 256
    local b3 = math.floor(nv2 / 16777216) % 256
    if le then
      out_[#out + 1] = string.char(b0, b1, b2, b3)
    else
      out_[#out + 1] = string.char(b3, b2, b1, b0)
    end
    return true

  elseif c == "I" or c == "L" then
    -- uint32
    if type(val) ~= "number" then return nil, "struct: expected number for '" .. c .. "'" end
    local nv = math.floor(val --[[:! number]])
    if nv < 0 or nv > 4294967295 then
      return nil, "struct: value out of range for '" .. c .. "'"
    end
    local b0 = nv % 256
    local b1 = math.floor(nv / 256) % 256
    local b2 = math.floor(nv / 65536) % 256
    local b3 = math.floor(nv / 16777216) % 256
    if le then
      out_[#out + 1] = string.char(b0, b1, b2, b3)
    else
      out_[#out + 1] = string.char(b3, b2, b1, b0)
    end
    return true

  elseif c == "q" then
    -- int64 — use FFI for correct bit handling
    if type(val) ~= "number" then return nil, "struct: expected number for 'q'" end
    local tmp = ffi.new("union { int64_t i; uint8_t b[8]; }")
    tmp.i = val --[[:! number]]
    local s
    if le then
      s = string.char(tmp.b[0], tmp.b[1], tmp.b[2], tmp.b[3],
                      tmp.b[4], tmp.b[5], tmp.b[6], tmp.b[7])
    else
      s = string.char(tmp.b[7], tmp.b[6], tmp.b[5], tmp.b[4],
                      tmp.b[3], tmp.b[2], tmp.b[1], tmp.b[0])
    end
    out[#out + 1] = s
    return true

  elseif c == "Q" then
    -- uint64
    if type(val) ~= "number" then return nil, "struct: expected number for 'Q'" end
    local tmp = ffi.new("union { uint64_t u; uint8_t b[8]; }")
    tmp.u = val --[[:! number]]
    local s
    if le then
      s = string.char(tmp.b[0], tmp.b[1], tmp.b[2], tmp.b[3],
                      tmp.b[4], tmp.b[5], tmp.b[6], tmp.b[7])
    else
      s = string.char(tmp.b[7], tmp.b[6], tmp.b[5], tmp.b[4],
                      tmp.b[3], tmp.b[2], tmp.b[1], tmp.b[0])
    end
    out[#out + 1] = s
    return true

  elseif c == "f" then
    -- float32
    if type(val) ~= "number" then return nil, "struct: expected number for 'f'" end
    local u = union_f32()
    u.f = val --[[:! number]]
    local s
    if le then
      s = string.char(u.b[0], u.b[1], u.b[2], u.b[3])
    else
      s = string.char(u.b[3], u.b[2], u.b[1], u.b[0])
    end
    out[#out + 1] = s
    return true

  elseif c == "d" then
    -- float64
    if type(val) ~= "number" then return nil, "struct: expected number for 'd'" end
    local u = union_f64()
    u.d = val --[[:! number]]
    local s
    if le then
      s = string.char(u.b[0], u.b[1], u.b[2], u.b[3],
                      u.b[4], u.b[5], u.b[6], u.b[7])
    else
      s = string.char(u.b[7], u.b[6], u.b[5], u.b[4],
                      u.b[3], u.b[2], u.b[1], u.b[0])
    end
    out[#out + 1] = s
    return true

  elseif c == "s" or c == "c" then
    -- string / char
    local n = op.count
    if type(val) ~= "string" then return nil, "struct: expected string for 's'/'c'" end
    local sval = val --[[:! string]]
    if #sval < n then
      -- zero-pad
      out[#out + 1] = sval .. string.rep("\0", n - #sval)
    elseif #sval > n then
      out[#out + 1] = sval:sub(1, n)
    else
      out[#out + 1] = sval
    end
    return true

  elseif c == "?" then
    out[#out + 1] = (val and val ~= 0) and "\1" or "\0"
    return true

  else
    return nil, "struct: unknown format character '" .. c .. "'"
  end
end

-- Read a value for a single op from string s at position pos.
-- Returns value, new_pos
--: (op: StructOp, s: string, pos: integer) -> (unknown, integer | nil, string | nil)
local function read_op(op, s, pos)
  local c = op.char
  local le = op.le

  if c == "x" then
    return nil, pos + op.count  -- pad: skip, return nil marker

  elseif c == "?" then
    local b = s:byte(pos)
    if not b then return nil, nil, "struct: buffer too short for '?'" end
    return (b ~= 0), pos + 1

  elseif c == "b" then
    local b = s:byte(pos)
    if not b then return nil, nil, "struct: buffer too short for 'b'" end
    if b >= 128 then b = b - 256 end
    return b, pos + 1

  elseif c == "B" then
    local b = s:byte(pos)
    if not b then return nil, nil, "struct: buffer too short for 'B'" end
    return b, pos + 1

  elseif c == "h" then
    local b0, b1 = s:byte(pos, pos + 1)
    if not b1 then return nil, nil, "struct: buffer too short for 'h'" end
    local v = 0 --: integer
    if le then v = (b0 + b1 * 256) --[[:! integer]]
    else      v = (b1 + b0 * 256) --[[:! integer]] end
    if v >= 32768 then v = v - 65536 end
    return v, pos + 2

  elseif c == "H" then
    local b0, b1 = s:byte(pos, pos + 1)
    if not b1 then return nil, nil, "struct: buffer too short for 'H'" end
    local v
    if le then v = b0 + b1 * 256
    else      v = b1 + b0 * 256 end
    return v, pos + 2

  elseif c == "i" or c == "l" then
    local b0, b1, b2, b3 = s:byte(pos, pos + 3)
    if not b3 then return nil, nil, "struct: buffer too short for '" .. c .. "'" end
    local v = 0 --: integer
    if le then v = (b0 + b1 * 256 + b2 * 65536 + b3 * 16777216) --[[:! integer]]
    else      v = (b3 + b2 * 256 + b1 * 65536 + b0 * 16777216) --[[:! integer]] end
    if v >= 2147483648 then v = (v - 4294967296) --[[:! integer]] end
    return v, pos + 4

  elseif c == "I" or c == "L" then
    local b0, b1, b2, b3 = s:byte(pos, pos + 3)
    if not b3 then return nil, nil, "struct: buffer too short for '" .. c .. "'" end
    local v
    if le then v = b0 + b1 * 256 + b2 * 65536 + b3 * 16777216
    else      v = b3 + b2 * 256 + b1 * 65536 + b0 * 16777216 end
    return v, pos + 4

  elseif c == "q" then
    local bytes = { s:byte(pos, pos + 7) }
    if #bytes < 8 then return nil, nil, "struct: buffer too short for 'q'" end
    local tmp = ffi.new("union { int64_t i; uint8_t b[8]; }")
    if le then
      for k = 0, 7 do tmp.b[k] = bytes[k + 1] end
    else
      for k = 0, 7 do tmp.b[k] = bytes[8 - k] end
    end
    return tonumber(tmp.i), pos + 8

  elseif c == "Q" then
    local bytes = { s:byte(pos, pos + 7) }
    if #bytes < 8 then return nil, nil, "struct: buffer too short for 'Q'" end
    local tmp = ffi.new("union { uint64_t u; uint8_t b[8]; }")
    if le then
      for k = 0, 7 do tmp.b[k] = bytes[k + 1] end
    else
      for k = 0, 7 do tmp.b[k] = bytes[8 - k] end
    end
    return tonumber(tmp.u), pos + 8

  elseif c == "f" then
    local bytes = { s:byte(pos, pos + 3) }
    if #bytes < 4 then return nil, nil, "struct: buffer too short for 'f'" end
    local u = union_f32()
    if le then
      u.b[0] = bytes[1]; u.b[1] = bytes[2]; u.b[2] = bytes[3]; u.b[3] = bytes[4]
    else
      u.b[0] = bytes[4]; u.b[1] = bytes[3]; u.b[2] = bytes[2]; u.b[3] = bytes[1]
    end
    return u.f, pos + 4

  elseif c == "d" then
    local bytes = { s:byte(pos, pos + 7) }
    if #bytes < 8 then return nil, nil, "struct: buffer too short for 'd'" end
    local u = union_f64()
    if le then
      for k = 0, 7 do u.b[k] = bytes[k + 1] end
    else
      for k = 0, 7 do u.b[k] = bytes[8 - k] end
    end
    return u.d, pos + 8

  elseif c == "s" or c == "c" then
    local n = op.count
    if pos + n - 1 > #s then return nil, nil, "struct: buffer too short for 's'/'c'" end
    return s:sub(pos, pos + n - 1), pos + n

  else
    return nil, nil, "struct: unknown format character '" .. c .. "'"
  end
end

-- Calculate the packed size for a format string.
-- Returns number, err
function M.calcsize(fmt)
  local ops, err = parse_fmt(fmt)
  if not ops then return nil, err end
  local total = 0
  for _, op in ipairs(ops) do
    local c = op.char
    if c == "s" or c == "c" then
      total = total + op.count
    elseif c == "x" then
      total = total + op.count
    else
      local sz = SIZES[c]
      if not sz then return nil, "struct: unknown format character '" .. c .. "'" end
      total = total + sz
    end
  end
  return total
end

-- Pack values according to format string.
-- Returns string, err
function M.pack(fmt, ...)
  local ops, err = parse_fmt(fmt)
  if not ops then return nil, err end

  local args = { ... }
  local arg_i = 1
  local out = {}

  for _, op in ipairs(ops) do
    if op.char == "x" then
      local ok2, err2 = write_op(out, op, nil)
      if not ok2 then return nil, err2 end
    else
      local val = args[arg_i]
      arg_i = arg_i + 1
      local ok2, err2 = write_op(out, op, val)
      if not ok2 then return nil, err2 end
    end
  end

  return table.concat(out)
end

-- Unpack binary string into values.
-- Returns values..., next_offset (Lua 1-based), err
-- The last return value before err is always next_offset.
function M.unpack(fmt, s, offset)
  local ops, err = parse_fmt(fmt)
  if not ops then return nil, err end

  offset = offset or 1
  local results = {}
  local pos = offset

  for _, op in ipairs(ops) do
    if op.char == "x" then
      -- pad: skip bytes, no value pushed
      local val, new_pos, err2 = read_op(op, s, pos)
      if err2 then return nil, err2 end
      pos = new_pos
    else
      local val, new_pos, err2 = read_op(op, s, pos)
      if err2 then return nil, err2 end
      results[#results + 1] = val
      pos = new_pos
    end
  end

  -- Append next_offset as last result (Python struct convention)
  results[#results + 1] = pos
  return unpack(results)
end

-- Compiled format object for reuse.
local Compiled = {}
Compiled.__index = Compiled

function Compiled:pack(...)
  return M.pack(self._fmt, ...)
end

function Compiled:unpack(s, offset)
  return M.unpack(self._fmt, s, offset)
end

function Compiled:size()
  return self._size
end

-- Precompile a format string for repeated use.
-- Returns compiled object, err
function M.compile(fmt)
  local sz, err = M.calcsize(fmt)
  if not sz then return nil, err end
  -- Validate format fully (parse_fmt already does this)
  local ops, err2 = parse_fmt(fmt)
  if not ops then return nil, err2 end
  local obj = setmetatable({ _fmt = fmt, _size = sz, _ops = ops }, Compiled)
  return obj
end

return M
