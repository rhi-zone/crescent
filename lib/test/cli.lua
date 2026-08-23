-- crescent test runner
-- discovers and runs *_test.lua files under lib/

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- ── FFI for fork/pipe/waitpid ─────────────────────────────────────────────────

local fork_available = false
local ffi_ok, ffi = pcall(require, "ffi")
if ffi_ok then
	local cdef_ok = pcall(function()
		ffi.cdef[[
			int fork(void);
			int waitpid(int pid, int *status, int options);
			int pipe(int pipefd[2]);
			ssize_t read(int fd, void *buf, size_t count);
			ssize_t write(int fd, const void *buf, size_t count);
			int close(int fd);
			long sysconf(int name);
			int setpgid(int pid, int pgid);
			int kill(int pid, int sig);
		]]
	end)
	local sym_ok = pcall(function() return ffi.C.fork ~= nil end)
	fork_available = (ffi_ok and sym_ok) == true
end

local SIGKILL = 9

--: () -> integer
local function get_cpu_count()
	if not fork_available then return 1 end
	local n = ffi.C.sysconf(84)  -- _SC_NPROCESSORS_ONLN = 84 on Linux
	if n <= 0 then return 1 end
	return math.floor(tonumber(n) or 1)
end

-- ── argument parsing ──────────────────────────────────────────────────────────

--- Parse args table into { coverage, jobs }.
-- Accepts either the global arg table or a 1-indexed list passed from M.main.
--: (argv: string[]) -> (boolean, integer | nil, string[])
local function parse_args(argv)
	local coverage = false
	local jobs_arg = nil --: integer | nil
	local files = {} --[[: string[] ]]

	for i = 1, #argv do
		local v = argv[i]
		if v == "--coverage" or v == "-c" then
			coverage = true
		elseif v:match("^%-%-jobs=(%d+)$") then
			local n = tonumber(v:match("^%-%-jobs=(%d+)$"))
			jobs_arg = n and math.floor(n) or nil
		elseif not v:match("^%-") then
			files[#files + 1] = v
		end
	end

	return coverage, jobs_arg, files
end

-- ── display helpers ──────────────────────────────────────────────────────────

local function build_counts(pass, fail, skip)
	if pass + fail + skip == 0 then return nil end
	local parts = {}
	if pass > 0 then parts[#parts+1] = pass .. " passed" end
	if skip > 0 then parts[#parts+1] = skip .. " skipped" end
	if fail > 0 then parts[#parts+1] = fail .. " failed" end
	return table.concat(parts, ", ")
end

local function build_summary(pass_files, fail_files, skip, total_files, assertions)
	local parts = { pass_files .. " passed" }
	if skip > 0 then parts[#parts+1] = skip .. " skipped" end
	parts[#parts+1] = fail_files .. " failed"
	parts[#parts+1] = total_files .. " total"
	local s = table.concat(parts, ", ")
	if assertions > 0 then
		s = s .. "  (" .. assertions .. " assertion" .. (assertions ~= 1 and "s" or "") .. ")"
	end
	return s
end

-- ── file discovery ────────────────────────────────────────────────────────────

local function find_test_files()
	local files = {}
	local handle = io.popen("find lib -name '*_test.lua' -type f | sort")
	if not handle then return files end
	for line in handle:lines() do
		files[#files + 1] = line
	end
	handle:close()
	return files
end

-- Expand a list of paths: directories → find *_test.lua under them; files kept as-is.
local function is_directory(p)
	-- Use test -d shell builtin: exits 0 if directory, 1 otherwise.
	local rc = os.execute("test -d " .. p)
	-- os.execute returns true/0 on success in LuaJIT
	return rc == true or rc == 0
end

local function expand_paths(paths)
	local out = {}
	for _, p in ipairs(paths) do
		if is_directory(p) then
			local handle = io.popen("find " .. p .. " -name '*_test.lua' -type f | sort")
			if handle then
				for line in handle:lines() do
					out[#out + 1] = line
				end
				handle:close()
			end
		else
			out[#out + 1] = p
		end
	end
	return out
end

-- ── sequential runner (used for coverage and --jobs=1) ───────────────────────

--:: Coverage = { start: () -> unknown, stop: () -> unknown, report: ({ uncovered?: boolean } | nil) -> unknown, ... }
local function run_sequential(file_list, coverage)
	local cov --: Coverage | nil
	if coverage then
		cov = require("lib.test.coverage")
		cov.start()
	end

	local assert_mod = require("lib.test.assert")

	local total_pass_files, total_fail_files = 0, 0
	local grand_pass, grand_fail, grand_skip = 0, 0, 0

	for _, file in ipairs(file_list) do
		assert_mod._reset()
		local ok, err = pcall(dofile, file)
		local summary = assert_mod._summary()

		grand_pass = grand_pass + summary.pass
		grand_fail = grand_fail + summary.fail
		grand_skip = grand_skip + summary.skip

		local counts = build_counts(summary.pass, summary.fail, summary.skip)

		if ok and summary.fail == 0 then
			total_pass_files = total_pass_files + 1
			io.write("  pass  " .. file)
			if counts ~= nil then io.write("  (" .. tostring(counts) .. ")") end
			io.write("\n")
		else
			total_fail_files = total_fail_files + 1
			io.write("  FAIL  " .. file)
			if counts ~= nil then io.write("  (" .. tostring(counts) .. ")") end
			io.write("\n")

			-- Show named test failures first.
			if #summary.tests > 0 then
				for _, t in ipairs(summary.tests) do
					if not t.ok then
						local detail = (t.err and (": " .. tostring(t.err))) or ""
						print("        \xE2\x9C\x97 " .. t.name .. detail)
					end
				end
			elseif not ok then
				-- Bare-assertion file: show the thrown error.
				print("        " .. tostring(err))
			end
		end
	end

	if cov then cov.stop() end

	print("")
	local total_assertions = grand_pass + grand_fail
	io.write(build_summary(total_pass_files, total_fail_files, grand_skip, #file_list, total_assertions))
	io.write("\n")

	if cov then
		cov.report({ uncovered = true })
	end

	if total_fail_files > 0 then os.exit(1) end
end

-- ── result encoding/decoding (newline-delimited, pipe-safe) ───────────────────
-- Each worker writes one line per file:
--   PASS <file> <pass> <fail>
--   FAIL <file> <pass> <fail> <urlencoded-details>
--
-- URL-encoding: only encodes chars that break line parsing (space, newline, %).

--: (s: string) -> string
local function urlencode(s)
	local result = s:gsub("([%c%s%%])", function(c)
		return ("%%%02X"):format(string.byte(c) or 0)
	end)
	return result
end

local function urldecode(s)
	return (s:gsub("%%(%x%x)", function(h)
		return string.char(tonumber(h, 16))
	end))
end

-- Encode a single test entry (from summary.tests) into a compact string.
-- Format: ok|name|err  (fields separated by pipe; name/err url-encoded)
local function encode_test(t)
	local ok_flag = t.ok and "1" or "0"
	local name_enc = urlencode(t.name or "")
	local err_enc = urlencode(t.err or "")
	return ok_flag .. "|" .. name_enc .. "|" .. err_enc
end

--:: TestResult = { ok: boolean, name: string, err: string | nil }

--: (s: string) -> TestResult | nil
local function decode_test(s)
	local ok_flag, name_enc, err_enc = s:match("^([01])|([^|]*)|(.*)$")
	if not ok_flag then return nil end
	local err_dec = urldecode(err_enc)
	return {
		ok   = ok_flag == "1",
		name = urldecode(name_enc),
		err  = err_dec ~= "" and err_dec or nil,
	}
end

-- Encode a full file result into a single line.
-- LINE: STATUS file pass fail skip pcall_err tests_list
local function encode_result(file, ok_file, pass, fail, skip, pcall_err, tests)
	local status = (ok_file and fail == 0) and "PASS" or "FAIL"
	local tests_enc = {}
	for _, t in ipairs(tests or {}) do
		tests_enc[#tests_enc + 1] = urlencode(encode_test(t))
	end
	local tests_str = table.concat(tests_enc, ",")
	local pcall_enc = urlencode(pcall_err or "")
	return status .. " " .. urlencode(file) .. " " .. pass .. " " .. fail
		.. " " .. (skip or 0) .. " " .. pcall_enc .. " " .. tests_str
end

--:: DecodedResult = { status: string, file: string, pass: integer, fail: integer, skip: integer, pcall_err: string, tests: TestResult[] }

--: (line: string) -> DecodedResult | nil
local function decode_result(line)
	local status, file_enc, pass_s, fail_s, skip_s, pcall_enc, tests_str =
		line:match("^(%u+) (%S+) (%d+) (%d+) (%d+) (%S*) ?(.*)$")
	if not status then return nil end

	local tests = {} --[[: TestResult[] ]]
	if tests_str and tests_str ~= "" then
		for enc in tests_str:gmatch("[^,]+") do
			local t = decode_test(urldecode(enc))
			if t then tests[#tests + 1] = t end
		end
	end

	return {
		status    = status,
		file      = urldecode(file_enc),
		pass      = math.floor(tonumber(pass_s) or 0),
		fail      = math.floor(tonumber(fail_s) or 0),
		skip      = math.floor(tonumber(skip_s) or 0),
		pcall_err = urldecode(pcall_enc),
		tests     = tests,
	}
end

-- ── worker: run a subset of files, write results to fd, then exit ─────────────

local function run_worker(file_subset, write_fd)
	-- We are in a forked child. Set up a fresh assert module state.
	local assert_mod = require("lib.test.assert")
	local results = {}

	for _, file in ipairs(file_subset) do
		assert_mod._reset()
		local ok, err = pcall(dofile, file)
		local summary = assert_mod._summary()
		local line = encode_result(
			file,
			ok,
			summary.pass,
			summary.fail,
			summary.skip,
			not ok and tostring(err) or nil,
			summary.tests
		) .. "\n"
		results[#results + 1] = line
	end

	-- Write all results to the pipe in one shot.
	local out = table.concat(results)
	local total = #out
	local buf = ffi.cast("const char *", out) --: cdata
	-- Write loop: retry on partial writes. Pointer arithmetic on cdata is
	-- valid in LuaJIT but unsupported by the typechecker; we suppress the
	-- arithmetic by going through the write syscall directly for each chunk.
	do
		local nwritten = 0
		while nwritten < total do
			local sub = out:sub(nwritten + 1)
			local sbuf = ffi.cast("const char *", sub) --: cdata
			local n = ffi.C.write(write_fd, sbuf, total - nwritten)
			if n <= 0 then break end
			nwritten = nwritten + n
		end
	end
	ffi.C.close(write_fd)
	os.exit(0)
end

-- ── parallel runner ───────────────────────────────────────────────────────────

-- Per-worker wall-clock budget before the parent kills the worker's whole
-- process group. Measured 2026-08-23 on this machine: a full `bin/cr test`
-- parallel run (pre-this-fix, sequential-drain runner) completes in ~21s wall
-- clock, which upper-bounds the slowest single worker's true runtime (all
-- workers run concurrently, so total wall time can't be less than the
-- slowest one -- though on the buggy runner it can also be inflated by
-- pipe-blocking artifacts from the very livelock this change fixes). ~5.7x
-- that (120s) is the default: generous enough to tolerate a slower or loaded
-- CI host without the timeout firing on legitimate work, short enough to
-- still catch a genuine hang instead of waiting indefinitely. Override via
-- the timeout_s parameter for callers that know their own budget.
local DEFAULT_WORKER_TIMEOUT_S = 120

local function run_parallel(file_list, n, timeout_s)
	timeout_s = timeout_s or DEFAULT_WORKER_TIMEOUT_S
	-- Distribute files round-robin across n workers.
	local buckets = {}
	for i = 1, n do buckets[i] = {} end
	for i, f in ipairs(file_list) do
		buckets[((i - 1) % n) + 1][#buckets[((i - 1) % n) + 1] + 1] = f
	end

	-- Remove empty buckets (when #files < n).
	local workers = {}
	for _, bucket in ipairs(buckets) do
		if #bucket > 0 then
			workers[#workers + 1] = bucket
		end
	end

	-- Fork workers, create a pipe per worker. Each worker is put in its own
	-- process group (setpgid(0,0) in the child) so a timeout can kill(-pgid)
	-- the whole subtree, not just the direct child -- a worker that spawns
	-- its own children (e.g. via lib.os_isolation) would otherwise leave
	-- orphans behind. Both parent and child call setpgid on the same pid to
	-- avoid the fork/setpgid race: whichever runs first wins, and by the
	-- time the parent might need to kill the group it is guaranteed set.
	local close_fds_ok, close_fds = pcall(require, "lib.os_isolation.close_fds")
	local pids    = {}
	local pgids   = {}
	local read_fds = {}
	local pipefd  = ffi.new("int[2]")

	for i, bucket in ipairs(workers) do
		if ffi.C.pipe(pipefd) ~= 0 then
			io.stderr:write("pipe() failed\n")
			os.exit(2)
		end
		local rfd = pipefd[0]
		local wfd = pipefd[1]

		local pid = ffi.C.fork()
		if pid < 0 then
			io.stderr:write("fork() failed\n")
			os.exit(2)
		elseif pid == 0 then
			-- Child: become its own process group leader, close every fd
			-- except stdio and this worker's own pipe write end (drops
			-- leaked read ends from earlier sibling workers' pipes, still
			-- open in this child because it was forked after they were
			-- created), close read end, run worker, exit.
			ffi.C.setpgid(0, 0)
			if close_fds_ok then close_fds.close_fds_except({ 0, 1, 2, wfd }) end
			ffi.C.close(rfd)
			run_worker(bucket, wfd)
			-- run_worker calls os.exit; unreachable.
		else
			-- Parent: close write end, remember read end + pid + pgid.
			ffi.C.setpgid(pid, pid)
			ffi.C.close(wfd)
			pids[i]     = pid
			pgids[i]    = pid -- setpgid(pid, pid) makes the pgid == the pid
			read_fds[i] = rfd
		end
	end

	-- Multiplex all worker pipes concurrently via io_poll instead of
	-- draining them one at a time: a worker that writes more than one pipe
	-- buffer of output blocks on write() until the parent reads it, and a
	-- sequential drain only reads pipe i after pipes 1..i-1 have hung up --
	-- so a slow/quiet worker ahead of a chatty one starves the chatty one's
	-- write() indefinitely. Concurrent readiness-driven draining removes
	-- that ordering dependency entirely.
	local io_poll_ok, io_poll = pcall(require, "lib.io_poll")
	local all_lines = {}
	local buf_by_i = {}
	local done_by_i = {}
	local counted_by_i = {}
	local remaining = #workers

	if io_poll_ok and remaining > 0 then
		local poller = io_poll.new()
		for i = 1, #workers do
			buf_by_i[i] = {}
			local rfd = read_fds[i]
			poller:add(rfd, function(data)
				buf_by_i[i][#buf_by_i[i] + 1] = data
			end, function()
				done_by_i[i] = true
			end)
		end

		local start_by_i = {} --[[: { [integer]: integer } ]]
		local now = os.time()
		for i = 1, #workers do start_by_i[i] = now end

		local POLL_TICK_MS = 200 -- wake periodically even with no I/O, to check timeouts
		while remaining > 0 do
			poller:wait(POLL_TICK_MS)

			local t = os.time()
			for i = 1, #workers do
				if done_by_i[i] and not counted_by_i[i] then
					counted_by_i[i] = true
					remaining = remaining - 1
				elseif not done_by_i[i] and (t - start_by_i[i]) >= timeout_s then
					-- Kill the whole process group, not just the direct
					-- child. The pipe write end dying delivers EOF to the
					-- read side, which the next wait() tick observes as a
					-- normal close -- so this worker is marked done here,
					-- immediately, rather than waiting on that round-trip.
					ffi.C.kill(-pgids[i], SIGKILL)
					done_by_i[i] = true
					counted_by_i[i] = true
					remaining = remaining - 1
				end
			end
		end

		for i = 1, #workers do
			ffi.C.close(read_fds[i])
			local text = table.concat(buf_by_i[i])
			for line in text:gmatch("[^\n]+") do
				all_lines[#all_lines + 1] = line
			end
		end
	else
		-- io_poll unavailable on this platform: fall back to the sequential
		-- drain. Workers may still block on write() if this path is taken,
		-- same as before this change -- io_poll not loading at all is a
		-- narrower, platform-detection failure distinct from the livelock
		-- this rewrite fixes.
		local chunk_size = 4096
		local buf = ffi.new("uint8_t[4096]")
		for i = 1, #workers do
			local rfd = read_fds[i]
			local chunks = {}
			while true do
				local n = ffi.C.read(rfd, buf, chunk_size)
				if n <= 0 then break end
				chunks[#chunks + 1] = ffi.string(buf, n)
			end
			ffi.C.close(rfd)
			local text = table.concat(chunks)
			for line in text:gmatch("[^\n]+") do
				all_lines[#all_lines + 1] = line
			end
		end
	end

	-- Wait for all children (including any just SIGKILLed above).
	local status_p = ffi.new("int[1]")
	for i = 1, #workers do
		ffi.C.waitpid(pids[i], status_p, 0)
	end

	-- Decode results.
	--: { [string]: { status: string, file: string, pass: integer, fail: integer, skip: integer, pcall_err: string, tests: { [integer]: { ok: boolean, name: string, err: string | nil } } } }
	local results_by_file = {}
	for _, line in ipairs(all_lines) do
		local r = decode_result(line)
		if r then
			results_by_file[r.file] = r
		end
	end

	-- Print in sorted (deterministic) file order.
	local total_pass_files, total_fail_files = 0, 0
	local grand_pass, grand_fail, grand_skip = 0, 0, 0

	for _, file in ipairs(file_list) do
		local r = results_by_file[file]
		if not r then
			io.write("  FAIL  " .. file .. "  (no result from worker)\n")
			total_fail_files = total_fail_files + 1
		else
			grand_pass = grand_pass + r.pass
			grand_fail = grand_fail + r.fail
			grand_skip = grand_skip + r.skip

			local counts = build_counts(r.pass, r.fail, r.skip)

			if r.status == "PASS" then
				total_pass_files = total_pass_files + 1
				io.write("  pass  " .. file)
				if counts ~= nil then io.write("  (" .. tostring(counts) .. ")") end
				io.write("\n")
			else
				total_fail_files = total_fail_files + 1
				io.write("  FAIL  " .. file)
				if counts ~= nil then io.write("  (" .. tostring(counts) .. ")") end
				io.write("\n")

				if #r.tests > 0 then
					for _, t in ipairs(r.tests) do
						if not t.ok then
							local detail = (t.err and (": " .. tostring(t.err))) or ""
							print("        \xE2\x9C\x97 " .. t.name .. detail)
						end
					end
				elseif r.pcall_err ~= "" then
					print("        " .. r.pcall_err)
				end
			end
		end
	end

	print("")
	local total_assertions = grand_pass + grand_fail
	io.write(build_summary(total_pass_files, total_fail_files, grand_skip, #file_list, total_assertions))
	io.write("\n")

	if total_fail_files > 0 then os.exit(1) end
end

-- ── main export ───────────────────────────────────────────────────────────────

--- Run the test suite. argv is a 1-indexed list of arguments.
function M.main(argv)
	local coverage, jobs_arg, explicit_files = parse_args(argv)

	local files = #explicit_files > 0 and expand_paths(explicit_files) or find_test_files()
	if #files == 0 then
		print("no test files found")
		os.exit(0)
	end

	local njobs
	if coverage then
		njobs = 1  -- debug.sethook is per-process; must be sequential
	elseif jobs_arg then
		njobs = jobs_arg
	elseif fork_available then
		njobs = math.min(get_cpu_count(), #files)
	else
		njobs = 1
	end

	if njobs <= 1 or not fork_available then
		run_sequential(files, coverage)
	else
		run_parallel(files, njobs)
	end
end

-- ── standalone entry point ────────────────────────────────────────────────────

if arg and arg[0] and arg[0]:match("test/cli%.lua$") then
	M.main(arg)
end

return M
