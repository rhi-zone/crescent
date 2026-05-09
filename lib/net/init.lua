-- lib/net/init.lua — network address parsing and manipulation (pure Lua)
-- No I/O, no sockets. Data structures and algorithms for network addresses.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- ── helpers ──────────────────────────────────────────────────────────────────

local function hex2(n)
  return string.format("%02x", n)
end

local function lshift(v, n)
  return v * (2 ^ n)
end

local function rshift(v, n)
  return math.floor(v / (2 ^ n))
end

local function band(a, b)
  -- Pure Lua bitwise AND (works for 32-bit values)
  local r = 0
  local bit = 1
  for _ = 1, 32 do
    if (a % (bit * 2) >= bit) and (b % (bit * 2) >= bit) then
      r = r + bit
    end
    bit = bit * 2
  end
  return r
end

local function bor(a, b)
  local r = 0
  local bit = 1
  for _ = 1, 32 do
    if (a % (bit * 2) >= bit) or (b % (bit * 2) >= bit) then
      r = r + bit
    end
    bit = bit * 2
  end
  return r
end

local function bnot32(v)
  -- bitwise NOT for 32-bit unsigned
  return 0xFFFFFFFF - v
end

-- Check if LuaJIT bit library is available and use it for speed.
-- All wrappers normalize to unsigned 32-bit (Lua double) by % 0x100000000
-- because bit.* returns signed 32-bit integers.
local ok, bit = pcall(require, "bit")
if ok and bit then
  band   = function(a, b) return bit.band(a, b) % 0x100000000 end
  bor    = function(a, b) return bit.bor(a, b)  % 0x100000000 end
  bnot32 = function(v)    return bit.bnot(v)     % 0x100000000 end
  lshift = function(v, n) return bit.lshift(v, n) % 0x100000000 end
  rshift = function(v, n) return bit.rshift(v, n) % 0x100000000 end
end

-- ── IPv4 ─────────────────────────────────────────────────────────────────────

--:: IPv4 = { _n: integer, ... }

local IPv4 = {}
IPv4.__index = IPv4

-- Parse dotted-decimal string; returns (obj) or (nil, errmsg)
function M.ipv4(s)
  if type(s) ~= "string" then
    return nil, "ipv4: expected string, got " .. type(s)
  end
  local a, b, c, d = s:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not a then
    return nil, "ipv4: invalid address: " .. s
  end
  a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
  if a == nil then return nil, "ipv4: invalid address: " .. s end
  if b == nil then return nil, "ipv4: invalid address: " .. s end
  if c == nil then return nil, "ipv4: invalid address: " .. s end
  if d == nil then return nil, "ipv4: invalid address: " .. s end
  if a > 255 or b > 255 or c > 255 or d > 255 then
    return nil, "ipv4: octet out of range in: " .. s
  end
  local n = a * 0x1000000 + b * 0x10000 + c * 0x100 + d
  return setmetatable({ _n = n }, IPv4)
end

-- Construct from 32-bit integer
function M.ipv4_from_number(n)
  if type(n) ~= "number" or n < 0 or n > 0xFFFFFFFF then
    return nil, "ipv4_from_number: value out of range"
  end
  n = math.floor(n)
  return setmetatable({ _n = n }, IPv4)
end

function IPv4:to_number()
  return self._n
end

function IPv4:octets()
  local n = self._n
  return {
    rshift(n, 24) % 256,
    rshift(n, 16) % 256,
    rshift(n, 8)  % 256,
    n % 256,
  }
end

function IPv4:to_string()
  local o = self:octets()
  return o[1] .. "." .. o[2] .. "." .. o[3] .. "." .. o[4]
end

function IPv4:is_loopback()
  -- 127.0.0.0/8
  local n = self._n
  return rshift(n, 24) % 256 == 127
end

function IPv4:is_private()
  -- RFC 1918: 10/8, 172.16/12, 192.168/16
  local n = self._n
  local a = rshift(n, 24) % 256
  local b = rshift(n, 16) % 256
  if a == 10 then return true end
  if a == 172 and b >= 16 and b <= 31 then return true end
  if a == 192 and b == 168 then return true end
  return false
end

function IPv4:is_multicast()
  -- 224.0.0.0/4
  local n = self._n
  return rshift(n, 24) % 256 >= 224 and rshift(n, 24) % 256 <= 239
end

function IPv4:is_broadcast()
  return self._n == 0xFFFFFFFF
end

function IPv4:is_link_local()
  -- 169.254.0.0/16
  local n = self._n
  local a = rshift(n, 24) % 256
  local b = rshift(n, 16) % 256
  return a == 169 and b == 254
end

-- ── IPv6 ─────────────────────────────────────────────────────────────────────

local IPv6 = {}
IPv6.__index = IPv6

-- Expand :: notation, return 8 groups of 16-bit ints or nil, errmsg
local function parse_ipv6_groups(s)
  -- Handle IPv4-mapped: ::ffff:192.168.1.1
  -- Check for embedded IPv4 at the end
  local s_str = s --[[:! string]]
  local ipv4_tail = s_str:match("(%d+%.%d+%.%d+%.%d+)$")
  local prefix = s_str
  local ipv4_groups
  if ipv4_tail then
    -- replace the IPv4 part with two placeholder groups
    local tail = ipv4_tail --[[:! string]]
    prefix = s_str:sub(1, #s_str - #tail)
    if prefix:sub(-1) == ":" then prefix = prefix:sub(1, -2) end
    local a, b, c, d = ipv4_tail:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
    if a == nil then return nil, "ipv6: invalid embedded IPv4" end
    if b == nil then return nil, "ipv6: invalid embedded IPv4" end
    if c == nil then return nil, "ipv6: invalid embedded IPv4" end
    if d == nil then return nil, "ipv6: invalid embedded IPv4" end
    if a > 255 or b > 255 or c > 255 or d > 255 then
      return nil, "ipv6: embedded IPv4 octet out of range"
    end
    ipv4_groups = { a * 256 + b, c * 256 + d }
  end

  -- Split on ::
  local left_str, right_str
  --: string
  local prefix_str = prefix
  local dc_pos = prefix_str:find("::", 1, true)
  if dc_pos then
    left_str  = prefix_str:sub(1, dc_pos - 1)
    right_str = prefix_str:sub(dc_pos + 2)
  else
    left_str  = prefix_str
    right_str = nil
  end

  --: (string) -> ({ [integer]: integer } | nil, string | nil)
  local function split_groups(str)
    if str == "" then return {} end
    local gs = {} --: { [integer]: integer }
    for part in (str .. ":"):gmatch("([^:]*):") do
      if part == "" then return nil, "ipv6: empty group (use :: for zero-run)" end
      local v = tonumber(part, 16)
      if v == nil then
        return nil, "ipv6: invalid group: " .. part
      end
      if v > 0xFFFF then
        return nil, "ipv6: invalid group: " .. part
      end
      gs[#gs + 1] = math.floor(v)
    end
    return gs
  end

  local left, err = split_groups(left_str)
  if not left then return nil, err end
  local right
  if right_str then
    right, err = split_groups(right_str)
    if not right then return nil, err end
  end

  local right_len = 0
  if right then right_len = #(right --[[:! { [integer]: integer }]]) end
  local total_explicit = #left + right_len + (ipv4_groups and 2 or 0)
  if dc_pos then
    if total_explicit > 7 then
      return nil, "ipv6: too many groups with ::"
    end
  else
    if total_explicit + (ipv4_groups and 2 or 0) ~= 8 and not ipv4_groups then
      if #left ~= 8 then
        return nil, "ipv6: wrong number of groups: " .. #left
      end
    end
    if ipv4_groups and #left ~= 6 then
      return nil, "ipv6: wrong number of groups before IPv4 tail"
    end
  end

  local groups = {}
  for i = 1, #left do groups[i] = left[i] end

  if dc_pos then
    local zeros_needed = 8 - total_explicit
    for _ = 1, zeros_needed do
      groups[#groups + 1] = 0
    end
    if right then
      local r = right --[[:! { [integer]: integer }]]
      for i = 1, #r do groups[#groups + 1] = r[i] end
    end
  end

  if ipv4_groups then
    groups[#groups + 1] = ipv4_groups[1]
    groups[#groups + 1] = ipv4_groups[2]
  end

  if #groups ~= 8 then
    return nil, "ipv6: wrong number of groups: " .. #groups
  end
  return groups
end

function M.ipv6(s)
  if type(s) ~= "string" then
    return nil, "ipv6: expected string, got " .. type(s)
  end
  local groups, err = parse_ipv6_groups(s)
  if not groups then return nil, err end
  return setmetatable({ _g = groups }, IPv6)
end

function IPv6:groups()
  local g = self._g
  return { g[1], g[2], g[3], g[4], g[5], g[6], g[7], g[8] }
end

function IPv6:to_full_string()
  local g = self._g
  return string.format(
    "%04x:%04x:%04x:%04x:%04x:%04x:%04x:%04x",
    g[1], g[2], g[3], g[4], g[5], g[6], g[7], g[8]
  )
end

function IPv6:to_string()
  local g = self._g
  -- Find longest run of zeros for :: compression
  local best_start, best_len = nil, 0
  local cur_start, cur_len = nil, 0
  for i = 1, 8 do
    if g[i] == 0 then
      if cur_start then
        cur_len = cur_len + 1
      else
        cur_start, cur_len = i, 1
      end
    else
      if cur_start and cur_len > best_len then
        best_start, best_len = cur_start, cur_len
      end
      cur_start, cur_len = nil, 0
    end
  end
  if cur_start and cur_len > best_len then
    best_start, best_len = cur_start, cur_len
  end

  -- Only compress if 2+ consecutive zeros
  if best_len < 2 then
    best_start, best_len = nil, 0
  end

  local parts = {}
  local i = 1
  while i <= 8 do
    if best_start and i == best_start then
      parts[#parts + 1] = ""  -- will become :: when joined
      i = i + best_len
    else
      parts[#parts + 1] = string.format("%x", g[i])
      i = i + 1
    end
  end

  local result = table.concat(parts, ":")
  -- Fix up leading/trailing :: vs single :
  if best_start then
    local bs = best_start --[[:! integer]]
    if bs == 1 then
      result = ":" .. result
    end
    if bs + best_len - 1 == 8 then
      result = result .. ":"
    end
  end
  return result
end

function IPv6:is_loopback()
  local g = self._g
  return g[1] == 0 and g[2] == 0 and g[3] == 0 and g[4] == 0
     and g[5] == 0 and g[6] == 0 and g[7] == 0 and g[8] == 1
end

function IPv6:is_link_local()
  -- fe80::/10
  return rshift(self._g[1], 6) == 0x3FA  -- 0xFE80 >> 6 = 0x3FA
end

function IPv6:is_multicast()
  -- ff00::/8
  return rshift(self._g[1], 8) % 256 == 0xFF
end

-- ── CIDR ─────────────────────────────────────────────────────────────────────

--:: CIDR = { _net: integer, _prefix: integer, _mask: integer, network: (self: CIDR) -> (IPv4 | nil, string | nil), broadcast: (self: CIDR) -> (IPv4 | nil, string | nil), ... }

local CIDR = {}
CIDR.__index = CIDR

function M.cidr(s)
  if type(s) ~= "string" then
    return nil, "cidr: expected string, got " .. type(s)
  end
  local addr_str, prefix_str = s:match("^([^/]+)/(%d+)$")
  if not addr_str then
    return nil, "cidr: invalid CIDR notation: " .. s
  end
  local prefix_raw = tonumber(prefix_str)
  if prefix_raw == nil then
    return nil, "cidr: prefix length out of range: " .. tostring(prefix_str)
  end
  if prefix_raw > 32 then
    return nil, "cidr: prefix length out of range: " .. tostring(prefix_str)
  end
  local prefix = math.floor(prefix_raw)
  local ip, err = M.ipv4(addr_str)
  if not ip then
    return nil, "cidr: " .. tostring(err)
  end
  -- Mask the address to get the network address
  local mask
  if prefix == 0 then
    mask = 0
  else
    mask = bnot32(rshift(0xFFFFFFFF, prefix))
    -- Clamp to 32-bit unsigned
    mask = mask % 0x100000000
  end
  local net_n = band(ip:to_number(), mask)
  return setmetatable({ _net = net_n, _prefix = prefix, _mask = mask }, CIDR)
end

function CIDR:prefix_len()
  return self._prefix
end

--: (unknown) -> integer
local function as_int(v)
  if type(v) == "number" then return math.floor(v) end
  return 0
end

function CIDR:network()
  return M.ipv4_from_number(as_int(self._net))
end

function CIDR:netmask()
  return M.ipv4_from_number(as_int(self._mask))
end

function CIDR:broadcast()
  local mask = as_int(self._mask)
  local net  = as_int(self._net)
  local inv_mask = bnot32(mask) % 0x100000000
  return M.ipv4_from_number(math.floor(bor(net, inv_mask)))
end

function CIDR:contains(ip)
  local n = ip:to_number()
  return band(n, as_int(self._mask)) == self._net
end

function CIDR:host_count()
  local prefix = as_int(self._prefix)
  if prefix >= 31 then return 0 end
  return rshift(0xFFFFFFFF, prefix) % 0x100000000 - 1
end

function CIDR:first_host()
  local prefix = as_int(self._prefix)
  if prefix >= 31 then return (self --[[:! CIDR]]):network() end
  return M.ipv4_from_number(as_int(self._net) + 1)
end

function CIDR:last_host()
  local prefix = as_int(self._prefix)
  if prefix >= 31 then return (self --[[:! CIDR]]):broadcast() end
  local net  = as_int(self._net)
  local mask = as_int(self._mask)
  local bcast = bor(net, bnot32(mask) % 0x100000000)
  return M.ipv4_from_number(math.floor(bcast - 1))
end

function CIDR:iter_hosts()
  local prefix = as_int(self._prefix)
  if prefix >= 31 then
    return function() return nil end
  end
  local net  = as_int(self._net)
  local mask = as_int(self._mask)
  local first = net + 1
  local last_n = bor(net, bnot32(mask) % 0x100000000) - 1
  local cur = first - 1
  return function()
    cur = cur + 1
    if cur > last_n then return nil end
    return M.ipv4_from_number(cur)
  end
end

function CIDR:to_string()
  return self:network():to_string() .. "/" .. tostring(self._prefix)
end

-- Find the smallest CIDR containing two IP addresses
function M.supernet(a_str, b_str)
  local a, err = M.ipv4(a_str)
  if not a then return nil, err end
  local b
  b, err = M.ipv4(b_str)
  if not b then return nil, err end

  local an = a:to_number()
  local bn = b:to_number()
  -- XOR to find differing bits, then find the prefix
  local diff = an
  -- Manual XOR
  diff = an + bn - 2 * band(an, bn)  -- XOR = a + b - 2*(a AND b)

  -- Find highest set bit in diff to determine prefix length
  local prefix = 32
  if diff > 0 then
    local v = diff
    while v > 0 do
      v = rshift(v, 1)
      prefix = prefix - 1
    end
  end

  local mask
  if prefix == 0 then
    mask = 0
  else
    mask = bnot32(rshift(0xFFFFFFFF, prefix)) % 0x100000000
  end
  local net_n = band(an, mask)
  local cidr_obj = setmetatable({ _net = net_n, _prefix = prefix, _mask = mask }, CIDR)
  return cidr_obj
end

-- ── URL ──────────────────────────────────────────────────────────────────────

--: (string) -> string
local function decode_percent(s)
  local out = s:gsub("%%(%x%x)", function(h)
    if type(h) ~= "string" then return "" end
    local n = tonumber(h, 16)
    if n == nil then return "" end
    return string.char(math.floor(n))
  end)
  return tostring(out)
end

--: (string, string) -> string
local function encode_percent(s, safe_pattern)
  local out = s:gsub("[^" .. safe_pattern .. "]", function(c)
    if type(c) ~= "string" then return "" end
    return string.format("%%%02X", c:byte())
  end)
  return tostring(out)
end

-- RFC 3986 unreserved chars
local UNRESERVED = "A-Za-z0-9%-._~"

function M.url_encode(s)
  if type(s) ~= "string" then return nil, "url_encode: expected string" end
  return encode_percent(s, UNRESERVED)
end

function M.url_decode(s)
  if type(s) ~= "string" then return nil, "url_decode: expected string" end
  return decode_percent(s)
end

-- Query string: spaces as +, encode everything else except unreserved
function M.query_encode(params)
  if type(params) ~= "table" then return nil, "query_encode: expected table" end
  local parts = {}
  -- Sort keys for deterministic output
  local keys = {}
  for k in pairs(params) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do
    local v = tostring(params[k])
    local ek = encode_percent(tostring(k), UNRESERVED):gsub("%%20", "+")
    local ev = encode_percent(v, UNRESERVED):gsub("%%20", "+")
    parts[#parts + 1] = ek .. "=" .. ev
  end
  return table.concat(parts, "&")
end

function M.query_decode(s)
  if type(s) ~= "string" then return nil, "query_decode: expected string" end
  local result = {}
  for pair in (s .. "&"):gmatch("([^&]*)&") do
    if pair ~= "" then
      local k, v = pair:match("^([^=]*)=(.*)$")
      if k then
        k = decode_percent(k:gsub("%+", " "))
        v = decode_percent(v:gsub("%+", " "))
        result[k] = v
      else
        -- key only, no value
        local key = decode_percent(pair:gsub("%+", " "))
        result[key] = ""
      end
    end
  end
  return result
end

-- Parse a URL into components
-- Returns table or (nil, errmsg)
function M.url_parse(s)
  if type(s) ~= "string" then return nil, "url_parse: expected string" end

  local url = {}

  -- scheme
  local rest = s
  local scheme, after_scheme = rest:match("^([A-Za-z][A-Za-z0-9+%-.]*):(//?.*)$")
  if scheme then
    url.scheme = scheme:lower()
    rest = after_scheme
  else
    return nil, "url_parse: missing or invalid scheme in: " .. s
  end

  -- authority (//...)
  if rest:sub(1, 2) == "//" then
    rest = rest:sub(3)
    -- authority ends at first /, ?, or #
    local authority, tail = rest:match("^([^/?#]*)(.*)$")
    rest = tail

    -- userinfo
    local userinfo, host_port = authority:match("^([^@]*)@(.+)$")
    if not userinfo then
      host_port = authority
    else
      local user, pass = userinfo:match("^([^:]*):(.*)")
      if user then
        url.user     = decode_percent(user)
        url.password = decode_percent(pass)
      else
        url.user = decode_percent(userinfo)
      end
    end

    -- host and port
    -- IPv6 literal
    local ipv6_host, port_str = host_port:match("^%[([^%]]+)%]:?(%d*)$")
    if ipv6_host then
      url.host = ipv6_host
      url.port = port_str ~= "" and tonumber(port_str) or nil
    else
      local host, port_s = host_port:match("^([^:]*):?(%d*)$")
      url.host = host ~= "" and host or nil
      url.port = port_s ~= "" and tonumber(port_s) or nil
    end
  end

  -- path
  local path, query_frag = (rest --[[:! string]]):match("^([^?#]*)(.*)$")
  url.path = path ~= "" and path or nil

  -- query
  if query_frag:sub(1, 1) == "?" then
    local q, frag = query_frag:sub(2):match("^([^#]*)(.*)$")
    url.query = q ~= "" and q or nil
    query_frag = frag
    if url.query then
      url.query_params = M.query_decode(url.query)
    end
  end

  -- fragment
  if query_frag:sub(1, 1) == "#" then
    url.fragment = query_frag:sub(2)
    if url.fragment == "" then url.fragment = nil end
  end

  return url
end

-- Reconstruct URL from components table
function M.url_build(url)
  if type(url) ~= "table" then return nil, "url_build: expected table" end
  local parts = {}
  if url.scheme then
    parts[#parts + 1] = url.scheme .. "://"
  end
  if url.user then
    parts[#parts + 1] = encode_percent(url.user, UNRESERVED)
    if url.password then
      parts[#parts + 1] = ":" .. encode_percent(url.password, UNRESERVED)
    end
    parts[#parts + 1] = "@"
  end
  if url.host then
    parts[#parts + 1] = url.host
  end
  if url.port then
    parts[#parts + 1] = ":" .. tostring(url.port)
  end
  if url.path then
    parts[#parts + 1] = url.path
  end
  if url.query then
    parts[#parts + 1] = "?" .. url.query
  end
  if url.fragment then
    parts[#parts + 1] = "#" .. url.fragment
  end
  return table.concat(parts)
end

-- ── MAC address ───────────────────────────────────────────────────────────────

local MAC = {}
MAC.__index = MAC

-- Accept colon-separated (00:1A:2B:...) or dash-separated (00-1A-2B-...)
function M.mac(s)
  if type(s) ~= "string" then
    return nil, "mac: expected string, got " .. type(s)
  end
  local sep
  if s:find(":", 1, true) then
    sep = ":"
  elseif s:find("-", 1, true) then
    sep = "-"
  else
    return nil, "mac: invalid MAC address: " .. s
  end

  local octets = {}
  for part in (s .. sep):gmatch("([^" .. sep .. "]*)" .. sep) do
    if #octets >= 6 then
      return nil, "mac: too many octets in: " .. s
    end
    if #part ~= 2 then
      return nil, "mac: octet must be 2 hex digits: " .. part
    end
    local v = tonumber(part, 16)
    if not v then
      return nil, "mac: invalid hex octet: " .. part
    end
    octets[#octets + 1] = v
  end
  if #octets ~= 6 then
    return nil, "mac: wrong number of octets: " .. #octets
  end
  return setmetatable({ _o = octets }, MAC)
end

function MAC:octets()
  local o = self._o
  return { o[1], o[2], o[3], o[4], o[5], o[6] }
end

function MAC:to_colon_string()
  local o = self._o
  return string.format("%02x:%02x:%02x:%02x:%02x:%02x",
    o[1], o[2], o[3], o[4], o[5], o[6])
end

function MAC:to_dash_string()
  local o = self._o
  return string.format("%02x-%02x-%02x-%02x-%02x-%02x",
    o[1], o[2], o[3], o[4], o[5], o[6])
end

-- Canonical: lowercase colon-separated
function MAC:to_string()
  return self:to_colon_string()
end

function MAC:is_broadcast()
  local o = self._o
  return o[1] == 0xFF and o[2] == 0xFF and o[3] == 0xFF
     and o[4] == 0xFF and o[5] == 0xFF and o[6] == 0xFF
end

function MAC:is_multicast()
  -- LSB of first octet set → multicast
  return (self._o[1] % 2) == 1
end

function MAC:oui()
  local o = self._o
  return string.format("%02x:%02x:%02x", o[1], o[2], o[3])
end

return M
