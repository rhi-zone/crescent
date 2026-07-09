if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

--[[cross-platform I/O readiness dispatcher.]]
--[[selects epoll (Linux), kqueue (macOS), or wepoll (Windows)]]
--[[and re-exports the backend's API transparently.]]

local os_name = (jit and jit.os) or nil

if os_name == "Linux" or os_name == "Windows" then
	return require("lib.epoll")
elseif os_name == "OSX" then
	return require("lib.kqueue")
end

error("io_poll: unsupported OS: " .. tostring(os_name))
