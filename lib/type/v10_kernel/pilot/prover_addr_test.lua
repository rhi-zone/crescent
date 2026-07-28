-- lib/type/v10_kernel/pilot/prover_addr_test.lua
--
-- Smoke tests for prover_addr.lua: deterministic file-id hashing, path/point
-- construction, and the if-statement child-index helpers.

local T = require("lib.test.assert")
local term_algebra = require("lib.type.v10_kernel.term_algebra")
local addr_v1 = require("lib.type.v10_kernel.pilot.addr_v1")
local prover_addr = require("lib.type.v10_kernel.pilot.prover_addr")

local TIERS = { "reference", "fast" }

for _, tier in ipairs(TIERS) do
	T.describe("prover_addr (" .. tier .. " tier)", function()
		local k = term_algebra.new({ tier = tier })
		local addr_sig = addr_v1.declare()
		local addr_ops = addr_sig.ops

		T.it("file_id_of_source is deterministic: same source, structurally equal file_id", function()
			local fid1 = prover_addr.file_id_of_source(k, addr_ops, "local x = 1\n")
			local fid2 = prover_addr.file_id_of_source(k, addr_ops, "local x = 1\n")
			T.ok(fid1)
			T.ok(fid2)
			T.ok(k.equal(fid1, fid2))
		end)

		T.it("file_id_of_source differs for different source", function()
			local fid1 = prover_addr.file_id_of_source(k, addr_ops, "local x = 1\n")
			local fid2 = prover_addr.file_id_of_source(k, addr_ops, "local x = 2\n")
			T.ok(fid1)
			T.ok(fid2)
			T.eq(k.equal(fid1, fid2), false)
		end)

		T.it("root/child builds the same path as manual path_root/path_child/nat chaining", function()
			local root = prover_addr.root(k, addr_ops)
			local c1 = prover_addr.child(k, addr_ops, root, 1)
			local c1_0 = prover_addr.child(k, addr_ops, c1, 0)

			local one = k.build(addr_ops.succ, { k.build(addr_ops.zero, {}) })
			local zero = k.build(addr_ops.zero, {})
			local manual = k.build(addr_ops.path_child, {
				k.build(addr_ops.path_child, { k.build(addr_ops.path_root, {}), one }), zero,
			})
			T.ok(k.equal(c1_0, manual))
		end)

		T.it("entry/exit wrap a path with a file_id, matching addr-v1's own shape", function()
			local fid = prover_addr.file_id_of_source(k, addr_ops, "x")
			local root = prover_addr.root(k, addr_ops)
			local e = prover_addr.entry(k, addr_ops, fid, root)
			local x = prover_addr.exit(k, addr_ops, fid, root)
			T.ok(e)
			T.ok(x)
			T.eq(k.equal(e, x), false)
		end)

		T.it("if-statement child-index helpers match the documented table", function()
			T.eq(prover_addr.if_clause_test_index(0), 0)
			T.eq(prover_addr.if_clause_body_index(0), 1)
			T.eq(prover_addr.if_clause_test_index(1), 2)
			T.eq(prover_addr.if_clause_body_index(1), 3)
			T.eq(prover_addr.if_else_index(1), 2)
			T.eq(prover_addr.if_else_index(2), 4)
		end)

		T.it("local_name_path addresses the k-th declared name as a child of the local-stmt path", function()
			local local_stmt_path = prover_addr.child(k, addr_ops, prover_addr.root(k, addr_ops), 0)
			local name0 = prover_addr.local_name_path(k, addr_ops, local_stmt_path, 0)
			local name1 = prover_addr.local_name_path(k, addr_ops, local_stmt_path, 1)
			T.ok(k.equal(name0, prover_addr.child(k, addr_ops, local_stmt_path, 0)))
			T.eq(k.equal(name0, name1), false)
		end)
	end)
end

return {}
