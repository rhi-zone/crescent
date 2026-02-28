-- minimal assertion library for crescent tests
-- Supports bare assertions (backward compat) and describe/it test groups.

local mod = {}

local _pass = 0
local _fail = 0
local _tests = {}    -- list of { name, ok, pass, fail, err } from it() blocks
local _describe = {} -- current describe-path stack

local function fmt(v)
	if type(v) == "string" then return ("%q"):format(v) end
	return tostring(v)
end

mod.eq = function(a, b, msg)
	if a ~= b then
		_fail = _fail + 1
		error((msg and msg .. ": " or "") .. "expected " .. fmt(b) .. ", got " .. fmt(a), 2)
	end
	_pass = _pass + 1
end

mod.neq = function(a, b, msg)
	if a == b then
		_fail = _fail + 1
		error((msg and msg .. ": " or "") .. "expected not " .. fmt(b), 2)
	end
	_pass = _pass + 1
end

mod.ok = function(v, msg)
	if not v then
		_fail = _fail + 1
		error((msg and msg .. ": " or "") .. "expected truthy, got " .. fmt(v), 2)
	end
	_pass = _pass + 1
end

mod.fail = function(v, msg)
	if v then
		_fail = _fail + 1
		error((msg and msg .. ": " or "") .. "expected falsy, got " .. fmt(v), 2)
	end
	_pass = _pass + 1
end

mod.throws = function(fn, msg)
	local ok = pcall(fn)
	if ok then
		_fail = _fail + 1
		error((msg and msg .. ": " or "") .. "expected error, but succeeded", 2)
	end
	_pass = _pass + 1
end

-- Group tests under a named section.
mod.describe = function(name, fn)
	_describe[#_describe + 1] = name
	fn()
	_describe[#_describe] = nil
end

-- Named test case: failures are caught and recorded; subsequent it() blocks run.
mod.it = function(name, fn)
	local full = (#_describe > 0 and table.concat(_describe, " > ") .. " > " or "") .. name
	local pre_pass, pre_fail = _pass, _fail
	local ok, err = pcall(fn)
	local n_pass = _pass - pre_pass
	local n_fail = _fail - pre_fail
	_tests[#_tests + 1] = {
		name = full,
		ok   = ok and n_fail == 0,
		pass = n_pass,
		fail = n_fail,
		err  = not ok and tostring(err) or nil,
	}
end

-- For the runner.
mod._summary = function()
	return { pass = _pass, fail = _fail, tests = _tests }
end

mod._reset = function()
	_pass = 0
	_fail = 0
	_tests = {}
	_describe = {}
end

return mod
