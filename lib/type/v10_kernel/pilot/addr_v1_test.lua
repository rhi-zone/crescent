-- lib/type/v10_kernel/pilot/addr_v1_test.lua
--
-- addr-v1's own smoke tests: declares cleanly, and builds the proposal's
-- own worked example (docs/typechecker-v10-pilot-signatures-proposal.md
-- §1.2) — a path into a file, wrapped in file_id_of over a short
-- bitstring, then entry_of/exit_of.

local T = require("lib.test.assert")
local term_algebra = require("lib.type.v10_kernel.term_algebra")
local addr_v1 = require("lib.type.v10_kernel.pilot.addr_v1")

local TIERS = { "reference", "fast" }

for _, tier in ipairs(TIERS) do
	T.describe("addr-v1 (" .. tier .. " tier)", function()
		local k = term_algebra.new({ tier = tier })

		T.it("declares with no errors", function()
			local sig, err = addr_v1.declare()
			T.ok(sig, err)
			T.eq(sig.name, "addr-v1")
			T.eq(sig.version, 1)
		end)

		T.it("builds the proposal's worked example: a path/file/point term", function()
			local sig = addr_v1.declare()
			local ops = sig.ops

			-- child 1, then child 0 of the chunk root
			local one = k.build(ops.succ, { k.build(ops.zero, {}) })
			local zero = k.build(ops.zero, {})
			T.ok(one)
			T.ok(zero)
			local path = k.build(ops.path_child, { k.build(ops.path_child, { k.build(ops.path_root, {}), one }), zero })
			T.ok(path)

			-- a short bitstring: [b1, b0] -> file_id
			local bits = k.build(ops.bs_cons, { k.build(ops.b1, {}), k.build(ops.bs_cons, { k.build(ops.b0, {}), k.build(ops.bs_nil, {}) }) })
			T.ok(bits)
			local fid = k.build(ops.file_id_of, { bits })
			T.ok(fid)

			local entry = k.build(ops.entry_of, { fid, path })
			local exit = k.build(ops.exit_of, { fid, path })
			T.ok(entry)
			T.ok(exit)
			T.eq(k.sort_of(entry), sig.sorts.point)
			T.eq(k.sort_of(exit), sig.sorts.point)
			T.fail(k.equal(entry, exit))
		end)
	end)
end

return {}
