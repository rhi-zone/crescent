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
--: (RingBuf, unknown) -> (boolean | nil, string | nil)
function RingBuf:push(v)
	if self._len == self._cap then
		return nil, "full"
	end
	self._buf[self._tail] = v
	self._tail = self._tail % self._cap + 1
	self._len  = self._len + 1
	return true
end

--- Push a value, evicting the oldest item if the buffer is full.
--: (RingBuf, unknown) -> nil
function RingBuf:push_overwrite(v)
	if self._len == self._cap then
		self._buf[self._head] = nil
		self._head = self._head % self._cap + 1
		self._len  = self._len - 1
	end
	self._buf[self._tail] = v
	self._tail = self._tail % self._cap + 1
	self._len  = self._len + 1
end

--- Pop the oldest value. Returns value, or nil when empty.
--: (RingBuf) -> unknown
function RingBuf:pop()
	if self._len == 0 then return nil
	else
		local v = self._buf[self._head]
		self._buf[self._head] = nil
		self._head = self._head % self._cap + 1
		self._len  = self._len - 1
		return v
	end
end

--- Peek at the oldest value without removing it. Returns value or nil.
--: (RingBuf) -> unknown
function RingBuf:peek()
	if self._len == 0 then return nil
	else return self._buf[self._head]
	end
end

--- Peek at the newest value without removing it. Returns value or nil.
--: (RingBuf) -> unknown
function RingBuf:peek_newest()
	if self._len == 0 then return nil
	else
		-- _tail points to next write slot; newest is one slot before that.
		local idx = (self._tail - 2) % self._cap + 1
		return self._buf[idx]
	end
end

--- Return true if the buffer has no items.
--: (RingBuf) -> boolean
function RingBuf:is_empty()
	return self._len == 0
end

--- Return true if the buffer is at capacity.
--: (RingBuf) -> boolean
function RingBuf:is_full()
	return self._len == self._cap
end

--- Return the number of items currently in the buffer.
--: (RingBuf) -> integer
function RingBuf:len()
	return self._len
end

--- Return the maximum capacity of the buffer.
--: (RingBuf) -> integer
function RingBuf:capacity()
	return self._cap
end

--- Remove all items from the buffer.
--: (RingBuf) -> nil
function RingBuf:clear()
	for i = 1, self._cap do
		self._buf[i] = nil
	end
	self._head = 1
	self._tail = 1
	self._len  = 0
end

--- Return a sequential table snapshot of the buffer, oldest first.
--: (RingBuf) -> { [integer]: unknown }
function RingBuf:to_array()
	local out = {}
	local idx = self._head
	local cap = self._cap
	local buf = self._buf
	for i = 1, self._len do
		out[i] = buf[idx]
		idx = idx % cap + 1
	end
	return out
end

--- Return an iterator over the buffer values, oldest first.
-- Usage: for v in r:iter() do ... end
--: (RingBuf) -> (() -> unknown)
function RingBuf:iter()
	local idx       = self._head
	local remaining = self._len
	local cap       = self._cap
	local buf       = self._buf
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
--: (ByteRingBuf, string) -> (boolean | nil, string | nil)
function ByteRingBuf:push_string(s_str)
	local slen = #s_str
	if slen == 0 then return true end
	if slen > self._cap - self._len then
		return nil, "not enough space"
	end
	local buf  = self._buf
	local tail = self._tail
	local cap  = self._cap
	for i = 1, slen do
		buf[tail] = s_str:byte(i)
		tail = tail % cap + 1
	end
	self._tail = tail
	self._len  = self._len + slen
	return true
end

--- Pop n bytes from the buffer as a string (destructive).
-- Returns the string, or (nil, "not enough data") if fewer than n bytes available.
--: (ByteRingBuf, integer) -> (string | nil, string | nil)
function ByteRingBuf:pop_string(n)
	if n == 0 then return "" end
	if n > self._len then
		return nil, "not enough data"
	end
	local buf  = self._buf
	local head = self._head
	local cap  = self._cap
	local t    = {}
	for i = 1, n do
		t[i]  = buf[head]
		buf[head] = nil
		head  = head % cap + 1
	end
	self._head = head
	self._len  = self._len - n
	return string.char(unpack(t))
end

--- Peek at the next n bytes as a string without consuming them.
-- Returns the string, or (nil, "not enough data").
--: (ByteRingBuf, integer) -> (string | nil, string | nil)
function ByteRingBuf:peek_string(n)
	if n == 0 then return "" end
	if n > self._len then
		return nil, "not enough data"
	end
	local buf = self._buf
	local idx = self._head
	local cap = self._cap
	local t   = {}
	for i = 1, n do
		t[i] = buf[idx]
		idx  = idx % cap + 1
	end
	return string.char(unpack(t))
end

--- Return the number of bytes currently stored.
--: (ByteRingBuf) -> integer
function ByteRingBuf:available()
	return self._len
end

--- Return the number of bytes that can still be written.
--: (ByteRingBuf) -> integer
function ByteRingBuf:free()
	return self._cap - self._len
end

--- Remove all bytes from the buffer.
--: (ByteRingBuf) -> nil
function ByteRingBuf:clear()
	for i = 1, self._cap do
		self._buf[i] = nil
	end
	self._head = 1
	self._tail = 1
	self._len  = 0
end

return M
