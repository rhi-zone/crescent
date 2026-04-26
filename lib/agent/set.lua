if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

--:: AgentSet = { [string]: unknown }

-- Create an empty set.
--: () -> AgentSet
function M.new()
	return {}
end

-- Return a new set with key=value added or replaced.
--: (AgentSet, string, unknown) -> AgentSet
function M.note(s, key, value)
	local out = {}
	for k, v in pairs(s) do out[k] = v end
	out[key] = value
	return out
end

-- Return a new set with key removed. No-op if key absent.
--: (AgentSet, string) -> AgentSet
function M.drop(s, key)
	local out = {}
	for k, v in pairs(s) do out[k] = v end
	out[key] = nil
	return out
end

-- Get a value by key. Returns nil if absent.
--: (AgentSet, string) -> unknown
function M.get(s, key)
	return s[key]
end

-- Merge two sets. s2 wins on key collision.
--: (AgentSet, AgentSet) -> AgentSet
function M.merge(s1, s2)
	local out = {}
	for k, v in pairs(s1) do out[k] = v end
	for k, v in pairs(s2) do out[k] = v end
	return out
end

-- Return sorted list of all keys.
--: (AgentSet) -> string[]
function M.keys(s)
	local ks = {}
	for k in pairs(s) do ks[#ks + 1] = k end
	table.sort(ks)
	return ks
end

return M
