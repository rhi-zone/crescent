if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local bit = require("bit")
local ffi = require("ffi")

local M = {}
M._tier = "pure"

local band, bor, rshift, lshift = bit.band, bit.bor, bit.rshift, bit.lshift

-- Lookup tables for hex conversion
local HEX_LO = {}
local HEX_HI = {}
for i = 0, 255 do
  HEX_LO[i] = string.format("%02x", i)
  HEX_HI[i] = string.format("%02X", i)
end

local function byte_to_hex(b, upper)
  return upper and HEX_HI[b] or HEX_LO[b]
end

--:: DumpOpts = { width?: integer, group?: integer, offset?: integer, uppercase?: boolean, show_ascii?: boolean, show_addr?: boolean, ascii_char?: string }

--- Classic xxd-style hex dump.
-- @param data  binary string
-- @param opts  table of options (optional)
-- @return      formatted hex dump string
--: (string, DumpOpts | nil) -> string
function M.dump(data, opts)
  opts = opts or {}
  local width      = opts.width      or 16
  local group      = opts.group      or 8
  local offset     = opts.offset     or 0
  local uppercase  = opts.uppercase  or false
  local show_ascii = opts.show_ascii ~= false  -- default true
  local show_addr  = opts.show_addr  ~= false  -- default true
  local ascii_char = opts.ascii_char or "."

  local hex_tab = uppercase and HEX_HI or HEX_LO
  local n = #data
  local lines = {}

  local row = 0
  while row * width < n or (row == 0 and n == 0) do
    local line_parts = {}
    local ascii_parts = {}

    -- Address column
    if show_addr then
      line_parts[#line_parts + 1] = string.format("%08x  ", offset + row * width)
    end

    -- Hex bytes
    local col_count = 0
    for col = 0, width - 1 do
      local idx = row * width + col
      if idx < n then
        local b = string.byte(data, idx + 1) --[[:! integer]]
        line_parts[#line_parts + 1] = hex_tab[b]
        if show_ascii then
          if b >= 32 and b <= 126 then
            ascii_parts[#ascii_parts + 1] = string.char(b)
          else
            ascii_parts[#ascii_parts + 1] = ascii_char
          end
        end
      else
        line_parts[#line_parts + 1] = "  "
        if show_ascii then
          ascii_parts[#ascii_parts + 1] = " "
        end
      end
      col_count = col_count + 1
      -- space after each byte, extra space at group boundary
      if col < width - 1 then
        if (col + 1) % group == 0 then
          line_parts[#line_parts + 1] = "  "
        else
          line_parts[#line_parts + 1] = " "
        end
      end
    end

    if show_ascii then
      line_parts[#line_parts + 1] = "  |"
      line_parts[#line_parts + 1] = table.concat(ascii_parts)
      line_parts[#line_parts + 1] = "|"
    end

    lines[#lines + 1] = table.concat(line_parts)

    row = row + 1
    if row * width >= n then break end
  end

  return table.concat(lines, "\n")
end

--- Convert binary string to hex string.
-- @param data  binary string
-- @return      hex string (lowercase)
--: (string) -> string
function M.to_hex(data)
  local t = {}
  for i = 1, #data do
    t[i] = HEX_LO[string.byte(data, i) --[[:! integer]]]
  end
  return table.concat(t)
end

--- Convert hex string to binary string.
-- @param hex  hex string (upper or lowercase, optional spaces/colons ignored)
-- @return     binary string, or nil + error message
function M.from_hex(hex)
  -- strip whitespace and colons
  local clean = hex:gsub("[%s:]", "")
  if #clean % 2 ~= 0 then
    return nil, "hex string has odd length"
  end
  local t = {} --[[: unknown]]
  for i = 1, #clean, 2 do
    local hi = clean:sub(i, i)
    local lo = clean:sub(i + 1, i + 1)
    if not hi:match("[0-9a-fA-F]") or not lo:match("[0-9a-fA-F]") then
      return nil, "invalid hex character at position " .. i
    end
    t[#t + 1] = string.char(tonumber(hi .. lo, 16))
  end
  return table.concat(t)
end

--- Parse a hex dump (as produced by dump()) back to binary.
-- Accepts xxd/hexdump -C style: address column optional, ASCII column optional.
-- @param dump_str  string produced by dump()
-- @return          binary string
function M.parse(dump_str)
  local bytes = {} --[[: unknown]]
  for line in (dump_str .. "\n"):gmatch("([^\n]*)\n") do
    -- strip optional diff prefix ("> " or "< " or "  ")
    local rest = line:gsub("^[><]?%s", "")
    -- strip optional address prefix: exactly 8 hex digits followed by spaces
    rest = rest:gsub("^%x%x%x%x%x%x%x%x%s+", "")
    -- strip optional ASCII suffix (space space | ... |)
    rest = rest:gsub("%s*|[^|]*|%s*$", "")
    -- collect hex byte tokens (pairs of hex digits separated by spaces)
    for hex in rest:gmatch("%x%x") do
      bytes[#bytes + 1] = string.char(tonumber(hex, 16))
    end
  end
  return table.concat(bytes)
end

--- Diff two binary strings, producing an annotated hex dump.
-- Lines with differences are marked with > on the left.
-- @param a     first binary string
-- @param b     second binary string
-- @param opts  dump options (optional)
-- @return      annotated diff string
--: (string, string, DumpOpts | nil) -> string
function M.diff(a, b, opts)
  opts = opts or {}
  local width = opts.width or 16
  local n = math.max(#a, #b)
  local lines = {}

  if n == 0 then
    return ""
  end

  local hex_tab = opts.uppercase and HEX_HI or HEX_LO
  local show_ascii = opts.show_ascii ~= false
  local show_addr  = opts.show_addr  ~= false
  local ascii_char = opts.ascii_char or "."
  local group      = opts.group or 8
  local offset     = opts.offset or 0

  local row = 0
  while row * width < n do
    local changed = false
    for col = 0, width - 1 do
      local idx = row * width + col
      local ba = idx < #a and string.byte(a, idx + 1) or nil
      local bb = idx < #b and string.byte(b, idx + 1) or nil
      if ba ~= bb then changed = true; break end
    end

    local line_a = {}
    local line_b = {}
    local ascii_a = {}
    local ascii_b = {}

    local prefix_a = changed and "> " or "  "
    local prefix_b = changed and "< " or "  "

    if show_addr then
      local addr = string.format("%08x  ", offset + row * width)
      line_a[#line_a + 1] = prefix_a .. addr
      line_b[#line_b + 1] = prefix_b .. addr
    else
      line_a[#line_a + 1] = prefix_a
      line_b[#line_b + 1] = prefix_b
    end

    for col = 0, width - 1 do
      local idx = row * width + col
      local ba = idx < #a and string.byte(a, idx + 1) or nil
      local bb = idx < #b and string.byte(b, idx + 1) or nil

      line_a[#line_a + 1] = ba and hex_tab[ba] or "  "
      line_b[#line_b + 1] = bb and hex_tab[bb] or "  "

      if show_ascii then
        if ba then
          ascii_a[#ascii_a + 1] = (ba >= 32 and ba <= 126) and string.char(ba) or ascii_char
        else
          ascii_a[#ascii_a + 1] = " "
        end
        if bb then
          ascii_b[#ascii_b + 1] = (bb >= 32 and bb <= 126) and string.char(bb) or ascii_char
        else
          ascii_b[#ascii_b + 1] = " "
        end
      end

      if col < width - 1 then
        if (col + 1) % group == 0 then
          line_a[#line_a + 1] = "  "
          line_b[#line_b + 1] = "  "
        else
          line_a[#line_a + 1] = " "
          line_b[#line_b + 1] = " "
        end
      end
    end

    if show_ascii then
      line_a[#line_a + 1] = "  |" .. table.concat(ascii_a) .. "|"
      line_b[#line_b + 1] = "  |" .. table.concat(ascii_b) .. "|"
    end

    if changed then
      lines[#lines + 1] = table.concat(line_a)
      lines[#lines + 1] = table.concat(line_b)
    else
      lines[#lines + 1] = table.concat(line_a)
    end

    row = row + 1
  end

  return table.concat(lines, "\n")
end

-- Inspect helpers

local ESCAPE = {
  ["\a"] = "\\a", ["\b"] = "\\b", ["\f"] = "\\f",
  ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
  ["\v"] = "\\v", ["\\"] = "\\\\", ["\""] = "\\\"",
}

--: (string) -> string
local function escape_string(s)
  local result = s:gsub('[%c\\"]', function(c)
    return ESCAPE[c] or string.format("\\%d", string.byte(c))
  end)
  return '"' .. result .. '"'
end

--:: InspectOpts = { indent?: integer, max_depth?: integer, compact?: boolean }
--: (unknown, InspectOpts, integer, { [unknown]: boolean | nil }) -> string
local function inspect_value(val, opts, depth, seen)
  local t = type(val)
  if t == "nil" then
    return "nil"
  elseif t == "boolean" then
    return tostring(val)
  elseif t == "number" then
    if val ~= val then return "nan"
    elseif val == math.huge then return "inf"
    elseif val == -math.huge then return "-inf"
    else return tostring(val)
    end
  elseif t == "string" then
    return escape_string(val --[[:! string]])
  elseif t == "function" then
    return tostring(val)  -- e.g. "function: 0x..."
  elseif t == "table" then
    if seen[val] then
      return "<cycle>"
    end
    local max_depth = opts.max_depth or 4
    if depth >= max_depth then
      return "{...}"
    end
    seen[val] = true

    local indent = opts.indent or 2
    local compact = opts.compact or false
    local pad = string.rep(" ", depth * indent)
    local inner_pad = string.rep(" ", (depth + 1) * indent)

    local parts = {}
    -- collect array part
    local arr_end = 0
    while val[arr_end + 1] ~= nil do arr_end = arr_end + 1 end

    local seen_keys = {}
    for i = 1, arr_end do
      seen_keys[i] = true
      parts[#parts + 1] = inspect_value(val[i], opts, depth + 1, seen)
    end
    -- collect hash part
    local hash_parts = {}
    for k, v in pairs(val) do
      if not seen_keys[k] then
        local ks
        if type(k) == "string" and k:match("^[%a_][%w_]*$") then
          ks = k
        else
          ks = "[" .. inspect_value(k, opts, depth + 1, seen) .. "]"
        end
        hash_parts[#hash_parts + 1] = ks .. " = " .. inspect_value(v, opts, depth + 1, seen)
      end
    end
    table.sort(hash_parts)
    for _, hp in ipairs(hash_parts) do
      parts[#parts + 1] = hp
    end

    seen[val] = nil  -- allow revisiting the same table in different branches

    if #parts == 0 then
      return "{}"
    elseif compact then
      return "{ " .. table.concat(parts, ", ") .. " }"
    else
      local sep = "\n" .. inner_pad
      return "{\n" .. inner_pad .. table.concat(parts, ",\n" .. inner_pad) .. "\n" .. pad .. "}"
    end
  else
    return tostring(val)
  end
end

--- Pretty-print a Lua value for debugging.
-- @param val   any Lua value
-- @param opts  {indent=2, max_depth=4, compact=false}
-- @return      human-readable string representation
function M.inspect(val, opts)
  opts = opts or {}
  return inspect_value(val, opts, 0, {})
end

--- Return an array of byte values from a binary string.
-- @param data  binary string
-- @return      array of integers {72, 101, 108, ...}
--: (string) -> { [integer]: integer, ... }
function M.bytes(data)
  local t = {}
  for i = 1, #data do
    t[i] = string.byte(data, i) --[[:! integer]]
  end
  return t
end

--- Build a binary string from an array of byte values.
-- @param arr  array of integers 0–255
-- @return     binary string
function M.from_bytes(arr)
  local t = {}
  for i = 1, #arr do
    t[i] = string.char(arr[i])
  end
  return table.concat(t)
end

--- Return 8-bit binary string representation of a byte value.
-- @param byte_val  integer 0–255
-- @return          string like "01001000"
function M.to_bin(byte_val)
  local bits = {}
  for i = 7, 0, -1 do
    bits[8 - i] = band(rshift(byte_val, i), 1) == 1 and "1" or "0"
  end
  return table.concat(bits)
end

--- Return octal string representation of a byte value.
-- @param byte_val  integer 0–255
-- @return          octal string (no leading zeros)
function M.to_oct(byte_val)
  if byte_val == 0 then return "0" end
  local digits = {}
  local v = byte_val
  while v > 0 do
    table.insert(digits, 1, tostring(v % 8))
    v = math.floor(v / 8)
  end
  return table.concat(digits)
end

-- FFI structs for float bit inspection
ffi.cdef[[
  typedef union { float  f; uint32_t u; } _hd_f32;
  typedef union { double d; uint64_t u; } _hd_f64;
]]

--- Return the 32-bit IEEE 754 bit pattern of a float as a hex string.
-- @param n  Lua number (treated as float32)
-- @return   8-character hex string e.g. "3f800000"
function M.float_bits(n)
  local u = ffi.new("_hd_f32")
  u.f = n
  local v = tonumber(u.u)
  return string.format("%08x", v)
end

--- Return the 64-bit IEEE 754 bit pattern of a double as a hex string.
-- @param n  Lua number (double)
-- @return   16-character hex string
function M.double_bits(n)
  local u = ffi.new("_hd_f64")
  u.d = n
  -- u.u is uint64_t; split into hi/lo 32 bits
  local lo = tonumber(ffi.cast("uint32_t", u.u))
  local hi = tonumber(ffi.cast("uint32_t", bit.rshift(u.u, 32)))
  return string.format("%08x%08x", hi, lo)
end

return M
