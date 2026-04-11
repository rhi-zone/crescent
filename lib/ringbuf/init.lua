if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

--- Ring buffer (circular buffer) library.
-- Two flavors:
--   ringbuf.new(capacity)   — general-purpose, stores arbitrary Lua values
--   ringbuf.bytes(capacity) — byte-oriented, stores a flat byte stream

local M = {}

--: string
M._tier = "pure"

-- ── value ring buffer ─────────────────────────────────────────────────────────

local RingBuf = {}
RingBuf.__index = RingBuf

--- Create a new value ring buffer with the given capacity.
--: (capacity: number) -> RingBuf
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
	if self._len == self._cap then
		return nil, "full"
	end
	self._buf[self._tail] = v
	self._tail = self._tail % self._cap + 1
	self._len  = self._len + 1
	return true
end

--- Push a value, evicting the oldest item if the buffer is full.
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
function RingBuf:pop()
	if self._len == 0 then return nil end
	local v = self._buf[self._head]
	self._buf[self._head] = nil
	self._head = self._head % self._cap + 1
	self._len  = self._len - 1
	return v
end

--- Peek at the oldest value without removing it. Returns value or nil.
function RingBuf:peek()
	if self._len == 0 then return nil end
	return self._buf[self._head]
end

--- Peek at the newest value without removing it. Returns value or nil.
function RingBuf:peek_newest()
	if self._len == 0 then return nil end
	-- _tail points to next write slot; newest is one slot before that.
	local idx = (self._tail - 2) % self._cap + 1
	return self._buf[idx]
end

--- Return true if the buffer has no items.
function RingBuf:is_empty()
	return self._len == 0
end

--- Return true if the buffer is at capacity.
function RingBuf:is_full()
	return self._len == self._cap
end

--- Return the number of items currently in the buffer.
function RingBuf:len()
	return self._len
end

--- Return the maximum capacity of the buffer.
function RingBuf:capacity()
	return self._cap
end

--- Remove all items from the buffer.
function RingBuf:clear()
	for i = 1, self._cap do
		self._buf[i] = nil
	end
	self._head = 1
	self._tail = 1
	self._len  = 0
end

--- Return a sequential table snapshot of the buffer, oldest first.
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
--: (capacity: number) -> ByteRingBuf
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
function ByteRingBuf:push_string(s)
	local slen = #s
	if slen == 0 then return true end
	if slen > self._cap - self._len then
		return nil, "not enough space"
	end
	local buf  = self._buf
	local tail = self._tail
	local cap  = self._cap
	for i = 1, slen do
		buf[tail] = s:byte(i)
		tail = tail % cap + 1
	end
	self._tail = tail
	self._len  = self._len + slen
	return true
end

--- Pop n bytes from the buffer as a string (destructive).
-- Returns the string, or (nil, "not enough data") if fewer than n bytes available.
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
function ByteRingBuf:available()
	return self._len
end

--- Return the number of bytes that can still be written.
function ByteRingBuf:free()
	return self._cap - self._len
end

--- Remove all bytes from the buffer.
function ByteRingBuf:clear()
	for i = 1, self._cap do
		self._buf[i] = nil
	end
	self._head = 1
	self._tail = 1
	self._len  = 0
end

return M
