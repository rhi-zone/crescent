-- lib/oauth2/init.lua
-- OAuth2 client library (RFC 6749) with injectable HTTP transport.
--
-- Supported flows:
--   client_credentials  — machine-to-machine (RFC 6749 §4.4)
--   authorization_code  — browser redirect + exchange (RFC 6749 §4.1)
--   refresh_token       — token refresh (RFC 6749 §6)
--   token introspection — (RFC 7662)
--
-- PKCE (RFC 7636) — code_verifier + code_challenge (SHA256/base64url).
-- SHA256 is implemented inline (pure Lua, ~80 lines) for spec compliance.
-- Token store — in-memory, with expiry tracking.
--
-- HTTP is fully injected: pass `http = { post = fn(url, headers, body) -> {status, body} }`.
-- No network calls in pure helpers (URL building, token parsing, JWT decode).

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local bit = require("bit")
--: (...number) -> number
local function band(...) return bit.band(... --[[: any]]) end
--: (...number) -> number
local function bor(...) return bit.bor(... --[[: any]]) end
--: (...number) -> number
local function bxor(...) return bit.bxor(... --[[: any]]) end
--: (number, number) -> number
local function rshift(a, b) return bit.rshift(a --[[: any]], b --[[: any]]) end
--: (number, number) -> number
local function lshift(a, b) return bit.lshift(a --[[: any]], b --[[: any]]) end
--: (number) -> number
local function bnot(a) return bit.bnot(a --[[: any]]) end

-- ── Inline pure-Lua SHA-256 ───────────────────────────────────────────────────
-- Returns 32-byte binary string.

local K = { --: { [integer]: number }
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
  0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
  0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
  0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
  0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
  0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function rotr32(x, n) return bor(rshift(x, n), lshift(x, 32 - n)) end

local function sha256(msg)
  local len = #msg
  -- Pre-processing: pad message
  local pad_len = 64 - (len + 9) % 64
  if pad_len == 64 then pad_len = 0 end
  msg = msg .. "\x80" .. string.rep("\0", pad_len) .. string.char(
    0, 0, 0, 0,
    band(rshift(len * 8, 24), 0xff),
    band(rshift(len * 8, 16), 0xff),
    band(rshift(len * 8,  8), 0xff),
    band(len * 8,             0xff)
  )

  local h0 = 0x6a09e667 --: number
  local h1 = 0xbb67ae85 --: number
  local h2 = 0x3c6ef372 --: number
  local h3 = 0xa54ff53a --: number
  local h4 = 0x510e527f --: number
  local h5 = 0x9b05688c --: number
  local h6 = 0x1f83d9ab --: number
  local h7 = 0x5be0cd19 --: number

  for i = 1, #msg, 64 do
    local w = {} --: { [integer]: number }
    for j = 0, 15 do
      local o = i + j * 4
      local a, b, c, d = msg:byte(o, o + 3)
      w[j] = bor(lshift(a --[[: integer]], 24), lshift(b --[[: integer]], 16), lshift(c --[[: integer]], 8), d --[[: integer]])
    end
    for j = 16, 63 do
      local s0 = bxor(rotr32(w[j-15], 7), rotr32(w[j-15], 18), rshift(w[j-15], 3))
      local s1 = bxor(rotr32(w[j-2], 17), rotr32(w[j-2], 19), rshift(w[j-2], 10))
      w[j] = band(w[j-16] + s0 + w[j-7] + s1, 0xffffffff)
    end

    local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
    for j = 0, 63 do
      local S1 = bxor(rotr32(e, 6), rotr32(e, 11), rotr32(e, 25))
      local ch = bxor(band(e, f), band(bnot(e), g))
      local temp1 = band(h + S1 + ch + K[j+1] + w[j], 0xffffffff)
      local S0 = bxor(rotr32(a, 2), rotr32(a, 13), rotr32(a, 22))
      local maj = bxor(band(a, b), band(a, c), band(b, c))
      local temp2 = band(S0 + maj, 0xffffffff)
      h = g; g = f; f = e
      e = band(d + temp1, 0xffffffff)
      d = c; c = b; b = a
      a = band(temp1 + temp2, 0xffffffff)
    end
    h0 = band(h0 + a, 0xffffffff)
    h1 = band(h1 + b, 0xffffffff)
    h2 = band(h2 + c, 0xffffffff)
    h3 = band(h3 + d, 0xffffffff)
    h4 = band(h4 + e, 0xffffffff)
    h5 = band(h5 + f, 0xffffffff)
    h6 = band(h6 + g, 0xffffffff)
    h7 = band(h7 + h, 0xffffffff)
  end

  local function w32(x)
    return string.char(
      band(rshift(x, 24), 0xff),
      band(rshift(x, 16), 0xff),
      band(rshift(x,  8), 0xff),
      band(x,             0xff)
    )
  end
  return w32(h0)..w32(h1)..w32(h2)..w32(h3)..w32(h4)..w32(h5)..w32(h6)..w32(h7)
end

-- ── Inline base64url (no padding) ────────────────────────────────────────────

local URL64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
local url_enc = {} --: { [integer]: integer }
for i = 1, 64 do url_enc[i - 1] = URL64:byte(i) or 0 end
local url_dec = {} --: { [integer]: integer }
for i = 1, 64 do url_dec[URL64:byte(i) or 0] = i - 1 end

--: (s: string) -> string
local function base64url_encode(s)
  local n = #s
  local rem = n % 3
  local t = {}
  local k = 1
  for i = 1, n - rem, 3 do
    local ba, bb, bc = s:byte(i, i + 2)
    local a, b, c = ba or 0, bb or 0, bc or 0
    local v = a * 0x10000 + b * 0x100 + c
    t[k] = string.char(
      url_enc[band(rshift(v, 18), 0x3f)],
      url_enc[band(rshift(v, 12), 0x3f)],
      url_enc[band(rshift(v,  6), 0x3f)],
      url_enc[band(v,             0x3f)]
    )
    k = k + 1
  end
  if rem == 2 then
    local ba, bb = s:byte(n - 1, n)
    local a, b = ba or 0, bb or 0
    local v = a * 0x10000 + b * 0x100
    t[k] = string.char(
      url_enc[band(rshift(v, 18), 0x3f)],
      url_enc[band(rshift(v, 12), 0x3f)],
      url_enc[band(rshift(v,  6), 0x3f)]
    )
  elseif rem == 1 then
    local v = (s:byte(n) or 0) * 0x10000
    t[k] = string.char(
      url_enc[band(rshift(v, 18), 0x3f)],
      url_enc[band(rshift(v, 12), 0x3f)]
    )
  end
  return table.concat(t)
end

--: (input: string) -> (string | nil, string | nil)
local function base64url_decode(input)
  -- Add padding
  local rem = #input % 4
  local s = input
  if rem == 2 then s = input .. "==" elseif rem == 3 then s = input .. "=" end
  local n = #s
  local bytes = {} --: { [integer]: integer }
  local nb = 0 --: integer
  for i = 1, n do
    local byte = string.byte(s, i)
    if byte ~= nil and byte ~= 0x3d then -- skip '='
      nb = nb + 1
      bytes[nb] = byte
    end
  end
  if nb == 0 then return "" end
  local t = {}
  local k = 1
  local rem2 = nb % 4
  for i = 1, nb - rem2, 4 do
    local da = url_dec[bytes[i]]
    local db = url_dec[bytes[i+1]]
    local dc = url_dec[bytes[i+2]]
    local dd = url_dec[bytes[i+3]]
    if not da or not db or not dc or not dd then
      return nil, "invalid base64url at position " .. i
    end
    local v = da * 0x40000 + db * 0x1000 + dc * 0x40 + dd
    t[k] = string.char(band(rshift(v,16),0xff), band(rshift(v,8),0xff), band(v,0xff))
    k = k + 1
  end
  if rem2 == 3 then
    local da, db, dc = url_dec[bytes[nb-2]], url_dec[bytes[nb-1]], url_dec[bytes[nb]]
    if not da or not db or not dc then return nil, "invalid base64url in final group" end
    local v = da * 0x40000 + db * 0x1000 + dc * 0x40
    t[k] = string.char(band(rshift(v,16),0xff), band(rshift(v,8),0xff))
  elseif rem2 == 2 then
    local da, db = url_dec[bytes[nb-1]], url_dec[bytes[nb]]
    if not da or not db then return nil, "invalid base64url in final group" end
    local v = da * 0x40000 + db * 0x1000
    t[k] = string.char(band(rshift(v,16),0xff))
  end
  return table.concat(t)
end

-- ── Minimal JSON parser (subset needed for token responses) ──────────────────
-- Handles flat objects with string/number/boolean/null values.
-- Returns a Lua table or (nil, errmsg).

--: (s: string) -> (unknown, string | nil)
local function json_parse(s)
  local pos = 1
  local function skip()
    while pos <= #s and (s:byte(pos) or 0) <= 32 do pos = pos + 1 end
  end
  local function parse_value()
    skip()
    local c = s:byte(pos)
    -- String
    if c == 0x22 then -- '"'
      pos = pos + 1
      local buf = {}
      while pos <= #s do
        local ch = s:byte(pos)
        if ch == 0x22 then pos = pos + 1; break end
        if ch == 0x5c then -- backslash
          pos = pos + 1
          local esc = s:byte(pos)
          if esc == 0x22 then buf[#buf+1] = '"'
          elseif esc == 0x5c then buf[#buf+1] = '\\'
          elseif esc == 0x2f then buf[#buf+1] = '/'
          elseif esc == 0x62 then buf[#buf+1] = '\b'
          elseif esc == 0x66 then buf[#buf+1] = '\f'
          elseif esc == 0x6e then buf[#buf+1] = '\n'
          elseif esc == 0x72 then buf[#buf+1] = '\r'
          elseif esc == 0x74 then buf[#buf+1] = '\t'
          else buf[#buf+1] = string.char(esc) end
        else
          buf[#buf+1] = string.char(ch)
        end
        pos = pos + 1
      end
      return table.concat(buf)
    end
    -- Number
    local cn = c or -1
    if (cn >= 0x30 and cn <= 0x39) or cn == 0x2d then -- 0-9 or -
      local start = pos
      if cn == 0x2d then pos = pos + 1 end
      while pos <= #s and (s:byte(pos) or 0) >= 0x30 and (s:byte(pos) or 0) <= 0x39 do pos = pos + 1 end
      if pos <= #s and s:byte(pos) == 0x2e then
        pos = pos + 1
        while pos <= #s and (s:byte(pos) or 0) >= 0x30 and (s:byte(pos) or 0) <= 0x39 do pos = pos + 1 end
      end
      if pos <= #s and (s:byte(pos) == 0x65 or s:byte(pos) == 0x45) then
        pos = pos + 1
        if pos <= #s and (s:byte(pos) == 0x2b or s:byte(pos) == 0x2d) then pos = pos + 1 end
        while pos <= #s and (s:byte(pos) or 0) >= 0x30 and (s:byte(pos) or 0) <= 0x39 do pos = pos + 1 end
      end
      return tonumber(s:sub(start, pos - 1))
    end
    -- Boolean / null
    if s:sub(pos, pos+3) == "true" then pos = pos + 4; return true end
    if s:sub(pos, pos+4) == "false" then pos = pos + 5; return false end
    if s:sub(pos, pos+3) == "null" then pos = pos + 4; return nil end
    -- Array (shallow support)
    if c == 0x5b then -- '['
      pos = pos + 1
      local arr = {}
      skip()
      if s:byte(pos) == 0x5d then pos = pos + 1; return arr end
      while true do
        local v = parse_value()
        arr[#arr+1] = v
        skip()
        local nc = s:byte(pos)
        if nc == 0x5d then pos = pos + 1; break
        elseif nc == 0x2c then pos = pos + 1
        else break end
      end
      return arr
    end
    -- Object
    if c == 0x7b then -- '{'
      pos = pos + 1
      local obj = {}
      skip()
      if s:byte(pos) == 0x7d then pos = pos + 1; return obj end
      while true do
        skip()
        local key = parse_value()
        if type(key) ~= "string" then return nil end
        skip()
        if s:byte(pos) ~= 0x3a then return nil end -- ':'
        pos = pos + 1
        local val = parse_value()
        obj[key] = val
        skip()
        local nc = s:byte(pos)
        if nc == 0x7d then pos = pos + 1; break
        elseif nc == 0x2c then pos = pos + 1
        else break end
      end
      return obj
    end
    return nil
  end
  local ok2, result = pcall(parse_value)
  if not ok2 then return nil, "json parse error: " .. tostring(result) end
  return result
end

-- ── URL helpers ───────────────────────────────────────────────────────────────

local HEX = "0123456789ABCDEF"

--: (c: string) -> string
local function url_encode_char(c)
  local b = c:byte(1) or 0
  local hi = math.floor(b / 16) + 1
  local lo = (b % 16) + 1
  return "%" .. HEX:sub(hi, hi) .. HEX:sub(lo, lo)
end

-- Percent-encode a single parameter value (RFC 3986 unreserved chars pass through).
--: (s: string) -> string
local function url_encode(s)
  local r = s:gsub("[^%w%-%.%_%~]", url_encode_char)
  return r
end

-- ── Public API ────────────────────────────────────────────────────────────────

local M = {}
M._tier = "pure"

-- Build a URL by appending query parameters.
-- params: table of key=value pairs (ordered by pairs iteration).
-- Returns: URL string.
--: (base_url: string, params: { [string]: string }) -> string
function M.build_auth_url(base_url, params)
  local parts = {} --: { [integer]: string }
  for k, v in pairs(params) do
    parts[#parts+1] = url_encode(tostring(k)) .. "=" .. url_encode(tostring(v))
  end
  table.sort(parts) -- deterministic for tests
  if #parts == 0 then return base_url end
  return base_url .. "?" .. table.concat(parts, "&")
end

-- Parse a JSON token response string.
-- Returns: table with access_token, token_type, expires_in, scope, etc., or (nil, errmsg).
function M.parse_token_response(json_str)
  local obj, err = json_parse(json_str)
  if not obj then return nil, err or "invalid JSON" end
  if type(obj) ~= "table" then return nil, "expected JSON object" end
  if not obj.access_token then return nil, "missing access_token" end
  return obj
end

-- Parse a JSON OAuth error response string.
-- Returns: table with `error` and optional `error_description`, or (nil, errmsg).
function M.parse_error_response(json_str)
  local obj, err = json_parse(json_str)
  if not obj then return nil, err or "invalid JSON" end
  if type(obj) ~= "table" then return nil, "expected JSON object" end
  if not obj["error"] then return nil, "missing error field" end
  return obj
end

-- PKCE: generate code_verifier (random URL-safe string, 43-128 chars per RFC 7636)
-- and code_challenge = BASE64URL(SHA256(verifier)).
-- Uses LuaJIT FFI getrandom or /dev/urandom for randomness.
-- Falls back to math.random seeded with time_fn() if FFI unavailable.
-- Returns: verifier (string), challenge (string) or (nil, errmsg).
--: (opts: { time_fn: () -> number }) -> (string, string)
function M.pkce(opts)
  assert(opts and opts.time_fn, "pkce requires opts.time_fn")
  -- Generate 32 random bytes → 43 base64url chars (enough entropy, spec min is 43).
  local raw --: string | nil
  local ok_ffi, ffi = pcall(require, "ffi")
  if ok_ffi then
    pcall(ffi.cdef, "long syscall(long number, ...); int open(const char*, int); ssize_t read(int, void*, size_t); int close(int);")
    local buf = ffi.new("uint8_t[32]")
    local got = false
    -- Try getrandom
    local SYS_getrandom = ffi.arch == "x64" and 318 or (ffi.arch == "arm64" and 278 or nil)
    if SYS_getrandom then
      local ret = ffi.C.syscall(ffi.cast("long", SYS_getrandom),
        ffi.cast("void*", buf), ffi.cast("size_t", 32), ffi.cast("long", 0))
      if tonumber(ret) == 32 then got = true end
    end
    if not got then
      local fd = ffi.C.open("/dev/urandom", 0)
      if fd >= 0 then
        local n = ffi.C.read(fd, buf, 32)
        ffi.C.close(fd)
        if tonumber(n) == 32 then got = true end
      end
    end
    if got then
      raw = ffi.string(buf, 32) --[[: string]]
    end
  end
  if not raw then
    -- Pure Lua fallback: use math.random (not cryptographically secure)
    math.randomseed(opts.time_fn())
    local bytes = {}
    for i = 1, 32 do bytes[i] = string.char(math.random(0, 255)) end
    raw = table.concat(bytes)
  end
  assert(raw, "pkce: raw bytes not generated")
  local verifier = base64url_encode(raw)
  local challenge = base64url_encode(sha256(verifier))
  return verifier, challenge
end

-- Decode a JWT token without signature verification.
-- Returns: { header = table, payload = table, signature_raw = string } or (nil, errmsg).
function M.decode_jwt(token_str)
  local parts = {}
  for part in token_str:gmatch("[^.]+") do
    parts[#parts+1] = part
  end
  if #parts ~= 3 then
    return nil, "invalid JWT: expected 3 dot-separated parts, got " .. #parts
  end
  local header_json, err1 = base64url_decode(parts[1])
  if not header_json then return nil, "invalid JWT header encoding: " .. (err1 or "?") end
  local payload_json, err2 = base64url_decode(parts[2])
  if not payload_json then return nil, "invalid JWT payload encoding: " .. (err2 or "?") end
  local header, herr = json_parse(header_json)
  if not header then return nil, "invalid JWT header JSON: " .. (herr or "?") end
  local payload, perr = json_parse(payload_json)
  if not payload then return nil, "invalid JWT payload JSON: " .. (perr or "?") end
  return { header = header, payload = payload, signature_raw = parts[3] }
end

-- ── Token Store ───────────────────────────────────────────────────────────────

--:: TokenStore = { _tokens: { [string]: { token: { expires_in: number | nil, ... }, issued_at: number } }, _time_fn: () -> number, ... }
local token_store_mt = {}
token_store_mt.__index = token_store_mt

-- Store a token under a key.
function token_store_mt:set(key, token, issued_at)
  self._tokens[key] = {
    token = token,
    issued_at = issued_at or self._time_fn(),
  }
end

-- Retrieve a stored token, or nil if not found.
function token_store_mt:get(key)
  local entry = self._tokens[key]
  if not entry then return nil end
  return entry.token
end

-- Returns true if the stored token has expired.
-- Uses issued_at + expires_in to determine expiry.
--: (self: TokenStore, key: string) -> boolean
function token_store_mt:is_expired(key)
  local entry = self._tokens[key]
  if not entry then return true end
  local token = entry.token
  if not token.expires_in then return false end -- no expiry info → assume valid
  local expiry = entry.issued_at + token.expires_in
  return self._time_fn() >= expiry
end

-- Returns true if the token will expire within `margin` seconds (default 60).
--: (self: TokenStore, key: string, margin: number | nil) -> boolean
function token_store_mt:needs_refresh(key, margin)
  local entry = self._tokens[key]
  if not entry then return true end
  local token = entry.token
  if not token.expires_in then return false end
  margin = margin or 60
  local expiry = entry.issued_at + token.expires_in
  return self._time_fn() + margin >= expiry
end

-- Delete a stored token.
function token_store_mt:delete(key)
  self._tokens[key] = nil
end

-- Create a new in-memory token store.
function M.token_store(opts)
  assert(opts and opts.time_fn, "token_store requires opts.time_fn")
  return setmetatable({ _tokens = {}, _time_fn = opts.time_fn }, token_store_mt)
end

-- ── OAuth2 Client ─────────────────────────────────────────────────────────────

--:: HttpTransport = { post: (string, { [string]: string }, string) -> ({ status: integer, body: string | nil } | nil, string | nil) }
--:: OAuthClient = { _client_id: string, _client_secret: string | nil, _token_url: string | nil, _http: HttpTransport | nil, ... }
local client_mt = {}
client_mt.__index = client_mt

-- Build URL-encoded form body from a table.
--: (params: { ... }) -> string
local function form_encode(params)
  local parts = {}
  for k, v in pairs(params) do
    parts[#parts+1] = url_encode(tostring(k)) .. "=" .. url_encode(tostring(v))
  end
  return table.concat(parts, "&")
end

-- Internal: POST to token endpoint, parse response.
-- Returns (token_table) or (nil, err_string_or_table).
--: (http: { post: (string, { [string]: string }, string) -> ({ status: integer, body: string | nil } | nil, string | nil) } | nil, url: string, headers: { [string]: string }, body: string) -> (unknown, unknown)
local function token_request(http, url, headers, body)
  if not http or not http.post then
    return nil, "http transport not configured"
  end
  local resp, err = http.post(url, headers, body)
  if not resp then
    return nil, err or "http request failed"
  end
  if resp.status ~= 200 then
    -- Try to parse OAuth error body
    if resp.body and #resp.body > 0 then
      local obj = json_parse(resp.body)
      if type(obj) == "table" and obj["error"] then
        return nil, { error = obj["error"], description = obj["error_description"] }
      end
    end
    return nil, "http " .. tostring(resp.status)
  else
    if not resp.body then
      return nil, "empty response body"
    end
    return M.parse_token_response(resp.body)
  end
end

-- Build the Authorization Code redirect URL.
-- opts: { auth_url, redirect_uri, scope, state, code_challenge, code_challenge_method, ... }
-- Returns: URL string.
--: (self: OAuthClient, opts: { auth_url: string, redirect_uri: string | nil, scope: string | nil, state: string | nil, code_challenge: string | nil, code_challenge_method: string | nil, ... }) -> string
function client_mt:authorization_url(opts)
  local params = ({} --[[:! { [string]: string }]])
  params["response_type"] = "code"
  params["client_id"]     = tostring(self._client_id)
  if opts.redirect_uri then params["redirect_uri"] = opts.redirect_uri end
  if opts.scope        then params["scope"] = opts.scope end
  if opts.state        then params["state"] = opts.state end
  if opts.code_challenge then
    params["code_challenge"] = opts.code_challenge
    params["code_challenge_method"] = opts.code_challenge_method or "S256"
  end
  -- Merge any extra params
  for k, v in pairs(opts) do
    if k ~= "auth_url" and k ~= "redirect_uri" and k ~= "scope" and k ~= "state"
       and k ~= "code_challenge" and k ~= "code_challenge_method" then
      if type(v) == "string" then
        params[k] = v
      elseif type(v) == "number" or type(v) == "boolean" then
        params[k] = tostring(v)
      end
    end
  end
  return M.build_auth_url(opts.auth_url, params)
end

-- Client Credentials flow (RFC 6749 §4.4).
-- opts: { scope? }
-- Returns: token_table or (nil, err).
--: (self: OAuthClient, opts: { scope: string | nil, ... } | nil) -> (unknown, unknown)
function client_mt:client_credentials(opts)
  if not self._token_url then return nil, "token_url not configured" end
  local params = {
    grant_type    = "client_credentials",
    client_id     = self._client_id,
    client_secret = self._client_secret,
  }
  if opts and opts.scope then params.scope = opts.scope end
  local headers = {
    ["Content-Type"] = "application/x-www-form-urlencoded",
  }
  return token_request(self._http, self._token_url, headers, form_encode(params))
end

-- Authorization Code exchange (RFC 6749 §4.1.3).
-- opts: { code, redirect_uri, code_verifier? }
-- Returns: token_table or (nil, err).
--: (self: OAuthClient, opts: { code: string | nil, redirect_uri: string | nil, code_verifier: string | nil, ... } | nil) -> (unknown, unknown)
function client_mt:exchange_code(opts)
  if not opts or not opts.code then
    return nil, "missing code"
  end
  if not self._token_url then return nil, "token_url not configured" end
  local params = {
    grant_type    = "authorization_code",
    code          = opts.code,
    client_id     = self._client_id,
    client_secret = self._client_secret,
  }
  if opts.redirect_uri   then params.redirect_uri   = opts.redirect_uri   end
  if opts.code_verifier  then params.code_verifier  = opts.code_verifier  end
  local headers = { ["Content-Type"] = "application/x-www-form-urlencoded" }
  return token_request(self._http, self._token_url, headers, form_encode(params))
end

-- Refresh Token flow (RFC 6749 §6).
-- opts: { refresh_token, scope? }
-- Returns: token_table or (nil, err).
--: (self: OAuthClient, opts: { refresh_token: string | nil, scope: string | nil, ... } | nil) -> (unknown, unknown)
function client_mt:refresh(opts)
  if not opts or not opts.refresh_token then
    return nil, "missing refresh_token"
  end
  if not self._token_url then return nil, "token_url not configured" end
  local params = {
    grant_type     = "refresh_token",
    refresh_token  = opts.refresh_token,
    client_id      = self._client_id,
    client_secret  = self._client_secret,
  }
  if opts.scope then params.scope = opts.scope end
  local headers = { ["Content-Type"] = "application/x-www-form-urlencoded" }
  return token_request(self._http, self._token_url, headers, form_encode(params))
end

-- Token Introspection (RFC 7662).
-- opts: { introspect_url }
-- Returns: introspection response table or (nil, err).
--: (self: OAuthClient, access_token: string | nil, opts: { introspect_url: string | nil, ... } | nil) -> (unknown, unknown)
function client_mt:introspect(access_token, opts)
  if not access_token then return nil, "missing access_token" end
  if not opts or not opts.introspect_url then return nil, "missing introspect_url" end
  local introspect_url = opts.introspect_url --[[:! string]]
  local params = {
    token     = access_token,
    client_id = self._client_id,
  }
  if self._client_secret then params.client_secret = self._client_secret end
  local headers = { ["Content-Type"] = "application/x-www-form-urlencoded" }
  if not self._http or not self._http.post then
    return nil, "http transport not configured"
  end
  local resp, err = self._http.post(introspect_url, headers, form_encode(params))
  if not resp then return nil, err or "http request failed" end
  if type(resp) ~= "table" then return nil, "unexpected response type" end
  local resp_ = resp --[[: { status: integer, body: string | nil }]]
  local status = resp_.status
  if status ~= 200 then return nil, "http " .. tostring(status) end
  if not resp_.body then return nil, "empty response body" end
  local obj, jerr = json_parse(resp_.body)
  if not obj then return nil, jerr or "invalid JSON" end
  return obj
end

-- Create a new OAuth2 client.
-- opts: { client_id, client_secret, token_url, http? }
function M.client(opts)
  if not opts or not opts.client_id then
    error("oauth2.client: client_id required")
  end
  return setmetatable({
    _client_id     = opts.client_id,
    _client_secret = opts.client_secret,
    _token_url     = opts.token_url,
    _http          = opts.http,
  }, client_mt)
end

return M
