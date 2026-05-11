if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

local byte = string.byte
local char = string.char
local format = string.format
local sub = string.sub
local find = string.find
local gsub = string.gsub
local match = string.match
local tonumber = tonumber
local tostring = tostring
local type = type
local pairs = pairs
local ipairs = ipairs
local concat = table.concat
local sort = table.sort

-- Lookup table: byte -> true if unreserved (RFC 3986 Section 2.3)
local unreserved = {} --: { [integer]: boolean }
for i = 0, 255 do unreserved[i] = false end
for i = byte("A"), byte("Z") do unreserved[i] = true end
for i = byte("a"), byte("z") do unreserved[i] = true end
for i = byte("0"), byte("9") do unreserved[i] = true end
unreserved[byte("-")] = true
unreserved[byte(".")] = true
unreserved[byte("_")] = true
unreserved[byte("~")] = true

-- Pre-computed percent-encoded bytes
local pct_encode = {}
for i = 0, 255 do
  pct_encode[i] = format("%%%02X", i)
end

--- Percent-encode a string (RFC 3986).
-- Encodes all characters except unreserved: A-Z a-z 0-9 - . _ ~
--: (string) -> string
function M.encode(s)
  local out = {}
  local n = 0
  for i = 1, #s do
    local b = byte(s, i)
    n = n + 1
    if unreserved[b] then
      out[n] = char(b)
    else
      out[n] = pct_encode[b]
    end
  end
  return concat(out)
end

--- Percent-decode a string.
--: (string) -> string
function M.decode(s)
  local s2 = gsub(s, "+", " ") --[[: unknown]]; s2 = s2 --[[:! string]]
  local result = gsub(s2, "%%(%x%x)", function(hex)
    return char(tonumber(hex, 16))
  end) --[[: unknown]]; result = result --[[:! string]]
  return result
end

--- Parse a query string into a table.
-- Handles & and ; as separators, + as space, percent-decoding.
-- Keys without values get empty string. Duplicate keys: last wins.
--: (string) -> { [string]: string }
function M.parse_query(qs)
  local result = {}
  if not qs or qs == "" then return result end
  for pair in qs:gmatch("[^&;]+") do
    local eq = find(pair, "=", 1, true)
    if eq then
      local key = M.decode(sub(pair, 1, eq - 1))
      local val = M.decode(sub(pair, eq + 1))
      result[key] = val
    else
      result[M.decode(pair)] = ""
    end
  end
  return result
end

--- Build a query string from a table.
-- Keys are sorted for deterministic output.
--: ({ [string]: string }) -> string
function M.build_query(t)
  local keys = {}
  local n = 0
  for k in pairs(t) do
    n = n + 1
    keys[n] = k
  end
  sort(keys)
  local parts = {}
  for i = 1, n do
    local k = keys[i]
    parts[i] = M.encode(k) .. "=" .. M.encode(t[k])
  end
  return concat(parts, "&")
end

--- Remove dot segments from a path (RFC 3986 Section 5.2.4).
--: (string) -> string
local function remove_dot_segments(path)
  local out = {}
  local n = 0
  -- Process the input buffer
  while #path > 0 do
    -- A: if path begins with ../ or ./
    if sub(path, 1, 3) == "../" then
      path = sub(path, 4)
    elseif sub(path, 1, 2) == "./" then
      path = sub(path, 3)
    -- B: if path begins with /./ or is /. exactly
    elseif sub(path, 1, 3) == "/./" then
      path = "/" .. sub(path, 4)
    elseif path == "/." then
      path = "/"
    -- C: if path begins with /../ or is /.. exactly
    elseif sub(path, 1, 4) == "/../" then
      path = "/" .. sub(path, 5)
      if n > 0 then n = n - 1 end
    elseif path == "/.." then
      path = "/"
      if n > 0 then n = n - 1 end
    -- D: if path is just . or ..
    elseif path == "." or path == ".." then
      path = ""
    -- E: move first path segment (including initial / if any) to output
    else
      local seg_start = 1
      local seg_end
      if sub(path, 1, 1) == "/" then
        seg_end = find(path, "/", 2, true)
      else
        seg_end = find(path, "/", 1, true)
      end
      if seg_end then
        seg_end = seg_end --[[:! integer]]
        n = n + 1
        out[n] = sub(path, seg_start, seg_end - 1)
        path = sub(path, seg_end)
      else
        n = n + 1
        out[n] = path
        path = ""
      end
    end
  end
  return concat(out, "", 1, n)
end

--- Parse a URL string into components (RFC 3986).
-- Returns a table with: scheme, userinfo, host, port, path, query, fragment.
-- Returns (nil, errmsg) on invalid input.
--: (string) -> ({ scheme: string | nil, userinfo: string | nil, host: string | nil, port: number | nil, path: string | nil, query: string | nil, fragment: string | nil } | nil, string | nil)
function M.parse(s)
  if type(s) ~= "string" then
    return nil, "url.parse: expected string, got " .. type(s)
  end

  local u = {} --[[:! { scheme: string | nil, userinfo: string | nil, host: string | nil, port: number | nil, path: string | nil, query: string | nil, fragment: string | nil }]]
  local rest = s

  -- Fragment
  local frag_pos = find(rest, "#", 1, true)
  if frag_pos then
    u.fragment = sub(rest, frag_pos + 1)
    rest = sub(rest, 1, frag_pos - 1)
  end

  -- Query
  local query_pos = find(rest, "?", 1, true)
  if query_pos then
    u.query = sub(rest, query_pos + 1)
    rest = sub(rest, 1, query_pos - 1)
  end

  -- Scheme
  local scheme, after_scheme = match(rest, "^([a-zA-Z][a-zA-Z0-9+%.%-]*):(.*)")
  if scheme then
    -- Check if this is really a scheme or a path like "C:\..." on Windows
    -- Schemes must be followed by // for authority or a path
    u.scheme = scheme:lower()
    rest = after_scheme
  end

  -- Authority
  if sub(rest, 1, 2) == "//" then
    rest = sub(rest, 3)
    -- Find end of authority (next / or end of string)
    local auth_end = find(rest, "/", 1, true)
    local authority
    if auth_end then
      authority = sub(rest, 1, auth_end - 1)
      rest = sub(rest, auth_end) -- keep the /
    else
      authority = rest
      rest = ""
    end

    -- Userinfo
    local at_pos = find(authority, "@", 1, true)
    if at_pos then
      u.userinfo = sub(authority, 1, at_pos - 1)
      authority = sub(authority, at_pos + 1)
    end

    -- Host and port — handle IPv6
    if sub(authority, 1, 1) == "[" then
      -- IPv6 address
      local bracket_end = find(authority, "]", 2, true)
      if bracket_end then
        bracket_end = bracket_end --[[:! integer]]
        u.host = sub(authority, 1, bracket_end)
        local port_str = sub(authority, bracket_end + 1)
        if sub(port_str, 1, 1) == ":" then
          local port_num_s = sub(port_str, 2)
          local p = tonumber(port_num_s)
          if p then u.port = p end
        end
      else
        u.host = authority
      end
    else
      -- Regular host — find last colon for port
      local colon = find(authority, ":", 1, true)
      if colon then
        local maybe_port = sub(authority, colon + 1)
        local p = tonumber(maybe_port)
        if p and match(maybe_port, "^%d+$") then
          u.host = sub(authority, 1, colon - 1)
          u.port = p
        else
          u.host = authority
        end
      else
        u.host = authority
      end
    end

    if u.host and u.host ~= "" then
      -- Lowercase host for normalization
    end
  end

  -- Path is whatever remains
  u.path = rest

  return u
end

--- Build a URL string from components.
--: ({ scheme: (string | nil), userinfo: (string | nil), host: (string | nil), port: (number | nil), path: (string | nil), query: (string | nil), fragment: (string | nil) }) -> string
function M.build(u)
  local parts = {}
  local n = 0

  if u.scheme then
    n = n + 1; parts[n] = u.scheme
    n = n + 1; parts[n] = ":"
  end

  if u.host then
    n = n + 1; parts[n] = "//"
    if u.userinfo then
      n = n + 1; parts[n] = u.userinfo
      n = n + 1; parts[n] = "@"
    end
    n = n + 1; parts[n] = u.host
    if u.port then
      n = n + 1; parts[n] = ":"
      n = n + 1; parts[n] = tostring(u.port)
    end
  end

  if u.path then
    n = n + 1; parts[n] = u.path
  end

  if u.query then
    n = n + 1; parts[n] = "?"
    n = n + 1; parts[n] = u.query
  end

  if u.fragment then
    n = n + 1; parts[n] = "#"
    n = n + 1; parts[n] = u.fragment
  end

  return concat(parts)
end

--- Resolve a relative reference against a base URL (RFC 3986 Section 5.2.2).
--: (string, string) -> (string | nil, string | nil)
function M.resolve(base, ref)
  local r, err = M.parse(ref)
  if not r then return nil, err end

  local b, berr = M.parse(base)
  if not b then return nil, berr end

  local t = {} --[[:! { scheme: string | nil, userinfo: string | nil, host: string | nil, port: number | nil, path: string | nil, query: string | nil, fragment: string | nil }]]

  if r.scheme then
    t.scheme = r.scheme
    t.host = r.host
    t.port = r.port
    t.userinfo = r.userinfo
    t.path = remove_dot_segments(r.path or "")
    t.query = r.query
  else
    if r.host then
      t.host = r.host
      t.port = r.port
      t.userinfo = r.userinfo
      t.path = remove_dot_segments(r.path or "")
      t.query = r.query
    else
      if r.path == "" then
        t.path = b.path
        if r.query then
          t.query = r.query
        else
          t.query = b.query
        end
      else
        local r_path = r.path or ""
        local b_path = b.path or ""
        if sub(r_path, 1, 1) == "/" then
          t.path = remove_dot_segments(r_path)
        else
          -- Merge: base authority + base path up to last / + ref path
          if b.host and b_path == "" then
            t.path = "/" .. r_path
          else
            local last_slash = 0
            for i = #b_path, 1, -1 do
              if byte(b_path, i) == byte("/") then
                last_slash = i
                break
              end
            end
            if last_slash > 0 then
              t.path = sub(b_path, 1, last_slash) .. r_path
            else
              t.path = r_path
            end
          end
          t.path = remove_dot_segments(t.path or "")
        end
        t.query = r.query
      end
      t.host = b.host
      t.port = b.port
      t.userinfo = b.userinfo
    end
    t.scheme = b.scheme
  end

  t.fragment = r.fragment

  return M.build(t)
end

--- Join a base URL with a relative path.
-- Alias for resolve.
--: (string, string) -> (string | nil, string | nil)
function M.join(base, relative)
  return M.resolve(base, relative)
end

-- Default ports per scheme for normalization
local default_ports = {
  http = 80,
  https = 443,
  ftp = 21,
  ws = 80,
  wss = 443,
}

--- Normalize a URL (RFC 3986 Section 6.2.2 + 6.2.3).
-- Lowercases scheme and host, removes default port, removes dot segments,
-- decodes unreserved percent-encoded characters.
--: (string) -> (string | nil, string | nil)
function M.normalize(s)
  local u, err = M.parse(s)
  if not u then return nil, err end

  -- Lowercase scheme (already done in parse)

  -- Lowercase host
  if u.host then
    u.host = u.host:lower()
  end

  -- Remove default port
  do
    local cur_port = u.port
    if u.scheme and cur_port and default_ports[u.scheme] == cur_port then
      u.port = nil
    end
  end

  -- Remove dot segments
  if u.path then
    u.path = remove_dot_segments(u.path)
  end

  -- Decode unreserved percent-encoded chars in path
  if u.path then
    u.path = gsub(u.path, "%%(%x%x)", function(hex)
      hex = hex --[[:! string]]
      local b = tonumber(hex, 16)
      if unreserved[b] then
        return char(b)
      end
      return "%" .. hex:upper()
    end)
  end

  -- Normalize empty path with authority to /
  if u.host and (u.path == nil or u.path == "") then
    u.path = "/"
  end

  return M.build(u)
end

-- Codec aliases
M.string_to_url = M.parse
M.url_to_string = M.build

return M
