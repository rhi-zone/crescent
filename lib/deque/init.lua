-- lib/deque/init.lua — double-ended queue with O(1) amortized push/pop
--
-- Growable deque backed by a Lua table with head/tail indices.
-- Negative indices grow toward the front; positive toward the back.
-- Useful as a stack, queue, or general deque.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

--:: Deque = { _data: { [integer]: unknown }, _head: integer, _tail: integer, push_back: (Deque, unknown) -> (), push_front: (Deque, unknown) -> (), pop_back: (Deque) -> unknown | nil, pop_front: (Deque) -> unknown | nil, peek_back: (Deque) -> unknown | nil, peek_front: (Deque) -> unknown | nil, get: (Deque, integer) -> unknown | nil, set: (Deque, integer, unknown) -> boolean, size: (Deque) -> integer, empty: (Deque) -> boolean, clear: (Deque) -> (), to_array: (Deque) -> { [integer]: unknown }, iter: (Deque) -> () -> unknown, iter_reverse: (Deque) -> () -> unknown, rotate: (Deque, integer) -> (), contains: (Deque, unknown) -> boolean }

local Deque = {}
Deque.__index = Deque

--- Create a new empty deque.
--: () -> Deque
function M.new()
	local self = setmetatable({
		_data = {},
		_head = 1, -- index of first element (inclusive)
		_tail = 0, -- index of last element (inclusive); _tail < _head means empty
	}, Deque) --[[: unknown]]
	return self --[[:! Deque]]
end

--- Push a value onto the back of the deque.
--: (Deque, unknown) -> ()
function Deque:push_back(v)
	local self_ = self --[[:! Deque]]
	self_._tail = self_._tail + 1
	self_._data[self_._tail] = v
end

--- Push a value onto the front of the deque.
--: (Deque, unknown) -> ()
function Deque:push_front(v)
	local self_ = self --[[:! Deque]]
	self_._head = self_._head - 1
	self_._data[self_._head] = v
end

--- Pop a value from the back. Returns nil if empty.
--: (Deque) -> unknown | nil
function Deque:pop_back()
	local self_ = self --[[:! Deque]]
	if self_._head > self_._tail then
		return nil
	end
	local tail = self_._tail
	local v = self_._data[tail]
	self_._data[tail] = nil
	self_._tail = tail - 1
	return v
end

--- Pop a value from the front. Returns nil if empty.
--: (Deque) -> unknown | nil
function Deque:pop_front()
	local self_ = self --[[:! Deque]]
	if self_._head > self_._tail then
		return nil
	end
	local head = self_._head
	local v = self_._data[head]
	self_._data[head] = nil
	self_._head = head + 1
	return v
end

--- Peek at the back value without removing it. Returns nil if empty.
--: (Deque) -> unknown | nil
function Deque:peek_back()
	local self_ = self --[[:! Deque]]
	if self_._head > self_._tail then
		return nil
	end
	return self_._data[self_._tail]
end

--- Peek at the front value without removing it. Returns nil if empty.
--: (Deque) -> unknown | nil
function Deque:peek_front()
	local self_ = self --[[:! Deque]]
	if self_._head > self_._tail then
		return nil
	end
	return self_._data[self_._head]
end

--- Get element at 1-based index. Returns nil on out-of-bounds.
--: (Deque, integer) -> unknown | nil
function Deque:get(i)
	local self_ = self --[[:! Deque]]
	if i < 1 or i > self_._tail - self_._head + 1 then
		return nil
	end
	return self_._data[self_._head + i - 1]
end

--- Set element at 1-based index. Returns false on out-of-bounds.
--: (Deque, integer, unknown) -> boolean
function Deque:set(i, v)
	local self_ = self --[[:! Deque]]
	if i < 1 or i > self_._tail - self_._head + 1 then
		return false
	end
	self_._data[self_._head + i - 1] = v
	return true
end

--- Return the number of elements in the deque.
--: (Deque) -> integer
function Deque:size()
	local self_ = self --[[:! Deque]]
	return self_._tail - self_._head + 1
end

--- Return true if the deque is empty.
--: (Deque) -> boolean
function Deque:empty()
	local self_ = self --[[:! Deque]]
	return self_._head > self_._tail
end

--- Remove all elements from the deque.
--: (Deque) -> ()
function Deque:clear()
	local self_ = self --[[:! Deque]]
	self_._data = {}
	self_._head = 1
	self_._tail = 0
end

--- Return a dense 1-based array of all elements (front to back).
--: (Deque) -> { [integer]: unknown }
function Deque:to_array()
	local self_ = self --[[:! Deque]]
	local arr = {} --: { [integer]: unknown }
	local n = 0
	for idx = self_._head, self_._tail do
		n = n + 1
		arr[n] = self_._data[idx]
	end
	return arr
end

--- Return an iterator over elements front to back.
--: (Deque) -> () -> unknown
function Deque:iter()
	local self_ = self --[[:! Deque]]
	local idx = self_._head - 1
	local tail = self_._tail
	local data = self_._data
	return function()
		idx = idx + 1
		if idx > tail then return nil end
		return data[idx]
	end
end

--- Return an iterator over elements back to front.
--: (Deque) -> () -> unknown
function Deque:iter_reverse()
	local self_ = self --[[:! Deque]]
	local idx = self_._tail + 1
	local head = self_._head
	local data = self_._data
	return function()
		idx = idx - 1
		if idx < head then return nil end
		return data[idx]
	end
end

--- Rotate the deque by n positions. Positive n rotates front-to-back;
--- negative n rotates back-to-front. O(n) where n is the rotation amount.
--: (Deque, integer) -> ()
function Deque:rotate(n)
	local self_ = self --[[:! Deque]]
	local sz = self_._tail - self_._head + 1
	if sz <= 1 then return end
	n = n % sz
	if n == 0 then return end
	-- Rotate by popping from one end and pushing to the other
	for _ = 1, n do
		local v = self_._data[self_._head]
		self_._data[self_._head] = nil
		self_._head = self_._head + 1
		self_._tail = self_._tail + 1
		self_._data[self_._tail] = v
	end
end

--- Return true if the deque contains the given value (by ==).
--: (Deque, unknown) -> boolean
function Deque:contains(v)
	local self_ = self --[[:! Deque]]
	for idx = self_._head, self_._tail do
		if self_._data[idx] == v then return true end
	end
	return false
end

return M
