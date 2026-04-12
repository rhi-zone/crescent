if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

local DEFAULT_MAX_LISTENERS = 10

-- Internal: get or create the listener list for an event
local function get_list(self, event)
	local list = self._listeners[event]
	if not list then
		list = {}
		self._listeners[event] = list
	end
	return list
end

-- Internal: emit to a single list, handling once removal and returning fired count
-- Returns: number of listeners called
local function call_list(list, ...)
	if not list or #list == 0 then return 0 end
	-- snapshot so mutations during emit don't affect iteration
	local snap = {}
	for i = 1, #list do snap[i] = list[i] end
	local fired = 0
	for i = 1, #snap do
		local entry = snap[i]
		-- find entry in current list and remove if once
		if entry.once then
			local cur = list
			for j = 1, #cur do
				if cur[j] == entry then
					table.remove(cur, j)
					break
				end
			end
		end
		entry.fn(...)
		fired = fired + 1
	end
	return fired
end

local emitter_mt = {}
emitter_mt.__index = emitter_mt

function emitter_mt:on(event, fn)
	local list = get_list(self, event)
	list[#list + 1] = { fn = fn, once = false }
	local max = self._max_listeners
	if max > 0 and #list > max then
		io.stderr:write(
			"event_emitter: possible memory leak, >"
				.. max
				.. " listeners for event '"
				.. tostring(event)
				.. "'\n"
		)
	end
	return self
end

function emitter_mt:once(event, fn)
	local list = get_list(self, event)
	list[#list + 1] = { fn = fn, once = true }
	local max = self._max_listeners
	if max > 0 and #list > max then
		io.stderr:write(
			"event_emitter: possible memory leak, >"
				.. max
				.. " listeners for event '"
				.. tostring(event)
				.. "'\n"
		)
	end
	return self
end

function emitter_mt:off(event, fn)
	local list = self._listeners[event]
	if not list then return self end
	for i = #list, 1, -1 do
		if list[i].fn == fn then
			table.remove(list, i)
			break
		end
	end
	return self
end

function emitter_mt:emit(event, ...)
	-- error event with no listeners raises
	if event == "error" then
		local list = self._listeners["error"]
		if not list or #list == 0 then
			local wild = self._listeners["*"]
			if not wild or #wild == 0 then
				local msg = ...
				error(msg ~= nil and msg or "unhandled error event")
			end
		end
	end

	local fired = 0

	local list = self._listeners[event]
	if list then
		fired = fired + call_list(list, ...)
	end

	-- wildcard listeners receive (event_name, ...)
	if event ~= "*" then
		local wild = self._listeners["*"]
		if wild then
			fired = fired + call_list(wild, event, ...)
		end
	end

	return fired > 0
end

function emitter_mt:listener_count(event)
	local list = self._listeners[event]
	return list and #list or 0
end

function emitter_mt:listeners(event)
	local list = self._listeners[event]
	if not list or #list == 0 then return {} end
	local copy = {}
	for i = 1, #list do
		copy[i] = list[i].fn
	end
	return copy
end

function emitter_mt:remove_all_listeners(event)
	if event ~= nil then
		self._listeners[event] = nil
	else
		self._listeners = {}
	end
	return self
end

function emitter_mt:set_max_listeners(n)
	self._max_listeners = n
	return self
end

function emitter_mt:prepend_listener(event, fn)
	local list = get_list(self, event)
	table.insert(list, 1, { fn = fn, once = false })
	local max = self._max_listeners
	if max > 0 and #list > max then
		io.stderr:write(
			"event_emitter: possible memory leak, >"
				.. max
				.. " listeners for event '"
				.. tostring(event)
				.. "'\n"
		)
	end
	return self
end

function emitter_mt:prepend_once(event, fn)
	local list = get_list(self, event)
	table.insert(list, 1, { fn = fn, once = true })
	local max = self._max_listeners
	if max > 0 and #list > max then
		io.stderr:write(
			"event_emitter: possible memory leak, >"
				.. max
				.. " listeners for event '"
				.. tostring(event)
				.. "'\n"
		)
	end
	return self
end

function M.new()
	return setmetatable({
		_listeners = {},
		_max_listeners = DEFAULT_MAX_LISTENERS,
	}, emitter_mt)
end

-- Add all emitter methods to an existing table
function M.mixin(t)
	t._listeners = t._listeners or {}
	t._max_listeners = t._max_listeners or DEFAULT_MAX_LISTENERS
	for k, v in pairs(emitter_mt) do
		if k ~= "__index" then
			t[k] = v
		end
	end
	return t
end

return M
