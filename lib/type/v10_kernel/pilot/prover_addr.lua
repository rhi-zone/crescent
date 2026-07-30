-- lib/type/v10_kernel/pilot/prover_addr.lua
--
-- Pilot step 4 (certificate-emitting prover), addressing half:
-- AST-node -> addr-v1 `path`/`point` term construction, over the REAL
-- crescent Lua parser's node shapes (lib/type/static/parse.lua,
-- lib/type/static/defs.lua). The addr-v1 signature itself is unchanged
-- (pilot/addr_v1.lua) — this module only fixes, ONCE, a deterministic
-- mapping from parser node kinds to path_child indices, so every
-- certificate the prover (prover_narrow.lua / prover.lua) emits addresses
-- the same real source location the same way every time. Terms are built
-- via the canonical v10 core (lib/type/v10_cleanroom/term_algebra, per the
-- owner-ratified canon swap) — module-level primitives, no tier instance
-- parameter.
--
-- ── The addressing contract (per-node-kind child-index table) ──────────────
--
-- A path is a child-index chain from the chunk root (`path_root`), built
-- with `path_child(parent, nat(i))`, 0-indexed. `entry_of`/`exit_of` wrap a
-- bare path into a flow point (no separate CFG point sort — see addr-v1's
-- header and docs/typechecker-v10-pilot-signatures-proposal.md §1.1). The
-- table below is EXHAUSTIVE for every node kind this prover touches; a node
-- kind not listed is never assigned a path by this module (the analysis
-- pass simply does not recurse into it — see prover_narrow.lua's scope
-- notes for exactly which statement kinds are walked).
--
--   NODE_CHUNK           child i = the i-th top-level statement (0-based),
--                        in source order (chunk's own body block).
--   NODE_IF_STMT         child 2k     = clause k's test expression (0-based
--                                      clause index; clause 0 is the `if`
--                                      clause itself, clause k>0 is the
--                                      k-th `elseif`)
--                        child 2k+1  = clause k's body block (its own
--                                      statements are children 0..n-1 of
--                                      THIS path, per the "block" rule
--                                      below)
--                        child 2*N   = the `else` block (N = number of
--                                      clauses), IFF FLAG_HAS_ELSE is set;
--                                      absent otherwise.
--                        (This prover extracts a guard from EACH clause of
--                        an if-statement, including elseif chains (N>1) —
--                        see prover_narrow.lua's "Elseif chains" section.
--                        A clause whose own test isn't one of the three
--                        recognized guard shapes still gets a stable,
--                        well-defined path via the indexing above; its
--                        body is merely walked through without extracting
--                        a guard, same as always.)
--   NODE_WHILE_STMT      child 0 = test expression
--                        child 1 = body block
--   NODE_REPEAT_STMT     child 0 = body block
--                        child 1 = until-test expression
--                        (order chosen to match source order: body appears
--                        before the test textually in `repeat ... until`.)
--   NODE_DO_STMT         child 0 = body block
--   NODE_FUNC_DECL       child 0..np-1 = the np declared parameters, in
--                        left-to-right source order (same convention as
--                        NODE_LOCAL_STMT's own name-indexing: bare intern
--                        ids, not AST nodes, so this range addresses
--                        identity only — see `M.func_param_path` below).
--                        child np       = the body block (name is NOT
--                        addressed — out of scope, same as before; see
--                        prover_narrow.lua). Injective: every param index
--                        is < np, and np is never < np, so the body's own
--                        index can never collide with a param's index, nor
--                        can two params collide with each other (distinct
--                        0-based indices). See `M.func_body_index` below —
--                        this generalizes the old fixed `M.FUNC_BODY_INDEX
--                        = 0` constant (removed; np=0, the no-params case,
--                        is now simply `func_body_index(0) = 0`, the same
--                        value as before for that case).
--   NODE_FUNC_EXPR       child 0..np-1 = params (same convention as
--                        NODE_FUNC_DECL above), child np = body block.
--   "a block" (a parser (start,len) statement-list belonging to one of the
--   owner slots above) is NOT its own addressable node distinct from its
--   owner slot's child index — the block's OWN statements are numbered as
--   children 0..len-1 of the SAME path that denotes the block slot itself
--   (e.g. an if-clause's body block is child index `2k+1` of the if-stmt;
--   that body's OWN first statement is child 0 of path_child(if_path,2k+1),
--   its second statement child 1 of the same, etc).
--   NODE_LOCAL_STMT      child 0..nl-1 = the nl declared names, in
--                        left-to-right source order (used ONLY to build a
--                        variable's declaration-site identity path — see
--                        `M.local_name_path` below; the names themselves
--                        are bare intern ids, not AST nodes, so this range
--                        addresses identity only, not a sub-term).
--                        child nl+j   = the j-th init expression (0-based,
--                        j in 0..el-1), in left-to-right source order,
--                        immediately following the name range (source
--                        order: names precede `=` precede init
--                        expressions — same source-order rationale as
--                        NODE_REPEAT_STMT's body/test ordering above). See
--                        `M.local_stmt_init_path` below.
--   NODE_ASSIGN_STMT     targets (`data[0]`/`data[1]`, AST nodes — unlike
--                        NODE_LOCAL_STMT's bare-intern-id names) are NOT
--                        addressed — out of scope, same convention as
--                        NODE_FUNC_DECL's params below: an unaddressed
--                        slot reserves no index, and nothing in this
--                        prover cites a path to an assignment target
--                        itself. child j = the j-th RHS expression
--                        (0-based, j in 0..el-1), in left-to-right source
--                        order — since targets consume no slots, RHS
--                        expressions start at child 0 directly. See
--                        `M.assign_stmt_init_path` below.
--   A func-expr that is the SOLE init expression of a single-name
--   NODE_LOCAL_STMT (`local f = function(...) ... end`) or a single-target
--   NODE_ASSIGN_STMT (`f = function(...) ... end`) — crescent's dominant
--   function-defining style — is addressed like any other init
--   expression: its path is the owning statement's
--   `M.local_stmt_init_path`/`M.assign_stmt_init_path` child (the
--   init-expression slot), NEVER the statement's own path — the func-expr
--   is a distinct AST node from its owning statement and MUST get a
--   distinct path (injectivity: no two distinct AST nodes may share one
--   path). NODE_FUNC_EXPR's own "child 0 = body block" rule then applies
--   to THIS path, exactly as it would for a func-expr reached any other
--   way. `function name(...) ... end` (NODE_FUNC_DECL) needs no such
--   indirection: it IS the statement, its own path is the statement's
--   path directly.
--
-- ── Addressing convention: assign-transfer's `Pa` (Phase 3 addition) ────────
--
-- docs/typechecker-v10-fixpoint-proposal.md §2.1 describes
-- `assign_literal`/`assign_copies`'s schematic `assign_point` argument
-- (`Pa`) as `exit_of(rhs_expr_path)` — exit of the specific init/RHS
-- expression, mirroring a guard's own `exit_of(test_expr_path)` choice.
-- That text is UNCHANGED (it is the theory's own documented reading of its
-- schematic `Pa`, still valid as written). What is added HERE is a
-- PROVER-SIDE CONVENTION (pilot territory, analogous to §4.1's already-
-- documented "`exit_of` of a block's own path" reading — not a kernel or
-- addressing-signature change): for a `NODE_LOCAL_STMT`/`NODE_ASSIGN_STMT`
-- whose sole RHS is a literal or bare-identifier copy (the only two shapes
-- `assign_literal`/`assign_copies` ever transfer), the PROVER binds the
-- concrete `Pa` term it cites to `exit_of(the owning statement's OWN
-- path)` — i.e. `M.exit(addr_ops, file_id, stmt_path)`, using
-- `local_stmt_path`/`assign_stmt_path` directly (child indices for names/
-- targets and the RHS notwithstanding) — NOT `exit_of(the RHS expression's
-- own child path)`. Nothing else happens in either statement kind after
-- evaluating that RHS (there is no further sub-expression, no additional
-- target-list side effect once a single value has been read), so the two
-- readings denote the SAME real control-flow instant; the prover picks the
-- statement's own path as the one concrete term because `stmt_seq`/
-- `stmt_preserves` (docs/typechecker-v10-fixpoint-proposal.md §8.3) also
-- relate `exit_of(stmt_i's own path)` to `exit_of(stmt_{i+1}'s own path)`
-- — whole-statement paths, never an RHS sub-path — and `seq-persist`/
-- `assign-*-transfer` citations must share the LITERALLY same point term
-- for "the fact right after this statement" wherever both apply to the
-- same statement in one certificate (shared metavariables require
-- structural equality, not merely denotational coincidence). This
-- convention is exercised by `lib/type/v10_kernel/pilot/fixpoint_prover.lua`
-- (pilot step 4, loop-invariant derivation); it does not change
-- `fixpoint_v1.lua`'s axiom/rule declarations, which still take an
-- arbitrary schematic `Pa`.
--
-- `file_id` comes from a content hash of the file's source text
-- (lib/type/static/sha256.lua's `hash`, reused rather than reimplemented)
-- encoded as an addr-v1 bitstring: each of the 64 hex digits of the
-- SHA-256 hex digest becomes 4 bits (MSB-first per digit), consed
-- left-to-right so the resulting `bs_cons` chain's head is the digest's
-- first hex digit's high bit and the tail is `bs_nil` — a purely
-- deterministic, structural encoding with no string payload anywhere in
-- the resulting term (per addr-v1's own design constraint).

local ta = require("lib.type.v10_cleanroom.term_algebra")
local sha256 = require("lib.type.static.sha256")

local M = {}

--:: AddrOps = { [string]: OpDecl }
--:: Path = Term

local HEX_BITS = {
	["0"] = { 0, 0, 0, 0 }, ["1"] = { 0, 0, 0, 1 }, ["2"] = { 0, 0, 1, 0 }, ["3"] = { 0, 0, 1, 1 },
	["4"] = { 0, 1, 0, 0 }, ["5"] = { 0, 1, 0, 1 }, ["6"] = { 0, 1, 1, 0 }, ["7"] = { 0, 1, 1, 1 },
	["8"] = { 1, 0, 0, 0 }, ["9"] = { 1, 0, 0, 1 }, ["a"] = { 1, 0, 1, 0 }, ["b"] = { 1, 0, 1, 1 },
	["c"] = { 1, 1, 0, 0 }, ["d"] = { 1, 1, 0, 1 }, ["e"] = { 1, 1, 1, 0 }, ["f"] = { 1, 1, 1, 1 },
} --[[: { [string]: integer[] } ]]

-- Build a `file_id` term from the SHA-256 hash of `source`, over the given
-- addr-v1 operator table. Caps-clean: `addr_ops` is injected, the source
-- text is a parameter (no ambient io — the caller reads the file).
--: (addr_ops: AddrOps, source: string) -> (Term | nil, string | nil)
function M.file_id_of_source(addr_ops, source)
	local hex = sha256.hash(source)
	local b0, err0 = ta.build(addr_ops.b0, {})
	local b1, err1 = ta.build(addr_ops.b1, {})
	if not b0 then return nil, err0 end
	if not b1 then return nil, err1 end
	local acc, aerr = ta.build(addr_ops.bs_nil, {})
	if not acc then return nil, aerr end
	for i = #hex, 1, -1 do
		local c = hex:sub(i, i)
		local bits = HEX_BITS[c]
		if not bits then return nil, "file_id_of_source: unexpected hex digit " .. tostring(c) end
		for j = 4, 1, -1 do
			local bit_term = (bits[j] == 1) and b1 or b0
			local next_acc, cerr = ta.build(addr_ops.bs_cons, { bit_term, acc })
			if not next_acc then return nil, cerr end
			acc = next_acc
		end
	end
	return ta.build(addr_ops.file_id_of, { acc })
end

-- Build a peano `nat` term for a non-negative integer child index.
--: (addr_ops: AddrOps, n: integer) -> (Term | nil, string | nil)
function M.nat(addr_ops, n)
	local acc, err = ta.build(addr_ops.zero, {})
	if not acc then return nil, err end
	for _ = 1, n do
		local next_acc, cerr = ta.build(addr_ops.succ, { acc })
		if not next_acc then return nil, cerr end
		acc = next_acc
	end
	return acc
end

--: (addr_ops: AddrOps) -> (Path | nil, string | nil)
function M.root(addr_ops)
	return ta.build(addr_ops.path_root, {})
end

-- Descend one child index from `parent`.
--: (addr_ops: AddrOps, parent: Path, index: integer) -> (Path | nil, string | nil)
function M.child(addr_ops, parent, index)
	local idx_term, ierr = M.nat(addr_ops, index)
	if not idx_term then return nil, ierr end
	return ta.build(addr_ops.path_child, { parent, idx_term })
end

--: (addr_ops: AddrOps, file_id: Term, path: Path) -> (Term | nil, string | nil)
function M.entry(addr_ops, file_id, path)
	return ta.build(addr_ops.entry_of, { file_id, path })
end

--: (addr_ops: AddrOps, file_id: Term, path: Path) -> (Term | nil, string | nil)
function M.exit(addr_ops, file_id, path)
	return ta.build(addr_ops.exit_of, { file_id, path })
end

-- ── If-statement child indices (see header table) ───────────────────────────

--: (clause_index: integer) -> integer
function M.if_clause_test_index(clause_index) return 2 * clause_index end
--: (clause_index: integer) -> integer
function M.if_clause_body_index(clause_index) return 2 * clause_index + 1 end
--: (num_clauses: integer) -> integer
function M.if_else_index(num_clauses) return 2 * num_clauses end

-- ── While/repeat/do/func child indices (see header table) ───────────────────

M.WHILE_TEST_INDEX = 0
M.WHILE_BODY_INDEX = 1
M.REPEAT_BODY_INDEX = 0
M.REPEAT_TEST_INDEX = 1
M.DO_BODY_INDEX = 0

-- A function's body-block child index: `num_params` (params occupy children
-- 0..num_params-1, per the header table; the body immediately follows,
-- exactly like `if_else_index` follows the last if-clause). Generalizes the
-- old fixed `M.FUNC_BODY_INDEX = 0` constant (removed): `func_body_index(0)
-- == 0`, the same value the old constant held for the (previously only
-- supported) no-params case.
--: (num_params: integer) -> integer
function M.func_body_index(num_params) return num_params end

-- A local variable's declaration-site identity path: child `name_index`
-- (0-based, left-to-right) of the NODE_LOCAL_STMT's own path.
--: (addr_ops: AddrOps, local_stmt_path: Path, name_index: integer) -> (Path | nil, string | nil)
function M.local_name_path(addr_ops, local_stmt_path, name_index)
	return M.child(addr_ops, local_stmt_path, name_index)
end

-- A function parameter's declaration-site identity path: child `param_index`
-- (0-based, left-to-right) of the NODE_FUNC_DECL/NODE_FUNC_EXPR's own path
-- (see header table). Structurally identical construction to
-- `M.local_name_path` (both are just `M.child` at a variable index) but
-- kept as a separate named helper — same discipline as `local_name_path`
-- vs `local_stmt_init_path` above being distinct helpers despite similar
-- shapes — because the two address conceptually distinct slots (a
-- function's own parameter list vs a local statement's declared names) and
-- callers (prover.lua's pass 2) must be able to tell which addressing rule
-- applies to a given tracked variable (see prover_narrow.lua's `ScopeVar`
-- `kind` field). Injective against a same-function body path per
-- `M.func_body_index`'s own argument above.
--: (addr_ops: AddrOps, func_path: Path, param_index: integer) -> (Path | nil, string | nil)
function M.func_param_path(addr_ops, func_path, param_index)
	return M.child(addr_ops, func_path, param_index)
end

-- A local statement's j-th init expression (0-based, left-to-right): child
-- `names_len + init_index` of the NODE_LOCAL_STMT's own path (see header
-- table) — the names occupy children 0..names_len-1, so init expressions
-- follow immediately after. Distinct from `local_name_path`'s indices for
-- any names_len > 0, keeping every init expression's path distinct from
-- every name's identity path AND from the statement's own path (child
-- indices are never negative, and names_len+init_index >= names_len for
-- all init_index >= 0, so this range never overlaps 0..names_len-1).
--: (addr_ops: AddrOps, local_stmt_path: Path, names_len: integer, init_index: integer) -> (Path | nil, string | nil)
function M.local_stmt_init_path(addr_ops, local_stmt_path, names_len, init_index)
	return M.child(addr_ops, local_stmt_path, names_len + init_index)
end

-- An assign statement's j-th RHS expression (0-based, left-to-right):
-- child `init_index` of the NODE_ASSIGN_STMT's own path (see header
-- table). Targets are NOT addressed by this module (out of scope), so RHS
-- expressions occupy children 0..el-1 directly, with no offset.
--: (addr_ops: AddrOps, assign_stmt_path: Path, init_index: integer) -> (Path | nil, string | nil)
function M.assign_stmt_init_path(addr_ops, assign_stmt_path, init_index)
	return M.child(addr_ops, assign_stmt_path, init_index)
end

return M
