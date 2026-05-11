-- lib/wire_protocol/init.lua
-- Binary wire protocol framing codecs.
-- Length-prefixed, delimited, fixed-size, TLV, varint, pack/unpack.
-- Pure Lua — no dependencies, works on LuaJIT and PUC-Rio Lua 5.2+.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

local byte, char, sub, find, rep = string.byte, string.char, string.sub, string.find, string.rep
local concat = table.concat
local floor = math.floor

-- ---------------------------------------------------------------------------
-- Internal helpers: integer encode/decode
-- ---------------------------------------------------------------------------

-- Encode an unsigned integer into `n` bytes, big-endian.
local function uint_to_be(v, n)
  local t = {} --: { [integer]: string }
  for i = n, 1, -1 do
    local i_ = i --[[:! integer]]
    t[i_] = char((v % 256) --[[:! integer]])
    v = floor(v / 256)
  end
  return concat(t)
end

-- Encode an unsigned integer into `n` bytes, little-endian.
local function uint_to_le(v, n)
  local t = {} --: { [integer]: string }
  for i = 1, n do
    local i_ = i --[[:! integer]]
    t[i_] = char((v % 256) --[[:! integer]])
    v = floor(v / 256)
  end
  return concat(t)
end

-- Decode `n` bytes starting at `pos` as big-endian unsigned integer.
-- Returns value, next_pos.
--: (string, integer, integer) -> (integer, integer)
local function be_to_uint(s, pos, n)
  local v = 0 --: number
  for i = pos, pos + n - 1 do
    v = v * 256 + (byte(s, i) or 0)
  end
  return floor(v), pos + n
end

-- Decode `n` bytes starting at `pos` as little-endian unsigned integer.
--: (string, integer, integer) -> (integer, integer)
local function le_to_uint(s, pos, n)
  local v = 0 --: number
  local mul = 1 --: number
  for i = pos, pos + n - 1 do
    v = v + (byte(s, i) or 0) * mul
    mul = mul * 256
  end
  return floor(v), pos + n
end

-- ---------------------------------------------------------------------------
-- Varint (unsigned LEB128, protobuf-style)
-- ---------------------------------------------------------------------------

--- Encode an unsigned integer as a LEB128 varint.
--: (integer) -> (string | nil, string | nil)
function M.encode_varint(v)
  if v < 0 then return nil, "encode_varint: negative values not supported" end
  local t = {}
  local i = 1
  repeat
    local b = v % 128
    v = floor(v / 128)
    if v > 0 then b = b + 128 end
    t[i] = char(b)
    i = i + 1
  until v == 0
  return concat(t)
end

--- Decode a LEB128 varint from string s at position pos (default 1).
-- Returns value, bytes_consumed or nil, errmsg.
--: (string, integer | nil) -> (integer | nil, integer | string)
function M.decode_varint(s, pos)
  pos = pos or 1
  local v = 0 --: number
  local shift = 0
  local len = #s
  local consumed = 0
  while true do
    if pos > len then
      return nil, "decode_varint: incomplete varint"
    end
    local b = (byte(s, pos) or 0)
    pos = pos + 1
    consumed = consumed + 1
    v = v + (b % 128) * (2 ^ shift)
    shift = shift + 7
    if b < 128 then break end
    if shift > 63 then
      return nil, "decode_varint: varint too large"
    end
  end
  return floor(v), consumed
end

-- ---------------------------------------------------------------------------
-- pack / unpack — simple binary struct codec
-- ---------------------------------------------------------------------------
-- Format string: ">" big-endian, "<" little-endian
-- B=uint8, H=uint16, I=uint32, Q=uint64
-- b=int8,  h=int16,  i=int32,  q=int64
-- s=string (consumes remaining bytes on unpack; packs as-is)

--- Pack values into a binary string.
--: (string, ...unknown) -> (string | nil, string | nil)
function M.pack(fmt, ...)
  local endian = "big"
  local i = 1
  if sub(fmt, 1, 1) == ">" then endian = "big"; i = 2
  elseif sub(fmt, 1, 1) == "<" then endian = "little"; i = 2
  end
  local args = {...}
  local ai = 1
  local parts = {} --: { [integer]: string }
  local pi = 1
  while (i --[[:! integer]]) <= #fmt do
    local c = sub(fmt, i, i)
    i = i + 1
    local v = (args[ai] --[[:! number]]); ai = ai + 1
    if c == "B" then
      parts[pi] = char((v % 256) --[[:! integer]]); pi = pi + 1
    elseif c == "b" then
      if v < 0 then v = v + 256 end
      parts[pi] = char((v % 256) --[[:! integer]]); pi = pi + 1
    elseif c == "H" then
      if endian == "big" then parts[pi] = uint_to_be(v % 65536, 2)
      else parts[pi] = uint_to_le(v % 65536, 2) end
      pi = pi + 1
    elseif c == "h" then
      if v < 0 then v = v + 65536 end
      if endian == "big" then parts[pi] = uint_to_be(v % 65536, 2)
      else parts[pi] = uint_to_le(v % 65536, 2) end
      pi = pi + 1
    elseif c == "I" then
      local uv = v % 4294967296
      if endian == "big" then parts[pi] = uint_to_be(uv, 4)
      else parts[pi] = uint_to_le(uv, 4) end
      pi = pi + 1
    elseif c == "i" then
      if v < 0 then v = v + 4294967296 end
      local uv = v % 4294967296
      if endian == "big" then parts[pi] = uint_to_be(uv, 4)
      else parts[pi] = uint_to_le(uv, 4) end
      pi = pi + 1
    elseif c == "Q" then
      -- 64-bit: split into high/low 32-bit
      local lo = v % 4294967296
      local hi = floor(v / 4294967296) % 4294967296
      if endian == "big" then
        parts[pi] = uint_to_be(hi, 4) .. uint_to_be(lo, 4)
      else
        parts[pi] = uint_to_le(lo, 4) .. uint_to_le(hi, 4)
      end
      pi = pi + 1
    elseif c == "q" then
      if v < 0 then v = v + 2^64 end
      local lo = v % 4294967296
      local hi = floor(v / 4294967296) % 4294967296
      if endian == "big" then
        parts[pi] = uint_to_be(hi, 4) .. uint_to_be(lo, 4)
      else
        parts[pi] = uint_to_le(lo, 4) .. uint_to_le(hi, 4)
      end
      pi = pi + 1
    elseif c == "s" then
      table.insert(parts, tostring(v))
      pi = pi + 1
    else
      return nil, "pack: unknown format specifier '" .. c .. "'"
    end
  end
  return concat(parts)
end

--- Unpack values from a binary string.
-- Returns multiple values (one per format specifier).
--: (string, string) -> (...unknown)
function M.unpack(fmt, s)
  local endian = "big"
  local fi = 1
  if sub(fmt, 1, 1) == ">" then endian = "big"; fi = 2
  elseif sub(fmt, 1, 1) == "<" then endian = "little"; fi = 2
  end
  local pos = 1
  local results = {} --: { [integer]: unknown }
  local ri = 1
  while (fi --[[:! integer]]) <= #fmt do
    local c = sub(fmt, fi, fi)
    fi = fi + 1
    if c == "B" then
      results[ri] = (byte(s, pos) or 0) --[[:! integer]]; pos = pos + 1; ri = ri + 1
    elseif c == "b" then
      local v = (byte(s, pos) or 0) --[[:! integer]]; pos = pos + 1
      if v >= 128 then v = v - 256 end
      results[ri] = v; ri = ri + 1
    elseif c == "H" then
      local v = 0 --: integer
      local npos = pos
      if endian == "big" then v, npos = be_to_uint(s, pos, 2)
      else v, npos = le_to_uint(s, pos, 2) end
      pos = npos; results[ri] = v; ri = ri + 1
    elseif c == "h" then
      local v = 0 --: integer
      local npos = pos
      if endian == "big" then v, npos = be_to_uint(s, pos, 2)
      else v, npos = le_to_uint(s, pos, 2) end
      pos = npos
      if v >= 32768 then v = v - 65536 end
      results[ri] = v; ri = ri + 1
    elseif c == "I" then
      local v = 0 --: integer
      local npos = pos
      if endian == "big" then v, npos = be_to_uint(s, pos, 4)
      else v, npos = le_to_uint(s, pos, 4) end
      pos = npos; results[ri] = v; ri = ri + 1
    elseif c == "i" then
      local v = 0 --: integer
      local npos = pos
      if endian == "big" then v, npos = be_to_uint(s, pos, 4)
      else v, npos = le_to_uint(s, pos, 4) end
      pos = npos
      if v >= 2147483648 then v = (v - 4294967296) --[[:! integer]] end
      results[ri] = v; ri = ri + 1
    elseif c == "Q" then
      local hi = 0 --: integer
      local lo = 0 --: integer
      local npos = pos
      if endian == "big" then
        hi, npos = be_to_uint(s, pos, 4)
        lo, npos = be_to_uint(s, npos, 4)
      else
        lo, npos = le_to_uint(s, pos, 4)
        hi, npos = le_to_uint(s, npos, 4)
      end
      pos = npos
      results[ri] = hi * 4294967296 + lo; ri = ri + 1
    elseif c == "q" then
      local hi = 0 --: integer
      local lo = 0 --: integer
      local npos = pos
      if endian == "big" then
        hi, npos = be_to_uint(s, pos, 4)
        lo, npos = be_to_uint(s, npos, 4)
      else
        lo, npos = le_to_uint(s, pos, 4)
        hi, npos = le_to_uint(s, npos, 4)
      end
      pos = npos
      local v = hi * 4294967296 + lo
      if hi >= 2147483648 then v = v - 2^64 end
      results[ri] = v; ri = ri + 1
    elseif c == "s" then
      results[ri] = sub(s, pos); pos = #s + 1; ri = ri + 1
    else
      return nil, "unpack: unknown format specifier '" .. c .. "'"
    end
  end
  return unpack(results, 1, ri - 1)
end

-- ---------------------------------------------------------------------------
-- Length-prefixed codec
-- ---------------------------------------------------------------------------

--- Build a length-prefixed frame codec.
-- opts.length_size: 1, 2, 4, or 8 (default 4)
-- opts.endian: "big" or "little" (default "big")
-- opts.max_frame_size: maximum payload size (default 4MB)
-- opts.include_length: whether length field includes itself (default false)
function M.length_prefixed(opts)
  opts = opts or {}
  local lsz = (opts.length_size or 4)
  local endian = opts.endian or "big"
  local max_size = (opts.max_frame_size or (4 * 1024 * 1024))
  local include_length = (opts.include_length or false) --[[:! boolean]]

  if lsz ~= 1 and lsz ~= 2 and lsz ~= 4 and lsz ~= 8 then
    error("length_prefixed: length_size must be 1, 2, 4, or 8")
  end

  local codec = {}

  --- Encode a payload string into a length-prefixed frame.
  --: (string) -> (string | nil, string)
  function codec:encode(payload)
    local plen = #payload
    if plen > max_size then
      return nil, "encode: payload exceeds max_frame_size (" .. plen .. " > " .. max_size .. ")"
    end
    local length_val = include_length and (plen + lsz) or plen
    local header
    if endian == "big" then
      header = uint_to_be(length_val, lsz)
    else
      header = uint_to_le(length_val, lsz)
    end
    return header .. payload
  end

  --- Decode a single complete frame. Returns payload, rest.
  --: (string) -> (string | nil, string)
  function codec:decode(s)
    if #s < lsz then
      return nil, "decode: not enough data for length header"
    end
    local length_val = 0 --: integer
    local next_pos = 1 --: integer
    if endian == "big" then
      length_val, next_pos = be_to_uint(s, 1, lsz)
    else
      length_val, next_pos = le_to_uint(s, 1, lsz)
    end
    local plen = include_length and (length_val - lsz) or length_val
    if plen < 0 then
      return nil, "decode: length field smaller than header size"
    end
    if plen > max_size then
      return nil, "decode: frame too large (" .. plen .. " > " .. max_size .. ")"
    end
    local frame_end = next_pos + plen - 1
    if #s < frame_end then
      return nil, "decode: incomplete frame"
    end
    return sub(s, next_pos, frame_end), sub(s, frame_end + 1)
  end

  --- Create a stateful streaming decoder.
  function codec:decoder()
    local dec = { _buf = "" }

    function dec:feed(data)
      self._buf = self._buf .. data
    end

    function dec:messages()
      local msgs = {}
      local mi = 1
      local buf = self._buf
      while true do
        if #buf < lsz then break end
        local length_val = 0 --: integer
        local next_pos = 1 --: integer
        if endian == "big" then
          length_val, next_pos = be_to_uint(buf, 1, lsz)
        else
          length_val, next_pos = le_to_uint(buf, 1, lsz)
        end
        local plen = include_length and (length_val - lsz) or length_val
        if plen < 0 then
          self._buf = buf
          return nil, "messages: length field smaller than header size"
        end
        if plen > max_size then
          self._buf = buf
          return nil, "messages: frame too large (" .. plen .. " > " .. max_size .. ")"
        end
        local frame_end = next_pos + plen - 1
        if #buf < frame_end then break end
        msgs[mi] = sub(buf, next_pos, frame_end)
        mi = mi + 1
        buf = sub(buf, frame_end + 1)
      end
      self._buf = buf
      return msgs
    end

    return dec
  end

  return codec
end

-- ---------------------------------------------------------------------------
-- Delimited codec
-- ---------------------------------------------------------------------------

--- Build a delimiter-based frame codec.
-- opts.delimiter: delimiter string (default "\n")
-- opts.max_frame_size: max frame size (default 64KB)
-- opts.strip_delimiter: whether to strip delimiter from decoded payload (default true)
function M.delimited(opts)
  opts = opts or {}
  local delim = (opts.delimiter or "\n")
  local max_size = (opts.max_frame_size or (64 * 1024))
  local strip = opts.strip_delimiter
  if strip == nil then strip = true end

  local codec = {}

  --- Encode a payload by appending the delimiter.
  --: (string) -> (string | nil, string)
  function codec:encode(payload)
    if #payload > max_size then
      return nil, "encode: payload exceeds max_frame_size"
    end
    return payload .. delim
  end

  --- Decode a single complete frame. Returns payload, rest.
  --: (string) -> (string | nil, string)
  function codec:decode(s)
    local dstart, dend = find(s, delim, 1, true)
    if not dstart then
      return nil, "decode: delimiter not found"
    end
    local dstart_ = dstart --[[:! integer]]
    local dend_ = dend --[[:! integer]]
    local payload_end = strip and (dstart_ - 1) or dend_
    local payload = sub(s, 1, payload_end)
    if #payload > max_size then
      return nil, "decode: frame too large"
    end
    return payload, sub(s, dend_ + 1)
  end

  --- Create a stateful streaming decoder.
  function codec:decoder()
    local dec = { _buf = "" }

    function dec:feed(data)
      self._buf = self._buf .. data
    end

    function dec:messages()
      local msgs = {}
      local mi = 1
      local buf = self._buf
      while true do
        local dstart, dend = find(buf, delim, 1, true)
        if not dstart then break end
        local dstart_ = dstart --[[:! integer]]
        local dend_ = dend --[[:! integer]]
        local payload_end = strip and (dstart_ - 1) or dend_
        local payload = sub(buf, 1, payload_end)
        if #payload > max_size then
          self._buf = buf
          return nil, "messages: frame too large"
        end
        msgs[mi] = payload
        mi = mi + 1
        buf = sub(buf, dend_ + 1)
      end
      self._buf = buf
      return msgs
    end

    return dec
  end

  return codec
end

-- ---------------------------------------------------------------------------
-- Fixed-size codec
-- ---------------------------------------------------------------------------

--- Build a fixed-size frame codec.
-- opts.size: exact frame size in bytes (required)
-- opts.pad: byte value to pad with (default 0)
function M.fixed(opts)
  opts = opts or {}
  local sz_raw = opts.size
  if not sz_raw or (sz_raw --[[:! number]]) < 1 then
    error("fixed: size must be a positive integer")
  end
  local sz = sz_raw --[[:! integer]]
  local pad_byte = (opts.pad or 0)

  local codec = {}

  --- Encode a payload, padding or truncating to fixed size.
  --: (string) -> string
  function codec:encode(payload)
    local plen = #payload
    if plen == sz then
      return payload
    elseif plen > sz then
      return sub(payload, 1, sz)
    else
      return payload .. rep(char(pad_byte), sz - plen)
    end
  end

  --- Decode a single complete fixed-size frame. Returns payload, rest.
  --: (string) -> (string | nil, string)
  function codec:decode(s)
    if #s < sz then
      return nil, "decode: not enough data (need " .. sz .. ", have " .. #s .. ")"
    end
    return sub(s, 1, sz), sub(s, sz + 1)
  end

  --- Decode all frames from a string. Returns array of frame strings.
  --: (s: string) -> string[]
  function codec:decode_all(s)
    local frames = {}
    local fi = 1
    local pos = 1
    local len = #s
    while pos + sz - 1 <= len do
      frames[fi] = sub(s, pos, pos + sz - 1)
      fi = fi + 1
      pos = pos + sz
    end
    return frames
  end

  --- Create a stateful streaming decoder.
  function codec:decoder()
    local dec = { _buf = "" }

    function dec:feed(data)
      self._buf = self._buf .. data
    end

    function dec:messages()
      local msgs = {}
      local mi = 1
      local buf = self._buf
      local len = #buf
      local pos = 1
      while pos + sz - 1 <= len do
        msgs[mi] = sub(buf, pos, pos + sz - 1)
        mi = mi + 1
        pos = pos + sz
      end
      self._buf = sub(buf, pos)
      return msgs
    end

    return dec
  end

  return codec
end

-- ---------------------------------------------------------------------------
-- TLV (Type-Length-Value) codec
-- ---------------------------------------------------------------------------

--- Build a TLV codec.
-- opts.type_size: bytes for type field (default 1)
-- opts.length_size: bytes for length field (default 2)
-- opts.endian: "big" or "little" (default "big")
-- opts.max_frame_size: max value size (default 64KB)
function M.tlv(opts)
  opts = opts or {}
  local tsz = (opts.type_size or 1)
  local lsz = (opts.length_size or 2)
  local endian = opts.endian or "big"
  local max_size = (opts.max_frame_size or (64 * 1024))

  local codec = {}

  --- Encode a TLV frame.
  --: (unknown, integer, string) -> (string | nil, string)
  function codec:encode(type_id, value)
    local vlen = #value
    if vlen > max_size then
      return nil, "encode: value exceeds max_frame_size"
    end
    local type_bytes, len_bytes
    if endian == "big" then
      type_bytes = uint_to_be(type_id, tsz)
      len_bytes = uint_to_be(vlen, lsz)
    else
      type_bytes = uint_to_le(type_id, tsz)
      len_bytes = uint_to_le(vlen, lsz)
    end
    return type_bytes .. len_bytes .. value
  end

  --- Decode a TLV frame. Returns type_id, value or nil, errmsg.
  --: (string) -> (integer | nil, string)
  function codec:decode(s)
    local header_size = tsz + lsz
    if #s < header_size then
      return nil, "decode: not enough data for TLV header"
    end
    local type_id = 0 --: integer
    local vlen = 0 --: integer
    if endian == "big" then
      type_id = (be_to_uint(s, 1, tsz))
      vlen = (be_to_uint(s, tsz + 1, lsz))
    else
      type_id = (le_to_uint(s, 1, tsz))
      vlen = (le_to_uint(s, tsz + 1, lsz))
    end
    if vlen > max_size then
      return nil, "decode: value too large (" .. vlen .. " > " .. max_size .. ")"
    end
    local frame_end = header_size + vlen
    if #s < frame_end then
      return nil, "decode: incomplete TLV frame"
    end
    return type_id, sub(s, header_size + 1, frame_end)
  end

  return codec
end

-- ---------------------------------------------------------------------------
-- Framer: encodes and buffers outgoing frames
-- ---------------------------------------------------------------------------

--:: FramerCodec = { encode: (FramerCodec, unknown) -> (string | nil, string | nil), ... }
--:: Framer = { _codec: FramerCodec, _pending: { [integer]: string }, ... }
--- Wrap a codec in a framer that buffers encoded output.
--: (codec: FramerCodec) -> Framer
function M.framer(codec)
  local fr = {} --[[: unknown]]
  local fr_ = fr --[[:! Framer]]
  fr_._codec = codec
  fr_._pending = {}

  --- Encode a message and buffer it.
  function fr_:write(msg)
    local s = self --[[:! Framer]]
    local frame, err = s._codec:encode(msg)
    if not frame then return nil, err end
    s._pending[#s._pending + 1] = frame
    return true
  end

  --- Return all buffered bytes as a single string (without clearing).
  function fr_:pending()
    local s = self --[[:! Framer]]
    return concat(s._pending)
  end

  --- Return and clear all buffered bytes.
  function fr_:flush()
    local s = self --[[:! Framer]]
    local out = concat(s._pending)
    s._pending = {}
    return out
  end

  return fr_
end

-- ---------------------------------------------------------------------------
-- Receiver: stateful incremental message reader
-- ---------------------------------------------------------------------------

--:: ReceiverDec = { feed: (ReceiverDec, string) -> nil, messages: (ReceiverDec) -> ({ [integer]: string } | nil, string | nil), ... }
--:: Receiver = { _dec: ReceiverDec, _queue: { [integer]: string }, _head: integer, ... }
--- Wrap a codec's decoder in a receiver with has_message/next interface.
--: (codec: { decoder: (unknown) -> ReceiverDec, ... }) -> Receiver
function M.receiver(codec)
  local dec = codec:decoder() --[[:! ReceiverDec]]
  local rv = {} --[[: unknown]]
  local rv_ = rv --[[:! Receiver]]
  rv_._dec = dec
  rv_._queue = {}
  rv_._head = 1

  --- Feed bytes into the receiver.
  function rv_:feed(data)
    local s = self --[[:! Receiver]]
    s._dec:feed(data)
    local msgs, err = s._dec:messages()
    if not msgs then return nil, err end
    local msgs_ = msgs --[[:! { [integer]: string }]]
    for i = 1, #msgs_ do
      s._queue[#s._queue + 1] = msgs_[i]
    end
    return true
  end

  --- Returns true if at least one complete message is available.
  function rv_:has_message()
    local s = self --[[:! Receiver]]
    return s._head <= #s._queue
  end

  --- Return the next complete message (or nil if none).
  function rv_:next()
    local s = self --[[:! Receiver]]
    if s._head > #s._queue then return nil end
    local msg = s._queue[s._head]
    s._queue[s._head] = nil --[[: unknown]]
    s._head = s._head + 1
    return msg
  end

  return rv_
end

return M
