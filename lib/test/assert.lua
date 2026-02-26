-- minimal assertion library for crescent tests

local mod = {}

local function fmt(v)
	if type(v) == "string" then return ("%q"):format(v) end
	return tostring(v)
end

mod.eq = function (a, b, msg)
	if a ~= b then error((msg and msg .. ": " or "") .. "expected " .. fmt(b) .. ", got " .. fmt(a), 2) end
end

mod.neq = function (a, b, msg)
	if a == b then error((msg and msg .. ": " or "") .. "expected not " .. fmt(b), 2) end
end

mod.ok = function (v, msg)
	if not v then error((msg and msg .. ": " or "") .. "expected truthy, got " .. fmt(v), 2) end
end

mod.fail = function (v, msg)
	if v then error((msg and msg .. ": " or "") .. "expected falsy, got " .. fmt(v), 2) end
end

mod.throws = function (fn, msg)
	local ok = pcall(fn)
	if ok then error((msg and msg .. ": " or "") .. "expected error, but succeeded", 2) end
end

return mod
