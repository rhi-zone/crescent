if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

--- Ring buffer (circular buffer) library.
-- Two flavors:
--   ringbuf.new(capacity)   — general-purpose, stores arbitrary Lua values
--   ringbuf.bytes(capacity) — byte-oriented, stores a flat byte stream

local M = {}

--:: RingBuf = { _buf: { [integer]: unknown }, _cap: integer, _head: integer, _tail: integer, _len: integer }
--:: ByteRingBuf = { _buf: { [integer]: integer }, _cap: integer, _head: integer, _tail: integer, _len: integer }

--: string
M._tier = "pure"

-- ── value ring buffer ─────────────────────────────────────────────────────────

local RingBuf = {}
RingBuf.__index = RingBuf

--- Create a new value ring buffer with the given capacity.
--: (capacity: integer) -> RingBuf
function M.new(capacity)
	assert(type(capacity) == "number" and capacity >= 1 and capacity == math.floor(capacity),
		"capacity must be a positive integer")
	-- _head: 1-based index of oldest item
	-- _tail: 1-based index of next write slot
	-- Indices are stored 1-based; wrap via (idx % cap + 1) where cap = _cap
	return setmetatable({
		_buf  = {},
		_head = 1,
		_tail = 1,
		_len  = 0,
		_cap  = capacity,
	}, RingBuf)
end

--- Push a value. Returns true on success, (nil, "full") when at capacity.
function RingBuf:push(v)
	local s = self --[[:! RingBuf]]
	if s._len == s._cap then
		return nil, "full"
	end
	s._buf[s._tail] = v
	s._tail = s._tail % s._cap + 1
	s._len  = s._len + 1
	return true
end

--- Push a value, evicting the oldest item if the buffer is full.
function RingBuf:push_overwrite(v)
	local s = self --[[:! RingBuf]]
	if s._len == s._cap then
		s._buf[s._head] = nil
		s._head = s._head % s._cap + 1
		s._len  = s._len - 1
	end
	s._buf[s._tail] = v
	s._tail = s._tail % s._cap + 1
	s._len  = s._len + 1
end

--- Pop the oldest value. Returns value, or nil when empty.
function RingBuf:pop()
	local s = self --[[:! RingBuf]]
	if s._len == 0 then return nil end
	local v = s._buf[s._head]
	s._buf[s._head] = nil
	s._head = s._head % s._cap + 1
	s._len  = s._len - 1
	return v
end

--- Peek at the oldest value without removing it. Returns value or nil.
function RingBuf:peek()
	local s = self --[[:! RingBuf]]
	if s._len == 0 then return nil end
	return s._buf[s._head]
end

--- Peek at the newest value without removing it. Returns value or nil.
function RingBuf:peek_newest()
	local s = self --[[:! RingBuf]]
	if s._len == 0 then return nil end
	-- _tail points to next write slot; newest is one slot before that.
	local idx = (s._tail - 2) % s._cap + 1
	return s._buf[idx]
end

--- Return true if the buffer has no items.
function RingBuf:is_empty()
	local s = self --[[:! RingBuf]]
	return s._len == 0
end

--- Return true if the buffer is at capacity.
function RingBuf:is_full()
	local s = self --[[:! RingBuf]]
	return s._len == s._cap
end

--- Return the number of items currently in the buffer.
function RingBuf:len()
	local s = self --[[:! RingBuf]]
	return s._len
end

--- Return the maximum capacity of the buffer.
function RingBuf:capacity()
	local s = self --[[:! RingBuf]]
	return s._cap
end

--- Remove all items from the buffer.
function RingBuf:clear()
	local s = self --[[:! RingBuf]]
	for i = 1, s._cap do
		s._buf[i] = nil
	end
	s._head = 1
	s._tail = 1
	s._len  = 0
end

--- Return a sequential table snapshot of the buffer, oldest first.
function RingBuf:to_array()
	local s   = self --[[:! RingBuf]]
	local out = {}
	local idx = s._head
	local cap = s._cap
	local buf = s._buf
	for i = 1, s._len do
		out[i] = buf[idx]
		idx = idx % cap + 1
	end
	return out
end

--- Return an iterator over the buffer values, oldest first.
-- Usage: for v in r:iter() do ... end
function RingBuf:iter()
	local s         = self --[[:! RingBuf]]
	local idx       = s._head
	local remaining = s._len
	local cap       = s._cap
	local buf       = s._buf
	return function()
		if remaining == 0 then return nil end
		local v = buf[idx]
		idx       = idx % cap + 1
		remaining = remaining - 1
		return v
	end
end

-- ── byte ring buffer ──────────────────────────────────────────────────────────

local ByteRingBuf = {}
ByteRingBuf.__index = ByteRingBuf

--- Create a new byte ring buffer with the given capacity (bytes).
--: (capacity: integer) -> ByteRingBuf
function M.bytes(capacity)
	assert(type(capacity) == "number" and capacity >= 1 and capacity == math.floor(capacity),
		"capacity must be a positive integer")
	return setmetatable({
		_buf  = {},  -- 1-indexed byte storage (numbers 0-255)
		_head = 1,   -- index of oldest byte
		_tail = 1,   -- index where next byte will be written
		_len  = 0,
		_cap  = capacity,
	}, ByteRingBuf)
end

--- Push a string of bytes into the buffer.
-- Returns true on success, (nil, "not enough space") if insufficient room.
function ByteRingBuf:push_string(s_str)
	local s    = self --[[:! ByteRingBuf]]
	local slen = #s_str
	if slen == 0 then return true end
	if slen > s._cap - s._len then
		return nil, "not enough space"
	end
	local buf  = s._buf
	local tail = s._tail
	local cap  = s._cap
	for i = 1, slen do
		buf[tail] = s_str:byte(i)
		tail = tail % cap + 1
	end
	s._tail = tail
	s._len  = s._len + slen
	return true
end

--- Pop n bytes from the buffer as a string (destructive).
-- Returns the string, or (nil, "not enough data") if fewer than n bytes available.
function ByteRingBuf:pop_string(n)
	local s = self --[[:! ByteRingBuf]]
	if n == 0 then return "" end
	if n > s._len then
		return nil, "not enough data"
	end
	local buf  = s._buf
	local head = s._head
	local cap  = s._cap
	local t    = {}
	for i = 1, n do
		t[i]  = buf[head]
		buf[head] = nil
		head  = head % cap + 1
	end
	s._head = head
	s._len  = s._len - n
	return string.char(unpack(t))
end

--- Peek at the next n bytes as a string without consuming them.
-- Returns the string, or (nil, "not enough data").
function ByteRingBuf:peek_string(n)
	local s = self --[[:! ByteRingBuf]]
	if n == 0 then return "" end
	if n > s._len then
		return nil, "not enough data"
	end
	local buf = s._buf
	local idx = s._head
	local cap = s._cap
	local t   = {}
	for i = 1, n do
		t[i] = buf[idx]
		idx  = idx % cap + 1
	end
	return string.char(unpack(t))
end

--- Return the number of bytes currently stored.
function ByteRingBuf:available()
	local s = self --[[:! ByteRingBuf]]
	return s._len
end

--- Return the number of bytes that can still be written.
function ByteRingBuf:free()
	local s = self --[[:! ByteRingBuf]]
	return s._cap - s._len
end

--- Remove all bytes from the buffer.
function ByteRingBuf:clear()
	local s = self --[[:! ByteRingBuf]]
	for i = 1, s._cap do
		s._buf[i] = nil
	end
	s._head = 1
	s._tail = 1
	s._len  = 0
end

return M
