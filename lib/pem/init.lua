-- lib/pem/init.lua
-- PEM (Privacy-Enhanced Mail, RFC 7468) parser and writer.
-- Pure Lua — no dependencies beyond lib/base64.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local base64 = require("lib.base64")

local M = {}
M._tier = "pure"

local concat = table.concat

-- Validate a PEM label: A-Z 0-9 space hyphen only.
local function valid_label(label)
  return label:match("^[A-Z0-9 %-]+$") ~= nil
end

-- Parse a BEGIN header line; return label or nil.
local function parse_begin(line)
  local label = line:match("^%-%-%-%-%-BEGIN ([A-Z0-9 %-]+)%-%-%-%-%-$")
  return label
end

-- Parse an END footer line; return label or nil.
local function parse_end(line)
  local label = line:match("^%-%-%-%-%-END ([A-Z0-9 %-]+)%-%-%-%-%-$")
  return label
end

--- Decode all PEM blocks from a string.
-- Returns: array of {label=string, data=binary_string}  OR  nil, errmsg
--: (string) -> { { label: string, data: string } } | (nil, string)
function M.decode_all(str)
  local blocks = {}
  local pos = 1
  local len = #str

  while pos <= len do
    -- Find next BEGIN line
    local begin_label = nil
    local body_start = nil

    -- Scan lines looking for -----BEGIN ...-----
    local i = pos
    while i <= len do
      local line_end = str:find("\n", i, true)
      local line
      if line_end then
        line = str:sub(i, line_end - 1)
        -- Strip trailing \r
        if line:sub(-1) == "\r" then line = line:sub(1, -2) end
        i = line_end + 1
      else
        line = str:sub(i)
        i = len + 1
      end

      begin_label = parse_begin(line)
      if begin_label then
        body_start = i
        break
      end
    end

    if not begin_label then
      -- No more BEGIN lines
      break
    end

    -- Collect body lines until -----END <label>-----
    local body_lines = {}
    local found_end = false
    local j = body_start

    while j <= len do
      local line_end = str:find("\n", j, true)
      local line
      if line_end then
        line = str:sub(j, line_end - 1)
        if line:sub(-1) == "\r" then line = line:sub(1, -2) end
        j = line_end + 1
      else
        line = str:sub(j)
        j = len + 1
      end

      local end_label = parse_end(line)
      if end_label then
        if end_label ~= begin_label then
          return nil, "pem: mismatched header/footer: BEGIN " ..
            begin_label .. " / END " .. end_label
        end
        found_end = true
        pos = j
        break
      end

      -- Skip blank lines; accumulate base64 body
      if line ~= "" then
        body_lines[#body_lines + 1] = line
      end
    end

    if not found_end then
      return nil, "pem: truncated PEM block (no END line) for label: " .. begin_label
    end

    -- Join and strip all whitespace from body, then base64-decode
    local b64 = concat(body_lines):gsub("%s", "")
    local data = base64.decode(b64)
    if not data then
      return nil, "pem: base64 decode error in block: " .. begin_label
    end

    blocks[#blocks + 1] = { label = begin_label, data = data }
  end

  return blocks
end

--- Decode the first PEM block from a string.
-- Returns: {label=string, data=binary_string}, nil  OR  nil, errmsg
--: (string) -> { label: string, data: string } | (nil, string)
function M.decode(str)
  local result, err = M.decode_all(str)
  if result then
    local blocks = result --[[:! { { label: string, data: string }, ... } ]]
    if #blocks == 0 then return nil, "pem: no PEM block found" end
    return blocks[1]
  end
  local errmsg = err --[[:! string | nil]]
  return nil, errmsg or "pem: decode_all failed"
end

--- Encode binary data to a PEM block.
-- label: e.g. "CERTIFICATE", "PRIVATE KEY"
-- data: raw binary string
-- opts: { line_length = 64 }
-- Returns: pem_string (includes trailing newline)  OR  nil, errmsg
--: (string, string, { line_length: number | nil } | nil) -> string | (nil, string)
function M.encode(label, data, opts)
  if not valid_label(label) then
    return nil, "pem: invalid label (must be A-Z 0-9 space hyphen): " .. tostring(label)
  end

  local line_len = (opts and opts.line_length) or 64
  if type(line_len) ~= "number" then
    return nil, "pem: line_length must be a positive number"
  end
  if line_len < 1 then
    return nil, "pem: line_length must be a positive number"
  end
  local line_len_i = math.floor(line_len) --: integer

  local b64 = base64.encode(data)
  local lines = {}
  lines[#lines + 1] = "-----BEGIN " .. label .. "-----"

  local b64_len = #b64
  local k = 1 --: integer
  while k <= b64_len do
    lines[#lines + 1] = b64:sub(k, k + line_len_i - 1)
    k = k + line_len_i
  end
  -- empty data edge case: no body lines, that's fine

  lines[#lines + 1] = "-----END " .. label .. "-----"
  lines[#lines + 1] = ""  -- trailing newline via concat with \n

  return concat(lines, "\n")
end

--- Check if a string looks like PEM (has a -----BEGIN line).
--: (string) -> boolean
function M.is_pem(str)
  return str:find("%-%-%-%-%-BEGIN [A-Z0-9 %-]+%-%-%-%-%-") ~= nil
end

--- Get the label from the first PEM block without fully decoding.
-- Returns: label_string, nil  OR  nil, errmsg
--: (string) -> string | (nil, string)
function M.label(str)
  -- Scan lines for first BEGIN
  local i = 1
  local len = #str
  while i <= len do
    local line_end = str:find("\n", i, true)
    local line
    if line_end then
      line = str:sub(i, line_end - 1)
      if line:sub(-1) == "\r" then line = line:sub(1, -2) end
      i = line_end + 1
    else
      line = str:sub(i)
      i = len + 1
    end
    local label = parse_begin(line)
    if label then return label end
  end
  return nil, "pem: no PEM block found"
end

return M
