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
		]]
	end)
	-- cdef errors if already declared (re-require); either way symbols are present
	fork_available = (ffi_ok and ffi.C.fork ~= nil)
end

local function get_cpu_count()
	if not fork_available then return 1 end
	local n = ffi.C.sysconf(84)  -- _SC_NPROCESSORS_ONLN = 84 on Linux
	if n <= 0 then return 1 end
	return tonumber(n)
end

-- ── argument parsing ──────────────────────────────────────────────────────────

--- Parse args table into { coverage, jobs }.
-- Accepts either the global arg table or a 1-indexed list passed from M.main.
local function parse_args(argv)
	local coverage = false
	local jobs_arg = nil  -- nil = auto-detect

	for i = 1, #argv do
		local v = argv[i]
		if v == "--coverage" or v == "-c" then
			coverage = true
		elseif v:match("^%-%-jobs=(%d+)$") then
			jobs_arg = tonumber(v:match("^%-%-jobs=(%d+)$"))
		end
	end

	return coverage, jobs_arg
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

-- ── sequential runner (used for coverage and --jobs=1) ───────────────────────

local function run_sequential(file_list, coverage)
	local cov
	if coverage then
		cov = require("lib.test.coverage")
		cov.start()
	end

	local assert_mod = require("lib.test.assert")

	local total_pass_files, total_fail_files = 0, 0
	local grand_pass, grand_fail = 0, 0

	for _, file in ipairs(file_list) do
		assert_mod._reset()
		local ok, err = pcall(dofile, file)
		local summary = assert_mod._summary()

		grand_pass = grand_pass + summary.pass
		grand_fail = grand_fail + summary.fail

		local counts
		if summary.pass + summary.fail > 0 then
			if summary.fail == 0 then
				counts = summary.pass .. " passed"
			else
				counts = summary.pass .. " passed, " .. summary.fail .. " failed"
			end
		end

		if ok and summary.fail == 0 then
			total_pass_files = total_pass_files + 1
			io.write("  pass  " .. file)
			if counts then io.write("  (" .. counts .. ")") end
			io.write("\n")
		else
			total_fail_files = total_fail_files + 1
			io.write("  FAIL  " .. file)
			if counts then io.write("  (" .. counts .. ")") end
			io.write("\n")

			-- Show named test failures first.
			if #summary.tests > 0 then
				for _, t in ipairs(summary.tests) do
					if not t.ok then
						local detail = t.err and (": " .. t.err) or ""
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
	io.write(total_pass_files .. " passed, " .. total_fail_files .. " failed, " .. #file_list .. " total")
	if total_assertions > 0 then
		io.write("  (" .. total_assertions .. " assertion" .. (total_assertions ~= 1 and "s" or "") .. ")")
	end
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

local function urlencode(s)
	return (s:gsub("([%c%s%%])", function(c)
		return ("%%%02X"):format(c:byte())
	end))
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

local function decode_test(s)
	local ok_flag, name_enc, err_enc = s:match("^([01])|([^|]*)|(.*)$")
	if not ok_flag then return nil end
	return {
		ok   = ok_flag == "1",
		name = urldecode(name_enc),
		err  = urldecode(err_enc) ~= "" and urldecode(err_enc) or nil,
	}
end

-- Encode a full file result into a single line.
local function encode_result(file, ok_file, pass, fail, pcall_err, tests)
	local status = (ok_file and fail == 0) and "PASS" or "FAIL"
	-- encode tests list
	local tests_enc = {}
	for _, t in ipairs(tests or {}) do
		tests_enc[#tests_enc + 1] = urlencode(encode_test(t))
	end
	local tests_str = table.concat(tests_enc, ",")
	local pcall_enc = urlencode(pcall_err or "")
	-- LINE: STATUS file pass fail pcall_err tests_list
	return status .. " " .. urlencode(file) .. " " .. pass .. " " .. fail
		.. " " .. pcall_enc .. " " .. tests_str
end

local function decode_result(line)
	local status, file_enc, pass_s, fail_s, pcall_enc, tests_str =
		line:match("^(%u+) (%S+) (%d+) (%d+) (%S*) ?(.*)$")
	if not status then return nil end

	local tests = {}
	if tests_str and tests_str ~= "" then
		for enc in tests_str:gmatch("[^,]+") do
			local t = decode_test(urldecode(enc))
			if t then tests[#tests + 1] = t end
		end
	end

	return {
		status    = status,
		file      = urldecode(file_enc),
		pass      = tonumber(pass_s),
		fail      = tonumber(fail_s),
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
			not ok and tostring(err) or nil,
			summary.tests
		) .. "\n"
		results[#results + 1] = line
	end

	-- Write all results to the pipe in one shot.
	local out = table.concat(results)
	local buf = ffi.cast("const char *", out)
	local total = #out
	local written = 0
	while written < total do
		local n = ffi.C.write(write_fd, buf + written, total - written)
		if n <= 0 then break end
		written = written + n
	end
	ffi.C.close(write_fd)
	os.exit(0)
end

-- ── parallel runner ───────────────────────────────────────────────────────────

local function run_parallel(file_list, n)
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

	-- Fork workers, create a pipe per worker.
	local pids    = {}
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
			-- Child: close read end, run worker, exit.
			ffi.C.close(rfd)
			run_worker(bucket, wfd)
			-- run_worker calls os.exit; unreachable.
		else
			-- Parent: close write end, remember read end + pid.
			ffi.C.close(wfd)
			pids[i]     = pid
			read_fds[i] = rfd
		end
	end

	-- Read all worker output (workers may finish in any order).
	-- We read from each pipe sequentially; workers write ≤ a few KB, so no deadlock.
	local all_lines = {}
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

	-- Wait for all children.
	local status_p = ffi.new("int[1]")
	for i = 1, #workers do
		ffi.C.waitpid(pids[i], status_p, 0)
	end

	-- Decode results.
	local results_by_file = {}
	for _, line in ipairs(all_lines) do
		local r = decode_result(line)
		if r then
			results_by_file[r.file] = r
		end
	end

	-- Print in sorted (deterministic) file order.
	local total_pass_files, total_fail_files = 0, 0
	local grand_pass, grand_fail = 0, 0

	for _, file in ipairs(file_list) do
		local r = results_by_file[file]
		if not r then
			-- Shouldn't happen; treat as error.
			io.write("  FAIL  " .. file .. "  (no result from worker)\n")
			total_fail_files = total_fail_files + 1
		else
			grand_pass = grand_pass + r.pass
			grand_fail = grand_fail + r.fail

			local counts
			if r.pass + r.fail > 0 then
				if r.fail == 0 then
					counts = r.pass .. " passed"
				else
					counts = r.pass .. " passed, " .. r.fail .. " failed"
				end
			end

			if r.status == "PASS" then
				total_pass_files = total_pass_files + 1
				io.write("  pass  " .. file)
				if counts then io.write("  (" .. counts .. ")") end
				io.write("\n")
			else
				total_fail_files = total_fail_files + 1
				io.write("  FAIL  " .. file)
				if counts then io.write("  (" .. counts .. ")") end
				io.write("\n")

				if #r.tests > 0 then
					for _, t in ipairs(r.tests) do
						if not t.ok then
							local detail = t.err and (": " .. t.err) or ""
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
	io.write(total_pass_files .. " passed, " .. total_fail_files .. " failed, " .. #file_list .. " total")
	if total_assertions > 0 then
		io.write("  (" .. total_assertions .. " assertion" .. (total_assertions ~= 1 and "s" or "") .. ")")
	end
	io.write("\n")

	if total_fail_files > 0 then os.exit(1) end
end

-- ── main export ───────────────────────────────────────────────────────────────

--- Run the test suite. argv is a 1-indexed list of arguments.
function M.main(argv)
	local coverage, jobs_arg = parse_args(argv)

	local files = find_test_files()
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
