-- bin/cr-check.lua — delegates to either the legacy or v4 typecheck CLI.
--
-- Default path is the legacy `lib/type/static/cli.lua`. The v4 driver is
-- opt-in via `--v4` (per docs/typechecker-v4-driver-design.md §7 — the
-- default stays legacy until the cutover gate in §10 is satisfied, so
-- pre-commit hooks and existing workflows are unaffected).
local M = {}

function M.main(argv)
	-- Scan argv for the `--v4` flag. We do NOT strip other unknown
	-- flags here; the chosen CLI module owns its own argv parsing.
	local use_v4 = false
	local forwarded = {}
	for i = 1, #argv do
		if argv[i] == "--v4" then
			use_v4 = true
			-- Drop the marker — the v4 CLI tolerates it but doesn't need it.
		else
			forwarded[#forwarded + 1] = argv[i]
		end
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
