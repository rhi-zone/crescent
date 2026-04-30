-- lib/csv/init.lua
-- RFC 4180-compliant CSV encoder and decoder.
-- Pure Lua — no dependencies, works on LuaJIT and PUC-Rio Lua 5.2+.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

--:: Decoder = { feed: (string) -> nil, rows: () -> { [integer]: { [integer]: string } }, finish: () -> nil }

local byte, char, sub, find, gsub = string.byte, string.char, string.sub, string.find, string.gsub
local concat, insert = table.concat, table.insert

local BYTE_LF    = 10  -- \n
local BYTE_CR    = 13  -- \r
local BYTE_SPACE = 32
local BYTE_TAB   = 9

-- ---------------------------------------------------------------------------
-- Coercion helper
-- ---------------------------------------------------------------------------

local function coerce_value(s)
  local n = tonumber(s)
  if n ~= nil then return n end
  if s == "true"  then return true  end
  if s == "false" then return false end
  return s
end

-- ---------------------------------------------------------------------------
-- Core parser: parse one field from position pos in string s.
-- Returns: field_value, next_pos, terminated_by, err_msg
-- terminated_by: "delim" | "newline" | "eof"
-- On unterminated quoted field: nil, pos, "eof", errmsg
-- ---------------------------------------------------------------------------

local function parse_field(s, pos, len, sep_b, quot_b, do_trim)
  local c = byte(s, pos)

  if c == quot_b then
    -- Quoted field — collect everything until unescaped closing quote
    pos = pos + 1
    local parts = {}
    local nparts = 0
    local start = pos
    while pos <= len do
      c = byte(s, pos)
      if c == quot_b then
        if pos + 1 <= len and byte(s, pos + 1) == quot_b then
          -- "" → escaped quote
          nparts = nparts + 1
          parts[nparts] = sub(s, start, pos)  -- includes the first "
          pos = pos + 2
          start = pos
        else
          -- Closing quote
          nparts = nparts + 1
          parts[nparts] = sub(s, start, pos - 1)
          pos = pos + 1
          break
        end
      else
        pos = pos + 1
      end
    end

    if nparts == 0 then
      -- Ran off end without closing quote
      return nil, pos, "eof", "csv: unterminated quoted field"
    end

    local field = nparts == 1 and parts[1] or concat(parts)

    -- Consume terminator after closing quote
    if pos > len then
      return field, pos, "eof"
    end
    c = byte(s, pos)
    if c == sep_b then
      return field, pos + 1, "delim"
    elseif c == BYTE_CR then
      pos = pos + 1
      if pos <= len and byte(s, pos) == BYTE_LF then pos = pos + 1 end
      return field, pos, "newline"
    elseif c == BYTE_LF then
      return field, pos + 1, "newline"
    end
    -- Lenient: non-conforming char after closing quote; treat as eof terminator
    return field, pos, "eof"
  end

  -- Unquoted field — scan to separator or newline
  local start = pos
  while pos <= len do
    c = byte(s, pos)
    if c == sep_b then
      local field = sub(s, start, pos - 1)
      if do_trim then field = field:match("^%s*(.-)%s*$") end
      return field, pos + 1, "delim"
    elseif c == BYTE_CR then
      local field = sub(s, start, pos - 1)
      if do_trim then field = field:match("^%s*(.-)%s*$") end
      pos = pos + 1
      if pos <= len and byte(s, pos) == BYTE_LF then pos = pos + 1 end
      return field, pos, "newline"
    elseif c == BYTE_LF then
      local field = sub(s, start, pos - 1)
      if do_trim then field = field:match("^%s*(.-)%s*$") end
      return field, pos + 1, "newline"
    end
    pos = pos + 1
  end
  local field = sub(s, start, pos - 1)
  if do_trim then field = field:match("^%s*(.-)%s*$") end
  return field, pos, "eof"
end

-- ---------------------------------------------------------------------------
-- decode
-- ---------------------------------------------------------------------------

--- Decode a CSV string into an array of rows (each row = array of strings/values).
--- Options:
---   separator   string  field separator (default ",")
---   quote       string  quote character (default '"')
---   trim        bool    trim whitespace from unquoted fields (default false)
---   headers     bool    first row is headers; return array of {key=value} tables
---   coerce      bool    auto-convert numeric/bool strings (default false)
--: (string, { separator: string|nil, quote: string|nil, trim: boolean|nil, headers: boolean|nil, coerce: boolean|nil }|nil) -> { [integer]: unknown } | (nil, string)
function M.decode(s, opts)
  if type(s) ~= "string" then
    return nil, "csv.decode: expected string, got " .. type(s)
  end

  opts = opts or {}
  local sep_str    = opts.separator or ","
  local quot_str   = opts.quote     or '"'
  local do_trim    = opts.trim      or false
  local do_headers = opts.headers   or false
  local do_coerce  = opts.coerce    or false

  local sep_b  = byte(sep_str,  1)
  local quot_b = byte(quot_str, 1)
  local len    = #s
  local pos    = 1

  local rows = {}
  local nrow = 0

  while pos <= len do
    local c = byte(s, pos)

    -- Blank line (newline at start of row position)
    if c == BYTE_CR then
      pos = pos + 1
      if pos <= len and byte(s, pos) == BYTE_LF then pos = pos + 1 end
      nrow = nrow + 1
      rows[nrow] = {}
    elseif c == BYTE_LF then
      pos = pos + 1
      nrow = nrow + 1
      rows[nrow] = {}
    else
      -- Parse a full row
      local row = {}
      local nfield = 0
      while true do
        local field, next_pos, term, err = parse_field(s, pos, len, sep_b, quot_b, do_trim)
        if err then
          return nil, err
        end
        if do_coerce then field = coerce_value(field) end
        nfield = nfield + 1
        row[nfield] = field
        pos = next_pos

        if term == "delim" then
          -- If delimiter was the last char, append trailing empty field
          if pos > len then
            nfield = nfield + 1
            row[nfield] = do_coerce and coerce_value("") or ""
            break
          end
          -- continue to next field
        else
          break  -- "newline" or "eof"
        end
      end
      nrow = nrow + 1
      rows[nrow] = row
    end
  end

  -- Strip a single trailing empty row produced by a trailing newline
  if nrow > 0 and #rows[nrow] == 0 then
    rows[nrow] = nil
    nrow = nrow - 1
  end

  if do_headers then
    if nrow == 0 then return {} end
    local headers = rows[1]
    local result = {}
    for ri = 2, nrow do
      local r = rows[ri]
      local rec = {}
      for hi = 1, #headers do
        rec[headers[hi]] = r[hi]
      end
      result[ri - 1] = rec
    end
    return result
  end

  return rows
end

-- ---------------------------------------------------------------------------
-- decode_row
-- ---------------------------------------------------------------------------

--- Decode a single CSV row string into an array of field strings.
--: (string, { separator: string|nil, quote: string|nil, trim: boolean|nil, coerce: boolean|nil }|nil) -> { [integer]: unknown } | (nil, string)
function M.decode_row(s, opts)
  local rows, err = M.decode(s, opts)
  if not rows then return nil, err end
  return rows[1] or {}
end

-- ---------------------------------------------------------------------------
-- Encoder helpers
-- ---------------------------------------------------------------------------

local function field_needs_quote(s, sep_str, quot_str, always_quote)
  if always_quote then return true end
  local n = #s
  if n == 0 then return false end
  -- leading/trailing whitespace
  local fb = byte(s, 1)
  local lb = byte(s, n)
  if fb == BYTE_SPACE or fb == BYTE_TAB or lb == BYTE_SPACE or lb == BYTE_TAB then
    return true
  end
  if find(s, sep_str,  1, true) then return true end
  if find(s, quot_str, 1, true) then return true end
  if find(s, "\n",     1, true) then return true end
  if find(s, "\r",     1, true) then return true end
  return false
end

-- ---------------------------------------------------------------------------
-- encode_row
-- ---------------------------------------------------------------------------

--- Encode a single row (array of values) into a CSV line without line ending.
--: ({ [integer]: unknown }, { separator: string|nil, quote: string|nil, always_quote: boolean|nil }|nil) -> string
function M.encode_row(row, opts)
  opts = opts or {}
  local sep_str  = opts.separator    or ","
  local quot_str = opts.quote        or '"'
  local always_q = opts.always_quote or false

  local parts = {}
  for i = 1, #row do
    local s = tostring(row[i])
    if field_needs_quote(s, sep_str, quot_str, always_q) then
      local escaped = s:gsub(quot_str, quot_str .. quot_str)
      parts[i] = quot_str .. escaped .. quot_str
    else
      parts[i] = s
    end
  end
  return concat(parts, sep_str)
end

-- ---------------------------------------------------------------------------
-- encode
-- ---------------------------------------------------------------------------

--- Encode an array of rows into a CSV string.
--: ({ [integer]: { [integer]: unknown } }, { separator: string|nil, quote: string|nil, line_ending: string|nil, always_quote: boolean|nil }|nil) -> string
function M.encode(rows, opts)
  opts = opts or {}
  local line_ending = opts.line_ending or "\n"
  local row_opts = {
    separator    = opts.separator,
    quote        = opts.quote,
    always_quote = opts.always_quote,
  }

  local lines = {}
  for i = 1, #rows do
    lines[i] = M.encode_row(rows[i], row_opts)
  end
  if #lines == 0 then return "" end
  return concat(lines, line_ending) .. line_ending
end

-- ---------------------------------------------------------------------------
-- encode_records
-- ---------------------------------------------------------------------------

--- Encode an array of record tables into a CSV string with a header row.
--- keys: ordered array of field names to include (defines column order).
--: ({ [integer]: { [string]: unknown } }, { [integer]: string }, { separator: string|nil, quote: string|nil, line_ending: string|nil, always_quote: boolean|nil }|nil) -> string
function M.encode_records(records, keys, opts)
  opts = opts or {}
  local line_ending = opts.line_ending or "\n"
  local row_opts = {
    separator    = opts.separator,
    quote        = opts.quote,
    always_quote = opts.always_quote,
  }

  local lines = {}
  lines[1] = M.encode_row(keys, row_opts)
  for i = 1, #records do
    local rec = records[i]
    local row = {}
    for ki = 1, #keys do
      local v = rec[keys[ki]]
      row[ki] = (v ~= nil) and v or ""
    end
    lines[i + 1] = M.encode_row(row, row_opts)
  end
  return concat(lines, line_ending) .. line_ending
end

-- ---------------------------------------------------------------------------
-- iter
-- ---------------------------------------------------------------------------

--- Return an iterator that yields one decoded row at a time.
--: (string, { separator: string|nil, quote: string|nil, trim: boolean|nil, coerce: boolean|nil }|nil) -> () -> { [integer]: unknown } | nil
function M.iter(s, opts)
  local rows, err = M.decode(s, opts)
  if not rows then error(err) end
  local i = 0
  return function()
    i = i + 1
    return rows[i]
  end
end

-- ---------------------------------------------------------------------------
-- Streaming decoder (push-based)
-- ---------------------------------------------------------------------------

local Decoder = {}
Decoder.__index = Decoder

--- Create a streaming CSV decoder.
--: ({ separator: string|nil, quote: string|nil, headers: boolean|nil }|nil) -> Decoder
function M.decoder(opts)
  local self = setmetatable({}, Decoder)
  self._opts        = opts
  self._buf         = ""
  self._rows        = {}
  self._n           = 0
  self._header_row  = nil
  self._header_mode = opts and (opts.headers or opts.header)
  return self
end

function Decoder:push(chunk)
  self._buf = self._buf .. chunk
  self:_process()
end

function Decoder:_process()
  local buf   = self._buf
  local len   = #buf
  local pos   = 1
  local in_q  = false
  local last  = 0

  local quot_str = (self._opts and (self._opts.quote or '"')) or '"'
  local quot_b   = byte(quot_str, 1)

  while pos <= len do
    local c = byte(buf, pos)
    if c == quot_b then
      in_q = not in_q
    elseif not in_q and (c == BYTE_LF or c == BYTE_CR) then
      local row_str = sub(buf, last + 1, pos - 1)
      if c == BYTE_CR and pos + 1 <= len and byte(buf, pos + 1) == BYTE_LF then
        pos = pos + 1
      end
      last = pos

      if #row_str > 0 then
        local ropts = {}
        if self._opts then
          ropts.separator = self._opts.separator or self._opts.delimiter
          ropts.quote     = self._opts.quote
        end
        local parsed = M.decode(row_str, ropts)
        if parsed and #parsed > 0 then
          local row = parsed[1]
          if self._header_mode and not self._header_row then
            self._header_row = row
          elseif self._header_mode and self._header_row then
            local rec = {}
            for j = 1, #self._header_row do
              rec[self._header_row[j]] = row[j] or ""
            end
            self._n = self._n + 1
            self._rows[self._n] = rec
          else
            self._n = self._n + 1
            self._rows[self._n] = row
          end
        end
      end
    end
    pos = pos + 1
  end

  if last > 0 then
    self._buf = sub(buf, last + 1)
  end
end

--- Get completed rows since the last call and reset the internal completed list.
--: () -> { [integer]: unknown }
function Decoder:rows()
  local rows = self._rows
  self._rows = {}
  self._n    = 0
  return rows
end

--- Process any remaining buffered data and return all remaining rows.
--: () -> { [integer]: unknown }
function Decoder:finish()
  if #self._buf > 0 then
    local ropts = {}
    if self._opts then
      ropts.separator = self._opts.separator or self._opts.delimiter
      ropts.quote     = self._opts.quote
    end
    local parsed = M.decode(self._buf, ropts)
    if parsed then
      for i = 1, #parsed do
        local row = parsed[i]
        if self._header_mode and not self._header_row then
          self._header_row = row
        elseif self._header_mode and self._header_row then
          local rec = {}
          for j = 1, #self._header_row do
            rec[self._header_row[j]] = row[j] or ""
          end
          self._n = self._n + 1
          self._rows[self._n] = rec
        else
          self._n = self._n + 1
          self._rows[self._n] = row
        end
      end
    end
    self._buf = ""
  end
  return self:rows()
end

-- ---------------------------------------------------------------------------
-- Primary name aliases (crescent codec convention: type-in-the-name)
-- ---------------------------------------------------------------------------
M.string_to_rows = M.decode
M.rows_to_string = M.encode

return M
