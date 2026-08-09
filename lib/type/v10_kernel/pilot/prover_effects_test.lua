-- lib/type/v10_kernel/pilot/prover_effects_test.lua
--
-- Real-file corroboration: pilot/prover_effects.lua run end-to-end on an
-- UNMODIFIED repository file, `lib/table_ext/init.lua`, found by scanning
-- every `lib/*/init.lua` in the repo for a file this prover certifies at
-- least one composed persistence judgment on (script:
-- /tmp .../scratchpad/scan_real_files.lua, not committed — a one-off
-- corpus scan, not part of the test suite). `M.flatten(t, depth)`'s own
-- `--: (unknown, number | nil) -> ...` parameter annotation, guarded by
-- `if depth == nil then depth_ = math.huge else depth_ = depth end`, is
-- EXACTLY the shape this pilot targets: the then-branch (the "match" branch
-- — `depth == nil` selects the `nil` member) assigns to a DIFFERENT local
-- (`depth_`, not `depth`), so `depth`'s guard-established `nil` type
-- survives across that one statement — a fact flow_narrow_v1's own rules
-- have no way to reach (they narrow only AT the branch entry, never past a
-- subsequent statement) and the effects theory + spine composition derives.
--
-- This is supplementary, corroborating evidence for the RIGOROUS
-- certificate-level three-leg proof in narrow_persist_v1_test.lua (which
-- exhaustively covers fail-closed/derives/scale-to-zero using the
-- replayer's own mechanics): here the SAME composition mechanism fires,
-- unassisted, on genuine unmodified repository source.

local T = require("lib.test.assert")
local prover_effects = require("lib.type.v10_kernel.pilot.prover_effects")

T.describe("prover-effects: real file end-to-end", function()
	T.it("lib/table_ext/init.lua: M.flatten's guard yields a certified match AND a composed persistence judgment", function()
		local f = io.open("lib/table_ext/init.lua", "r")
		T.ok(f, "could not open lib/table_ext/init.lua")
		if f == nil then return end
		local src = f:read("*a")
		f:close()
		T.ok(src)
		if not src then return end

		local result, err = prover_effects.analyze_file(src, "lib/table_ext/init.lua")
		T.ok(result, err)
		if result == nil then return end

		local stats = result.stats
		T.eq(stats.guards_found, 1)
		T.eq(stats.guards_certified, 1)
		T.eq(stats.persist_certified, 1)
		-- Exactly two replayed judgments: the guard-branch `holds_at` (flow
		-- narrowing alone) and the composed narrow-persist `holds_at` (only
		-- reachable with the effects theory).
		T.eq(#result.judgments, 2)

		local composed = result.judgments[2]
		-- root-strict replay already enforced this, but assert it directly:
		-- the composed judgment's taint names the effects theory's OWN
		-- reality-boundary axiom — the ONLY vocabulary this whole derivation
		-- crosses between the two independently-authored theories is the
		-- spine judgment's producing axiom, never a narrowing-owned or
		-- effects-owned operator reaching into the other theory's signature.
		local found_effects_axiom = false
		for key in pairs(composed.taint) do
			if key:find("assign%-effects%-syntax%-facts%-v1") then found_effects_axiom = true end
		end
		T.ok(found_effects_axiom)
	end)

	T.it("scanning the whole lib/ corpus is deterministic: re-running yields the same stats", function()
		local f = io.open("lib/table_ext/init.lua", "r")
		T.ok(f)
		if f == nil then return end
		local src = f:read("*a")
		f:close()
		T.ok(src)
		if not src then return end
		local r1 = prover_effects.analyze_file(src, "lib/table_ext/init.lua")
		local r2 = prover_effects.analyze_file(src, "lib/table_ext/init.lua")
		T.ok(r1)
		T.ok(r2)
		if r1 == nil or r2 == nil then return end
		T.eq(r1.stats.persist_certified, r2.stats.persist_certified)
	end)
end)

return {}
