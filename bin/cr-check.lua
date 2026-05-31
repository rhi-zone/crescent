-- bin/cr-check.lua — delegates to one of several typecheck CLIs.
--
-- Default path is the legacy `lib/type/static/cli.lua`. The v4 driver is
-- opt-in via `--v4` (per docs/typechecker-v4-driver-design.md §7). v5/v6 are
-- opt-in via `--v5` / `--v6` while they are under active development. The
-- parity-testing aid is opt-in via `--compare` (K5b) — it runs both the
-- legacy and v4 pipelines and reports divergence. The default stays
-- legacy until the cutover gate in §10 is satisfied, so pre-commit hooks
-- and existing workflows are unaffected.
local M = {}

function M.main(argv)
	-- Scan argv for the `--v4` / `--v5` / `--v6` / `--compare` flags. We do NOT
	-- strip other unknown flags here; the chosen CLI module owns its own
	-- argv parsing.  `--compare` takes priority if both are present (the
	-- compare driver internally invokes v4).
	local use_v4      = false
	local use_v5      = false
	local use_v6      = false
	local use_compare = false
	local forwarded   = {}
	for i = 1, #argv do
		if argv[i] == "--v4" then
			use_v4 = true
		elseif argv[i] == "--v5" then
			use_v5 = true
		elseif argv[i] == "--v6" then
			use_v6 = true
		elseif argv[i] == "--compare" then
			use_compare = true
		else
			forwarded[#forwarded + 1] = argv[i]
		end
	end

	if use_compare then
		local compare_cli = require("lib.type.static-v4.cli_compare")
		local code = compare_cli.main(forwarded)
		if type(code) == "number" and code ~= 0 then
			os.exit(math.floor(code))
		end
		return
	end

	if use_v6 then
		local v6_cli = require("lib.type.static-v6.cli")
		-- Construct real I/O caps here — global io.*/os.* permitted only in
		-- top-level entry scripts.  lib/ code receives caps as parameters.
		--: V6CliCaps
		local caps = {
			--: (string) -> (string | nil, string | nil)
			read_file = function(path)
				local f, oerr = io.open(path, "rb")
				if f == nil then return nil, tostring(oerr) end
				local bytes = f:read("*a")
				f:close()
				if bytes == nil then return nil, "read failed: " .. path end
				return bytes, nil
			end,
			--: (string) -> nil
			write_out = function(msg) io.stdout:write(msg) end,
			--: (string) -> nil
			write_err = function(msg) io.stderr:write(msg) end,
			--: (unknown) -> boolean
			is_tty = function(_fd)
				if os.getenv("NO_COLOR") ~= nil then return false end
				if os.getenv("FORCE_COLOR") ~= nil then return true end
				return false
			end,
		}
		local code = v6_cli.run(forwarded, caps)
		if type(code) == "number" and code ~= 0 then
			os.exit(math.floor(code))
		end
		return
	end

	if use_v5 then
		local v5_cli = require("lib.type.static-v5.cli")
		-- Construct real I/O caps here — global io.*/os.* permitted only in
		-- top-level entry scripts.  lib/ code receives caps as parameters.
		--: V5CliCaps
		local caps = {
			--: (string) -> (string | nil, string | nil)
			read_file = function(path)
				local f, oerr = io.open(path, "rb")
				if f == nil then return nil, tostring(oerr) end
				local bytes = f:read("*a")
				f:close()
				if bytes == nil then return nil, "read failed: " .. path end
				return bytes, nil
			end,
			--: (string) -> nil
			write_out = function(msg) io.stdout:write(msg) end,
			--: (string) -> nil
			write_err = function(msg) io.stderr:write(msg) end,
			--: (unknown) -> boolean
			is_tty = function(_fd)
				-- Best-effort TTY detection: check standard environment variables.
				-- Plain (no color) by default so piped/test capture remains stable;
				-- respects FORCE_COLOR/NO_COLOR.
				if os.getenv("NO_COLOR") ~= nil then return false end
				if os.getenv("FORCE_COLOR") ~= nil then return true end
				return false
			end,
		}
		local code = v5_cli.run(forwarded, caps)
		if type(code) == "number" and code ~= 0 then
			os.exit(math.floor(code))
		end
		return
	end

	if use_v4 then
		local v4_cli = require("lib.type.static-v4.cli")
		local code = v4_cli.main(forwarded)
		if type(code) == "number" and code ~= 0 then
			os.exit(math.floor(code))
		end
		return
	end
	return require("lib.type.static.cli").main(argv)
end

return M
