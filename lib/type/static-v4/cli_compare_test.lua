-- K5b — tests for the `bin/cr check --compare` parity-testing aid.
--
-- Two layers (mirroring cli_test.lua):
--
--   1. Unit tests for argv parsing, ANSI stripping, legacy-output parsing,
--      and the compare verdict computation.
--   2. End-to-end tests that shell out to `bin/cr check --compare ...`
--      and assert on the stdout report and exit code.

if not package.path:find("?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T   = require("lib.test.assert")
local cmp = require("lib.type.static-v4.cli_compare")

-- ── Argv parsing ─────────────────────────────────────────────────────────

T.describe("v4 compare cli: argv parsing", function()
	T.it("captures file args + default cache_dir", function()
		local opts, err = cmp.parse_argv({ "foo.lua" })
		T.eq(err, nil)
		T.ok(opts ~= nil)
		if opts == nil then return end
		T.eq(opts.files[1], "foo.lua")
		T.ok(opts.cache_dir ~= nil and opts.cache_dir ~= "")
	end)

	T.it("tolerates the --compare marker", function()
		local opts = cmp.parse_argv({ "--compare", "foo.lua" })
		T.ok(opts ~= nil)
		if opts == nil then return end
		T.eq(opts.files[1], "foo.lua")
	end)

	T.it("accepts --cache-dir= and --legacy-cmd=", function()
		local opts = cmp.parse_argv({
			"--cache-dir=/tmp/c", "--legacy-cmd=./bin/cr check", "f.lua",
		})
		T.ok(opts ~= nil)
		if opts == nil then return end
		T.eq(opts.cache_dir, "/tmp/c")
		T.eq(opts.legacy_cmd, "./bin/cr check")
	end)

	T.it("rejects unknown flag", function()
		local opts, err = cmp.parse_argv({ "--nope", "f.lua" })
		T.eq(opts, nil)
		T.ok(err ~= nil and err:find("unknown flag", 1, true) ~= nil)
	end)

	T.it("requires at least one file", function()
		local opts, err = cmp.parse_argv({})
		T.eq(opts, nil)
		T.ok(err ~= nil)
	end)
end)

-- ── Legacy output parser ─────────────────────────────────────────────────

T.describe("v4 compare cli: legacy stdout parse", function()
	T.it("parses a coloured diagnostic line", function()
		local sample = "\27[1m/tmp/x.lua:1:8:\27[0m \27[31merror:\27[0m unknown identifier `nope`\n" ..
			"  1 | return nope\n             \27[31m^^^^\27[0m\n\n" ..
			"Checked 1 file(s): 1 error(s), 0 warning(s)\n"
		local diags = cmp.parse_legacy_diagnostics(sample)
		T.eq(#diags, 1)
		T.eq(diags[1].file, "/tmp/x.lua")
		T.eq(diags[1].line, 1)
		T.eq(diags[1].col, 8)
		T.eq(diags[1].severity, "error")
	end)

	T.it("empty input → no diagnostics", function()
		T.eq(#cmp.parse_legacy_diagnostics(""), 0)
	end)

	T.it("ignores summary / source-quote lines", function()
		local diags = cmp.parse_legacy_diagnostics(
			"Checked 1 file(s): 0 error(s), 0 warning(s)\n")
		T.eq(#diags, 0)
	end)
end)

-- ── Verdict computation ──────────────────────────────────────────────────

T.describe("v4 compare cli: verdict", function()
	T.it("both clean → agree", function()
		local v = cmp.compare_diagnostics({}, {})
		T.eq(v.kind, "agree")
	end)

	T.it("both reject at same position → agree", function()
		local d = { { file = "f", line = 1, col = 1, severity = "error", msg = "" } }
		local v = cmp.compare_diagnostics(d, {
			{ file = "f", line = 1, col = 1, severity = "error", msg = "different msg ok" },
		})
		T.eq(v.kind, "agree")
	end)

	T.it("one clean, one rejects → diverge_decision", function()
		local v = cmp.compare_diagnostics({},
			{ { file = "f", line = 1, col = 1, severity = "error", msg = "" } })
		T.eq(v.kind, "diverge_decision")
	end)

	T.it("both reject at different positions → diverge_details", function()
		local a = { { file = "f", line = 1, col = 1, severity = "error", msg = "" } }
		local b = { { file = "f", line = 2, col = 3, severity = "error", msg = "" } }
		local v = cmp.compare_diagnostics(a, b)
		T.eq(v.kind, "diverge_details")
	end)

	T.it("both reject but different error counts → diverge_details", function()
		local a = {
			{ file = "f", line = 1, col = 1, severity = "error", msg = "" },
			{ file = "f", line = 2, col = 1, severity = "error", msg = "" },
		}
		local b = { { file = "f", line = 1, col = 1, severity = "error", msg = "" } }
		T.eq(cmp.compare_diagnostics(a, b).kind, "diverge_details")
	end)
end)

-- ── End-to-end ───────────────────────────────────────────────────────────

--: (string, string) -> string
local function write_tmp(name, content)
	local path = "/tmp/v4_compare_test_" .. name
	local f = io.open(path, "wb")
	if f == nil then error("cannot open " .. path) end
	f:write(content); f:close()
	return path
end

--: (string) -> (string, string, integer)
local function run_cli(args_str)
	local out_path  = os.tmpname()
	local err_path  = os.tmpname()
	local code_path = os.tmpname()
	local cache_dir = os.tmpname()
	os.remove(cache_dir)
	local cmd = "./bin/cr check --compare --cache-dir=" .. cache_dir ..
		" " .. args_str .. " >" .. out_path .. " 2>" .. err_path ..
		"; echo $? >" .. code_path
	os.execute(cmd)
	--: (string) -> string
	local function slurp(p)
		local f = io.open(p, "rb"); if f == nil then return "" end
		local s = f:read("*a") or ""; f:close(); return tostring(s)
	end
	local stdout = slurp(out_path)
	local stderr = slurp(err_path)
	local code_n = tonumber((slurp(code_path):gsub("%s+$", ""))) or -1
	os.remove(out_path); os.remove(err_path); os.remove(code_path)
	return stdout, stderr, math.floor(code_n --[[: number]])
end

T.describe("v4 compare cli: end-to-end", function()
	T.it("both impls clean → exit 0, 'agree: clean'", function()
		local path = write_tmp("clean.lua", "local x = 1\nreturn x\n")
		local stdout, _stderr, code = run_cli(path)
		T.eq(code, 0)
		T.ok(stdout:find("agree: clean", 1, true) ~= nil,
			"expected 'agree: clean'; got: " .. stdout)
	end)

	T.it("both impls reject same undefined name → exit 0, 'agree:'", function()
		-- Content must be unique per test run: the legacy CLI caches
		-- diagnostics by source-content hash and returns the ORIGINAL
		-- file path on a cache hit. If two tmp files share content the
		-- legacy diag would carry the other file's path, breaking the
		-- positional compare. Use an identifier unlikely to collide with
		-- any other test source in the repo.
		local path = write_tmp("err.lua",
			"return nope_a_unique_undefined_name_for_compare_test\n")
		local stdout, _stderr, code = run_cli(path)
		T.eq(code, 0,
			"expected agree exit 0; stdout=" .. stdout)
		T.ok(stdout:find("agree:", 1, true) ~= nil,
			"expected 'agree:' verdict; got: " .. stdout)
	end)

	T.it("diverge on decision: legacy accepts, v4 rejects → exit 1", function()
		-- `local x = 1 + 1` — legacy is happy with the binary expression;
		-- v4's walker stub for NODE_BINARY_EXPR rejects. This is a real
		-- divergence the K6 corpus run will surface; it's a good
		-- positive-control here because it's stable.
		local path = write_tmp("dec_div.lua",
			"local zz_unique_compare_decision = 1 + 1\n" ..
			"return zz_unique_compare_decision\n")
		local stdout, _stderr, code = run_cli(path)
		T.eq(code, 1, "expected exit 1 for decision divergence; got " ..
			tostring(code) .. " stdout=" .. stdout)
		T.ok(stdout:find("DIVERGE on decision", 1, true) ~= nil,
			"expected 'DIVERGE on decision'; got: " .. stdout)
		T.ok(stdout:find("legacy accepts", 1, true) ~= nil,
			"expected legacy-accepts; got: " .. stdout)
	end)

	T.it("diverge on details: both reject but different positions → exit 2", function()
		local path = write_tmp("det_div.lua",
			"local f_unique_det = function(a) return a + 1 end\n" ..
			"return f_unique_det(\"unique_det_str\")\n")
		local stdout, _stderr, code = run_cli(path)
		T.eq(code, 2, "expected exit 2 for detail divergence; got " ..
			tostring(code) .. " stdout=" .. stdout)
		T.ok(stdout:find("DIVERGE on details", 1, true) ~= nil,
			"expected 'DIVERGE on details'; got: " .. stdout)
		-- Both diagnostic streams should appear in the report.
		T.ok(stdout:find("legacy:", 1, true) ~= nil)
		T.ok(stdout:find("v4:", 1, true) ~= nil)
	end)

	T.it("missing file → driver-itself failure (exit 3)", function()
		local stdout, stderr, code = run_cli("/tmp/v4_compare_nonexistent_xyz.lua")
		T.eq(code, 3)
		T.ok(stderr:find("v4 driver failed", 1, true) ~= nil
			or stderr:find("cannot read", 1, true) ~= nil,
			"expected v4 driver error; stderr=" .. stderr .. " stdout=" .. stdout)
	end)
end)
