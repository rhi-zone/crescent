-- lib/oauth/init.lua
-- OAuth 2.0 protocol helper: URL building, PKCE, JWT decode, token helpers.
-- Pure Lua — no HTTP client included. Callers inject their own HTTP function.
--
-- Public API:
--   M.url_encode(str) -> str
--   M.url_decode(str) -> str
--   M.build_query(params) -> query_string   (sorted keys)
--   M.parse_query(query_string) -> table
--   M.base64url_encode(str) -> str
--   M.base64url_decode(str) -> str | nil
--   M.random_state(length?) -> str          (URL-safe random, default 32)
--   M.pkce_verifier(length?) -> str         (43-128 chars, default 64)
--   M.pkce_challenge(verifier, sha256_fn?) -> { code_challenge, code_challenge_method }
--   M.auth_url(opts) -> url_string
--   M.token_request(grant_type, opts) -> body_str, headers
--   M.parse_token_response(json_str) -> token, err
--   M.jwt_decode(token_str) -> { header, payload, signature_b64 }, err
--   M.jwt_expired(payload, clock?) -> boolean
--   M.jwt_claims(token_str) -> payload_table, err

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- ── URL encoding ─────────────────────────────────────────────────────────────

-- RFC 3986 unreserved chars: A-Z a-z 0-9 - _ . ~
local function is_unreserved(c)
  return c:match("[A-Za-z0-9%-_.~]") ~= nil
end

--: (string) -> string
function M.url_encode(str)
  if type(str) ~= "string" then str = tostring(str) end
  --: (c: string) -> string
  local function escape(c)
    local n = c:byte() or 0
    return string.format("%%%02X", n)
  end
  local result, _ = str:gsub("([^A-Za-z0-9%-_.~])", escape)
  return result
end

function M.url_decode(str)
  if type(str) ~= "string" then return nil end
  return str:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end):gsub("%+", " ")
end

-- ── Query string helpers ──────────────────────────────────────────────────────

-- Returns a sorted, URL-encoded query string.
--: (params: { [string]: unknown }) -> string
function M.build_query(params)
  local keys = {}
  for k in pairs(params) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    local v = params[k]
    if v ~= nil then
      parts[#parts + 1] = M.url_encode(tostring(k)) .. "=" .. M.url_encode(tostring(v))
    end
  end
  return table.concat(parts, "&")
end

function M.parse_query(query_string)
  local result = {}
  if not query_string or query_string == "" then return result end
  for pair in (query_string .. "&"):gmatch("([^&]+)&") do
    local k, v = pair:match("^([^=]*)=(.*)$")
    if k then
      result[M.url_decode(k)] = M.url_decode(v)
    end
  end
  return result
end

-- ── Base64url (RFC 4648, no padding) ─────────────────────────────────────────

local B64URL_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

--: (str: string) -> string
function M.base64url_encode(str)
  local result = {} --: { [integer]: string }
  local len = #str
  local i = 1
  while i <= len do
    local b1 = str:sub(i, i):byte() or 0
    local b2 = str:sub(i+1, i+1):byte() or 0
    local b3 = str:sub(i+2, i+2):byte() or 0
    local triple = b1 * 0x10000 + b2 * 0x100 + b3
    local i1 = math.floor(math.floor(triple / 0x40000) % 64 + 1)
    local i2 = math.floor(math.floor(triple / 0x1000) % 64 + 1)
    result[#result + 1] = B64URL_CHARS:sub(i1, i1)
    result[#result + 1] = B64URL_CHARS:sub(i2, i2)
    if i + 1 <= len then
      local i3 = math.floor(math.floor(triple / 0x40) % 64 + 1)
      result[#result + 1] = B64URL_CHARS:sub(i3, i3)
    end
    if i + 2 <= len then
      local i4 = math.floor((triple % 64) + 1)
      result[#result + 1] = B64URL_CHARS:sub(i4, i4)
    end
    i = i + 3
  end
  return table.concat(result)
end

-- Build reverse lookup table
local B64URL_DECODE = {}
for idx = 1, #B64URL_CHARS do
  B64URL_DECODE[B64URL_CHARS:sub(idx, idx)] = idx - 1
end

function M.base64url_decode(str)
  if type(str) ~= "string" then return nil end
  -- Strip padding if present
  str = str:gsub("=+$", "")
  local result = {}
  local len = #str
  local i = 1
  while i <= len do
    local c1 = B64URL_DECODE[str:sub(i, i)]
    local c2 = B64URL_DECODE[str:sub(i + 1, i + 1)]
    if c1 == nil or c2 == nil then return nil end
    local c3 = B64URL_DECODE[str:sub(i + 2, i + 2)]
    local c4 = B64URL_DECODE[str:sub(i + 3, i + 3)]
    local triple = c1 * 0x40000 + c2 * 0x1000
    result[#result + 1] = string.char(math.floor(triple / 0x10000) % 256)
    if c3 ~= nil then
      triple = triple + c3 * 0x40
      result[#result + 1] = string.char(math.floor(triple / 0x100) % 256)
    end
    if c4 ~= nil then
      triple = triple + c4
      result[#result + 1] = string.char(triple % 256)
    end
    i = i + 4
  end
  return table.concat(result)
end

-- ── Minimal JSON parser ───────────────────────────────────────────────────────
-- Handles full recursive JSON: objects, arrays, strings, numbers, bools, null.

local json_parse  -- forward declaration

--: (s: string, pos: integer) -> integer
local function skip_ws(s, pos)
  local p = pos
  while p <= #s do
    local c = s:sub(p, p)
    if c == " " or c == "\t" or c == "\n" or c == "\r" then
      p = p + 1
    else
      break
    end
  end
  return p
end

--: (s: string, pos: integer) -> (string | nil, integer | nil)
local function parse_string(s, pos)
  -- pos is on the opening quote
  assert(s:sub(pos, pos) == '"')
  pos = pos + 1
  local buf = {} --[[:! { [integer]: string }]]
  while pos <= #s do
    local c = s:sub(pos, pos)
    if c == '"' then
      return table.concat(buf), pos + 1
    elseif c == "\\" then
      local esc = s:sub(pos + 1, pos + 1)
      if     esc == '"'  then buf[#buf + 1] = '"';  pos = pos + 2
      elseif esc == "\\" then buf[#buf + 1] = "\\"; pos = pos + 2
      elseif esc == "/"  then buf[#buf + 1] = "/";  pos = pos + 2
      elseif esc == "b"  then buf[#buf + 1] = "\b"; pos = pos + 2
      elseif esc == "f"  then buf[#buf + 1] = "\f"; pos = pos + 2
      elseif esc == "n"  then buf[#buf + 1] = "\n"; pos = pos + 2
      elseif esc == "r"  then buf[#buf + 1] = "\r"; pos = pos + 2
      elseif esc == "t"  then buf[#buf + 1] = "\t"; pos = pos + 2
      elseif esc == "u"  then
        local hex = s:sub(pos + 2, pos + 5)
        local cp_n = tonumber(hex, 16)
        if cp_n then
          local cp = cp_n --[[:! integer]]
          -- Basic BMP encode to UTF-8
          if cp < 0x80 then
            buf[#buf + 1] = string.char(cp)
          elseif cp < 0x800 then
            local c1 = 0xC0 + math.floor(cp / 0x40) --[[:! integer]]
            local c2 = 0x80 + cp % 0x40
            buf[#buf + 1] = string.char(c1, c2)
          else
            local c1 = 0xE0 + math.floor(cp / 0x1000) --[[:! integer]]
            local c2 = 0x80 + math.floor(cp / 0x40) % 0x40 --[[:! integer]]
            local c3 = 0x80 + cp % 0x40
            buf[#buf + 1] = string.char(c1, c2, c3)
          end
        end
        pos = pos + 6
      else
        buf[#buf + 1] = esc; pos = pos + 2
      end
    else
      buf[#buf + 1] = c
      pos = pos + 1
    end
  end
  return nil, nil  -- unterminated string
end

--: (s: string, pos: integer) -> (number | nil, integer)
local function parse_number(s, pos)
  local num_str = s:match("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
  if not num_str then return nil, pos end
  return tonumber(num_str), pos + #num_str
end

--: (s: string, pos: integer) -> (unknown, integer | nil)
local function parse_value(s, pos)
  pos = skip_ws(s, pos)
  if pos > #s then return nil, pos end
  local c = s:sub(pos, pos)
  if c == '"' then
    local v, npos = parse_string(s, pos)
    return v, npos
  elseif c == "{" then
    return json_parse(s, pos)
  elseif c == "[" then
    -- parse array
    local arr = {}
    pos = pos + 1
    pos = skip_ws(s, pos)
    if s:sub(pos, pos) == "]" then return arr, pos + 1 end
    while pos <= #s do
      local v, npos = parse_value(s, pos)
      if npos == nil then return nil, pos end
      arr[#arr + 1] = v
      pos = skip_ws(s, npos --[[:! integer]])
      local sep = s:sub(pos, pos)
      if sep == "]" then return arr, pos + 1
      elseif sep == "," then pos = pos + 1
      else return nil, pos
      end
    end
    return nil, pos
  elseif c == "t" and s:sub(pos, pos + 3) == "true" then
    return true, pos + 4
  elseif c == "f" and s:sub(pos, pos + 4) == "false" then
    return false, pos + 5
  elseif c == "n" and s:sub(pos, pos + 3) == "null" then
    return nil, pos + 4  -- null → nil
  elseif c == "-" or c:match("%d") then
    return parse_number(s, pos)
  end
  return nil, pos
end

-- json_parse: parse a JSON object starting at pos (on the "{")
--: (s: string, pos: integer) -> (unknown, integer | nil)
json_parse = function(s, pos)
  assert(s:sub(pos, pos) == "{")
  pos = pos + 1
  local obj = {}
  pos = skip_ws(s, pos)
  if s:sub(pos, pos) == "}" then return obj, pos + 1 end
  while pos <= #s do
    pos = skip_ws(s, pos)
    if s:sub(pos, pos) ~= '"' then return nil, pos end
    local key, npos = parse_string(s, pos)
    if not key then return nil, pos end
    pos = skip_ws(s, npos --[[:! integer]])
    if s:sub(pos, pos) ~= ":" then return nil, pos end
    pos = pos + 1
    local val, vpos = parse_value(s, pos)
    if vpos == nil then return nil, pos end
    obj[key] = val
    pos = skip_ws(s, vpos --[[:! integer]])
    local sep = s:sub(pos, pos)
    if sep == "}" then return obj, pos + 1
    elseif sep == "," then pos = pos + 1
    else return nil, pos
    end
  end
  return nil, pos
end

local function json_decode(s)
  if type(s) ~= "string" then return nil, "expected string" end
  local pos = skip_ws(s, 1)
  if pos > #s then return nil, "empty input" end
  local c = s:sub(pos, pos)
  local val, npos
  if c == "{" then
    val, npos = json_parse(s, pos)
  elseif c == "[" then
    val, npos = parse_value(s, pos)
  else
    return nil, "JSON must start with { or ["
  end
  if val == nil and npos == nil then return nil, "JSON parse error" end
  return val
end

-- ── Random bytes ──────────────────────────────────────────────────────────────

-- Generates URL-safe random string using math.random (seeded by caller if desired).
-- For cryptographic use, replace with a CSPRNG.
local URL_SAFE_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

function M.random_state(length)
  length = length or 32
  local out = {}
  for i = 1, length do
    local idx = math.random(1, #URL_SAFE_CHARS) --[[:! integer]]
    out[i] = URL_SAFE_CHARS:sub(idx, idx)
  end
  return table.concat(out)
end

-- ── PKCE (RFC 7636) ───────────────────────────────────────────────────────────

function M.pkce_verifier(length)
  length = length or 64
  if length < 43 then length = 43 end
  if length > 128 then length = 128 end
  local out = {}
  for i = 1, length do
    local idx = math.random(1, #URL_SAFE_CHARS) --[[:! integer]]
    out[i] = URL_SAFE_CHARS:sub(idx, idx)
  end
  return table.concat(out)
end

-- Returns { code_challenge, code_challenge_method }.
-- When sha256_fn is provided: S256 (base64url(sha256(verifier))).
-- When sha256_fn is nil: plain method (code_challenge = verifier).
-- sha256_fn(str) must return the raw 32-byte binary digest (not hex).
function M.pkce_challenge(verifier, sha256_fn)
  if sha256_fn then
    local digest = sha256_fn(verifier)
    return {
      code_challenge = M.base64url_encode(digest),
      code_challenge_method = "S256",
    }
  else
    return {
      code_challenge = verifier,
      code_challenge_method = "plain",
    }
  end
end

-- ── Authorization URL builder ─────────────────────────────────────────────────
-- opts: { base_url, client_id, redirect_uri, scope, state,
--         code_challenge?, code_challenge_method?, extra={} }

function M.auth_url(opts)
  local params = {
    response_type = "code",
    client_id     = opts.client_id,
    redirect_uri  = opts.redirect_uri,
    scope         = opts.scope,
    state         = opts.state,
  }
  if opts.code_challenge then
    params.code_challenge        = opts.code_challenge
    params.code_challenge_method = opts.code_challenge_method or "plain"
  end
  -- merge extra params
  if opts.extra then
    for k, v in pairs(opts.extra) do
      params[k] = v
    end
  end
  -- Remove nil values before building query
  local clean = {}
  for k, v in pairs(params) do
    if v ~= nil then clean[k] = v end
  end
  local qs = M.build_query(clean)
  local base = opts.base_url or ""
  if qs == "" then return base end
  return base .. "?" .. qs
end

-- ── Token request body builder ────────────────────────────────────────────────
-- Returns form-encoded body string and headers table.

function M.token_request(grant_type, opts)
  local params = { grant_type = grant_type }

  if grant_type == "authorization_code" then
    params.client_id    = opts.client_id
    params.code         = opts.code
    params.redirect_uri = opts.redirect_uri
    if opts.client_secret then params.client_secret = opts.client_secret end
    if opts.code_verifier then params.code_verifier  = opts.code_verifier end

  elseif grant_type == "refresh_token" then
    params.client_id      = opts.client_id
    params.refresh_token  = opts.refresh_token
    if opts.client_secret then params.client_secret = opts.client_secret end

  elseif grant_type == "client_credentials" then
    params.client_id     = opts.client_id
    params.client_secret = opts.client_secret
    if opts.scope then params.scope = opts.scope end

  elseif grant_type == "password" then
    params.client_id = opts.client_id
    params.username  = opts.username
    params.password  = opts.password
    if opts.client_secret then params.client_secret = opts.client_secret end
    if opts.scope         then params.scope         = opts.scope         end

  else
    return nil, "unknown grant_type: " .. tostring(grant_type)
  end

  local body = M.build_query(params --[[:! { [string]: unknown }]])
  local headers = {
    ["Content-Type"]   = "application/x-www-form-urlencoded",
    ["Content-Length"] = tostring(#body),
  }
  return body, headers
end

-- ── Token response parser ─────────────────────────────────────────────────────

function M.parse_token_response(json_str)
  local obj, err = json_decode(json_str)
  if not obj then
    return nil, "JSON parse error: " .. tostring(err)
  end
  if obj.error then
    local errf = obj.error --[[:! string]]
    local desc = obj.error_description --[[:! string | nil]]
    return nil, errf .. (desc and (": " .. desc) or "")
  end
  if not obj.access_token then
    return nil, "missing access_token"
  end
  return {
    access_token  = obj.access_token,
    token_type    = obj.token_type,
    expires_in    = obj.expires_in,
    refresh_token = obj.refresh_token,
    scope         = obj.scope,
    id_token      = obj.id_token,
  }
end

-- ── JWT utilities (decode only — no verification) ────────────────────────────

function M.jwt_decode(token_str)
  if type(token_str) ~= "string" then
    return nil, "token must be a string"
  end
  -- Split on dots
  local parts = {}
  for part in (token_str .. "."):gmatch("([^.]*)%.") do
    parts[#parts + 1] = part
  end
  if #parts < 3 then
    return nil, "invalid JWT: expected 3 dot-separated parts, got " .. #parts
  end

  local header_b64  = parts[1]
  local payload_b64 = parts[2]
  local sig_b64     = parts[3]

  local header_json = M.base64url_decode(header_b64)
  if not header_json then
    return nil, "invalid JWT: cannot base64url-decode header"
  end
  local payload_json = M.base64url_decode(payload_b64)
  if not payload_json then
    return nil, "invalid JWT: cannot base64url-decode payload"
  end

  local header, herr = json_decode(header_json)
  if not header then
    return nil, "invalid JWT header JSON: " .. tostring(herr)
  end
  local payload, perr = json_decode(payload_json)
  if not payload then
    return nil, "invalid JWT payload JSON: " .. tostring(perr)
  end

  return {
    header        = header,
    payload       = payload,
    signature_b64 = sig_b64,
  }
end

-- time_fn is required: function returning unix timestamp.
function M.jwt_expired(payload, time_fn)
  assert(time_fn, "jwt_expired requires time_fn")
  if type(payload) ~= "table" then return true end
  local exp = payload.exp
  if exp == nil then return false end  -- no exp claim → never expires
  local now = time_fn()
  return now >= exp
end

function M.jwt_claims(token_str)
  local decoded, err = M.jwt_decode(token_str)
  if not decoded then return nil, err end
  return decoded.payload
end

return M
