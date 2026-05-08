if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- ── Month name → number ──────────────────────────────────────────────────────

--: { [string]: integer }
local MONTH = {
  Jan=1, Feb=2, Mar=3, Apr=4, May=5, Jun=6,
  Jul=7, Aug=8, Sep=9, Oct=10, Nov=11, Dec=12,
}

-- ── Time helpers ─────────────────────────────────────────────────────────────

-- Days in each month (non-leap year)
local DAYS_IN_MONTH = {31,28,31,30,31,30,31,31,30,31,30,31} --: integer[]

--: (number) -> boolean
local function is_leap(y)
  return (y % 4 == 0 and y % 100 ~= 0) or (y % 400 == 0)
end

-- Simple Julian Day Number based unix timestamp (no os.time to stay portable)
-- Returns seconds since epoch (1970-01-01 00:00:00 UTC)
--: (year: number, month: number, day: number, hour: number, min: number, sec: number, tz_offset_min: number | nil) -> number
local function ymd_hms_to_unix(year, month, day, hour, min, sec, tz_offset_min)
  -- Days from epoch to start of year
  local y = year - 1
  local days = y*365 + math.floor(y/4) - math.floor(y/100) + math.floor(y/400)
  -- Epoch itself: 1970-01-01 = JDN for that date
  local epoch_y = 1969
  local epoch_days = epoch_y*365 + math.floor(epoch_y/4) - math.floor(epoch_y/100) + math.floor(epoch_y/400) + 1
  days = days - epoch_days
  -- Days in months of this year
  for m = 1, month - 1 do
    local d = DAYS_IN_MONTH[m]
    if m == 2 and is_leap(year) then d = 29 end
    days = days + d
  end
  days = days + (day - 1)
  local unix = days * 86400 + hour * 3600 + min * 60 + sec
  -- Subtract tz offset (tz_offset_min is offset from UTC, so UTC = local - offset)
  if tz_offset_min then
    unix = unix - tz_offset_min * 60
  end
  return unix
end

-- Parse CLF time: "[10/Oct/2000:13:55:36 -0700]" → unix timestamp | nil
--: (s: string) -> number | nil
function M.parse_clf_time(s)
  local day, mon, year, hour, min, sec, sign, tzh, tzm =
    s:match("^%[(%d+)/(%a+)/(%d+):(%d+):(%d+):(%d+) ([%+%-])(%d%d)(%d%d)%]$")
  if not day then return nil end
  local month = MONTH[mon]
  if not month then return nil end
  local n_tzh = tonumber(tzh) or 0
  local n_tzm = tonumber(tzm) or 0
  local tz_offset_min = n_tzh * 60 + n_tzm
  if sign == "-" then tz_offset_min = -tz_offset_min end
  return ymd_hms_to_unix(tonumber(year) or 0, month, tonumber(day) or 0,
    tonumber(hour) or 0, tonumber(min) or 0, tonumber(sec) or 0, tz_offset_min)
end

-- Parse ISO 8601: "2024-01-15T10:30:00Z" or "2024-01-15T10:30:00+05:30" → unix | nil
function M.parse_iso8601(s)
  local year, month, day, hour, min, sec, tz =
    s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d):(%d%d)(.*)$")
  if not year then return nil end
  local tz_offset_min = 0 --: number
  if tz == "" or tz == "Z" or tz == "z" then
    tz_offset_min = 0
  else
    local sign, tzh, tzm = tz:match("^([%+%-])(%d%d):?(%d%d)$")
    if not sign then return nil end
    tz_offset_min = (tonumber(tzh) or 0) * 60 + (tonumber(tzm) or 0)
    if sign == "-" then tz_offset_min = -tz_offset_min end
  end
  return ymd_hms_to_unix(tonumber(year) or 0, tonumber(month) or 0, tonumber(day) or 0,
    tonumber(hour) or 0, tonumber(min) or 0, tonumber(sec) or 0, tz_offset_min)
end

-- Format bytes: 1200 → "1.2 KB"
function M.format_bytes(n)
  if n < 1024 then return tostring(n) .. " B" end
  if n < 1024 * 1024 then
    return string.format("%.1f KB", n / 1024)
  end
  if n < 1024 * 1024 * 1024 then
    return string.format("%.1f MB", n / (1024 * 1024))
  end
  return string.format("%.1f GB", n / (1024 * 1024 * 1024))
end

-- ── Parsers ───────────────────────────────────────────────────────────────────

-- Combined/Common log format:
-- 127.0.0.1 - frank [10/Oct/2000:13:55:36 -0700] "GET /apache_pb.gif HTTP/1.0" 200 2326 "http://ref/" "Mozilla/5.0"
-- Common log format omits referrer and user_agent

--: (s: string, pos: integer) -> (string | nil, integer)
local function parse_quoted(s, pos)
  -- parse a double-quoted field starting at pos (which should be at '"')
  if s:sub(pos, pos) ~= '"' then return nil, pos end
  local result = {} --: Arr<string>
  local i = pos + 1
  while i <= #s do
    local c = s:sub(i, i)
    if c == '"' then
      return table.concat(result), i + 1
    elseif c == '\\' then
      i = i + 1
      result[#result + 1] = s:sub(i, i)
    else
      result[#result + 1] = c
    end
    i = i + 1
  end
  return nil, pos
end

local function parse_clf_request(req)
  -- "METHOD /path?query PROTOCOL"
  local method, rest = req:match("^(%S+) (.+)$")
  if not method then return nil end
  local path_query, proto = rest:match("^(.+) (%S+)$")
  if not path_query then
    -- no protocol
    path_query = rest
    proto = nil
  end
  local path, query = path_query:match("^([^?]*)%?(.*)$")
  if not path then
    path = path_query
    query = nil
  end
  return method, path, query, proto
end

--: (line: string) -> (unknown, string | nil)
local function parse_combined_line(line)
  -- ip ident user [time] "request" status bytes ["referrer"] ["user_agent"]
  local pos = 1
  local len = #line

  -- ip
  local ip, rest_start = line:match("^(%S+)%s+()", pos)
  if not ip then return nil, "log_parser: failed to parse combined log: missing ip" end
  pos = rest_start

  -- ident
  local ident, p2 = line:match("^(%S+)%s+()", pos)
  if not ident then return nil, "log_parser: failed to parse combined log: missing ident" end
  pos = p2

  -- user
  local user, p3 = line:match("^(%S+)%s+()", pos)
  if not user then return nil, "log_parser: failed to parse combined log: missing user" end
  pos = p3

  -- [time]
  local time_str, p4 = line:match("^(%b[])%s+()", pos)
  if not time_str then return nil, "log_parser: failed to parse combined log: missing time" end
  pos = p4
  local time_str_s = time_str --[[:! string]]

  -- "request"
  if line:sub(pos, pos) ~= '"' then
    return nil, "log_parser: failed to parse combined log: expected '\"' before request"
  end
  local req, p5 = parse_quoted(line, pos)
  if not req then return nil, "log_parser: failed to parse combined log: malformed request" end
  pos = p5
  -- skip whitespace
  while pos <= len and line:sub(pos, pos) == " " do pos = pos + 1 end

  -- status
  local status_str, p6 = line:match("^(%S+)%s*()", pos)
  if not status_str then return nil, "log_parser: failed to parse combined log: missing status" end
  pos = p6

  -- bytes
  local bytes_str, p7 = line:match("^(%S+)()", pos)
  if not bytes_str then return nil, "log_parser: failed to parse combined log: missing bytes" end
  pos = p7

  -- optional referrer
  local referrer = nil
  local user_agent = nil
  -- skip whitespace
  while pos <= len and line:sub(pos, pos) == " " do pos = pos + 1 end

  if pos <= len and line:sub(pos, pos) == '"' then
    local ref, p8 = parse_quoted(line, pos)
    if ref then
      referrer = ref
      pos = p8
    end
    -- skip whitespace
    while pos <= len and line:sub(pos, pos) == " " do pos = pos + 1 end
    if pos <= len and line:sub(pos, pos) == '"' then
      local ua, _ = parse_quoted(line, pos)
      if ua then user_agent = ua end
    end
  end

  local method, path, query, protocol = parse_clf_request(req)
  local entry = {
    ip        = ip,
    ident     = ident ~= "-" and ident or nil,
    user      = user ~= "-" and user or nil,
    time      = time_str_s,
    timestamp = M.parse_clf_time(time_str_s),
    method    = method,
    path      = path,
    query     = query,
    protocol  = protocol,
    status    = tonumber(status_str),
    bytes     = bytes_str ~= "-" and tonumber(bytes_str) or 0,
    referrer  = referrer ~= "-" and referrer or nil,
    user_agent= user_agent ~= "-" and user_agent or nil,
  }
  return entry
end

-- Syslog RFC 3164 / common variant:
-- Oct 11 22:14:15 hostname app[1234]: message
-- or with priority: <13>Oct 11 22:14:15 hostname app[1234]: message
--: (line: string) -> (unknown, string | nil)
local function parse_syslog_line(line)
  local s = line:gsub("^<(%d+)>", "") --: string
  -- timestamp: "Oct 11 22:14:15" or "Oct  1 22:14:15"
  local mon, day, time_part, rest = s:match("^(%a+)%s+(%d+)%s+(%d%d:%d%d:%d%d)%s+(.+)$")
  if not mon then
    return nil, "log_parser: failed to parse syslog: missing timestamp"
  end
  local timestamp = mon .. " " .. day .. " " .. time_part
  -- hostname app[pid]: message
  local hostname, app_rest = rest:match("^(%S+)%s+(.+)$")
  if not hostname then
    return nil, "log_parser: failed to parse syslog: missing hostname"
  end
  local app, pid, message = app_rest:match("^([^%[%]:]+)%[(%d+)%]:%s*(.*)$")
  if not app then
    -- no pid
    app, message = app_rest:match("^([^:]+):%s*(.*)$")
    pid = nil
    if not app then
      return nil, "log_parser: failed to parse syslog: missing app"
    end
  end
  return {
    timestamp = timestamp,
    hostname  = hostname,
    app       = app,
    pid       = pid and tonumber(pid) or nil,
    message   = message,
  }
end

-- JSON log line: any valid JSON object
--: (line: string) -> (unknown, string | nil)
local function parse_json_line(line)
  -- minimal JSON object parser sufficient for flat objects with string/number/bool/null values
  -- delegates to a hand-written parser; for production use, swap in a full JSON library
  local s = (line:match("^%s*(.-)%s*$") or line) --[[:! string]]
  if s:sub(1,1) ~= "{" then
    return nil, "log_parser: failed to parse json: not an object"
  end

  --: (str: string, i: integer) -> integer
  local function skip_ws(str, i)
    while i <= #str and str:sub(i,i):match("%s") do i = i + 1 end
    return i
  end

  --: (str: string, i: integer) -> (string | nil, integer)
  local function parse_string(str, i)
    if str:sub(i,i) ~= '"' then return nil, i end
    local buf = {} --: Arr<string>
    i = i + 1
    while i <= #str do
      local c = str:sub(i,i)
      if c == '"' then return table.concat(buf), i + 1 end
      if c == '\\' then
        i = i + 1
        local e = str:sub(i,i)
        if e == 'n' then buf[#buf+1] = '\n'
        elseif e == 't' then buf[#buf+1] = '\t'
        elseif e == 'r' then buf[#buf+1] = '\r'
        elseif e == 'u' then
          local hex = str:sub(i+1, i+4)
          local codepoint = tonumber(hex, 16) or 63 --: number
          buf[#buf+1] = string.char(codepoint --[[:! integer]])
          i = i + 4
        else buf[#buf+1] = e end
      else
        buf[#buf+1] = c
      end
      i = i + 1
    end
    return nil, i
  end

  --: (str: string, i: integer) -> (string | number | boolean | nil, integer)
  local function parse_value(str, i)
    i = skip_ws(str, i)
    local c = str:sub(i,i)
    if c == '"' then
      return parse_string(str, i)
    elseif c == 't' then
      if str:sub(i,i+3) == 'true' then return true, i+4 end
    elseif c == 'f' then
      if str:sub(i,i+4) == 'false' then return false, i+5 end
    elseif c == 'n' then
      if str:sub(i,i+3) == 'null' then return nil, i+4 end  -- nil as value
    elseif c == '-' or c:match("%d") then
      local num_s, e = str:match("^(-?%d+%.?%d*[eE]?[%+%-]?%d*)()", i)
      if num_s then return tonumber(num_s), e end
    end
    return nil, i
  end

  local result = {}
  local i = 2  -- skip '{'
  i = skip_ws(s, i)
  if s:sub(i,i) == '}' then return result end
  while i <= #s do
    i = skip_ws(s, i)
    if s:sub(i,i) == '}' then break end
    -- key
    local key, ni = parse_string(s, i)
    if not key then return nil, "log_parser: failed to parse json: bad key at pos " .. i end
    i = skip_ws(s, ni)
    if s:sub(i,i) ~= ':' then return nil, "log_parser: failed to parse json: expected ':' at pos " .. i end
    i = skip_ws(s, i+1)
    -- value
    local val, vi = parse_value(s, i)
    result[key] = val
    i = skip_ws(s, vi)
    if s:sub(i,i) == ',' then i = i + 1
    elseif s:sub(i,i) == '}' then break
    else return nil, "log_parser: failed to parse json: unexpected char at pos " .. i end
  end
  return result
end

-- logfmt: key=value key="quoted value" key=123
--: (line: string) -> (unknown, string | nil)
local function parse_logfmt_line(line)
  local result = {} --: { [string]: string | number | boolean }
  local i = 1
  local len = #line
  while i <= len do
    -- skip whitespace
    while i <= len and line:sub(i,i):match("%s") do i = i + 1 end
    if i > len then break end
    -- key
    local key, ki = line:match("^([^=%s]+)=()", i)
    if not key then break end
    i = ki
    -- value: quoted or unquoted
    local val
    if line:sub(i,i) == '"' then
      local v, ni = parse_quoted(line, i)
      if v == nil then break end
      val = v
      i = ni
    else
      local v, ni = line:match("^(%S*)()", i)
      val = v
      i = ni
    end
    -- try to coerce value type
    local num = tonumber(val)
    if num then
      result[key] = num
    elseif val == "true" then
      result[key] = true
    elseif val == "false" then
      result[key] = false
    else
      result[key] = val
    end
  end
  return result
end

-- ── Auto-detect format ────────────────────────────────────────────────────────

function M.detect(line)
  if not line or line == "" then return nil end
  local s = line:match("^%s*(.-)%s*$")
  -- JSON object
  if s:sub(1,1) == "{" then return "json" end
  -- logfmt: contains key=value pairs (no leading CLF-like structure)
  -- syslog: starts with optional priority, then month name
  if s:match("^<(%d+)>%a%a%a%s") or s:match("^%a%a%a%s+%d+%s+%d%d:%d%d:%d%d%s") then
    return "syslog"
  end
  -- combined/nginx: starts with IP, then has [date] and "METHOD /path HTTP/x.x" status bytes
  if s:match("^%d+%.%d+%.%d+%.%d+%s") or s:match("^[%x:]+%s") then
    -- check for CLF time bracket
    if s:find("%[%d+/%a+/%d+:%d+:%d+:%d+%s[%+%-]%d+%]") then
      -- check for "user_agent" at end → combined; else common
      local has_ua = s:match('"[^"]*"%s*$')
      -- count quoted fields after status
      local after_status = s:match('%]%s+"[^"]*"%s+%d+%s+%d+(.*)$')
        or s:match('%]%s+"[^"]*"%s+%d+%s+%-(.*)$')
      if after_status and after_status:match('"') then
        return "combined"
      end
      return "common"
    end
  end
  -- logfmt: has at least one key=value
  if s:match("%S+=%S") then return "logfmt" end
  return nil
end

-- ── M.parse ───────────────────────────────────────────────────────────────────

--: (line: string, format: string | nil) -> (unknown, string | nil)
function M.parse(line, format)
  if format == "auto" or format == nil then
    format = M.detect(line)
    if not format then
      return nil, "log_parser: failed to detect format"
    end
  end
  if format == "combined" or format == "common" or format == "nginx" then
    return parse_combined_line(line)
  elseif format == "syslog" then
    return parse_syslog_line(line)
  elseif format == "json" then
    return parse_json_line(line)
  elseif format == "logfmt" then
    return parse_logfmt_line(line), nil
  else
    return nil, "log_parser: unknown format: " .. tostring(format)
  end
end

-- ── M.parse_lines ─────────────────────────────────────────────────────────────

function M.parse_lines(text, format)
  local entries = {}
  local errors = {}
  local line_num = 0
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if line ~= "" then
      line_num = line_num + 1
      local entry, err = M.parse(line, format)
      if entry then
        entries[#entries + 1] = entry
      elseif err then
        errors[#errors + 1] = { line_num = line_num, err = err }
      end
    end
  end
  return entries, errors
end

-- ── M.pattern ─────────────────────────────────────────────────────────────────

-- Build a parser from a format string with named captures: %{name:type}
-- Types: str, int, float, ip, timestamp
-- Example: "%{ip:ip} [%{time:str}] %{status:int} %{bytes:int}"
--: (fmt_string: string) -> (string) -> { [string]: string | number | nil } | nil
function M.pattern(fmt_string)
  -- Convert format string to a Lua pattern with captures
  local fields = {}  -- ordered list of {name, type}
  local lua_pat = fmt_string

  -- escape Lua magic chars except our %{...} placeholders
  -- We'll do a multi-pass: first extract placeholders, then escape, then re-insert
  local parts = {}
  local names = {}
  local i = 1
  local plain = {}
  local s = fmt_string --: string
  local out_parts = {}
  local field_idx = 0

  while true do
    local ps, pe, name, typ = s:find("%%{(%w+):(%w+)}", i)
    if not ps then
      -- rest is literal, escape it
      local lit = s:sub(i)
      lit = lit:gsub("[%(%)%.%%%+%-%*%?%[%^%$]", "%%%1")
      out_parts[#out_parts + 1] = lit
      break
    end
    -- literal before this placeholder
    local lit = s:sub(i, ps - 1)
    lit = lit:gsub("[%(%)%.%%%+%-%*%?%[%^%$]", "%%%1")
    out_parts[#out_parts + 1] = lit
    -- capture for this field
    local cap
    if typ == "int" then
      cap = "(%-?%d+)"
    elseif typ == "float" then
      cap = "(%-?%d+%.?%d*)"
    elseif typ == "ip" then
      cap = "(%d+%.%d+%.%d+%.%d+)"
    elseif typ == "timestamp" then
      cap = "(%S+)"  -- grab non-space; caller can parse further
    else  -- str
      cap = "([^%s]+)"
    end
    out_parts[#out_parts + 1] = cap
    field_idx = field_idx + 1
    names[field_idx] = { name = name, typ = typ }
    i = pe + 1
  end

  local pat = table.concat(out_parts)

  return function(line)
    local captures = { line:match(pat) }
    if not captures[1] and #names > 0 then return nil end
    if #names == 0 and not line:match(pat) then return nil end
    local result = {} --: { [string]: string | number | nil }
    for idx, field in ipairs(names) do
      local raw = captures[idx] --[[:! string | nil]]
      if field.typ == "int" then
        result[field.name] = tonumber(raw)
      elseif field.typ == "float" then
        result[field.name] = tonumber(raw)
      else
        result[field.name] = raw
      end
    end
    return result
  end
end

-- ── Filtering ─────────────────────────────────────────────────────────────────

function M.filter(entries, predicate)
  local out = {}
  for _, e in ipairs(entries) do
    if predicate(e) then out[#out + 1] = e end
  end
  return out
end

-- range: 200 (exact), "2xx" (class), {200,299} (range)
function M.filter_status(entries, range)
  local pred
  if type(range) == "number" then
    pred = function(e) return e.status == range end
  elseif type(range) == "string" then
    local class = tonumber(range:sub(1,1))
    pred = function(e)
      return e.status and math.floor(e.status / 100) == class
    end
  elseif type(range) == "table" then
    local lo, hi = range[1], range[2]
    pred = function(e) return e.status and e.status >= lo and e.status <= hi end
  else
    return entries
  end
  return M.filter(entries, pred)
end

-- methods: "GET" or {"GET","POST"}
function M.filter_method(entries, methods)
  local set = {}
  if type(methods) == "string" then
    set[methods] = true
  else
    for _, m in ipairs(methods) do set[m] = true end
  end
  return M.filter(entries, function(e) return set[e.method] end)
end

-- pattern: Lua pattern match on path field
function M.filter_path(entries, pat)
  return M.filter(entries, function(e)
    return e.path and e.path:find(pat) ~= nil
  end)
end

-- after/before: unix timestamps (inclusive)
function M.filter_time(entries, after, before)
  return M.filter(entries, function(e)
    local ts = e.timestamp
    if not ts then return false end
    if after and ts < after then return false end
    if before and ts > before then return false end
    return true
  end)
end

-- ── Aggregation ───────────────────────────────────────────────────────────────

function M.count(entries)
  return #entries
end

function M.count_by(entries, field)
  local counts = {}
  for _, e in ipairs(entries) do
    local v = tostring(e[field] or "")
    counts[v] = (counts[v] or 0) + 1
  end
  return counts
end

function M.sum_by(entries, num_field, group_field)
  if group_field then
    local sums = {}
    for _, e in ipairs(entries) do
      local k = tostring(e[group_field] or "")
      local v = tonumber(e[num_field]) or 0
      sums[k] = (sums[k] or 0) + v
    end
    return sums
  else
    -- sum num_field grouped by itself (all → one entry), or just return total
    local total = 0 --: number
    for _, e in ipairs(entries) do
      total = total + (tonumber(e[num_field]) or 0)
    end
    return total
  end
end

--: (entries: unknown[], field: unknown, n: integer) -> unknown[]
function M.top_n(entries, field, n)
  local counts = M.count_by(entries, field)
  local sorted = {}
  for v, c in pairs(counts) do
    sorted[#sorted + 1] = { v, c }
  end
  table.sort(sorted, function(a, b) return a[2] > b[2] end)
  local out = {}
  for i = 1, math.min(n, #sorted) do
    out[i] = sorted[i]
  end
  return out
end

-- p: percentile 0–100
function M.percentile(values, p)
  if #values == 0 then return nil end
  local sorted = {}
  for i, v in ipairs(values) do sorted[i] = v end
  table.sort(sorted)
  local n = #sorted
  if p <= 0 then return sorted[1] end
  if p >= 100 then return sorted[n] end
  -- nearest-rank method
  local rank = math.ceil(p / 100 * n)
  return sorted[rank]
end

return M
