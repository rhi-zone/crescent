if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local bit = require("bit")

local M = {}
M._tier = "pure"

--:: HuffNode = { freq: number, sym: unknown, left: HuffNode | nil, right: HuffNode | nil }

-- Build a Huffman tree from a frequency table.
-- freqs: {symbol = count, ...}
-- Returns: root node of Huffman tree, or nil, errmsg
--: ({ [unknown]: number }) -> (HuffNode | nil, string | nil)
function M.build_tree(freqs)
  if type(freqs) ~= "table" then
    return nil, "freqs must be a table"
  end

  local nodes = {} --: { [integer]: HuffNode }
  for sym, freq in pairs(freqs) do
    if type(freq) ~= "number" or freq < 0 then
      return nil, "frequency for symbol " .. tostring(sym) .. " must be a non-negative number"
    end
    nodes[#nodes + 1] = { freq = freq, sym = sym, left = nil, right = nil }
  end

  if #nodes == 0 then
    return nil, "freqs table is empty"
  end

  -- Single symbol: return leaf directly
  if #nodes == 1 then
    return nodes[1]
  end

  -- Repeatedly merge the two lowest-frequency nodes.
  -- Tie-break by symbol key for determinism (nil sym = internal node, sort last).
  local function node_lt(a, b)
    if a.freq ~= b.freq then return a.freq < b.freq end
    -- Both leaves: compare symbol lexicographically
    if a.sym ~= nil and b.sym ~= nil then
      return tostring(a.sym) < tostring(b.sym)
    end
    -- Leaves before internal nodes on tie
    if a.sym ~= nil then return true end
    if b.sym ~= nil then return false end
    return false
  end

  while #nodes > 1 do
    table.sort(nodes, node_lt)
    local left = table.remove(nodes, 1) --[[:! HuffNode]]
    local right = table.remove(nodes, 1) --[[:! HuffNode]]
    nodes[#nodes + 1] = {
      freq = left.freq + right.freq,
      sym = nil,
      left = left,
      right = right,
    }
  end

  return nodes[1]
end

-- DFS traversal to assign bit-string codes to each leaf symbol.
--: (HuffNode, string, { [unknown]: string }) -> nil
local function build_codes_dfs(node, prefix, codes)
  if node.sym ~= nil then
    -- Single-symbol tree: assign "0" if prefix is empty
    codes[node.sym] = prefix == "" and "0" or prefix
    return
  end
  if node.left then
    build_codes_dfs(node.left, prefix .. "0", codes)
  end
  if node.right then
    build_codes_dfs(node.right, prefix .. "1", codes)
  end
end

-- Build Huffman codes from a tree.
-- Returns: {symbol = bitstring, ...}  (bitstring is "0101..." string of 0s and 1s)
function M.build_codes(tree)
  if tree == nil then
    return nil, "tree is nil"
  end
  local codes = {}
  build_codes_dfs(tree, "", codes)
  return codes
end

-- Pack a binary string of '0'/'1' characters into bytes.
--: (string) -> string
local function pack_bits(bits)
  local bytes = {}
  for i = 1, #bits, 8 do
    local byte_bits = bits:sub(i, i + 7)
    -- Pad to 8 bits with zeros
    while #byte_bits < 8 do
      byte_bits = byte_bits .. "0"
    end
    local val = 0
    for j = 1, 8 do
      if byte_bits:sub(j, j) == "1" then
        val = bit.bor(val, bit.lshift(1, 8 - j))
      end
    end
    bytes[#bytes + 1] = string.char(val)
  end
  return table.concat(bytes)
end

-- Encode a sequence of symbols using the given code table.
-- symbols: array of symbols {s1, s2, ...}
-- codes: output of build_codes
-- Returns: bit-packed string, total_bits
function M.encode_symbols(symbols, codes)
  if type(symbols) ~= "table" then
    return nil, nil, "symbols must be an array"
  end
  if type(codes) ~= "table" then
    return nil, nil, "codes must be a table"
  end

  local parts = {}
  for i = 1, #symbols do
    local sym = symbols[i]
    local code = codes[sym]
    if code == nil then
      return nil, nil, "no code for symbol: " .. tostring(sym)
    end
    parts[#parts + 1] = code
  end

  local bits = table.concat(parts)
  local total_bits = #bits
  local packed = pack_bits(bits)
  return packed, total_bits
end

-- Decode a bit-packed string back to symbols using the Huffman tree.
-- Returns: array of symbols
function M.decode_symbols(bits_string, total_bits, tree)
  if type(bits_string) ~= "string" then
    return nil, "bits_string must be a string"
  end
  if type(total_bits) ~= "number" then
    return nil, "total_bits must be a number"
  end
  if tree == nil then
    return nil, "tree is nil"
  end

  -- Single-symbol tree (leaf node at root)
  if tree.sym ~= nil then
    local result = {}
    for _ = 1, total_bits do
      result[#result + 1] = tree.sym
    end
    return result
  end

  -- Unpack bytes back to bit string (only use total_bits significant bits)
  local bits = {}
  for i = 1, #bits_string do
    local byte = string.byte(bits_string, i) or 0
    for j = 7, 0, -1 do
      bits[#bits + 1] = bit.band(bit.rshift(byte, j), 1) == 1 and "1" or "0"
    end
  end

  local symbols = {}
  local node = tree
  local bit_count = 0
  for i = 1, total_bits do
    local b = bits[i]
    if b == "0" then
      node = node.left
    else
      node = node.right
    end
    if node == nil then
      return nil, "invalid bit stream: fell off tree at bit " .. i
    end
    if node.sym ~= nil then
      symbols[#symbols + 1] = node.sym
      node = tree
      bit_count = bit_count + 1
    end
  end

  return symbols
end

-- High-level: encode a string using byte-level Huffman coding.
-- Returns: encoded_bytes, metadata, err
-- metadata: {freqs=..., total_bits=n}
function M.compress(str)
  if type(str) ~= "string" then
    return nil, nil, "input must be a string"
  end

  -- Handle empty string
  if #str == 0 then
    return "", { freqs = {}, total_bits = 0 }
  end

  -- Compute byte frequencies
  local freqs = {} --: { [integer]: number }
  for i = 1, #str do
    local b = (string.byte(str, i) or 0) --[[:! integer]]
    freqs[b] = (freqs[b] or 0) + 1
  end

  local tree, err = M.build_tree(freqs)
  if tree == nil then
    return nil, nil, err
  end

  local codes, cerr = M.build_codes(tree)
  if codes == nil then
    return nil, nil, cerr
  end

  -- Convert string to symbol array (byte values)
  local symbols = {}
  for i = 1, #str do
    symbols[i] = string.byte(str, i)
  end

  local encoded, total_bits, eerr = M.encode_symbols(symbols, codes)
  if encoded == nil then
    return nil, nil, eerr
  end

  return encoded, { freqs = freqs, total_bits = total_bits }
end

-- Decompress a previously compressed string.
-- Returns: str, err
function M.decompress(encoded, metadata)
  if type(encoded) ~= "string" then
    return nil, "encoded must be a string"
  end
  if type(metadata) ~= "table" then
    return nil, "metadata must be a table"
  end
  local meta = metadata --[[:! { total_bits: number, freqs: { [unknown]: number } }]]

  -- Handle empty string
  if meta.total_bits == 0 then
    return ""
  else
  local freqs = meta.freqs
  local total_bits = meta.total_bits

  local tree, err = M.build_tree(freqs)
  if tree == nil then
    return nil, err
  end

  local symbols, derr = M.decode_symbols(encoded, total_bits, tree)
  if symbols == nil then
    return nil, derr
  end
  local symbols_ = (symbols --[[: unknown]]) --[[:! { [integer]: integer }]]

  local chars = {}
  for i = 1, #symbols_ do
    chars[i] = string.char(symbols_[i])
  end

  return table.concat(chars)
  end
end

-- Get code lengths (depth of each leaf) from a tree.
-- Returns: {symbol = length, ...}
--: (HuffNode, integer, { [unknown]: integer }) -> nil
local function code_lengths_dfs(node, depth, lengths)
  if node.sym ~= nil then
    lengths[node.sym] = depth == 0 and 1 or depth
    return
  end
  if node.left then
    code_lengths_dfs(node.left, depth + 1, lengths)
  end
  if node.right then
    code_lengths_dfs(node.right, depth + 1, lengths)
  end
end

function M.code_lengths(tree)
  if tree == nil then
    return nil, "tree is nil"
  end
  local lengths = {}
  code_lengths_dfs(tree, 0, lengths)
  return lengths
end

-- Canonical Huffman codes from symbol lengths.
-- Symbols with same length get consecutive codes; longer = left-shifted.
-- symbol_lengths: {symbol = length, ...}
-- Returns: {symbol = bitstring, ...}
--: ({ [unknown]: integer }) -> ({ [unknown]: string } | nil, string | nil)
function M.canonical_codes(symbol_lengths)
  if type(symbol_lengths) ~= "table" then
    return nil, "symbol_lengths must be a table"
  end

  -- Collect (symbol, length) pairs and sort by (length, symbol)
  local pairs_list = {} --: { [integer]: { sym: unknown, len: integer } }
  for sym, len in pairs(symbol_lengths) do
    pairs_list[#pairs_list + 1] = { sym = sym, len = len --[[:! integer]] }
  end
  local sort_any = table.sort --[[: unknown]]
  sort_any(pairs_list, function(a, b)
    if a.len ~= b.len then
      return a.len < b.len
    end
    return tostring(a.sym) < tostring(b.sym)
  end)

  local codes = {}
  local code = 0
  local prev_len = 0

  for i = 1, #pairs_list do
    local sym = pairs_list[i].sym
    local len = pairs_list[i].len

    -- Shift code left when moving to a longer length
    if len > prev_len and prev_len > 0 then
      code = bit.lshift(code, len - prev_len)
    end
    prev_len = len

    -- Convert integer code to bit string of length `len`
    local bits = {}
    for j = len - 1, 0, -1 do
      bits[#bits + 1] = bit.band(bit.rshift(code, j), 1) == 1 and "1" or "0"
    end
    codes[sym] = table.concat(bits)

    code = code + 1
  end

  return codes
end

-- Serialize a frequency table to a string.
-- Format: "sym:freq\n" lines; sym is hex-encoded byte value (integer key)
-- or URL-encoded for string keys.
local function encode_sym(sym)
  if type(sym) == "number" then
    return string.format("n%d", sym)
  else
    -- Escape colons, newlines, backslashes
    local s = tostring(sym)
    s = s:gsub("\\", "\\\\"):gsub(":", "\\:"):gsub("\n", "\\n")
    return "s" .. s
  end
end

local function decode_sym(s)
  if s:sub(1, 1) == "n" then
    return tonumber(s:sub(2))
  else
    local val = s:sub(2)
    val = val:gsub("\\n", "\n"):gsub("\\:", ":"):gsub("\\\\", "\\")
    return val
  end
end

function M.serialize_freqs(freqs)
  if type(freqs) ~= "table" then
    return nil, "freqs must be a table"
  end
  local parts = {}
  for sym, freq in pairs(freqs) do
    parts[#parts + 1] = encode_sym(sym) .. ":" .. tostring(freq)
  end
  table.sort(parts)
  return table.concat(parts, "\n")
end

function M.deserialize_freqs(s)
  if type(s) ~= "string" then
    return nil, "input must be a string"
  end
  if s == "" then
    return {}
  end
  local freqs = {}
  for line in (s .. "\n"):gmatch("([^\n]*)\n") do
    if line ~= "" then
      -- Split on last colon (sym may contain escaped colons)
      -- We need to find the unescaped colon that separates sym from freq
      local sep = nil
      local i = 1
      while i <= #line do
        local c = line:sub(i, i)
        if c == "\\" then
          i = i + 2 -- skip escaped char
        elseif c == ":" then
          sep = i
          i = i + 1
        else
          i = i + 1
        end
      end
      if sep == nil then
        return nil, "malformed line: " .. line
      end
      local sym_enc = line:sub(1, sep - 1)
      local freq_str = line:sub(sep + 1)
      local sym = decode_sym(sym_enc)
      local freq = tonumber(freq_str)
      if freq == nil then
        return nil, "malformed frequency: " .. freq_str
      end
      freqs[sym] = freq
    end
  end
  return freqs
end

-- Shannon entropy in bits.
--: ({ [unknown]: number }) -> (number | nil, string | nil)
function M.entropy(freqs)
  if type(freqs) ~= "table" then
    return nil, "freqs must be a table"
  end
  local freqs_ = freqs --[[: unknown]]
  local total = 0 --: number
  for _, freq in pairs(freqs_) do
    total = total + (freq --[[:! number]])
  end
  if total == 0 then
    return 0
  end
  local h = 0 --: number
  local log2 = math.log(2)
  for _, freq in pairs(freqs_) do
    local freq_ = freq --[[:! number]]
    if freq_ > 0 then
      local p = freq_ / total
      h = h - p * math.log(p) / log2
    end
  end
  return h
end

-- Expected bits per symbol given a code table and frequency table.
--: ({ [unknown]: number }, { [unknown]: string }) -> (number | nil, string | nil)
function M.expected_length(freqs, codes)
  if type(freqs) ~= "table" then
    return nil, "freqs must be a table"
  end
  if type(codes) ~= "table" then
    return nil, "codes must be a table"
  end
  local freqs_ = freqs --[[: unknown]]
  local codes_ = codes --[[: unknown]]
  local total = 0 --: number
  for _, freq in pairs(freqs_) do
    total = total + (freq --[[:! number]])
  end
  if total == 0 then
    return 0
  end
  local avg = 0 --: number
  for sym, freq in pairs(freqs_) do
    local code = codes_[sym]
    if code == nil then
      return nil, "no code for symbol: " .. tostring(sym)
    end
    avg = avg + ((freq --[[:! number]]) / total) * #code
  end
  return avg
end

return M
