-- lib/platform/daemon/pid_test.lua — tests for lib/platform/daemon/pid.lua

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local pid_mod = require("lib.platform.daemon.pid")

-- In-memory fakes so tests are hermetic.
local function make_fakes()
	local files = {} --: { [string]: string }
	local alive = {} --: { [integer]: boolean }
	return {
		read = function(p)
			if files[p] then return files[p], nil end
			return nil, "ENOENT"
		end,
		write = function(p, d) files[p] = d; return true, nil end,
		remove = function(p) rawset(files, p, nil); return true, nil end,
		mkdir = function(_) return true, nil end,
		alive = function(pid) return alive[pid] == true end,
		set_alive = function(pid, b) alive[pid] = b end,
		files = files,
	}
end

T.describe("pid.write + read round-trip", function()
	T.it("writes and reads back the same info when process is alive", function()
		local fakes = make_fakes()
		fakes.set_alive(4242, true)
		local p = pid_mod.make({
			pid_file = "/run/test/daemon.pid",
			read_fn = fakes.read, write_fn = fakes.write,
			remove_fn = fakes.remove, mkdir_fn = fakes.mkdir,
			alive_fn = fakes.alive,
		})
		local ok = p.write({ pid = 4242, host = "127.0.0.1", port = 7777 })
		T.eq(ok, true)
		local info, err = p.read()
		T.eq(err, nil)
		T.ok(info)
		if info then
			T.eq(info.pid, 4242)
			T.eq(info.host, "127.0.0.1")
			T.eq(info.port, 7777)
		end
	end)

	T.it("returns stale-pid error when process is not alive", function()
		local fakes = make_fakes()
		fakes.set_alive(4242, false)
		local p = pid_mod.make({
			pid_file = "/run/test/daemon.pid",
			read_fn = fakes.read, write_fn = fakes.write,
			remove_fn = fakes.remove, mkdir_fn = fakes.mkdir,
			alive_fn = fakes.alive,
		})
		p.write({ pid = 4242, host = "127.0.0.1", port = 7777 })
		local info, err = p.read()
		T.eq(info, nil)
		T.eq(err, "stale pid")
	end)

	T.it("returns nil on missing file", function()
		local fakes = make_fakes()
		local p = pid_mod.make({
			pid_file = "/run/test/daemon.pid",
			read_fn = fakes.read, write_fn = fakes.write,
			remove_fn = fakes.remove, mkdir_fn = fakes.mkdir,
			alive_fn = fakes.alive,
		})
		local info, err = p.read()
		T.eq(info, nil)
		T.eq(err, "ENOENT")
	end)

	T.it("clear removes the file", function()
		local fakes = make_fakes()
		fakes.set_alive(4242, true)
		local p = pid_mod.make({
			pid_file = "/run/test/daemon.pid",
			read_fn = fakes.read, write_fn = fakes.write,
			remove_fn = fakes.remove, mkdir_fn = fakes.mkdir,
			alive_fn = fakes.alive,
		})
		p.write({ pid = 4242, host = "127.0.0.1", port = 7777 })
		T.eq(fakes.files["/run/test/daemon.pid"] ~= nil, true)
		p.clear()
		T.eq(fakes.files["/run/test/daemon.pid"], nil)
	end)

	T.it("rejects malformed file", function()
		local fakes = make_fakes()
		fakes.files["/run/test/daemon.pid"] = "garbage\n"
		local p = pid_mod.make({
			pid_file = "/run/test/daemon.pid",
			read_fn = fakes.read, write_fn = fakes.write,
			remove_fn = fakes.remove, mkdir_fn = fakes.mkdir,
			alive_fn = fakes.alive,
		})
		local info, err = p.read()
		T.eq(info, nil)
		T.ok(err and err:find("malformed", 1, true))
	end)
end)
