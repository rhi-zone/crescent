if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

M._tier = "pure"

local pool_mt = {}
pool_mt.__index = pool_mt

function pool_mt:acquire()
	local idle = self._idle
	local n = #idle
	if n > 0 then
		local obj = idle[n]
		idle[n] = nil
		if self._on_acquire then self._on_acquire(obj) end
		return obj
	end
	local obj = self._create()
	if self._on_acquire then self._on_acquire(obj) end
	return obj
end

function pool_mt:release(obj)
	local idle = self._idle
	local max = self._max
	if max == nil or #idle < max then
		if self._reset then self._reset(obj) end
		idle[#idle + 1] = obj
	end
	if self._on_release then self._on_release(obj) end
end

function pool_mt:use(fn)
	local obj = self:acquire()
	local ok, result = pcall(fn, obj)
	self:release(obj)
	if not ok then
		error(result, 2)
	end
	return result
end

function pool_mt:size()
	return #self._idle
end

function pool_mt:capacity()
	return self._max
end

function pool_mt:drain()
	local idle = self._idle
	for i = #idle, 1, -1 do
		idle[i] = nil
	end
end

function pool_mt:prefill(n)
	for _ = 1, n do
		local obj = self._create()
		if self._reset then self._reset(obj) end
		self._idle[#self._idle + 1] = obj
	end
end

-- Create a new object pool.
-- opts.create:     function() -> object  (required)
-- opts.reset:      function(obj)          (optional; called before returning to pool)
-- opts.max:        number                 (max idle objects; default: unlimited)
-- opts.on_acquire: function(obj)          (optional hook)
-- opts.on_release: function(obj)          (optional hook)
function M.new(opts)
	if not opts or not opts.create then
		return nil, "pool.new: opts.create is required"
	end
	local self = setmetatable({}, pool_mt)
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
