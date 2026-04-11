-- lib/deque/init.lua — double-ended queue with O(1) amortized push/pop
--
-- Growable deque backed by a Lua table with head/tail indices.
-- Negative indices grow toward the front; positive toward the back.
-- Useful as a stack, queue, or general deque.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

--:: Deque = { _data: { [number]: unknown }, _head: number, _tail: number }

local Deque = {}
Deque.__index = Deque

--- Create a new empty deque.
--: () -> Deque
function M.new()
	return setmetatable({
		_data = {},
		_head = 1, -- index of first element (inclusive)
		_tail = 0, -- index of last element (inclusive); _tail < _head means empty
	}, Deque)
end

--- Push a value onto the back of the deque.
--: (unknown) -> ()
function Deque:push_back(v)
	self._tail = self._tail + 1
	self._data[self._tail] = v
end

--- Push a value onto the front of the deque.
--: (unknown) -> ()
function Deque:push_front(v)
	self._head = self._head - 1
	self._data[self._head] = v
end

--- Pop a value from the back. Returns (nil, errmsg) if empty.
--: () -> unknown | (nil, string)
function Deque:pop_back()
	if self._head > self._tail then
		return nil, "deque is empty"
	end
	local tail = self._tail
	local v = self._data[tail]
	self._data[tail] = nil
	self._tail = tail - 1
	return v
end

--- Pop a value from the front. Returns (nil, errmsg) if empty.
--: () -> unknown | (nil, string)
function Deque:pop_front()
	if self._head > self._tail then
		return nil, "deque is empty"
	end
	local head = self._head
	local v = self._data[head]
	self._data[head] = nil
	self._head = head + 1
	return v
end

--- Peek at the back value without removing it. Returns (nil, errmsg) if empty.
--: () -> unknown | (nil, string)
function Deque:peek_back()
	if self._head > self._tail then
		return nil, "deque is empty"
	end
	return self._data[self._tail]
end

--- Peek at the front value without removing it. Returns (nil, errmsg) if empty.
--: () -> unknown | (nil, string)
function Deque:peek_front()
	if self._head > self._tail then
		return nil, "deque is empty"
	end
	return self._data[self._head]
end

--- Get element at 1-based index. Returns (nil, errmsg) on out-of-bounds.
--: (number) -> unknown | (nil, string)
function Deque:get(i)
	if i < 1 or i > self._tail - self._head + 1 then
		return nil, "index out of bounds"
	end
	return self._data[self._head + i - 1]
end

--- Set element at 1-based index. Returns (nil, errmsg) on out-of-bounds.
--: (number, unknown) -> true | (nil, string)
function Deque:set(i, v)
	if i < 1 or i > self._tail - self._head + 1 then
		return nil, "index out of bounds"
	end
	self._data[self._head + i - 1] = v
	return true
end

--- Return the number of elements in the deque.
--: () -> number
function Deque:size()
	return self._tail - self._head + 1
end

--- Return true if the deque is empty.
--: () -> boolean
function Deque:empty()
	return self._head > self._tail
end

--- Remove all elements from the deque.
--: () -> ()
function Deque:clear()
	self._data = {}
	self._head = 1
	self._tail = 0
end

--- Return a dense 1-based array of all elements (front to back).
--: () -> { [number]: unknown }
function Deque:to_array()
	local arr = {}
	local n = 0
	for idx = self._head, self._tail do
		n = n + 1
		arr[n] = self._data[idx]
	end
	return arr
end

--- Return an iterator over elements front to back.
--: () -> () -> unknown
function Deque:iter()
	local idx = self._head - 1
	local tail = self._tail
	local data = self._data
	return function()
		idx = idx + 1
		if idx > tail then return nil end
		return data[idx]
	end
end

--- Return an iterator over elements back to front.
--: () -> () -> unknown
function Deque:iter_reverse()
	local idx = self._tail + 1
	local head = self._head
	local data = self._data
	return function()
		idx = idx - 1
		if idx < head then return nil end
		return data[idx]
	end
end

--- Rotate the deque by n positions. Positive n rotates front-to-back;
--- negative n rotates back-to-front. O(n) where n is the rotation amount.
--: (number) -> ()
function Deque:rotate(n)
	local sz = self._tail - self._head + 1
	if sz <= 1 then return end
	n = n % sz
	if n == 0 then return end
	-- Rotate by popping from one end and pushing to the other
	for _ = 1, n do
		local v = self._data[self._head]
		self._data[self._head] = nil
		self._head = self._head + 1
		self._tail = self._tail + 1
		self._data[self._tail] = v
	end
end

--- Return true if the deque contains the given value (by ==).
--: (unknown) -> boolean
function Deque:contains(v)
	for idx = self._head, self._tail do
		if self._data[idx] == v then return true end
	end
	return false
end

return M
