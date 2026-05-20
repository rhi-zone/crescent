-- K5 — v4 typechecker CLI entry.
--
-- Invoked via `bin/cr check --v4 [--summary] <file>...` (bin/cr-check.lua
-- dispatches to this module when `--v4` is present in argv).
--
-- Responsibilities (per docs/typechecker-v4-driver-design.md §7 and §8):
--
--   1. Parse argv for the v4 invocation (filename(s), `--summary`,
--      `--cache-dir=PATH`). Unrecognised flags error loudly — no ad-hoc
--      shortcuts.
--   2. Build io_caps directly from `io`/`os` (the CLI is the legitimate
--      I/O entry point per CLAUDE.md "Caps-first, everywhere" — caps
--      discipline is about libraries, not the CLI itself).
--   3. Load the v4 stdlib bindings record once per invocation
--      (`lib.type.static-v4.stdlib_types_v4`).
--   4. Install the legacy parser (`lib.type.static.parse.parse`) as the
--      driver's `parse` cap.
--   5. Invoke the K1 driver per file, collect diagnostics, render via K4
--      (default or `--summary` mode).
--   6. Exit code: 0 iff no error-severity diagnostics across all files
--      and no driver-itself failures.
--
-- This module is NOT a re-read of `lib/type/static/cli.lua` (the legacy
-- CLI). The v4 CLI is designed fresh from the K1+K4 surfaces.
--
-- Out of scope for K5 (documented in the prompt + design doc):
--
--   * `--compare` mode (run both legacy and v4 and diff) — K5b/later.
--   * LSP integration.
--   * Project-wide check with no file args (implies a discovery pass).

if not package.path:find("?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local driver_mod  = require("lib.type.static-v4.driver.driver")
local summary_mod = require("lib.type.static-v4.driver.summary")
local stdlib_mod  = require("lib.type.static-v4.stdlib_types_v4")
local parse_mod   = require("lib.type.static.parse")

local M = {}

-- ── io caps backed directly by io / os ───────────────────────────────────
--
-- The CLI is the legitimate boundary that materialises real I/O caps.
-- Libraries downstream see these as injected functions — never as direct
-- `io` / `os` references.

--: (string) -> (string | nil, string | nil)
local function cap_read_file(path)
	local f, oerr = io.open(path, "rb")
	if f == nil then return nil, tostring(oerr) end
	local bytes = f:read("*a")
	f:close()
	if bytes == nil then return nil, "read failed: " .. path end
	return bytes, nil
end

--: (string, string) -> (boolean, string | nil)
local function cap_write_file(path, bytes)
	local f, oerr = io.open(path, "wb")
	if f == nil then return false, tostring(oerr) end
	local _, werr = f:write(bytes)
	f:close()
	if werr ~= nil then return false, tostring(werr) end
	return true, nil
end

--: (string) -> (boolean, string | nil)
local function cap_mkdir(path)
	-- mkdir -p semantics; portable to POSIX shells. Windows path of
	-- bin/cr is `cr.bat` / `cr.ps1` (unchanged in K5); when v4 lands on
	-- Windows this fork-mkdir needs revisiting.
	local escaped = (path:gsub("'", "'\\''"))
	local quoted = "'" .. escaped .. "'"
	local ok = os.execute("mkdir -p " .. quoted)
	if ok == true or ok == 0 then return true, nil end
	return false, "mkdir failed: " .. path
end

--: (string) -> boolean
local function cap_file_exists(path)
	local f = io.open(path, "rb")
	if f == nil then return false end
	f:close()
	return true
end

--: () -> { read_file: (path: string) -> (string | nil, string | nil), write_file: (path: string, bytes: string) -> (boolean, string | nil), mkdir: (path: string) -> (boolean, string | nil), file_exists: (path: string) -> boolean }
local function make_io_caps()
	return {
		read_file   = cap_read_file,
		write_file  = cap_write_file,
		mkdir       = cap_mkdir,
		file_exists = cap_file_exists,
	}
end

M.make_io_caps = make_io_caps

-- ── Default cache_dir ────────────────────────────────────────────────────
--
-- Per design doc §11 #7 (open question) and `.gitignore` precedent
-- (`.crescentcache/`), the per-repo cache directory is the chosen
-- default. Git-aware (`.gitignore`-able), and a fresh clone starts with
-- an empty cache (no stale entries from a previous clone). This matches
-- CLAUDE.md's "git clone and run" invariant — a sibling clone shares no
-- typechecker state with the current one.
M.DEFAULT_CACHE_DIR = ".crescentcache"

-- ── Argv parsing ─────────────────────────────────────────────────────────
--
-- Recognised flags (after `check --v4` has been consumed by bin/cr-check.lua):
--
--   --summary             switch to root-cause-grouped rendering
--   --cache-dir=PATH      override cache directory
--   --                    end-of-flags marker; subsequent args are files
--
-- Anything else starting with `--` is an error. Bare arguments are files.

--:: V4CliOpts = { files: { [integer]: string }, summary: boolean, cache_dir: string }

--: ({ [integer]: string }) -> (V4CliOpts | nil, string | nil)
local function parse_argv(argv)
	local opts = {
		files     = {} --[[: { [integer]: string } ]],
		summary   = false,
		cache_dir = M.DEFAULT_CACHE_DIR,
	}
	local end_of_flags = false
	for i = 1, #argv do
		local a = argv[i]
		if end_of_flags then
			opts.files[#opts.files + 1] = a
		elseif a == "--" then
			end_of_flags = true
		elseif a == "--v4" then
			-- Already-consumed marker; tolerated if bin/cr-check forwards it.
		elseif a == "--summary" then
			opts.summary = true
		elseif a:sub(1, 12) == "--cache-dir=" then
			local v = a:sub(13)
			if v == "" then
				return nil, "cr check --v4: --cache-dir= requires a value"
			end
			opts.cache_dir = v
		elseif a == "--cache-dir" then
			return nil, "cr check --v4: --cache-dir requires =VALUE (got bare flag)"
		elseif a:sub(1, 2) == "--" then
			return nil, "cr check --v4: unknown flag " .. a
		else
			opts.files[#opts.files + 1] = a
		end
	end
	if #opts.files == 0 then
		return nil, "cr check --v4: at least one file is required"
	end
	return opts, nil
end

M.parse_argv = parse_argv

-- ── One-file driver invocation ───────────────────────────────────────────
--
-- Wraps the K1 driver with our io_caps / stdlib / parse cap. Returns
-- (result, errmsg) — errmsg non-nil indicates a driver-itself failure
-- (missing file, parse exception bubble, cache-store I/O failure).

--: (string, V4CliOpts, unknown) -> ({ diagnostics: unknown, ... } | nil, string | nil)
local function check_one(path, opts, io_caps)
	local drive_opts = {
		io_caps   = io_caps,
		cache_dir = opts.cache_dir,
		stdlib    = stdlib_mod,
		parse     = parse_mod.parse,
	}
	return driver_mod.drive(path, drive_opts)
end

-- ── Main entry ───────────────────────────────────────────────────────────
--
-- Returns an integer exit code; callers (bin/cr-check.lua) os.exit()
-- with the returned value. We do not call os.exit ourselves so unit
-- tests can drive `main` without aborting the process.

--: ({ [integer]: string }) -> integer
function M.main(argv)
	local opts, perr = parse_argv(argv)
	if opts == nil then
		io.stderr:write(tostring(perr) .. "\n")
		return 2
	end

	-- Ensure cache dir exists (best-effort; the cache layer will also
	-- mkdir as needed, but creating up-front gives a clearer error if
	-- the path is unwritable).
	local io_caps = make_io_caps()
	local _ok, _merr = io_caps.mkdir(opts.cache_dir)
	-- We deliberately do NOT fail on mkdir error — the cache layer will
	-- surface a more precise failure when it tries to write.

	--:: V4Diag = { code: string, pos: { file: string, line: integer, col: integer, end_line: integer | nil, end_col: integer | nil } | nil, msg: string, severity: string, origin_kind: string | nil, module: string | nil }
	local all_diagnostics = {} --[[: { [integer]: V4Diag } ]]
	local any_driver_error = false

	for _, path in ipairs(opts.files) do
		local result, errmsg = check_one(path, opts, io_caps)
		if result == nil then
			io.stderr:write("cr check --v4: " .. tostring(errmsg) .. "\n")
			any_driver_error = true
		else
			for _, d in ipairs(result.diagnostics or {}) do
				all_diagnostics[#all_diagnostics + 1] = d --[[: V4Diag]]
			end
		end
	end

	-- Render.
	local rendered
	if opts.summary then
		rendered = summary_mod.render_summary(all_diagnostics)
	else
		rendered = summary_mod.render_default(all_diagnostics)
	end
	if rendered ~= nil and rendered ~= "" then
		io.stdout:write(rendered)
	end

	-- Exit code: 0 iff no error-severity diagnostics AND no driver
	-- failures.
	local has_error = any_driver_error
	if not has_error then
		for _, d in ipairs(all_diagnostics) do
			if d.severity == "error" then
				has_error = true
				break
			end
		end
	end
	return has_error and 1 or 0
end

return M
