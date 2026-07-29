-- lib/type/v10_kernel/pilot/prover_addr_test.lua
--
-- Smoke tests for prover_addr.lua over the canonical v10 core:
-- deterministic file-id hashing, path/point construction, and the
-- if-statement child-index helpers.

local T = require("lib.test.assert")
local ta = require("lib.type.v10_cleanroom.term_algebra")
local addr_v1 = require("lib.type.v10_kernel.pilot.addr_v1")
local prover_addr = require("lib.type.v10_kernel.pilot.prover_addr")

--: (v: Term | nil, err: string | nil) -> Term
local function must_term(v, err)
	if v == nil then error("unexpected error: " .. tostring(err), 2) end
	return v
end

--: (v: Signature | nil, err: string | nil) -> Signature
local function must_sig(v, err)
	if v == nil then error("unexpected error: " .. tostring(err), 2) end
	return v
end

T.describe("prover_addr", function()
	local addr_sig = must_sig(addr_v1.declare())
	local addr_ops = addr_sig.ops

	T.it("file_id_of_source is deterministic: same source, structurally equal file_id", function()
		local fid1 = must_term(prover_addr.file_id_of_source(addr_ops, "local x = 1\n"))
		local fid2 = must_term(prover_addr.file_id_of_source(addr_ops, "local x = 1\n"))
		T.ok(ta.equal(fid1, fid2))
	end)

	T.it("file_id_of_source differs for different source", function()
		local fid1 = must_term(prover_addr.file_id_of_source(addr_ops, "local x = 1\n"))
		local fid2 = must_term(prover_addr.file_id_of_source(addr_ops, "local x = 2\n"))
		T.eq(ta.equal(fid1, fid2), false)
	end)

	T.it("root/child builds the same path as manual path_root/path_child/nat chaining", function()
		local root = must_term(prover_addr.root(addr_ops))
		local c1 = must_term(prover_addr.child(addr_ops, root, 1))
		local c1_0 = must_term(prover_addr.child(addr_ops, c1, 0))

		local one = must_term(ta.build(addr_ops.succ, { must_term(ta.build(addr_ops.zero, {})) }))
		local zero = must_term(ta.build(addr_ops.zero, {}))
		local manual = must_term(ta.build(addr_ops.path_child, {
			must_term(ta.build(addr_ops.path_child, { must_term(ta.build(addr_ops.path_root, {})), one })), zero,
		}))
		T.ok(ta.equal(c1_0, manual))
	end)

	T.it("entry/exit wrap a path with a file_id, matching addr-v1's own shape", function()
		local fid = must_term(prover_addr.file_id_of_source(addr_ops, "x"))
		local root = must_term(prover_addr.root(addr_ops))
		local e = must_term(prover_addr.entry(addr_ops, fid, root))
		local x = must_term(prover_addr.exit(addr_ops, fid, root))
		T.eq(ta.equal(e, x), false)
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
		local local_stmt_path = must_term(prover_addr.child(addr_ops, must_term(prover_addr.root(addr_ops)), 0))
		local name0 = must_term(prover_addr.local_name_path(addr_ops, local_stmt_path, 0))
		local name1 = must_term(prover_addr.local_name_path(addr_ops, local_stmt_path, 1))
		T.ok(ta.equal(name0, must_term(prover_addr.child(addr_ops, local_stmt_path, 0))))
		T.eq(ta.equal(name0, name1), false)
	end)

	T.it("local_stmt_init_path is injective against the local-stmt's own path and its names: " ..
		"`local f = function(...) ... end` gives the statement, the func-expr, and each declared " ..
		"name three pairwise-distinct paths", function()
		local local_stmt_path = must_term(prover_addr.child(addr_ops, must_term(prover_addr.root(addr_ops)), 0))
		local name0 = must_term(prover_addr.local_name_path(addr_ops, local_stmt_path, 0))
		-- names_len = 1 (single-name local), init_index = 0 (sole init expr)
		local func_expr_path = must_term(prover_addr.local_stmt_init_path(addr_ops, local_stmt_path, 1, 0))
		T.eq(ta.equal(func_expr_path, local_stmt_path), false)
		T.eq(ta.equal(func_expr_path, name0), false)
		T.ok(ta.equal(func_expr_path, must_term(prover_addr.child(addr_ops, local_stmt_path, 1))))
	end)

	T.it("local_stmt_init_path offsets by names_len: a two-name local's init expressions " ..
		"start after both declared names, not at child 0", function()
		local local_stmt_path = must_term(prover_addr.child(addr_ops, must_term(prover_addr.root(addr_ops)), 0))
		local init0 = must_term(prover_addr.local_stmt_init_path(addr_ops, local_stmt_path, 2, 0))
		local init1 = must_term(prover_addr.local_stmt_init_path(addr_ops, local_stmt_path, 2, 1))
		T.ok(ta.equal(init0, must_term(prover_addr.child(addr_ops, local_stmt_path, 2))))
		T.ok(ta.equal(init1, must_term(prover_addr.child(addr_ops, local_stmt_path, 3))))
		T.eq(ta.equal(init0, init1), false)
	end)

	T.it("assign_stmt_init_path is injective against the assign-stmt's own path: " ..
		"`f = function(...) ... end` gives the statement and the func-expr distinct paths", function()
		local assign_stmt_path = must_term(prover_addr.child(addr_ops, must_term(prover_addr.root(addr_ops)), 0))
		local func_expr_path = must_term(prover_addr.assign_stmt_init_path(addr_ops, assign_stmt_path, 0))
		T.eq(ta.equal(func_expr_path, assign_stmt_path), false)
		T.ok(ta.equal(func_expr_path, must_term(prover_addr.child(addr_ops, assign_stmt_path, 0))))
	end)
end)

return {}
