if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

M._tier = "pure"

--:: Pool = {
--::   _idle: { [integer]: unknown },
--::   _create: () -> unknown,
--::   _reset: ((unknown) -> ()) | nil,
--::   _max: integer | nil,
--::   _on_acquire: ((unknown) -> ()) | nil,
--::   _on_release: ((unknown) -> ()) | nil,
--::   acquire: (self: Pool) -> unknown,
--::   release: (self: Pool, obj: unknown) -> (),
--::   use: (self: Pool, fn: (unknown) -> unknown) -> unknown,
--::   size: (self: Pool) -> integer,
--::   capacity: (self: Pool) -> integer | nil,
--::   drain: (self: Pool) -> (),
--::   prefill: (self: Pool, n: integer) -> (),
--:: }

--:: PoolOpts = {
--::   create: () -> unknown,
--::   reset?: (unknown) -> (),
--::   max?: integer,
--::   on_acquire?: (unknown) -> (),
--::   on_release?: (unknown) -> (),
--:: }

local pool_mt = {}
pool_mt.__index = pool_mt

--: (self: Pool) -> unknown
function pool_mt:acquire()
	local idle = self._idle
	local n = #idle
	if n > 0 then
		local obj = idle[n]
		idle[n] = nil
		local on_acquire = self._on_acquire
		if on_acquire then on_acquire(obj) end
		return obj
	end
	local obj = self._create()
	local on_acquire = self._on_acquire
	if on_acquire then on_acquire(obj) end
	return obj
end

--: (self: Pool, obj: unknown) -> ()
function pool_mt:release(obj)
	local idle = self._idle
	local max = self._max
	if max ~= nil and #idle < max then
		local reset = self._reset
		if reset then reset(obj) end
		idle[#idle + 1] = obj
	elseif max == nil then
		local reset = self._reset
		if reset then reset(obj) end
		idle[#idle + 1] = obj
	end
	local on_release = self._on_release
	if on_release then on_release(obj) end
end

--: (self: Pool, fn: (unknown) -> unknown) -> unknown
function pool_mt:use(fn)
	local obj = self:acquire()
	local ok, result = pcall(fn, obj)
	self:release(obj)
	if not ok then
		error(result, 2)
	end
	return result
end

--: (self: Pool) -> integer
function pool_mt:size()
	return #self._idle
end

--: (self: Pool) -> integer | nil
function pool_mt:capacity()
	return self._max
end

--: (self: Pool) -> ()
function pool_mt:drain()
	local idle = self._idle
	for i = #idle, 1, -1 do
		idle[i] = nil
	end
end

--: (self: Pool, n: integer) -> ()
function pool_mt:prefill(n)
	for _ = 1, n do
		local obj = self._create()
		local reset = self._reset
		if reset then reset(obj) end
		self._idle[#self._idle + 1] = obj
	end
end

-- Create a new object pool.
-- opts.create:     function() -> object  (required)
-- opts.reset:      function(obj)          (optional; called before returning to pool)
-- opts.max:        number                 (max idle objects; default: unlimited)
-- opts.on_acquire: function(obj)          (optional hook)
-- opts.on_release: function(obj)          (optional hook)
--: (opts: PoolOpts | nil) -> (Pool | nil, string | nil)
function M.new(opts)
	if not opts or not opts.create then
		return nil, "pool.new: opts.create is required"
	end
	local self = setmetatable({}, pool_mt) --[[:! Pool]]
	self._idle = {}
	self._create = opts.create
	self._reset = opts.reset
	self._max = opts.max
	self._on_acquire = opts.on_acquire
	self._on_release = opts.on_release
	return self
end

-- Typed pool for tables.
-- template: table of default values; acquired tables are copies of template.
-- On release, all keys are wiped and template values are restored.
-- max: optional max pool size.
function M.table_pool(template, max)
	local tmpl = template or {}
	local function create()
		local t = {}
		for k, v in pairs(tmpl) do
			t[k] = v
		end
		return t
	end
	local function reset(t)
		-- wipe all keys
		for k in pairs(t) do
			t[k] = nil
		end
		-- restore template values
		for k, v in pairs(tmpl) do
			t[k] = v
		end
	end
	return M.new({ create = create, reset = reset, max = max })
end

return M
