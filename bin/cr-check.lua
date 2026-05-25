-- bin/cr-check.lua — delegates to one of three typecheck CLIs.
--
-- Default path is the legacy `lib/type/static/cli.lua`. The v4 driver is
-- opt-in via `--v4` (per docs/typechecker-v4-driver-design.md §7). The
-- parity-testing aid is opt-in via `--compare` (K5b) — it runs both the
-- legacy and v4 pipelines and reports divergence. The default stays
-- legacy until the cutover gate in §10 is satisfied, so pre-commit hooks
-- and existing workflows are unaffected.
local M = {}

function M.main(argv)
	-- Scan argv for the `--v4` / `--v5` / `--compare` flags. We do NOT
	-- strip other unknown flags here; the chosen CLI module owns its own
	-- argv parsing.  `--compare` takes priority if both are present (the
	-- compare driver internally invokes v4).
	local use_v4      = false
	local use_v5      = false
	local use_compare = false
	local forwarded   = {}
	for i = 1, #argv do
		if argv[i] == "--v4" then
			use_v4 = true
		elseif argv[i] == "--v5" then
			use_v5 = true
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

	if use_v5 then
		local v5_cli = require("lib.type.static-v5.cli")
		local code = v5_cli.main(forwarded)
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
