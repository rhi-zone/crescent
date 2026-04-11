-- lib/pool/init.lua — object pool and connection pool
-- Reuse expensive-to-create objects (database connections, buffers, workers).
-- Fixed-size pool with acquire/release, health checks, idle timeout.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- ── Pool prototype ───────────────────────────────────────────────────────────

local Pool = {}
Pool.__index = Pool

--: (Pool) -> number
function Pool:size()
	return self._idle_count + self._in_use_count
end

--: (Pool) -> number
function Pool:idle()
	return self._idle_count
end

--: (Pool) -> number
function Pool:in_use()
	return self._in_use_count
end

--: (Pool) -> { size: number, idle: number, in_use: number, created: number, reused: number }
function Pool:stats()
	return {
		size = self._idle_count + self._in_use_count,
		idle = self._idle_count,
		in_use = self._in_use_count,
		created = self._created,
		reused = self._reused,
	}
end

--: (Pool) -> unknown, string?
function Pool:acquire()
	-- try to reuse an idle object
	while self._idle_count > 0 do
		local obj = self._idle[self._idle_count]
		self._idle[self._idle_count] = nil
		self._idle_count = self._idle_count - 1
		-- validate before handing out
		if self._validate then
			local ok = self._validate(obj)
			if not ok then
				-- destroy invalid object, don't count as in-use
				if self._destroy then self._destroy(obj) end
				-- loop to try next idle object
			else
				self._checked_out[obj] = true
				self._in_use_count = self._in_use_count + 1
				self._reused = self._reused + 1
				return obj
			end
		else
			self._checked_out[obj] = true
			self._in_use_count = self._in_use_count + 1
			self._reused = self._reused + 1
			return obj
		end
	end
	-- no idle objects; create if under max
	if self._idle_count + self._in_use_count >= self._max then
		return nil, "pool exhausted"
	end
	local obj = self._create()
	self._created = self._created + 1
	self._checked_out[obj] = true
	self._in_use_count = self._in_use_count + 1
	return obj
end

--: (Pool, unknown) -> true | (nil, string)
function Pool:release(obj)
	if not self._checked_out[obj] then
		return nil, "object not from this pool"
	end
	self._checked_out[obj] = nil
	self._in_use_count = self._in_use_count - 1
	-- reset state before returning to pool
	if self._reset then self._reset(obj) end
	self._idle_count = self._idle_count + 1
	self._idle[self._idle_count] = obj
	return true
end

--: (Pool, (unknown) -> unknown) -> unknown, string?
function Pool:with(fn)
	local obj, err = self:acquire()
	if not obj then return nil, err end
	local ok, result = pcall(fn, obj)
	self:release(obj)
	if not ok then error(result, 2) end
	return result
end

--: (Pool) -> nil
function Pool:drain()
	for i = 1, self._idle_count do
		local obj = self._idle[i]
		if self._destroy then self._destroy(obj) end
		self._idle[i] = nil
	end
	self._idle_count = 0
end

-- ── Constructor ──────────────────────────────────────────────────────────────

--: ({ size: number, create: () -> unknown, destroy: ((unknown) -> nil)?, validate: ((unknown) -> boolean)?, reset: ((unknown) -> nil)? }) -> Pool
function M.new(opts)
	if not opts or not opts.create then
		return nil, "opts.create is required"
	end
	if not opts.size or opts.size < 1 then
		return nil, "opts.size must be >= 1"
	end
	local p = setmetatable({
		_max = opts.size,
		_create = opts.create,
		_destroy = opts.destroy,
		_validate = opts.validate,
		_reset = opts.reset,
		_idle = {},
		_idle_count = 0,
		_checked_out = {},
		_in_use_count = 0,
		_created = 0,
		_reused = 0,
	}, Pool)
	return p
end

-- ── Buffer pool ──────────────────────────────────────────────────────────────

--: ({ size: number, buffer_size: number? }) -> Pool
function M.buffers(opts)
	local buf_size = (opts and opts.buffer_size) or 4096
	local pool_size = (opts and opts.size) or 16
	return M.new({
		size = pool_size,
		create = function()
			--: { [number]: number, n: number, cap: number }
			local buf = { n = 0, cap = buf_size }
			return buf
		end,
		reset = function(buf)
			-- clear contents without deallocating
			for i = 1, buf.n do buf[i] = nil end
			buf.n = 0
		end,
	})
end

return M
