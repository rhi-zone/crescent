if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- Shamir's Secret Sharing over GF(256).
-- Splits a secret into n shares such that any k reconstruct it,
-- but k-1 shares reveal nothing (information-theoretic security).
--
-- GF(256) uses the AES irreducible polynomial x^8+x^4+x^3+x+1 (0x11B).
-- Addition = XOR. Multiplication via log/exp tables for O(1).

local bit = require("bit")

local M = {}

M._tier = "pure"

-- GF(256) tables using primitive polynomial 0x11B.
-- Generator g = 0x03.
--: { [integer]: integer }
local GF_EXP = {}  -- gf_exp[i] = g^i, indices 0..254 (255 wraps to 1)
--: { [integer]: integer }
local GF_LOG = {}  -- gf_log[x] = discrete log base g of x (for x != 0)

do
  local x = 1
  for i = 0, 254 do
    GF_EXP[i] = x
    GF_LOG[x] = i
    -- multiply x by g=3 in GF(256): x*3 = x XOR (x<<1 mod poly)
    local x2 = x * 2  -- shift left
    if x2 >= 256 then x2 = bit.bxor(x2, 0x11B) end
    x = bit.bxor(x, x2)
  end
  -- extend exp table to avoid modular reduction in multiply
  for i = 255, 511 do
    GF_EXP[i] = GF_EXP[i - 255]
  end
  GF_EXP[255] = 1  -- g^255 = 1 (order is 255)
  -- GF_LOG[0] is undefined (log of 0), so we leave it unset
end

local function gf_mul(a, b)
  if a == 0 or b == 0 then return 0 end
  return GF_EXP[(GF_LOG[a] + GF_LOG[b]) % 255]
end

local function gf_div(a, b)
  if b == 0 then error("GF division by zero") end
  if a == 0 then return 0 end
  return GF_EXP[(GF_LOG[a] - GF_LOG[b] + 255) % 255]
end

local function gf_pow(a, n)
  if n == 0 then return 1 end
  if a == 0 then return 0 end
  return GF_EXP[(GF_LOG[a] * n) % 255]
end

-- Evaluate polynomial (coeffs[1] = constant term) at x in GF(256).
-- Uses Horner's method.
local function poly_eval(coeffs, x)
  local result = coeffs[#coeffs]
  for i = #coeffs - 1, 1, -1 do
    result = bit.bxor(gf_mul(result, x), coeffs[i])
  end
  return result
end

-- Lagrange interpolation at x=0 over GF(256).
-- xs: array of x-coordinates, ys: corresponding y-coordinates.
local function lagrange_at_zero(xs, ys)
  local k = #xs
  local result = 0
  for i = 1, k do
    local num = ys[i]
    local den = 1
    for j = 1, k do
      if i ~= j then
        -- numerator *= xs[j]  (x=0, so x - xs[j] = xs[j])
        num = gf_mul(num, xs[j])
        -- denominator *= xs[j] - xs[i] = XOR in GF
        den = gf_mul(den, bit.bxor(xs[j], xs[i]))
      end
    end
    result = bit.bxor(result, gf_div(num, den))
  end
  return result
end

-- split(secret, n, k) -> shares or nil, errmsg
-- secret: binary string
-- n: total shares (2..255)
-- k: threshold (2..n)
-- Returns array of n tables {x=int, y=binary_string}
function M.split(secret, n, k)
  if type(secret) ~= "string" then
    return nil, "secret must be a string"
  end
  if type(n) ~= "number" or n < 2 or n > 255 or math.floor(n) ~= n then
    return nil, "n must be an integer 2..255"
  end
  if type(k) ~= "number" or k < 2 or k > n or math.floor(k) ~= k then
    return nil, "k must be an integer 2..n"
  end

  local len = #secret
  -- Prepare share byte buffers as arrays of numbers (one per share)
  local share_bytes = {}
  for i = 1, n do share_bytes[i] = {} end

  for bi = 1, len do
    local secret_byte = secret:byte(bi)
    -- Build random polynomial of degree k-1 with constant = secret_byte
    local coeffs = { secret_byte }
    for ci = 2, k do
      coeffs[ci] = math.random(0, 255)
    end
    -- Evaluate at x = 1..n
    for xi = 1, n do
      share_bytes[xi][bi] = poly_eval(coeffs, xi)
    end
  end

  -- Convert to share objects
  local shares = {}
  for i = 1, n do
    local buf = share_bytes[i]
    -- Build string from byte array
    local chars = {}
    for bi = 1, len do chars[bi] = string.char(buf[bi]) end
    shares[i] = { x = i, y = table.concat(chars) }
  end
  return shares
end

-- join(shares) -> secret or nil, errmsg
-- shares: array of {x=int, y=binary_string} (k or more)
function M.join(shares)
  if type(shares) ~= "table" then
    return nil, "shares must be an array"
  end
  local k = #shares
  if k < 2 then
    return nil, "need at least 2 shares to reconstruct"
  end

  -- Validate and extract xs/ys
  local xs = {}
  local seen = {}
  local len = nil

  for i = 1, k do
    local s = shares[i]
    if type(s) ~= "table" then
      return nil, "share " .. i .. " is not a table"
    end
    local x = s.x
    local y = s.y
    if type(x) ~= "number" or x < 1 or x > 255 or math.floor(x) ~= x then
      return nil, "share " .. i .. " has invalid x: " .. tostring(x)
    end
    if type(y) ~= "string" then
      return nil, "share " .. i .. " y must be a string"
    end
    if seen[x] then
      return nil, "duplicate x value: " .. x
    end
    seen[x] = true
    xs[i] = x
    if len == nil then
      len = #y
    elseif #y ~= len then
      return nil, "share " .. i .. " has inconsistent length"
    end
  end

  -- Reconstruct byte by byte
  local out = {}
  local ys = {}
  for bi = 1, len do
    for i = 1, k do ys[i] = shares[i].y:byte(bi) end
    out[bi] = string.char(lagrange_at_zero(xs, ys))
  end
  return table.concat(out)
end

-- encode_shares(shares) -> array of hex strings "XX:yyhex..."
function M.encode_shares(shares)
  local result = {}
  for i, s in ipairs(shares) do
    local x_hex = string.format("%02x", s.x)
    local y_hex = s.y:gsub(".", function(c) return string.format("%02x", c:byte()) end)
    result[i] = x_hex .. ":" .. y_hex
  end
  return result
end

-- decode_shares(hex_strings) -> shares or nil, errmsg
function M.decode_shares(hex_strings)
  if type(hex_strings) ~= "table" then
    return nil, "hex_strings must be an array"
  end
  local shares = {}
  local hex_strings_ = hex_strings --[[:! { [integer]: unknown }]]
  for i, s in ipairs(hex_strings_) do
    local i_ = tostring(i)
    if type(s) ~= "string" then
      return nil, "entry " .. i_ .. " is not a string"
    end
    local s_ = s --[[:! string]]
    local x_hex, y_hex = s_:match("^(%x%x):(%x*)$")
    if not x_hex then
      return nil, "entry " .. i_ .. " has invalid format (expected XX:yyhex)"
    end
    -- y_hex length must be even
    if #y_hex % 2 ~= 0 then
      return nil, "entry " .. i_ .. " y hex has odd length"
    end
    local x = tonumber(x_hex, 16)
    local y_bytes = {}
    local pos = 1
    while pos <= #y_hex do
      y_bytes[#y_bytes + 1] = string.char(tonumber(y_hex:sub(pos, pos+1), 16))
      pos = pos + 2
    end
    shares[i] = { x = x, y = table.concat(y_bytes) }
  end
  return shares
end

-- split_hex(secret, n, k) -> hex_shares or nil, errmsg
function M.split_hex(secret, n, k)
  local shares, err = M.split(secret, n, k)
  if not shares then return nil, err end
  return M.encode_shares(shares)
end

-- join_hex(hex_shares) -> secret or nil, errmsg
function M.join_hex(hex_shares)
  local shares, err = M.decode_shares(hex_shares)
  if not shares then return nil, err end
  return M.join(shares)
end

return M
