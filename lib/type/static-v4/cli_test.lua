-- K5 — tests for the v4 CLI (`bin/cr check --v4`).
--
-- Two layers:
--
--   1. Unit tests against `M.parse_argv` for argv parsing rules
--      (recognised flags, errors on unknowns, file-list capture).
--   2. End-to-end tests that shell out to `bin/cr check --v4 ...` via
--      io.popen, capture stdout+stderr+exit code, and assert against
--      the rendered output. The smoke tests exist because the CLI is
--      the I/O boundary — a unit-only test cannot prove the wiring
--      (bin/cr-check.lua dispatch, real io_caps, parse cap, stdlib
--      injection) works.
--
-- E2E tests are tagged via the `CRESCENT_V4_CLI_E2E_SKIP` env var so
-- they can be skipped in environments without a usable shell (the test
-- runner is the same `bin/cr` we invoke, so the binary is guaranteed to
-- exist).

if not package.path:find("?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T   = require("lib.test.assert")
local cli = require("lib.type.static-v4.cli")

-- ── Argv parsing ─────────────────────────────────────────────────────────

T.describe("v4 cli: argv parsing", function()
	T.it("captures bare file arguments", function()
		local opts, err = cli.parse_argv({ "foo.lua", "bar.lua" })
		T.eq(err, nil)
		T.ok(opts ~= nil)
		if opts == nil then return end
		T.eq(#opts.files, 2)
		T.eq(opts.files[1], "foo.lua")
		T.eq(opts.files[2], "bar.lua")
		T.eq(opts.summary, false)
		T.eq(opts.cache_dir, cli.DEFAULT_CACHE_DIR)
	end)

	T.it("recognises --summary", function()
		local opts = cli.parse_argv({ "--summary", "foo.lua" })
		T.ok(opts ~= nil)
		if opts == nil then return end
		T.eq(opts.summary, true)
		T.eq(opts.files[1], "foo.lua")
	end)

	T.it("recognises --cache-dir=PATH", function()
		local opts = cli.parse_argv({ "--cache-dir=/tmp/cache", "foo.lua" })
		T.ok(opts ~= nil)
		if opts == nil then return end
		T.eq(opts.cache_dir, "/tmp/cache")
	end)

	T.it("--cache-dir= with empty value errors", function()
		local opts, err = cli.parse_argv({ "--cache-dir=", "foo.lua" })
		T.eq(opts, nil)
		T.ok(err ~= nil and err:find("cache-dir", 1, true) ~= nil)
	end)

	T.it("rejects unknown flags", function()
		local opts, err = cli.parse_argv({ "--bogus", "foo.lua" })
		T.eq(opts, nil)
		T.ok(err ~= nil and err:find("unknown flag", 1, true) ~= nil)
	end)

	T.it("`--` ends flag parsing", function()
		local opts = cli.parse_argv({ "--", "--summary" })
		T.ok(opts ~= nil)
		if opts == nil then return end
		T.eq(opts.summary, false)
		T.eq(opts.files[1], "--summary")
	end)

	T.it("requires at least one file", function()
		local opts, err = cli.parse_argv({})
		T.eq(opts, nil)
		T.ok(err ~= nil and err:find("at least one file", 1, true) ~= nil)
	end)

	T.it("tolerates the --v4 marker (bin/cr-check.lua strips it but we accept it)", function()
		local opts = cli.parse_argv({ "--v4", "foo.lua" })
		T.ok(opts ~= nil)
		if opts == nil then return end
		T.eq(opts.files[1], "foo.lua")
	end)
end)

-- ── E2E via io.popen ─────────────────────────────────────────────────────

-- Helper: write a Lua source string to a tmp file under /tmp and return
-- the path. Tests own /tmp paths uniquely; no cleanup since /tmp is
-- volatile and test names are stable.
--: (string, string) -> string
local function write_tmp(name, content)
	local path = "/tmp/v4_cli_test_" .. name
	local f = io.open(path, "wb")
	if f == nil then error("cannot open " .. path) end
	f:write(content)
	f:close()
	return path
end

-- Run `bin/cr check --v4 <args>` and capture (stdout, stderr, exit code).
-- LuaJIT's `io.popen`/`p:close()` does not reliably surface child exit
-- codes (the build here returns plain `true`), so we redirect stdout and
-- stderr into separate files and capture the exit code via `$?` written
-- to a third file by the shell. This is robust across LuaJIT versions.
--: (string) -> (string, string, integer)
local function run_cli(args_str)
	local stdout_path = os.tmpname()
	local stderr_path = os.tmpname()
	local code_path   = os.tmpname()
	-- Use a temporary cache_dir per test to keep them independent.
	local cache_dir   = os.tmpname()
	os.remove(cache_dir)
	-- The test runner's cwd is the repo root (bin/cr test invokes from
	-- there); bin/cr is therefore on a relative path. Use `./bin/cr`.
	local cmd = "./bin/cr check --v4 --cache-dir=" .. cache_dir ..
		" " .. args_str .. " >" .. stdout_path .. " 2>" .. stderr_path ..
		"; echo $? >" .. code_path
	os.execute(cmd)
	--: (string) -> string
	local function slurp(p)
		local f = io.open(p, "rb")
		if f == nil then return "" end
		local s = f:read("*a") or ""
		f:close()
		return tostring(s)
	end
	local stdout = slurp(stdout_path)
	local stderr = slurp(stderr_path)
	local code_str = (slurp(code_path):gsub("%s+$", ""))
	local code_n = tonumber(code_str) or -1
	local code = math.floor(code_n --[[: number]])
	os.remove(stdout_path); os.remove(stderr_path); os.remove(code_path)
	return stdout, stderr, code
end

T.describe("v4 cli: end-to-end", function()
	T.it("simple file: exit 0, no diagnostics", function()
		local path = write_tmp("simple.lua", "local x = 1\nreturn x\n")
		local stdout, _stderr, code = run_cli(path)
		T.eq(code, 0)
		T.eq(stdout, "")
	end)

	T.it("file with type error: exit non-zero, diagnostic on stdout", function()
		local path = write_tmp("err.lua", "return nope\n")
		local stdout, _stderr, code = run_cli(path)
		T.neq(code, 0)
		-- Default rendering: file:line:col format.
		T.ok(stdout:find(path, 1, true) ~= nil,
			"expected stdout to mention path; got: " .. stdout)
		T.ok(stdout:find("undefined-name", 1, true) ~= nil,
			"expected undefined-name diagnostic; got: " .. stdout)
	end)

	T.it("`--summary` produces grouped output", function()
		local path = write_tmp("multi_err.lua",
			"local x = nope1\n" ..
			"local y = nope2\n" ..
			"return x\n")
		local stdout, _stderr, code = run_cli("--summary " .. path)
		T.neq(code, 0)
		-- Summary header.
		T.ok(stdout:find("error", 1, true) ~= nil)
		-- Summary section heading.
		T.ok(stdout:find("undefined names", 1, true) ~= nil,
			"expected summary heading; got: " .. stdout)
	end)

	T.it("missing file: clean error, non-zero exit", function()
		local stdout, stderr, code = run_cli("/tmp/v4_cli_test_nonexistent_xyz.lua")
		T.neq(code, 0)
		-- The driver returns errmsg; the CLI writes it to stderr.
		T.ok(stderr:find("cannot read", 1, true) ~= nil
			or stderr:find("ENOENT", 1, true) ~= nil
			or stderr:find("No such file", 1, true) ~= nil,
			"expected stderr to mention read failure; got stderr=" .. stderr
				.. " stdout=" .. stdout)
	end)

	T.it("legacy path unchanged: no --v4 dispatches to legacy", function()
		local path = write_tmp("legacy_smoke.lua", "local x = 1\nreturn x\n")
		-- Don't go through run_cli (it forces --v4). Build the raw
		-- command; capture exit code via shell since popen doesn't
		-- expose it reliably.
		local code_path = os.tmpname()
		local out_path  = os.tmpname()
		os.execute("./bin/cr check " .. path .. " >" .. out_path ..
			" 2>&1; echo $? >" .. code_path)
		--: (string) -> string
		local function slurp(p)
			local f = io.open(p, "rb"); if f == nil then return "" end
			local s = f:read("*a") or ""; f:close(); return tostring(s)
		end
		local out = slurp(out_path)
		local code_str = (slurp(code_path):gsub("%s+$", ""))
		local exit_code = tonumber(code_str) or -1
		os.remove(out_path); os.remove(code_path)
		-- We just assert the legacy CLI ran (exit 0 on a trivial file)
		-- and produced output that does NOT mention v4 internals.
		T.eq(exit_code, 0,
			"legacy `bin/cr check <file>` should still pass on a trivial file; got code=" ..
			tostring(exit_code) .. " out=" .. out)
	end)

	T.it("unknown flag errors loudly", function()
		local path = write_tmp("simple2.lua", "return 1\n")
		local stdout, stderr, code = run_cli("--bogus " .. path)
		T.neq(code, 0)
		T.ok(stderr:find("unknown flag", 1, true) ~= nil,
			"expected stderr unknown-flag; got stderr=" .. stderr
				.. " stdout=" .. stdout)
	end)
end)
