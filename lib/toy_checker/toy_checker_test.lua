if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

local T = require("lib.test.assert")
local TC = require("lib.toy_checker")
local ir = TC.ir

-- ========================
-- unit tests: Unify / Sub producers directly
-- ========================

T.describe("Unify producer", function()
	T.it("binds an unbound uvar to a concrete type", function()
		local u = ir.mk_uvar()
		local p = TC.new_checker()
		p:submit("Unify", { u, ir.mk_int() }, nil, "test")
		local r = p:run()
		T.eq(r.verdict, "proved")
		T.eq(ir.deref(u).kind, "int")
	end)

	T.it("fails occurs check on a self-referential fn type", function()
		local u = ir.mk_uvar()
		local p = TC.new_checker()
		p:submit("Unify", { u, ir.mk_fn({ u }, ir.mk_int()) }, nil, "test")
		local r = p:run()
		T.eq(r.verdict, "refuted")
		T.ok(r.message:find("occurs check"))
	end)

	T.it("refutes mismatched base types", function()
		local p = TC.new_checker()
		p:submit("Unify", { ir.mk_int(), ir.mk_string() }, nil, "test")
		local r = p:run()
		T.eq(r.verdict, "refuted")
	end)
end)

T.describe("Sub producer", function()
	T.it("int <: number", function()
		local p = TC.new_checker()
		p:submit("Sub", { ir.mk_int(), ir.mk_number() }, nil, "test")
		T.eq(p:run().verdict, "proved")
	end)

	T.it("number is not <: int", function()
		local p = TC.new_checker()
		p:submit("Sub", { ir.mk_number(), ir.mk_int() }, nil, "test")
		T.eq(p:run().verdict, "refuted")
	end)

	T.it("T <: T reflexive for a rigid tyvar", function()
		local p = TC.new_checker()
		p:submit("Sub", { ir.mk_tyvar("T"), ir.mk_tyvar("T") }, nil, "test")
		T.eq(p:run().verdict, "proved")
	end)

	T.it("fn contravariant params / covariant return", function()
		-- (number) -> int  <:  (int) -> number
		local p = TC.new_checker()
		p:submit("Sub", {
			ir.mk_fn({ ir.mk_number() }, ir.mk_int()),
			ir.mk_fn({ ir.mk_int() }, ir.mk_number()),
		}, nil, "test")
		T.eq(p:run().verdict, "proved")
	end)

	T.it("fn subtyping fails when contravariance is violated", function()
		-- (int) -> int  is NOT <: (number) -> int   (param must widen, not narrow)
		local p = TC.new_checker()
		p:submit("Sub", {
			ir.mk_fn({ ir.mk_int() }, ir.mk_int()),
			ir.mk_fn({ ir.mk_number() }, ir.mk_int()),
		}, nil, "test")
		T.eq(p:run().verdict, "refuted")
	end)
end)

-- ========================
-- (a) fizzbuzz-shaped
-- ========================
-- fb(n: int) -> string =
--   if n % 3 == 0 then "fizz" else if n % 5 == 0 then "buzz" else "n"
-- (uses int literal, modulo-like binop, comparison, if/else join, string
-- literal, concat — string builder role played by concat)

T.describe("fizzbuzz-shaped program", function()
	local fb = {
		kind = "fn_lit",
		params = { { name = "n", type = ir.mk_int() } },
		ret = ir.mk_string(),
		body = {
			kind = "if",
			cond = { kind = "binop", op = "eq", left = { kind = "binop", op = "mod", left = { kind = "var", name = "n" }, right = { kind = "lit_int", value = 3 } }, right = { kind = "lit_int", value = 0 } },
			then_ = { kind = "lit_str", value = "fizz" },
			else_ = {
				kind = "if",
				cond = { kind = "binop", op = "eq", left = { kind = "binop", op = "mod", left = { kind = "var", name = "n" }, right = { kind = "lit_int", value = 5 } }, right = { kind = "lit_int", value = 0 } },
				then_ = { kind = "lit_str", value = "buzz" },
				else_ = { kind = "binop", op = "concat", left = { kind = "lit_str", value = "n=" }, right = { kind = "lit_str", value = "?" } },
			},
		},
	}

	T.it("infers fn(int) -> string", function()
		local ty, err = TC.check(fb)
		T.ok(ty, err)
		T.eq(ty.kind, "fn")
		T.eq(ty.params[1].kind, "int")
		T.eq(ty.ret.kind, "string")
	end)
end)

-- ========================
-- (b) CLI-shaped
-- ========================
-- dispatch: <T>(handlers: {[string]: T}, name: string) -> void   (builtin)
-- call dispatch({ run = fn()->void_lit, stop = fn()->void_lit }, "run")

T.describe("CLI-shaped program", function()
	local Tc = ir.mk_tyvar("T")
	local dispatch_scheme = ir.mk_scheme_cell(
		ir.mk_scheme({ "T" }, ir.mk_fn({ ir.mk_map(ir.mk_string(), Tc), ir.mk_string() }, ir.mk_void()))
	)
	local env = { vars = { dispatch = dispatch_scheme }, parent = nil }

	local handler = { kind = "fn_lit", params = {}, ret = nil, body = { kind = "lit_unit" } }
	local prog = {
		kind = "call",
		fn = { kind = "var", name = "dispatch" },
		args = {
			{
				kind = "map_lit",
				entries = {
					{ key = { kind = "lit_str", value = "run" }, value = handler },
					{ key = { kind = "lit_str", value = "stop" }, value = handler },
				},
			},
			{ kind = "lit_str", value = "run" },
		},
	}

	T.it("instantiates the generic dispatch fn and infers void", function()
		local ty, err = TC.check(prog, { env = env })
		T.ok(ty, err)
		T.eq(ty.kind, "void")
	end)
end)

-- ========================
-- (c) ECS-shaped
-- ========================
-- new_store: <T>(x: T) -> Store<T>       (builtin)
-- query:     <T>(s: Store<T>) -> T[]     (builtin)
-- "component type" is modeled abstractly as `int` (a concrete component
-- record type adds nothing to the generics/instantiation story this test
-- is exercising, so it's punted for focus, per init.lua's punt list).

T.describe("ECS-shaped program", function()
	local Te = ir.mk_tyvar("T")
	local new_store_scheme = ir.mk_scheme_cell(
		ir.mk_scheme({ "T" }, ir.mk_fn({ Te }, ir.mk_generic("Store", { Te })))
	)
	local query_scheme = ir.mk_scheme_cell(
		ir.mk_scheme({ "T" }, ir.mk_fn({ ir.mk_generic("Store", { Te }) }, ir.mk_array(Te)))
	)
	local env = { vars = { new_store = new_store_scheme, query = query_scheme }, parent = nil }

	local prog = {
		kind = "let",
		name = "store",
		value = { kind = "call", fn = { kind = "var", name = "new_store" }, args = { { kind = "lit_int", value = 42 } } },
		body = {
			kind = "let",
			name = "results",
			value = { kind = "call", fn = { kind = "var", name = "query" }, args = { { kind = "var", name = "store" } } },
			body = { kind = "var", name = "results" },
		},
	}

	T.it("infers Array<int> via Store<T> instantiation", function()
		local ty, err = TC.check(prog, { env = env })
		T.ok(ty, err)
		T.eq(ty.kind, "array")
		T.eq(ir.deref(ty.elem).kind, "int")
	end)
end)

-- ========================
-- (d) SHOULD-FAIL cases
-- ========================

T.describe("should-fail: string where int expected", function()
	local prog = {
		kind = "let",
		name = "x",
		ann = ir.mk_int(),
		value = { kind = "lit_str", value = "hello" },
		body = { kind = "var", name = "x" },
	}

	T.it("refutes with a Sub(string,int) failure and a real trail", function()
		local r = TC.check_verbose(prog)
		T.eq(r.verdict, "refuted")
		T.ok(r.message:find("subtype"), "expected a subtyping refutation message, got: " .. tostring(r.message))
		T.ok(r.trail and #r.trail >= 2, "expected a multi-step provenance trail")
		-- trail should mention the let-value check that started the chain
		local found_let = false
		for _, line in ipairs(r.trail) do
			if line:find("let value check") then found_let = true end
		end
		T.ok(found_let, "trail should mention the let-value Check that led here: " .. table.concat(r.trail, " | "))
	end)
end)

T.describe("should-fail: function subtype violation (contravariance)", function()
	-- let f: (number) -> int = fn(n: int) -> int { n } in f
	-- fn(int)->int is NOT <: fn(number)->int (contravariance requires number <: int, which is false)
	local prog = {
		kind = "let",
		name = "f",
		ann = ir.mk_fn({ ir.mk_number() }, ir.mk_int()),
		value = {
			kind = "fn_lit",
			params = { { name = "n", type = ir.mk_int() } },
			ret = ir.mk_int(),
			body = { kind = "var", name = "n" },
		},
		body = { kind = "var", name = "f" },
	}

	T.it("refutes with a contravariant param subtyping failure and a trail", function()
		local r = TC.check_verbose(prog)
		T.eq(r.verdict, "refuted")
		T.ok(r.message:find("subtype"), "expected a subtyping refutation message, got: " .. tostring(r.message))
		local found_contravariant = false
		for _, line in ipairs(r.trail) do
			if line:find("contravariant") then found_contravariant = true end
		end
		T.ok(found_contravariant, "trail should show the contravariant param check that failed: " .. table.concat(r.trail, " | "))
	end)
end)

-- ========================
-- stuck: a genuinely undischargeable obligation (not a refutation, not a crash)
-- ========================

T.describe("stuck saturation", function()
	T.it("reports stuck rather than proved/refuted/hanging when nothing can resolve a var", function()
		local p = TC.new_checker()
		local u1, u2 = ir.mk_uvar(), ir.mk_uvar()
		-- Instantiate blocks on an unresolved scheme_cell forever: nothing ever calls ctx:resolve on it.
		local cell = ir.mk_scheme_cell(nil)
		p:submit("Instantiate", { cell, u1 }, nil, "stuck instantiate")
		p:submit("Unify", { u2, ir.mk_int() }, nil, "unrelated, should still run")
		local r = p:run()
		T.eq(r.verdict, "stuck")
		T.eq(ir.deref(u2).kind, "int") -- the unrelated obligation still made progress
	end)
end)
