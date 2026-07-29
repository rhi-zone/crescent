-- lib/type/v10_kernel/pilot/addr_v1_test.lua
--
-- addr-v1's own smoke tests over the canonical v10 core: declares cleanly,
-- and builds the proposal's own worked example
-- (docs/typechecker-v10-pilot-signatures-proposal.md §1.2) — a path into a
-- file, wrapped in file_id_of over a short bitstring, then
-- entry_of/exit_of.

local T = require("lib.test.assert")
local ta = require("lib.type.v10_cleanroom.term_algebra")
local addr_v1 = require("lib.type.v10_kernel.pilot.addr_v1")

--: (v: Term | nil, err: string | nil) -> Term
local function must_term(v, err)
	if v == nil then error("unexpected error: " .. tostring(err), 2) end
	return v
end

T.describe("addr-v1", function()
	T.it("declares with no errors", function()
		local sig, err = addr_v1.declare()
		T.ok(sig, err)
		if sig == nil then return end
		T.eq(sig.name, "addr-v1")
		T.eq(sig.version, 1)
	end)

	T.it("builds the proposal's worked example: a path/file/point term", function()
		local sig = addr_v1.declare()
		T.ok(sig)
		if sig == nil then return end
		local ops = sig.ops

		-- child 1, then child 0 of the chunk root
		local one = must_term(ta.build(ops.succ, { must_term(ta.build(ops.zero, {})) }))
		local zero = must_term(ta.build(ops.zero, {}))
		local path = must_term(ta.build(ops.path_child, {
			must_term(ta.build(ops.path_child, { must_term(ta.build(ops.path_root, {})), one })), zero,
		}))
		T.ok(path)

		-- a short bitstring: [b1, b0] -> file_id
		local bits = must_term(ta.build(ops.bs_cons, {
			must_term(ta.build(ops.b1, {})),
			must_term(ta.build(ops.bs_cons, { must_term(ta.build(ops.b0, {})), must_term(ta.build(ops.bs_nil, {})) })),
		}))
		local fid = must_term(ta.build(ops.file_id_of, { bits }))

		local entry = must_term(ta.build(ops.entry_of, { fid, path }))
		local exit = must_term(ta.build(ops.exit_of, { fid, path }))
		T.eq(ta.sort_of(entry), sig.sorts.point)
		T.eq(ta.sort_of(exit), sig.sorts.point)
		T.fail(ta.equal(entry, exit))
	end)
end)

return {}
