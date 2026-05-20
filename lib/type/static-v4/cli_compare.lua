-- K5b — `bin/cr check --compare <file>` parity-testing aid.
--
-- Invokes both the legacy typechecker and the v4 driver on the same
-- file(s), then reports whether they agree on the accept/reject decision
-- and the locations of any diagnostics.
--
-- Treatment of legacy
-- ───────────────────
-- The legacy typechecker is treated as a **black-box subprocess**. We
-- shell out to `bin/cr check <file>` (no `--v4`) and parse its stdout for
-- `file:line:col: severity:` lines. This is deliberately lossy — we do
-- NOT depend on the legacy CLI's internal diagnostic representation, so
-- changes there don't ripple into compare. ANSI colour codes are stripped
-- before parsing.
--
-- Treatment of v4
-- ──────────────
-- We have structured diagnostics directly from the driver, so no
-- text-parse round-trip is required.
--
-- Diff logic — what "agreement" means
-- ───────────────────────────────────
-- Each impl produces a list of diagnostic positions:
--   { file = string, line = integer, col = integer, severity = string }
-- (`severity` is "error" or "warning"; legacy may also emit "note" — we
-- carry it through but don't special-case it.)
--
-- Agreement is computed in two layers:
--
--   1. **Decision agreement**: legacy clean iff v4 clean. "Clean" means
--      no error-severity diagnostics. (Warnings alone count as clean —
--      legacy's exit code does too.) This is the primary parity signal.
--   2. **Detail agreement**: when both reject, the canonical-position
--      multisets are equal. Canonical position = (file, line, col,
--      severity). Messages are NOT compared (legacy and v4 don't share
--      taxonomy).
--
-- Exit codes
-- ──────────
--   0  — agreement (whether clean or both-reject with identical positions)
--   1  — diverge on decision (one accepts, the other rejects)
--   2  — diverge on details  (both reject but positions/counts differ)
--   3  — argv parse error or driver-itself failure
--
-- This is a parity *aid*, not a typecheck pass. Exit reflects whether
-- the impls agree, not whether the file is well-typed.

if not package.path:find("?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local driver_mod = require("lib.type.static-v4.driver.driver")
local stdlib_mod = require("lib.type.static-v4.stdlib_types_v4")
local parse_mod  = require("lib.type.static.parse")
local v4_cli     = require("lib.type.static-v4.cli")

local M = {}

--:: CompareDiag = { file: string, line: integer, col: integer, severity: string, msg: string }
--:: CompareDiags = { [integer]: CompareDiag }
--:: CompareVerdict = { kind: string, legacy_errors: integer, v4_errors: integer, legacy_total: integer, v4_total: integer }
--:: V4CompareOpts = { files: { [integer]: string }, cache_dir: string, legacy_cmd: string }

-- ── Argv parsing ─────────────────────────────────────────────────────────
--
-- Recognised flags:
--   --cache-dir=PATH    forwarded to the v4 driver
--   --legacy-cmd=CMD    override the legacy invocation (default `./bin/cr check`)
--                       — useful when running from a different cwd. The
--                       file path is appended.
--   --                  end-of-flags marker
--
-- Bare arguments are files (≥1 required).

--: ({ [integer]: string }) -> (V4CompareOpts | nil, string | nil)
local function parse_argv(argv)
	local opts = {
		files      = {} --[[: { [integer]: string } ]],
		cache_dir  = v4_cli.DEFAULT_CACHE_DIR,
		legacy_cmd = "./bin/cr check",
	}
	local end_of_flags = false
	for i = 1, #argv do
		local a = argv[i]
		if end_of_flags then
			opts.files[#opts.files + 1] = a
		elseif a == "--" then
			end_of_flags = true
		elseif a == "--compare" then
			-- already-consumed marker; tolerated
		elseif a:sub(1, 12) == "--cache-dir=" then
			local v = a:sub(13)
			if v == "" then
				return nil, "cr check --compare: --cache-dir= requires a value"
			end
			opts.cache_dir = v
		elseif a:sub(1, 13) == "--legacy-cmd=" then
			local v = a:sub(14)
			if v == "" then
				return nil, "cr check --compare: --legacy-cmd= requires a value"
			end
			opts.legacy_cmd = v
		elseif a:sub(1, 2) == "--" then
			return nil, "cr check --compare: unknown flag " .. a
		else
			opts.files[#opts.files + 1] = a
		end
	end
	if #opts.files == 0 then
		return nil, "cr check --compare: at least one file is required"
	end
	return opts, nil
end

M.parse_argv = parse_argv

-- ── Legacy subprocess driver ─────────────────────────────────────────────
--
-- Runs `<legacy_cmd> <file>` and parses the resulting stdout for
-- diagnostic lines. We capture stdout+stderr together (legacy writes diag
-- text to stdout; we keep stderr in case the file is missing).
--
-- Why parse text instead of importing the legacy diagnostics: the prompt
-- forbids re-reading the legacy CLI to learn its diagnostic shape.
-- Subprocess parsing is the contamination-free interface.

--: (string) -> string
local function strip_ansi(s)
	-- ESC `[` <params> <intermediate>* <final>; strip CSI sequences. Lua's
	-- pattern engine doesn't do character classes well, but `%[...m` is
	-- sufficient for the colour codes legacy emits.
	local out, _n = s:gsub("\27%[[%d;]*[a-zA-Z]", "")
	return out
end

-- Parse legacy stdout into a diagnostic-position list. Looks for lines
-- matching `<file>:<line>:<col>: <severity>:` after ANSI stripping. Lines
-- not matching (source quote lines, the trailing "Checked N file(s)"
-- summary) are ignored.
--
--: (string) -> CompareDiags
local function parse_legacy_diagnostics(text)
	local out = {} --[[: CompareDiags ]]
	local clean = strip_ansi(text)
	for line in clean:gmatch("[^\r\n]+") do
		-- Anchor: <path>:<digits>:<digits>: <severity>:  — severity is one
		-- of error|warning|note. The path can contain `:` on Windows; this
		-- compare tool is POSIX-shell-bound anyway (see legacy_cmd
		-- default), so we accept any non-colon-non-space run for the path.
		local file, ln, col, sev, msg =
			line:match("^([^:]+):(%d+):(%d+):%s+(%a+):%s*(.*)$")
		if file ~= nil and (sev == "error" or sev == "warning" or sev == "note") then
			local ln_n  = tonumber(ln)  or 0
			local col_n = tonumber(col) or 0
			out[#out + 1] = {
				file     = file,
				line     = math.floor(ln_n  --[[: number]]),
				col      = math.floor(col_n --[[: number]]),
				severity = sev,
				msg      = msg or "",
			}
		end
	end
	return out
end

M.parse_legacy_diagnostics = parse_legacy_diagnostics
M._strip_ansi = strip_ansi

-- Shell-escape a path for inclusion in a single-quoted argument.
--: (string) -> string
local function sh_quote(s)
	local escaped, _n = s:gsub("'", "'\\''")
	return "'" .. escaped .. "'"
end

-- Slurp a file to string via the io_caps read_file cap. Returns "" on
-- failure (used only for capturing temp output where missing-file is
-- effectively "empty").
--
--: ((string) -> (string | nil, string | nil), string) -> string
local function slurp(read_file, path)
	local bytes, _err = read_file(path)
	if bytes == nil then return "" end
	return bytes
end

--:: CompareIoCaps = { read_file: (path: string) -> (string | nil, string | nil), write_file: (path: string, bytes: string) -> (boolean, string | nil), mkdir: (path: string) -> (boolean, string | nil), file_exists: (path: string) -> boolean }

-- Run the legacy typechecker on one file. Returns (diagnostics, exit_code,
-- raw_output). `raw_output` is included so callers can display it on
-- divergence-on-details.
--
--: (string, string, CompareIoCaps) -> (CompareDiags, integer, string)
local function run_legacy(legacy_cmd, path, io_caps)
	-- We need both stdout and the exit code. LuaJIT's p:close() doesn't
	-- reliably surface exit on all builds; use the same shell-redirect
	-- trick as cli_test.lua.
	local out_path  = os.tmpname()
	local code_path = os.tmpname()
	local cmd = legacy_cmd .. " " .. sh_quote(path) ..
		" >" .. out_path .. " 2>&1; echo $? >" .. code_path
	os.execute(cmd)
	local out_bytes  = slurp(io_caps.read_file, out_path)
	local code_bytes = slurp(io_caps.read_file, code_path)
	os.remove(out_path); os.remove(code_path)
	local trimmed, _n = code_bytes:gsub("%s+$", "")
	local code_n = tonumber(trimmed) or -1
	local diags = parse_legacy_diagnostics(out_bytes)
	local code_int = math.floor(code_n --[[: number]])
	return diags, code_int, out_bytes
end

M.run_legacy = run_legacy

-- ── v4 driver invocation ─────────────────────────────────────────────────

--:: V4DriveResult = { diagnostics: { [integer]: { pos: { file: string, line: integer, col: integer, ... } | nil, severity: string, msg: string, ... } }, ... }

-- Run the v4 driver on one file. Returns the same diagnostic-position
-- list shape as run_legacy plus the raw structured diagnostics.
--
--: (string, V4CompareOpts, CompareIoCaps) -> (CompareDiags | nil, string | nil)
local function run_v4(path, opts, io_caps)
	local result, errmsg = driver_mod.drive(path, {
		io_caps   = io_caps,
		cache_dir = opts.cache_dir,
		stdlib    = stdlib_mod,
		parse     = parse_mod.parse,
	})
	if result == nil then return nil, errmsg end
	local rr = result --[[: V4DriveResult]]
	local out = {} --[[: CompareDiags ]]
	for _, d in ipairs(rr.diagnostics or {}) do
		local pos = d.pos
		out[#out + 1] = {
			file     = (pos and pos.file) or path,
			line     = (pos and pos.line) or 0,
			col      = (pos and pos.col)  or 0,
			severity = d.severity or "error",
			msg      = d.msg or "",
		}
	end
	return out, nil
end

M.run_v4 = run_v4

-- ── Diff logic ───────────────────────────────────────────────────────────
--
-- Canonical-key multiset comparison. The key is "<file>:<line>:<col>:
-- <severity>"; messages are intentionally NOT in the key (legacy and v4
-- have independent taxonomies).
--
--: (CompareDiags) -> { [string]: integer }
local function key_multiset(diags)
	local m = {} --[[: { [string]: integer } ]]
	for _, d in ipairs(diags) do
		local k = d.file .. ":" .. tostring(d.line) .. ":" ..
			tostring(d.col) .. ":" .. d.severity
		m[k] = (m[k] or 0) + 1
	end
	return m
end

--: ({ [string]: integer }, { [string]: integer }) -> boolean
local function multisets_equal(a, b)
	for k, v in pairs(a) do if b[k] ~= v then return false end end
	for k, v in pairs(b) do if a[k] ~= v then return false end end
	return true
end

--: (CompareDiags) -> integer
local function count_errors(diags)
	local n = 0
	for _, d in ipairs(diags) do if d.severity == "error" then n = n + 1 end end
	return n
end

M.key_multiset    = key_multiset
M.multisets_equal = multisets_equal
M.count_errors    = count_errors

-- Compare two diagnostic lists.
--
--: (CompareDiags, CompareDiags) -> CompareVerdict
local function compare_diagnostics(legacy_diags, v4_diags)
	local le = count_errors(legacy_diags)
	local ve = count_errors(v4_diags)
	local legacy_clean = le == 0
	local v4_clean     = ve == 0
	local kind
	if legacy_clean ~= v4_clean then
		kind = "diverge_decision"
	elseif multisets_equal(key_multiset(legacy_diags), key_multiset(v4_diags)) then
		kind = "agree"
	else
		kind = "diverge_details"
	end
	return {
		kind          = kind,
		legacy_errors = le,
		v4_errors     = ve,
		legacy_total  = #legacy_diags,
		v4_total      = #v4_diags,
	}
end

M.compare_diagnostics = compare_diagnostics

-- ── Rendering ────────────────────────────────────────────────────────────

--: (CompareDiags) -> string
local function render_diag_block(diags)
	if #diags == 0 then return "  (clean)\n" end
	local lines = {} --[[: { [integer]: string } ]]
	for _, d in ipairs(diags) do
		lines[#lines + 1] = "  " .. d.file .. ":" .. tostring(d.line) ..
			":" .. tostring(d.col) .. ": " .. d.severity .. ": " .. d.msg
	end
	return table.concat(lines, "\n") .. "\n"
end

--:: CompareWriter = { write: (CompareWriter, string) -> unknown, ... }

-- Render one file's verdict. `out` is io.stdout-shape (matched
-- structurally via `...` — only the `write` method is consumed).
--: (string, CompareDiags, CompareDiags, CompareVerdict, CompareWriter) -> nil
local function render_file_verdict(path, legacy_diags, v4_diags, verdict, out)
	out:write(path .. ":\n")
	if verdict.kind == "agree" then
		if verdict.v4_errors == 0 and verdict.legacy_errors == 0 and
			verdict.v4_total == 0 and verdict.legacy_total == 0 then
			out:write("  agree: clean\n")
		else
			out:write("  agree: " .. tostring(verdict.v4_errors) .. " error(s), " ..
				tostring(verdict.v4_total - verdict.v4_errors) .. " warning(s)\n")
		end
		return
	end
	if verdict.kind == "diverge_decision" then
		local accepted = verdict.legacy_errors == 0 and "legacy" or "v4"
		local rejected = accepted == "legacy" and "v4" or "legacy"
		out:write("  DIVERGE on decision: " .. accepted .. " accepts, " ..
			rejected .. " rejects\n")
	else
		out:write("  DIVERGE on details: legacy " ..
			tostring(verdict.legacy_errors) .. " error(s) / v4 " ..
			tostring(verdict.v4_errors) .. " error(s)\n")
	end
	out:write("  legacy:\n")
	out:write(render_diag_block(legacy_diags))
	out:write("  v4:\n")
	out:write(render_diag_block(v4_diags))
end

M.render_file_verdict = render_file_verdict

-- ── Main entry ───────────────────────────────────────────────────────────
--
-- Returns an integer exit code per the codes documented at the top of
-- this file. Aggregation rule across files: the worst verdict wins
-- (3 > 2 > 1 > 0).

--: ({ [integer]: string }) -> integer
function M.main(argv)
	local opts, perr = parse_argv(argv)
	if opts == nil then
		io.stderr:write(tostring(perr) .. "\n")
		return 3
	end

	local io_caps = v4_cli.make_io_caps() --[[: CompareIoCaps]]
	io_caps.mkdir(opts.cache_dir)

	local worst = 0 -- 0=agree, 1=decision, 2=details, 3=driver-error
	for _, path in ipairs(opts.files) do
		local legacy_diags, _lcode, _lraw = run_legacy(opts.legacy_cmd, path, io_caps)
		local v4_diags, v4_err = run_v4(path, opts, io_caps)
		if v4_diags == nil then
			io.stderr:write("cr check --compare: v4 driver failed on " ..
				path .. ": " .. tostring(v4_err) .. "\n")
			if worst < 3 then worst = 3 end
		else
			local verdict = compare_diagnostics(legacy_diags, v4_diags)
			render_file_verdict(path, legacy_diags, v4_diags, verdict,
				io.stdout --[[: CompareWriter]])
			local code
			if verdict.kind == "agree" then code = 0
			elseif verdict.kind == "diverge_decision" then code = 1
			else code = 2
			end
			if code > worst then worst = code end
		end
	end
	return worst
end

return M
