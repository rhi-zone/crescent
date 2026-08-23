-- lib/os_isolation/close_fds_test.lua
--
-- Every assertion here runs in a forked child, never in the test process.
-- close_fds_except() closes descriptors process-wide, and the test process is
-- a worker of the parallel test runner: sweeping it would close the results
-- pipe the runner is waiting on and wedge the suite -- the exact failure this
-- module exists to prevent. So each case forks, sweeps inside the child, and
-- reports what survived back over one deliberately-kept pipe.

if not package.path:find("?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local ffi = require("ffi")
local T = require("lib.test.assert")
local close_fds = require("lib.os_isolation.close_fds")

pcall(ffi.cdef, [[
	int pipe(int fds[2]);
	int fork(void);
	int close(int fd);
	int fcntl(int fd, int cmd, ...);
	void _exit(int status);
	int waitpid(int pid, int *status, int options);
	long read(int fd, void *buf, unsigned long count);
	long write(int fd, const void *buf, unsigned long count);
]])

local F_GETFD = 1

--: () -> (integer, integer)
local function make_pipe()
	local p = ffi.new("int[2]")
	if ffi.C.pipe(p) ~= 0 then error("close_fds_test: pipe() failed") end
	return p[0], p[1]
end

--: (integer) -> boolean
local function is_open(fd)
	return ffi.C.fcntl(fd, F_GETFD) >= 0
end

-- Fork, run `body(report_fd)` in the child, and return whatever the child
-- wrote to report_fd. The child is given report_fd and is expected to keep it
-- across its sweep; that is the point of the exercise, not an exemption.
--: ((integer) -> nil) -> string
local function in_child(body)
	local rfd, wfd = make_pipe()
	local pid = ffi.C.fork()
	if pid < 0 then error("close_fds_test: fork() failed") end
	if pid == 0 then
		ffi.C.close(rfd)
		pcall(body, wfd)
		ffi.C._exit(0)
	end
	ffi.C.close(wfd)
	local buf = ffi.new("uint8_t[4096]")
	local chunks = {}
	while true do
		local n = tonumber(ffi.C.read(rfd, buf, 4096)) or -1
		if n <= 0 then break end
		chunks[#chunks + 1] = ffi.string(buf, n)
	end
	ffi.C.close(rfd)
	local status = ffi.new("int[1]")
	ffi.C.waitpid(pid, status, 0)
	return table.concat(chunks)
end

-- The tiers this host can actually run. A machine without close_range(2) or
-- without /proc still exercises whatever it does have -- the parity claim is
-- over available implementations, not over a fixed list.
--:: tier_entry = { name: string, impl: (keep_fds: { [integer]: integer }) -> (true | nil, string | nil) }
--: { [integer]: tier_entry }
local available = {}
local close_range_impl = close_fds.close_range_impl
if close_range_impl then
	available[#available + 1] = { name = "close_range", impl = close_range_impl }
end
local proc_impl = close_fds.proc_impl
if proc_impl then
	available[#available + 1] = { name = "proc", impl = proc_impl }
end
available[#available + 1] = { name = "scan", impl = close_fds.scan_impl }

-- Open `count` probe pipes and return their descriptors as a flat list.
--: (integer) -> { [integer]: integer }
local function open_probes(count)
	--: { [integer]: integer }
	local fds = {}
	for _ = 1, count do
		local r, w = make_pipe()
		fds[#fds + 1] = r
		fds[#fds + 1] = w
	end
	return fds
end

-- Run one tier against one keep-list and get back a survival bitmap over the
-- probe descriptors: "1" where the descriptor is still open after the sweep,
-- "0" where it is gone.
--: (impl: (keep_fds: { [integer]: integer }) -> (true | nil, string | nil), probes: { [integer]: integer }, keep_probe_indices: { [integer]: integer }) -> string
local function survival_map(impl, probes, keep_probe_indices)
	return in_child(function(report_fd)
		--: { [integer]: integer }
		local keep = { report_fd }
		for _, idx in ipairs(keep_probe_indices) do
			keep[#keep + 1] = probes[idx]
		end
		impl(keep)
		local bits = {}
		for _, fd in ipairs(probes) do
			bits[#bits + 1] = is_open(fd) and "1" or "0"
		end
		local out = table.concat(bits)
		ffi.C.write(report_fd, out, #out)
	end)
end

T.describe("close_fds tier selection", function()
	T.it("binds close_fds_except to the tier named by _tier", function()
		local by_name = {
			close_range = close_fds.close_range_impl,
			proc        = close_fds.proc_impl,
			scan        = close_fds.scan_impl,
		}
		T.ok(by_name[close_fds._tier] ~= nil, "unknown tier: " .. tostring(close_fds._tier))
		T.eq(close_fds.close_fds_except, by_name[close_fds._tier])
	end)

	T.it("never selects a slower tier while a faster one is available", function()
		if close_fds.close_range_impl then
			T.eq(close_fds._tier, "close_range")
		elseif close_fds.proc_impl then
			T.eq(close_fds._tier, "proc")
		else
			T.eq(close_fds._tier, "scan")
		end
	end)
end)

T.describe("close_fds_except", function()
	T.it("keeps exactly the listed descriptors and closes every other one", function()
		local probes = open_probes(4)
		-- Keep probes 1 and 5: two kept descriptors that are not adjacent, so
		-- a range-based tier has to walk a gap before, between, and after them.
		local map = survival_map(close_fds.close_fds_except, probes, { 1, 5 })
		T.eq(map, "10001000")
		for _, fd in ipairs(probes) do ffi.C.close(fd) end
	end)

	T.it("closes everything when the keep list names only the report pipe", function()
		local probes = open_probes(3)
		local map = survival_map(close_fds.close_fds_except, probes, {})
		T.eq(map, "000000")
		for _, fd in ipairs(probes) do ffi.C.close(fd) end
	end)

	T.it("tolerates a keep list naming descriptors that were never open", function()
		local probes = open_probes(1)
		local map = in_child(function(report_fd)
			local ok = close_fds.close_fds_except({ report_fd, 4000, 4001 })
			ffi.C.write(report_fd, ok and "ok" or "no", 2)
		end)
		T.eq(map, "ok")
		for _, fd in ipairs(probes) do ffi.C.close(fd) end
	end)

	T.it("lets a reader see EOF once the child has swept the write end", function()
		-- The livelock in miniature. The child inherits `leaked_w`, which it
		-- has no business holding; without the sweep the parent's read() below
		-- never returns 0 and this test hangs rather than fails.
		local leaked_r, leaked_w = make_pipe()
		local out = in_child(function(report_fd)
			close_fds.close_fds_except({ report_fd })
			ffi.C.write(report_fd, "swept", 5)
		end)
		T.eq(out, "swept")
		ffi.C.close(leaked_w) -- parent's own copy; the child's is the one at issue
		local buf = ffi.new("uint8_t[16]")
		T.eq(tonumber(ffi.C.read(leaked_r, buf, 16)), 0, "read() should report EOF")
		ffi.C.close(leaked_r)
	end)
end)

T.describe("close_fds tier parity", function()
	T.it("every available tier produces the same survival map", function()
		--: { [integer]: integer }
		local keep_indices = { 1, 4, 5 }
		local expected = nil
		local expected_tier = nil
		for _, entry in ipairs(available) do
			local probes = open_probes(3)
			local map = survival_map(entry.impl, probes, keep_indices)
			for _, fd in ipairs(probes) do ffi.C.close(fd) end
			if expected == nil then
				expected, expected_tier = map, entry.name
			else
				T.eq(map, expected, entry.name .. " disagrees with " .. tostring(expected_tier))
			end
		end
		T.eq(expected, "100110")
	end)

	T.it("exercises more than one tier on a host that has more than one", function()
		-- Not an assertion about this machine -- a guard against the parity
		-- test silently degrading to a single-implementation test if a tier
		-- probe regresses. It records what was actually covered.
		T.ok(#available >= 1)
		if close_fds._tier ~= "scan" then
			T.ok(#available >= 2, "faster tier selected but parity has only one impl")
		end
	end)
end)
