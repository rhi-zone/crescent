-- Tests for lib/type/v10_toy — EXPERIMENT, not canon. See README.md.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")

-- TYPECHECKER WORKAROUND: same require-typing gap as w.lua (see its matching
-- comment + TODO.md) — `require(...)`'s result types `unknown`; narrow once
-- via `type() == "table"` then a single checked cast recovers real types.
--:: Term = { tag: "var", index: integer, sort: string } | { tag: "op", op: string, args: Term[] } | { tag: "meta", name: string, sort: string }
--:: Sig = unknown
--:: Env = { [string]: Term }
--:: CoreModule = { var: (integer, string) -> Term, op: (string, Term[]) -> Term, meta: (string, string) -> Term, deep_eq: (Term, Term) -> boolean, sort_of: (Term, Sig) -> string | nil, match: (Term, Term, Sig, Env) -> Env | (nil, string), replay: (unknown, Sig, unknown) -> (Term, { [string]: boolean }) | (nil, string), has_free_vars: (Term, Sig) -> boolean }
local C_raw = require("lib.type.v10_toy")
if type(C_raw) ~= "table" then error("lib.type.v10_toy failed to load") end
local C = C_raw --[[: CoreModule ]]

local W_raw = require("lib.type.v10_toy.w")
if type(W_raw) ~= "table" then error("lib.type.v10_toy.w failed to load") end
--:: WModule = { sig: Sig, rules: unknown, infer: (unknown) -> (unknown, Term) | (nil, string) }
local W = W_raw --[[: WModule ]]

local var, op, meta, deep_eq = C.var, C.op, C.meta, C.deep_eq

--: (term: Term, ty: Term) -> Term
local function typeof(term, ty) return op("typeof", { term, ty }) end

-- replay(node, ...) requires `node` narrowed to a bare `table` first — see
-- the recursive-union-Node comment in init.lua/w.lua: a checker gap makes
-- ANY specifically-shaped value (annotated OR literal-inferred) other than
-- Node's first declared arm fail assignability, but a value with no MORE
-- specific inferred shape than `table` passes through fine regardless of
-- which arm it actually is at runtime. This tiny wrapper is the single
-- narrowing point every test below goes through instead of repeating it.
--: (node: unknown, sig: Sig, rules: unknown) -> (Term, { [string]: boolean }) | (nil, string)
local function replay(node, sig, rules)
	if type(node) ~= "table" then return nil, "node is not a table" end
	return C.replay(node, sig, rules)
end

-- ── W inference round trips ───────────────────────────────────────────────────

T.describe("Algorithm W -> replay: literal", function()
	T.it("lit_int replays to an accepted root of type int", function()
		local node, ty = W.infer({ k = "int" })
		T.ok(node)
		local concl, taint = replay(node, W.sig, W.rules)
		T.ok(concl, taint)
		if type(concl) == "table" then T.ok(deep_eq(concl, typeof(op("lit_int", {}), op("int", {})))) end
		if type(ty) == "table" then T.ok(deep_eq(ty, op("int", {}))) end
	end)
end)

T.describe("Algorithm W -> replay: monomorphic application", function()
	T.it("(fn x -> x) applied to a literal infers and replays to int", function()
		local ast = {
			k = "app",
			fn = { k = "abs", body = { k = "var", i = 0 } },
			arg = { k = "int" },
		}
		local node, ty = W.infer(ast)
		T.ok(node, ty)
		if type(ty) == "table" then T.ok(deep_eq(ty, op("int", {}))) end
		local concl, taint = replay(node, W.sig, W.rules)
		T.ok(concl, taint)
		T.ok(type(taint) == "table" and taint["LitIntType@v1"], "taint should include LitIntType@v1")
	end)
end)

T.describe("Algorithm W -> replay: let-polymorphism", function()
	-- let id = fn x -> x in pair(id 3, id true) : prod(int, bool)
	local ast = {
		k = "let",
		generalize = true,
		e = { k = "abs", body = { k = "var", i = 0 } },
		body = {
			k = "pair",
			a = { k = "app", fn = { k = "var", i = 0 }, arg = { k = "int" } },
			b = { k = "app", fn = { k = "var", i = 0 }, arg = { k = "bool" } },
		},
	}

	T.it("infers prod(int, bool): id used at two distinct types", function()
		local node, ty = W.infer(ast)
		T.ok(node, ty)
		if type(ty) == "table" then T.ok(deep_eq(ty, op("prod", { op("int", {}), op("bool", {}) }))) end
	end)

	T.it("replays to an accepted root with both literal axioms in taint", function()
		local node = W.infer(ast)
		local concl, taint = replay(node, W.sig, W.rules)
		T.ok(concl, taint)
		if type(concl) == "table" then T.ok(C.sort_of(concl, W.sig) == "judgment") end
		T.ok(type(taint) == "table" and taint["LitIntType@v1"], "taint should include LitIntType@v1")
		T.ok(type(taint) == "table" and taint["LitBoolType@v1"], "taint should include LitBoolType@v1")
	end)
end)

-- ── tamper test ────────────────────────────────────────────────────────────────

T.describe("tamper: corrupted certificate is rejected", function()
	T.it("wrong rule cited on a node is rejected by replay", function()
		local node = W.infer({
			k = "app",
			fn = { k = "abs", body = { k = "var", i = 0 } },
			arg = { k = "int" },
		})
		T.ok(node)
		-- Corrupt: cite AppType's argument node with the wrong rule name.
		if type(node) == "table" then
			local premises = node.premises
			if type(premises) == "table" then
				local arg_node = premises[2]
				if type(arg_node) == "table" then
					arg_node.rule = "LitBoolType"
				end
			end
		end
		local concl, err = replay(node, W.sig, W.rules)
		T.eq(concl, nil)
		T.ok(err, "expected an error message")
	end)

	T.it("altered premise (wrong bound type) is rejected by replay", function()
		local node = W.infer({
			k = "app",
			fn = { k = "abs", body = { k = "var", i = 0 } },
			arg = { k = "int" },
		})
		-- Corrupt: the abstraction's discharged hypothesis now claims bool
		-- where the body actually assumed int — AbsType's discharge match
		-- must fail since the hyp's own judgment doesn't change to match.
		if type(node) == "table" then
			local premises = node.premises
			if type(premises) == "table" then
				local fn_node = premises[1]
				if type(fn_node) == "table" then
					local discharge = fn_node.discharge
					if type(discharge) == "table" then
						local slot1 = discharge[1]
						if type(slot1) == "table" then
							local hyp = slot1[1]
							if type(hyp) == "table" then
								hyp.judgment = typeof(var(0, "term"), op("bool", {}))
							end
						end
					end
				end
			end
		end
		local concl, err = replay(node, W.sig, W.rules)
		T.eq(concl, nil)
		T.ok(err, "expected an error message")
	end)
end)

-- ── taint test ─────────────────────────────────────────────────────────────────

T.describe("taint propagation", function()
	T.it("an axiom-free derivation reports empty taint", function()
		-- typeof(abs(var 0), arrow(int, int)), proved purely from a self-
		-- discharged hypothesis — no axiom is ever cited.
		local hyp = { kind = "hyp", judgment = typeof(var(0, "term"), op("int", {})) }
		local root = {
			kind = "rule", rule = "AbsType",
			premises = { hyp },
			discharge = { [1] = { hyp } },
		}
		local concl, taint = replay(root, W.sig, W.rules)
		T.ok(concl, taint)
		if type(concl) == "table" then
			T.ok(deep_eq(concl, typeof(op("abs", { var(0, "term") }), op("arrow", { op("int", {}), op("int", {}) }))))
		end
		local n = 0
		if type(taint) == "table" then
			for _ in pairs(taint) do n = n + 1 end
		end
		T.eq(n, 0, "axiom-free derivation should have empty taint")
	end)

	T.it("an axiom-using derivation reports the axiom in its taint", function()
		local node = W.infer({ k = "int" })
		local _, taint = replay(node, W.sig, W.rules)
		T.ok(type(taint) == "table" and taint["LitIntType@v1"])
	end)
end)

-- ── discharge test ─────────────────────────────────────────────────────────────

T.describe("discharge", function()
	T.it("undischarged hypothesis is rejected at the root", function()
		-- LetType's conclusion pattern doesn't need discharge to supply
		-- anything (unlike AbsType's T1) — Body's var(0) is structurally
		-- bound by let_'s own binder either way, so omitting discharge here
		-- isolates the open-hypothesis check from the free-variable check.
		local hyp = { kind = "hyp", judgment = typeof(var(0, "term"), op("int", {})) }
		local e_node = { kind = "axiom", rule = "LitIntType" }
		local root = { kind = "rule", rule = "LetType", premises = { e_node, hyp } }
		local concl, err = replay(root, W.sig, W.rules)
		T.eq(concl, nil)
		T.ok(type(err) == "string" and (err:find("open") or err:find("undischarged")), "expected an open-hypothesis rejection, got: " .. tostring(err))
	end)

	T.it("properly discharged hypothesis is accepted", function()
		local node = W.infer({
			k = "app",
			fn = { k = "abs", body = { k = "var", i = 0 } },
			arg = { k = "int" },
		})
		local concl = replay(node, W.sig, W.rules)
		T.ok(concl)
	end)

	T.it("shared-hypothesis DAG: one parent discharges, another does not", function()
		local hyp = { kind = "hyp", judgment = typeof(var(0, "term"), op("int", {})) }

		-- Parent A: AbsType discharges hyp — should be accepted.
		local parent_a = {
			kind = "rule", rule = "AbsType",
			premises = { hyp },
			discharge = { [1] = { hyp } },
		}
		local concl_a, err_a = replay(parent_a, W.sig, W.rules)
		T.ok(concl_a, err_a)

		-- Parent B: cites the SAME hyp node as a bare root without ever
		-- discharging it — must be rejected, and must be rejected
		-- independently of parent A's successful discharge (no shared
		-- mutable state on the hyp node itself).
		local concl_b, err_b = replay(hyp, W.sig, W.rules)
		T.eq(concl_b, nil)
		T.ok(err_b)

		-- Replaying parent A again afterward still succeeds — B's rejection
		-- did not retroactively corrupt anything.
		local concl_a2, err_a2 = replay(parent_a, W.sig, W.rules)
		T.ok(concl_a2, err_a2)
		if type(concl_a) == "table" and type(concl_a2) == "table" then
			T.ok(deep_eq(concl_a, concl_a2))
		end
	end)
end)

-- ── core kernel unit tests (match / instantiate / sorts) ────────────────────────

T.describe("core: sort_of", function()
	T.it("var and meta report their stored sort", function()
		T.eq(C.sort_of(var(0, "term"), W.sig), "term")
		T.eq(C.sort_of(meta("X", "type"), W.sig), "type")
	end)
	T.it("op reports the signature's declared result sort", function()
		T.eq(C.sort_of(op("int", {}), W.sig), "type")
		T.eq(C.sort_of(op("lit_int", {}), W.sig), "term")
	end)
end)

T.describe("core: match consistency", function()
	T.it("same metavariable twice must bind equal subterms", function()
		local pat = op("arrow", { meta("M", "type"), meta("M", "type") })
		local env, err = C.match(pat, op("arrow", { op("int", {}), op("int", {}) }), W.sig, {})
		T.ok(env, err)
		local env2, err2 = C.match(pat, op("arrow", { op("int", {}), op("bool", {}) }), W.sig, {})
		T.eq(env2, nil)
		T.ok(err2)
	end)
end)

T.describe("core: has_free_vars is binder-depth aware", function()
	T.it("a variable bound by an enclosing operator is not free", function()
		T.ok(not C.has_free_vars(op("abs", { var(0, "term") }), W.sig))
	end)
	T.it("a variable not covered by any enclosing binder is free", function()
		T.ok(C.has_free_vars(var(0, "term"), W.sig))
		T.ok(C.has_free_vars(op("app", { var(0, "term"), op("lit_int", {}) }), W.sig))
	end)
end)
