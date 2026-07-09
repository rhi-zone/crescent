local ffi = require("ffi")

local T = require("lib.test.assert")

local ok_io_poll, io_poll = pcall(require, "lib.io_poll")

T.describe("io_poll", function()
	T.describe("loading", function()
		T.it("loads successfully on supported platforms", function()
			local os_name = jit and jit.os
			if os_name == "Linux" or os_name == "OSX" or os_name == "Windows" then
				T.ok(ok_io_poll, "io_poll should load on " .. tostring(os_name) .. ": " .. tostring(io_poll))
			end
		end)
	end)

	if not ok_io_poll then return end

	T.describe("api shape", function()
		T.it("exports new", function()
			T.eq(type(io_poll.new), "function")
		end)

		T.it("exports add", function()
			T.eq(type(io_poll.add), "function")
		end)

		T.it("exports wait", function()
			T.eq(type(io_poll.wait), "function")
		end)

		T.it("exports loop", function()
			T.eq(type(io_poll.loop), "function")
		end)
	end)

	T.describe("backend selection", function()
		T.it("selects the correct backend for the current OS", function()
			local os_name = jit and jit.os
			if os_name == "Linux" or os_name == "Windows" then
				T.ok(io_poll.epoll ~= nil, "should use epoll backend")
			elseif os_name == "OSX" then
				T.ok(io_poll.kqueue ~= nil, "should use kqueue backend")
			end
		end)
	end)

	if ffi.os == "Linux" then
		T.describe("functional (Linux)", function()
			T.it("creates a poller", function()
				local poller = io_poll.new()
				T.ok(poller ~= nil, "new() should return a poller")
				T.eq(type(poller.count), "number")
				T.eq(poller.count, 0)
			end)
		end)
	end
end)
