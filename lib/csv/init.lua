if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

local byte = string.byte
local sub = string.sub
local find = string.find
local concat = table.concat

local BYTE_LF = 10  -- \n
local BYTE_CR = 13  -- \r

-- Parse one field starting at pos. Returns (field, next_pos, terminated_by).
-- terminated_by: "delim", "newline", "eof"
local function parse_field(s, pos, len, delim_byte, quote_byte)
  local c = byte(s, pos)

  if c == quote_byte then
    -- Quoted field
    pos = pos + 1
    local parts = {}
    local nparts = 0
    local start = pos
    while pos <= len do
      c = byte(s, pos)
      if c == quote_byte then
        if pos + 1 <= len and byte(s, pos + 1) == quote_byte then
          -- Escaped quote
          nparts = nparts + 1
          parts[nparts] = sub(s, start, pos)
          pos = pos + 2
          start = pos
        else
          -- End of quoted field
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
      return nil, pos, "eof", "csv.decode: unterminated quoted field"
    end

    local field = nparts == 1 and parts[1] or concat(parts)

    -- Consume separator after closing quote
    if pos > len then
      return field, pos, "eof"
    end
    c = byte(s, pos)
    if c == delim_byte then
      return field, pos + 1, "delim"
    elseif c == BYTE_CR then
      pos = pos + 1
      if pos <= len and byte(s, pos) == BYTE_LF then
        pos = pos + 1
      end
      return field, pos, "newline"
    elseif c == BYTE_LF then
      return field, pos + 1, "newline"
    end
    -- Lenient: skip unexpected chars after close quote until delimiter/newline
    return field, pos, "eof"
  end

  -- Unquoted field
  local start = pos
  while pos <= len do
    c = byte(s, pos)
    if c == delim_byte then
      return sub(s, start, pos - 1), pos + 1, "delim"
    elseif c == BYTE_CR then
      local field = sub(s, start, pos - 1)
      pos = pos + 1
      if pos <= len and byte(s, pos) == BYTE_LF then
        pos = pos + 1
      end
      return field, pos, "newline"
    elseif c == BYTE_LF then
      return sub(s, start, pos - 1), pos + 1, "newline"
    end
    pos = pos + 1
  end
  return sub(s, start, pos - 1), pos, "eof"
end

--- Parse a CSV string into an array of rows.
--- Each row is an array of string fields.
--- opts.delimiter: field separator (default ",")
--- opts.quote: quote character (default '"')
--- opts.header: if true, first row becomes keys and returns array of tables
--- opts.skip_empty: if true, skip rows that have no fields or only empty fields
--: (s: string, opts?: { delimiter?: string, quote?: string, header?: boolean, skip_empty?: boolean }) -> { { string } } | (nil, string)
function M.string_to_rows(s, opts)
  if type(s) ~= "string" then
    return nil, "csv.decode: expected string, got " .. type(s)
  end

  local delim = (opts and opts.delimiter) or ","
  local quote = (opts and opts.quote) or '"'
  local header_mode = opts and opts.header
  local skip_empty = opts and opts.skip_empty

  local delim_byte = byte(delim, 1)
  local quote_byte = byte(quote, 1)
  local len = #s
  local pos = 1
  local rows = {}
  local nrow = 0

  while pos <= len do
    -- Check for blank line (newline at start of row)
    local c = byte(s, pos)
    if c == BYTE_CR or c == BYTE_LF then
      -- Blank line
      if c == BYTE_CR then
        pos = pos + 1
        if pos <= len and byte(s, pos) == BYTE_LF then
          pos = pos + 1
        end
      else
        pos = pos + 1
      end
      if not skip_empty then
        nrow = nrow + 1
        rows[nrow] = {}
      end
    else
      -- Parse a row of fields
      local row = {}
      local nfield = 0
      while true do
        local field, next_pos, term, err = parse_field(s, pos, len, delim_byte, quote_byte)
        if err then
          return nil, err
        end
        nfield = nfield + 1
        row[nfield] = field
        pos = next_pos

        if term == "delim" then
          -- If delimiter is at end of input or followed by newline, there's one more empty field
          if pos > len then
            nfield = nfield + 1
            row[nfield] = ""
            break
          end
          -- Continue to parse next field
        else
          -- "newline" or "eof"
          break
        end
      end
      nrow = nrow + 1
      rows[nrow] = row
    end
  end

  if skip_empty then
    local filtered = {}
    local nf = 0
    for i = 1, nrow do
      local r = rows[i]
      local empty = true
      for j = 1, #r do
        if r[j] ~= "" then
          empty = false
          break
        end
      end
      if not empty then
        nf = nf + 1
        filtered[nf] = r
      end
    end
    rows = filtered
    nrow = nf
  end

  if header_mode and nrow > 0 then
    local headers = rows[1]
    local records = {}
    for i = 2, nrow do
      local r = rows[i]
      local record = {}
      for j = 1, #headers do
        record[headers[j]] = r[j] or ""
      end
      records[i - 1] = record
    end
    return records
  end

  return rows
end

--- Encode an array of rows into a CSV string.
--- opts.delimiter: field separator (default ",")
--- opts.quote: quote character (default '"')
--- opts.line_ending: line ending (default "\n")
--- opts.header: if provided, array of strings prepended as header row
--: (rows: { { string } }, opts?: { delimiter?: string, quote?: string, line_ending?: string, header?: { string } }) -> string
function M.rows_to_string(rows, opts)
  local delim = (opts and opts.delimiter) or ","
  local quote = (opts and opts.quote) or '"'
  local line_ending = (opts and opts.line_ending) or "\n"
  local header = opts and opts.header

  local escaped_quote = quote .. quote

  local out = {}
  local nout = 0

  local function encode_field(field)
    local s = tostring(field)
    if find(s, delim, 1, true) or find(s, quote, 1, true)
        or find(s, "\n", 1, true) or find(s, "\r", 1, true) then
      local escaped = s:gsub(quote, escaped_quote)
      return quote .. escaped .. quote
    end
    return s
  end

  local function encode_row(row)
    local fields = {}
    local nfields = #row
    for i = 1, nfields do
      fields[i] = encode_field(row[i] or "")
    end
    nout = nout + 1
    out[nout] = concat(fields, delim)
  end

  if header then
    encode_row(header)
  end

  for i = 1, #rows do
    encode_row(rows[i])
  end

  return concat(out, line_ending) .. line_ending
end

-- Streaming decoder

local Decoder = {}
Decoder.__index = Decoder

--- Create a streaming CSV decoder.
--: (opts?: { delimiter?: string, quote?: string, header?: boolean, skip_empty?: boolean }) -> Decoder
function M.decoder(opts)
  local self = setmetatable({}, Decoder)
  self._opts = opts
  self._buf = ""
  self._completed_rows = {}
  self._n_completed = 0
  self._header_row = nil
  self._header_mode = opts and opts.header
  return self
end

--- Push a chunk of data into the decoder.
--: (self: Decoder, chunk: string) -> ()
function Decoder:push(chunk)
  self._buf = self._buf .. chunk
  self:_process()
end

function Decoder:_process()
  local buf = self._buf
  local len = #buf
  local pos = 1
  local in_quote = false
  local last_row_end = 0

  local quote = (self._opts and self._opts.quote) or '"'
  local quote_byte = byte(quote, 1)

  while pos <= len do
    local c = byte(buf, pos)
    if c == quote_byte then
      in_quote = not in_quote
    elseif not in_quote and (c == BYTE_LF or c == BYTE_CR) then
      local row_str = sub(buf, last_row_end + 1, pos - 1)
      if c == BYTE_CR and pos + 1 <= len and byte(buf, pos + 1) == BYTE_LF then
        pos = pos + 1
      end
      last_row_end = pos

      if #row_str > 0 then
        local row_opts = {}
        if self._opts then
          row_opts.delimiter = self._opts.delimiter
          row_opts.quote = self._opts.quote
        end
        local parsed = M.string_to_rows(row_str, row_opts)
        if parsed and #parsed > 0 then
          local row = parsed[1]
          if self._header_mode and not self._header_row then
            self._header_row = row
          elseif self._header_mode and self._header_row then
            local record = {}
            for j = 1, #self._header_row do
              record[self._header_row[j]] = row[j] or ""
            end
            self._n_completed = self._n_completed + 1
            self._completed_rows[self._n_completed] = record
          else
            self._n_completed = self._n_completed + 1
            self._completed_rows[self._n_completed] = row
          end
        end
      end
    end
    pos = pos + 1
  end

  if last_row_end > 0 then
    self._buf = sub(buf, last_row_end + 1)
  end
end

--- Get completed rows and clear the buffer.
--: (self: Decoder) -> { { string } }
function Decoder:rows()
  local rows = self._completed_rows
  self._completed_rows = {}
  self._n_completed = 0
  return rows
end

--- Finalize the decoder — process remaining buffer and return rows.
--: (self: Decoder) -> { { string } }
function Decoder:finish()
  if #self._buf > 0 then
    local row_opts = {}
    if self._opts then
      row_opts.delimiter = self._opts.delimiter
      row_opts.quote = self._opts.quote
    end
    local parsed = M.string_to_rows(self._buf, row_opts)
    if parsed then
      for i = 1, #parsed do
        local row = parsed[i]
        if self._header_mode and not self._header_row then
          self._header_row = row
        elseif self._header_mode and self._header_row then
          local record = {}
          for j = 1, #self._header_row do
            record[self._header_row[j]] = row[j] or ""
          end
          self._n_completed = self._n_completed + 1
          self._completed_rows[self._n_completed] = record
        else
          self._n_completed = self._n_completed + 1
          self._completed_rows[self._n_completed] = row
        end
      end
    end
    self._buf = ""
  end
  return self:rows()
end

-- Aliases
M.decode = M.string_to_rows
M.encode = M.rows_to_string

return M
