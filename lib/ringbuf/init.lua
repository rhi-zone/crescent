if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

--:: RingBuf = { buf: { [number]: unknown }, head: number, len: number, cap: number }

local RB = {}
RB.__index = RB

--: (capacity: number) -> RingBuf | (nil, string)
function M.new(capacity)
	if type(capacity) ~= "number" or capacity < 1 or capacity ~= math.floor(capacity) then
		return nil, "capacity must be a positive integer"
	end
	return setmetatable({
		buf = {},
		head = 0, -- index into buf (0-based internally)
		len = 0,
		cap = capacity,
	}, RB)
end

--: (self: RingBuf) -> number
function RB:size()
	return self.len
end

--: (self: RingBuf) -> number
function RB:capacity()
	return self.cap
end

--: (self: RingBuf) -> boolean
function RB:empty()
	return self.len == 0
end

--: (self: RingBuf) -> boolean
function RB:full()
	return self.len == self.cap
end

--: (self: RingBuf, v: unknown) -> ()
function RB:push_back(v)
	if self.len == self.cap then
		-- overwrite oldest (head), advance head
		self.buf[self.head] = v
		self.head = (self.head + 1) % self.cap
	else
		local tail = (self.head + self.len) % self.cap
		self.buf[tail] = v
		self.len = self.len + 1
	end
end

--: (self: RingBuf, v: unknown) -> ()
function RB:push_front(v)
	if self.len == self.cap then
		-- overwrite newest (tail - 1), move head back
		self.head = (self.head - 1) % self.cap
		self.buf[self.head] = v
	else
		self.head = (self.head - 1) % self.cap
		self.buf[self.head] = v
		self.len = self.len + 1
	end
end

--: (self: RingBuf) -> unknown | nil
function RB:pop_front()
	if self.len == 0 then return nil end
	local v = self.buf[self.head]
	self.buf[self.head] = nil
	self.head = (self.head + 1) % self.cap
	self.len = self.len - 1
	return v
end

--: (self: RingBuf) -> unknown | nil
function RB:pop_back()
	if self.len == 0 then return nil end
	local tail = (self.head + self.len - 1) % self.cap
	local v = self.buf[tail]
	self.buf[tail] = nil
	self.len = self.len - 1
	return v
end

--: (self: RingBuf) -> unknown | nil
function RB:peek_front()
	if self.len == 0 then return nil end
	return self.buf[self.head]
end

--: (self: RingBuf) -> unknown | nil
function RB:peek_back()
	if self.len == 0 then return nil end
	local tail = (self.head + self.len - 1) % self.cap
	return self.buf[tail]
end

--: (self: RingBuf, i: number) -> unknown | nil
function RB:get(i)
	if i < 1 or i > self.len then return nil end
	local idx = (self.head + i - 1) % self.cap
	return self.buf[idx]
end

--: (self: RingBuf) -> ()
function RB:clear()
	for j = 0, self.cap - 1 do
		self.buf[j] = nil
	end
	self.head = 0
	self.len = 0
end

--: (self: RingBuf) -> { [number]: unknown }
function RB:to_array()
	local out = {}
	for j = 0, self.len - 1 do
		out[j + 1] = self.buf[(self.head + j) % self.cap]
	end
	return out
end

--: (self: RingBuf) -> () -> (number, unknown) | nil
function RB:iter()
	local j = 0
	local head, cap, len = self.head, self.cap, self.len
	return function()
		if j >= len then return nil end
		local idx = (head + j) % cap
		j = j + 1
		return j, self.buf[idx]
	end
end

--: (self: RingBuf) -> { [number]: unknown }
function RB:drain()
	local out = self:to_array()
	self:clear()
	return out
end

return M
