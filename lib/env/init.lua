if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local ffi = require("ffi")

local mod = {}

if ffi.os == "Windows" then error("env: windows not supported")
else
ffi.cdef [[ char **env(); ]]
local _di = debug.getinfo(1) --[[:! { source: string }]]
local env_ffi = ffi.load(_di.source:match("@?(.*/)") .. "env.so") --[[: any]]

local env_iter = function (_, i)
	local ptr = env_ffi.env()
	local str = ptr[i + 1]
	if str == nil then return end
	return i + 1, ffi.string(str)
end

--[[thinnest possible wrapper over `env`]]
--: () -> (((unknown, integer) -> (integer, string) | nil), nil, integer)
mod.env_stateless = function ()	return env_iter, nil, -1 end

--: () -> { [string]: string }
mod.env = function ()
	local ptr = env_ffi.env()
	local env = {}
	while true do
		local str = ptr[0]
		if str == nil then break end
		ptr = ptr + 1
		local name, value = ffi.string(str):match("(.-)=(.*)")
		env[name] = value
	end
	return env
end

end -- else (not Windows)

return mod
