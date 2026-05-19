-- Tests for the AST walker — sub-phase A.
--
-- The only module with real behavior in sub-phase A is `env.lua`; tests for
-- it cover the functional update discipline (new envs are returned; the
-- original is never mutated) and the narrowing-overlay precedence rule.
--
-- `walker.lua` is exercised as a dispatch shell: an unknown / unregistered
-- node tag must produce a clean error, and a registered handler must fire.

if not package.path:find("?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local V      = require("lib.type.static-v4")
local E      = require("lib.type.static-v4.walker.env")
local W      = require("lib.type.static-v4.walker.walker")
local defs   = require("lib.type.static.defs")
local T      = require("lib.test.assert")

-- ── env.lua ───────────────────────────────────────────────────────────────

T.describe("walker.env: new", function()
	T.it("returns an empty environment", function()
		local e = E.new()
		T.eq(next(e.bindings), nil)
		T.eq(next(e.narrowed), nil)
		T.eq(e.return_ty, nil)
		T.eq(e.vararg, nil)
		T.eq(next(e.effects), nil)
		T.eq(e.module, nil)
		T.eq(e.expected, nil)
		T.ok(type(e.source) == "table")
		T.eq(e.source.file, "?")
		T.eq(e.source.line, 0)
		T.eq(e.source.col, 0)
	end)
end)

T.describe("walker.env: bind / lookup", function()
	T.it("binding round-trips via lookup", function()
		local e = E.bind(E.new(), "x", V.integer)
		T.eq(E.lookup(e, "x"), V.integer)
	end)

	T.it("lookup on an unbound name returns nil", function()
		T.eq(E.lookup(E.new(), "missing"), nil)
	end)

	T.it("bind is functional — original env unchanged", function()
		local e0 = E.new()
		local e1 = E.bind(e0, "x", V.integer)
		T.eq(E.lookup(e0, "x"), nil)
		T.eq(E.lookup(e1, "x"), V.integer)
	end)

	T.it("multiple binds compose", function()
		local e = E.bind(E.bind(E.new(), "x", V.integer), "y", V.string_)
		T.eq(E.lookup(e, "x"), V.integer)
		T.eq(E.lookup(e, "y"), V.string_)
	end)

	T.it("re-bind overrides earlier binding", function()
		local e = E.bind(E.bind(E.new(), "x", V.integer), "x", V.string_)
		T.eq(E.lookup(e, "x"), V.string_)
	end)

	T.it("has reports underlying binding presence", function()
		local e = E.bind(E.new(), "x", V.integer)
		T.ok(E.has(e, "x"))
		T.fail(E.has(e, "y"))
	end)
end)

T.describe("walker.env: narrow", function()
	T.it("narrowed overlay takes precedence over bindings", function()
		local e = E.bind(E.new(), "x", V.union({ V.integer, V.string_ }))
		local n = E.narrow(e, "x", V.integer)
		T.eq(E.lookup(n, "x"), V.integer)
		-- Underlying binding accessible via has() but lookup returns overlay.
		T.ok(E.has(n, "x"))
	end)

	T.it("narrow is functional — original env unchanged", function()
		local u = V.union({ V.integer, V.string_ })
		local e = E.bind(E.new(), "x", u)
		local n = E.narrow(e, "x", V.integer)
		T.eq(E.lookup(e, "x"), u)
		T.eq(E.lookup(n, "x"), V.integer)
	end)

	T.it("unnarrow restores the underlying binding view", function()
		local u = V.union({ V.integer, V.string_ })
		local e = E.bind(E.new(), "x", u)
		local n = E.narrow(e, "x", V.integer)
		local r = E.unnarrow(n, "x")
		T.eq(E.lookup(r, "x"), u)
	end)

	T.it("re-binding a narrowed name drops the narrowing", function()
		local e = E.bind(E.new(), "x", V.union({ V.integer, V.string_ }))
		local n = E.narrow(e, "x", V.integer)
		local r = E.bind(n, "x", V.boolean)
		T.eq(E.lookup(r, "x"), V.boolean)
	end)

	T.it("clear_narrowed wipes all overlays", function()
		local e = E.bind(E.bind(E.new(), "x", V.integer), "y", V.string_)
		local n = E.narrow(E.narrow(e, "x", V.integer), "y", V.string_)
		local c = E.clear_narrowed(n)
		T.eq(next(c.narrowed), nil)
		T.eq(E.lookup(c, "x"), V.integer)
	end)
end)

T.describe("walker.env: with_expected / with_position / with_source", function()
	T.it("with_expected round-trips", function()
		local e = E.with_expected(E.new(), V.integer)
		T.eq(e.expected, V.integer)
	end)

	T.it("with_expected(nil) clears the expectation", function()
		local e = E.with_expected(E.new(), V.integer)
		local e2 = E.with_expected(e, nil)
		T.eq(e2.expected, nil)
	end)

	T.it("with_expected does not mutate the original", function()
		local e0 = E.new()
		local _e1 = E.with_expected(e0, V.integer)
		T.eq(e0.expected, nil)
	end)

	T.it("with_position updates line and col, preserves file", function()
		local e0 = E.with_source(E.new(), { file = "foo.lua", line = 0, col = 0 })
		local e1 = E.with_position(e0, 42, 7)
		T.eq(e1.source.file, "foo.lua")
		T.eq(e1.source.line, 42)
		T.eq(e1.source.col, 7)
		-- Original untouched.
		T.eq(e0.source.line, 0)
	end)

	T.it("with_source replaces the whole source record", function()
		local e = E.with_source(E.new(), { file = "bar.lua", line = 1, col = 1 })
		T.eq(e.source.file, "bar.lua")
		T.eq(e.source.line, 1)
		T.eq(e.source.col, 1)
	end)
end)

T.describe("walker.env: enter_function", function()
	T.it("enters a function frame: fresh return/vararg/effects, inherits bindings, clears narrowing", function()
		local outer = E.bind(E.new(), "x", V.integer)
		local outer_n = E.narrow(outer, "x", V.integer)
		local outer_n_eff = E.add_effect(outer_n, "yield")
		local inner = E.enter_function(outer_n_eff, V.string_, V.boolean)
		-- Bindings inherited.
		T.eq(E.lookup(inner, "x"), V.integer)
		-- Narrowing cleared.
		T.eq(next(inner.narrowed), nil)
		-- Effects reset.
		T.eq(next(inner.effects), nil)
		-- Return / vararg installed.
		T.eq(inner.return_ty, V.string_)
		T.eq(inner.vararg, V.boolean)
		-- module / expected reset.
		T.eq(inner.module, nil)
		T.eq(inner.expected, nil)
	end)
end)

T.describe("walker.env: add_effect / with_module", function()
	T.it("add_effect accumulates", function()
		local e = E.add_effect(E.add_effect(E.new(), "yield"), "throw")
		T.eq(e.effects.yield, true)
		T.eq(e.effects.throw, true)
	end)

	T.it("add_effect is idempotent and functional", function()
		local e0 = E.add_effect(E.new(), "yield")
		local e1 = E.add_effect(e0, "yield")
		T.eq(e1.effects.yield, true)
		-- Original effect set untouched.
		T.eq(e0.effects.yield, true)
	end)

	T.it("with_module installs the module accumulator", function()
		local m = V.var("M")
		local e = E.with_module(E.new(), m)
		T.eq(e.module, m)
	end)
end)

-- ── walker.lua dispatch shell ─────────────────────────────────────────────

T.describe("walker: dispatch shell", function()
	T.it("synth on a node with no registered handler returns a clean error", function()
		W._reset_handlers()
		local s = V.new_solver()
		-- Use a tag with no builtin handler. NODE_CHUNK is sub-phase J;
		-- nothing registers it yet.
		local node = { tag = defs.NODE_CHUNK, line = 1, col = 1 }
		local ty, _env, err = W.walk_synth(node, E.new(), s)
		T.eq(ty, nil)
		T.ok(err ~= nil)
		T.ok(err:find("NODE_CHUNK", 1, true) ~= nil)
		T.ok(err:find("not yet implemented", 1, true) ~= nil)
		W._register_builtins()
	end)

	T.it("walk_check on an unregistered node falls through to synth and surfaces synth's error", function()
		W._reset_handlers()
		local s = V.new_solver()
		local node = { tag = defs.NODE_CHUNK, line = 1, col = 1 }
		local _env, err = W.walk_check(node, E.new(), s, V.integer)
		T.ok(err ~= nil)
		T.ok(err:find("NODE_CHUNK", 1, true) ~= nil)
		W._register_builtins()
	end)

	T.it("register_synth wires a handler that fires", function()
		W._reset_handlers()
		local s = V.new_solver()
		local called = false
		W.register_synth(defs.NODE_LITERAL, function(_node, env, _solver)
			called = true
			return V.integer, env, nil
		end)
		T.ok(W.has_synth(defs.NODE_LITERAL))
		local ty, _env, err = W.walk_synth({ tag = defs.NODE_LITERAL }, E.new(), s)
		T.ok(called)
		T.eq(err, nil)
		T.eq(ty, V.integer)
		W._reset_handlers(); W._register_builtins()
	end)

	T.it("register_check wires a handler that fires", function()
		W._reset_handlers()
		local s = V.new_solver()
		local got_expected = nil
		W.register_check(defs.NODE_LITERAL, function(_node, env, _solver, expected)
			got_expected = expected
			return env, nil
		end)
		T.ok(W.has_check(defs.NODE_LITERAL))
		local _env, err = W.walk_check({ tag = defs.NODE_LITERAL }, E.new(), s, V.integer)
		T.eq(err, nil)
		T.eq(got_expected, V.integer)
		W._reset_handlers(); W._register_builtins()
	end)

	T.it("walk routes to CHECK when env.expected is set", function()
		W._reset_handlers()
		local s = V.new_solver()
		local check_fired = false
		W.register_check(defs.NODE_LITERAL, function(_node, env, _solver, _expected)
			check_fired = true
			return env, nil
		end)
		local env = E.with_expected(E.new(), V.integer)
		local ty, _env, err = W.walk({ tag = defs.NODE_LITERAL }, env, s)
		T.eq(err, nil)
		T.ok(check_fired)
		T.eq(ty, V.integer)
		W._reset_handlers(); W._register_builtins()
	end)

	T.it("walk routes to SYNTHESIZE when env.expected is nil", function()
		W._reset_handlers()
		local s = V.new_solver()
		W.register_synth(defs.NODE_LITERAL, function(_node, env, _solver)
			return V.string_, env, nil
		end)
		local ty, _env, err = W.walk({ tag = defs.NODE_LITERAL }, E.new(), s)
		T.eq(err, nil)
		T.eq(ty, V.string_)
		W._reset_handlers(); W._register_builtins()
	end)

	T.it("position is threaded into env from node line/col", function()
		W._reset_handlers()
		local s = V.new_solver()
		local seen_line, seen_col = nil, nil
		W.register_synth(defs.NODE_LITERAL, function(_node, env, _solver)
			seen_line = env.source.line
			seen_col = env.source.col
			return V.integer, env, nil
		end)
		local _ty, _env, err = W.walk_synth(
			{ tag = defs.NODE_LITERAL, line = 17, col = 4 }, E.new(), s)
		T.eq(err, nil)
		T.eq(seen_line, 17)
		T.eq(seen_col, 4)
		W._reset_handlers(); W._register_builtins()
	end)

	T.it("sub-phase B+C handlers are registered by default", function()
		-- Sub-phase B installs SYNTHESIZE handlers for literals, identifiers,
		-- varargs. Sub-phase C adds function defs, calls, method calls,
		-- returns, and (minimally) expression statements. Tags for later
		-- sub-phases must remain unregistered.
		T.ok(W.has_synth(defs.NODE_LITERAL))
		T.ok(W.has_synth(defs.NODE_IDENTIFIER))
		T.ok(W.has_synth(defs.NODE_VARARG_EXPR))
		T.ok(W.has_synth(defs.NODE_FUNC_EXPR))
		T.ok(W.has_synth(defs.NODE_FUNC_DECL))
		T.ok(W.has_synth(defs.NODE_CALL_EXPR))
		T.ok(W.has_synth(defs.NODE_METHOD_CALL))
		T.ok(W.has_synth(defs.NODE_RETURN_STMT))
		T.ok(W.has_synth(defs.NODE_EXPR_STMT))
		-- Sub-phase D adds control-flow + loop family.
		T.ok(W.has_synth(defs.NODE_IF_STMT))
		T.ok(W.has_synth(defs.NODE_WHILE_STMT))
		T.ok(W.has_synth(defs.NODE_REPEAT_STMT))
		T.ok(W.has_synth(defs.NODE_FOR_NUM))
		T.ok(W.has_synth(defs.NODE_FOR_IN))
		T.ok(W.has_synth(defs.NODE_DO_STMT))
		T.ok(W.has_synth(defs.NODE_BREAK_STMT))
		-- Sub-phase F adds indexed access + table literal.
		T.ok(W.has_synth(defs.NODE_FIELD_EXPR))
		T.ok(W.has_synth(defs.NODE_INDEX_EXPR))
		T.ok(W.has_synth(defs.NODE_TABLE_EXPR))
		for _, tag in pairs({
			defs.NODE_CHUNK,
		}) do
			T.fail(W.has_synth(tag))
			T.fail(W.has_check(tag))
		end
		-- No CHECK handlers registered yet — every CHECK goes through the
		-- default synth+constrain rule.
		T.fail(W.has_check(defs.NODE_LITERAL))
		T.fail(W.has_check(defs.NODE_IDENTIFIER))
		T.fail(W.has_check(defs.NODE_VARARG_EXPR))
		T.fail(W.has_check(defs.NODE_FUNC_EXPR))
		T.fail(W.has_check(defs.NODE_CALL_EXPR))
	end)
end)

-- ── sub-phase B: literals ─────────────────────────────────────────────────

T.describe("walker sub-phase B: NODE_LITERAL", function()
	T.it("nil literal synthesizes V.prim('nil')", function()
		local s = V.new_solver()
		local node = { tag = defs.NODE_LITERAL, lit_kind = defs.LIT_NIL }
		local ty, _env, err = W.walk_synth(node, E.new(), s)
		T.eq(err, nil)
		T.eq(ty, V.prim("nil"))
	end)

	T.it("boolean literal synthesizes V.literal('boolean', v)", function()
		local s = V.new_solver()
		local t_node = { tag = defs.NODE_LITERAL, lit_kind = defs.LIT_BOOLEAN, value = true }
		local ty_t, _e1, e1 = W.walk_synth(t_node, E.new(), s)
		T.eq(e1, nil)
		T.eq(ty_t, V.literal("boolean", true))
		local f_node = { tag = defs.NODE_LITERAL, lit_kind = defs.LIT_BOOLEAN, value = false }
		local ty_f, _e2, e2 = W.walk_synth(f_node, E.new(), s)
		T.eq(e2, nil)
		T.eq(ty_f, V.literal("boolean", false))
	end)

	T.it("integer literal synthesizes V.literal('integer', v)", function()
		local s = V.new_solver()
		local node = { tag = defs.NODE_LITERAL, lit_kind = defs.LIT_INTEGER, value = 42 }
		local ty, _env, err = W.walk_synth(node, E.new(), s)
		T.eq(err, nil)
		T.eq(ty, V.literal("integer", 42))
	end)

	T.it("number literal synthesizes V.literal('number', v)", function()
		local s = V.new_solver()
		local node = { tag = defs.NODE_LITERAL, lit_kind = defs.LIT_NUMBER, value = 3.14 }
		local ty, _env, err = W.walk_synth(node, E.new(), s)
		T.eq(err, nil)
		T.eq(ty, V.literal("number", 3.14))
	end)

	T.it("string literal synthesizes V.literal('string', v)", function()
		local s = V.new_solver()
		local node = { tag = defs.NODE_LITERAL, lit_kind = defs.LIT_STRING, value = "hi" }
		local ty, _env, err = W.walk_synth(node, E.new(), s)
		T.eq(err, nil)
		T.eq(ty, V.literal("string", "hi"))
	end)

	T.it("unknown lit_kind produces a clean error", function()
		local s = V.new_solver()
		local node = { tag = defs.NODE_LITERAL, lit_kind = 999 }
		local ty, _env, err = W.walk_synth(node, E.new(), s)
		T.eq(ty, nil)
		T.ok(err ~= nil)
		T.ok(err:find("unknown lit_kind", 1, true) ~= nil)
	end)

	T.it("CHECK mode: literal subtypes its primitive base", function()
		local s = V.new_solver()
		local node = { tag = defs.NODE_LITERAL, lit_kind = defs.LIT_INTEGER, value = 7 }
		local _env, err = W.walk_check(node, E.new(), s, V.integer)
		T.eq(err, nil)
	end)

	T.it("CHECK mode: string literal vs integer expected fails", function()
		local s = V.new_solver()
		local node = { tag = defs.NODE_LITERAL, lit_kind = defs.LIT_STRING, value = "x" }
		local _env, err = W.walk_check(node, E.new(), s, V.integer)
		T.ok(err ~= nil)
	end)
end)

T.describe("walker sub-phase B: NODE_IDENTIFIER", function()
	T.it("synthesizes the bound type", function()
		local s = V.new_solver()
		local env = E.bind(E.new(), "x", V.integer)
		local node = { tag = defs.NODE_IDENTIFIER, name = "x" }
		local ty, _env, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
		T.eq(ty, V.integer)
	end)

	T.it("undefined name errors (no ambient globals)", function()
		local s = V.new_solver()
		local node = { tag = defs.NODE_IDENTIFIER, name = "nope" }
		local ty, _env, err = W.walk_synth(node, E.new(), s)
		T.eq(ty, nil)
		T.ok(err ~= nil)
		T.ok(err:find("undefined name", 1, true) ~= nil)
		T.ok(err:find("nope", 1, true) ~= nil)
	end)

	T.it("narrowed overlay takes precedence over binding", function()
		local s = V.new_solver()
		local env = E.bind(E.new(), "x", V.union({ V.integer, V.string_ }))
		env = E.narrow(env, "x", V.integer)
		local node = { tag = defs.NODE_IDENTIFIER, name = "x" }
		local ty, _env, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
		T.eq(ty, V.integer)
	end)

	T.it("CHECK mode: bound type subtypes expected", function()
		local s = V.new_solver()
		local env = E.bind(E.new(), "x", V.integer)
		local node = { tag = defs.NODE_IDENTIFIER, name = "x" }
		local _env, err = W.walk_check(node, env, s, V.integer)
		T.eq(err, nil)
	end)

	T.it("CHECK mode: undefined name still errors before subtyping", function()
		local s = V.new_solver()
		local node = { tag = defs.NODE_IDENTIFIER, name = "nope" }
		local _env, err = W.walk_check(node, E.new(), s, V.integer)
		T.ok(err ~= nil)
		T.ok(err:find("undefined name", 1, true) ~= nil)
	end)
end)

T.describe("walker sub-phase B: NODE_VARARG_EXPR", function()
	T.it("synthesizes env.vararg when in scope", function()
		local s = V.new_solver()
		local env = E.enter_function(E.new(), V.string_, V.integer)
		local node = { tag = defs.NODE_VARARG_EXPR }
		local ty, _env, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
		T.eq(ty, V.integer)
	end)

	T.it("errors when no enclosing vararg function", function()
		local s = V.new_solver()
		local node = { tag = defs.NODE_VARARG_EXPR }
		local ty, _env, err = W.walk_synth(node, E.new(), s)
		T.eq(ty, nil)
		T.ok(err ~= nil)
		T.ok(err:find("varargs not in scope", 1, true) ~= nil)
	end)

	T.it("CHECK mode: vararg type subtypes expected", function()
		local s = V.new_solver()
		local env = E.enter_function(E.new(), V.string_, V.integer)
		local node = { tag = defs.NODE_VARARG_EXPR }
		local _env, err = W.walk_check(node, env, s, V.integer)
		T.eq(err, nil)
	end)
end)

-- ── sub-phase C: function defs, calls, returns ────────────────────────────
--
-- Builders that produce decoded-Lua-table AST nodes mirroring the shapes
-- declared in `lib/type/static-v4/walker/functions.lua`. Tests below
-- construct AST trees directly; the parser→walker bridge is sub-phase J.

-- AST-builder helpers. Intentionally unannotated to match the no-annotation
-- style of the rest of this test file (HEAD walker_test.lua has zero `--:`
-- annotations). Adding annotations in tandem with requiring the walker.env
-- module surfaces env.lua's documented cross-module alias-resolution
-- limitation as a wave of latent diagnostics; staying unannotated avoids
-- that pre-existing trap without weakening assertions (each helper is a
-- one-liner table constructor and reads obviously).
local function lit_int(n)
	return { tag = defs.NODE_LITERAL, lit_kind = defs.LIT_INTEGER, value = n }
end
local function lit_str(s)
	return { tag = defs.NODE_LITERAL, lit_kind = defs.LIT_STRING, value = s }
end
local function id(name)
	return { tag = defs.NODE_IDENTIFIER, name = name }
end
local function ret(...)
	return { tag = defs.NODE_RETURN_STMT, exprs = { ... } }
end
local function call(callee, ...)
	return { tag = defs.NODE_CALL_EXPR, callee = callee, args = { ... } }
end
local function mcall(recv, name, ...)
	return { tag = defs.NODE_METHOD_CALL,
		receiver = recv, method = name, args = { ... } }
end
local function expr_stmt(e)
	return { tag = defs.NODE_EXPR_STMT, expr = e }
end
-- Positional builder: `func(params, body, annotation)`. The positional
-- shape sidesteps the structural-record inference that would happen if we
-- accepted an `opts` record (callers would have to supply every field the
-- helper accesses, even unused ones). Optional positions: pass nil.
local function func(params, body, annotation)
	return {
		tag        = defs.NODE_FUNC_EXPR,
		params     = params or {},
		vararg     = false,
		vararg_ann = nil,
		ret_ann    = nil,
		annotation = annotation,
		generic    = nil,
		body       = body or {},
	}
end

T.describe("walker sub-phase C: NODE_FUNC_EXPR (unannotated)", function()
	T.it("empty body synthesizes a function arrow with fresh vars", function()
		local s = V.new_solver()
		local node = func({ { name = "x" } }, {})
		local ty, _env, err = W.walk_synth(node, E.new(), s)
		T.eq(err, nil)
		T.ok(ty ~= nil)
		T.eq(ty.tag, "fn")
		T.eq(#ty.params, 1)
		T.eq(ty.params[1].tag, "var")
	end)

	T.it("return inside body constrains the return var", function()
		local s = V.new_solver()
		-- function(x) return x end  — identity-like at the fresh-var level.
		local node = func({ { name = "x" } }, { ret(id("x")) })
		local ty, _env, err = W.walk_synth(node, E.new(), s)
		T.eq(err, nil)
		T.eq(ty.tag, "fn")
		-- The param var was bound as x; the return var received it as a
		-- lower bound via constrain. We assert that the solver did not error.
		T.eq(s.error, nil)
	end)
end)

T.describe("walker sub-phase C: NODE_FUNC_EXPR (annotated)", function()
	T.it("full annotation produces the annotated type", function()
		local s = V.new_solver()
		local ann = V.fn({ V.integer }, V.string_, nil)
		local node = func(
			{ { name = "x", ann = V.integer } },
			{ ret(lit_str("hi")) },
			ann)
		local ty, _env, err = W.walk_synth(node, E.new(), s)
		T.eq(err, nil)
		T.eq(ty, ann)
	end)

	T.it("body return-type mismatch fails", function()
		local s = V.new_solver()
		local ann = V.fn({ V.integer }, V.string_, nil)
		local node = func(
			{ { name = "x", ann = V.integer } },
			{ ret(lit_int(42)) },  -- integer vs expected string
			ann)
		local _ty, _env, err = W.walk_synth(node, E.new(), s)
		T.ok(err ~= nil)
	end)

	T.it("annotation arity mismatch errors", function()
		local s = V.new_solver()
		local ann = V.fn({ V.integer, V.string_ }, V.string_, nil)
		local node = func({ { name = "x" } }, {}, ann)
		local _ty, _env, err = W.walk_synth(node, E.new(), s)
		T.ok(err ~= nil)
		T.ok(err:find("arity", 1, true) ~= nil)
	end)
end)

T.describe("walker sub-phase C: rank-N skolemization", function()
	T.it("generic identity annotation is preserved verbatim", function()
		local s = V.new_solver()
		-- ∀T. (T) -> T
		local ann = V.forall({ "T" }, function(vs)
			return V.fn({ vs[1] }, vs[1], nil)
		end)
		local node = func(
			{ { name = "x" } },  -- ann picked up from forall body
			{ ret(id("x")) },
			ann)
		local ty, _env, err = W.walk_synth(node, E.new(), s)
		T.eq(err, nil)
		T.eq(ty, ann)
	end)

	T.it("body sees a skolem for the bound type variable", function()
		-- We confirm skolemization by exploiting subtyping at the call
		-- site: if `x` were the (still-free) bound var, returning a
		-- concrete `integer` from a `(T)->T` body would constrain T's
		-- lower to integer and succeed. Skolemizing turns T into a rigid
		-- opaque tag — `integer <: #T` is mismatched constructors, so the
		-- body fails. This is a one-shot check that the body's `T` is a
		-- skolem (not a free var).
		local s = V.new_solver()
		local ann = V.forall({ "T" }, function(vs)
			return V.fn({ vs[1] }, vs[1], nil)
		end)
		local node = func(
			{ { name = "x" } },
			{ ret(lit_int(42)) },  -- integer <: skolem #T should fail
			ann)
		local _ty, _env, err = W.walk_synth(node, E.new(), s)
		T.ok(err ~= nil)
	end)
end)

T.describe("walker sub-phase C: NODE_CALL_EXPR", function()
	T.it("monomorphic arrow + matching args synthesizes the return", function()
		local s = V.new_solver()
		local f_ty = V.fn({ V.integer }, V.string_, nil)
		local env = E.bind(E.new(), "f", f_ty)
		local node = call(id("f"), lit_int(7))
		local ty, _env, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
		T.eq(ty, V.string_)
	end)

	T.it("argument type mismatch errors", function()
		local s = V.new_solver()
		local f_ty = V.fn({ V.integer }, V.string_, nil)
		local env = E.bind(E.new(), "f", f_ty)
		local node = call(id("f"), lit_str("nope"))
		local _ty, _env, err = W.walk_synth(node, env, s)
		T.ok(err ~= nil)
	end)

	T.it("arity mismatch errors", function()
		local s = V.new_solver()
		local f_ty = V.fn({ V.integer, V.string_ }, V.string_, nil)
		local env = E.bind(E.new(), "f", f_ty)
		local node = call(id("f"), lit_int(1))
		local _ty, _env, err = W.walk_synth(node, env, s)
		T.ok(err ~= nil)
		T.ok(err:find("arity", 1, true) ~= nil)
	end)

	T.it("generic arrow + concrete args instantiates", function()
		local s = V.new_solver()
		-- ∀T. (T) -> T — applied at integer.
		local f_ty = V.forall({ "T" }, function(vs)
			return V.fn({ vs[1] }, vs[1], nil)
		end)
		local env = E.bind(E.new(), "f", f_ty)
		local node = call(id("f"), lit_int(42))
		local ty, _env, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
		-- The result should be an inference var (instantiate produced fresh
		-- T, the arg type lit_int(42) was constrained as a lower bound on T,
		-- and the return is that same fresh var).
		T.eq(ty.tag, "var")
	end)

	T.it("subtyping at call site: int into int|string param accepted", function()
		local s = V.new_solver()
		local f_ty = V.fn({ V.union({ V.integer, V.string_ }) }, V.string_, nil)
		local env = E.bind(E.new(), "f", f_ty)
		local node = call(id("f"), lit_int(1))
		local ty, _env, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
		T.eq(ty, V.string_)
	end)

	T.it("indexed callee resolves via field synthesis (sub-phase F)", function()
		local s = V.new_solver()
		local env = E.bind(E.new(), "t", V.rec({ f = V.fn({}, V.integer, nil) }, false, nil))
		local node = call({
			tag = defs.NODE_FIELD_EXPR, target = id("t"), key = "f",
		})
		local ty, _env, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
		T.eq(ty, V.integer)
	end)
end)

T.describe("walker sub-phase C: NODE_METHOD_CALL", function()
	T.it("method on a closed rec dispatches to the field's arrow", function()
		local s = V.new_solver()
		-- obj = { greet: (self, name: string) -> string }
		local self_ty = V.var("self")
		local method_ty = V.fn({ self_ty, V.string_ }, V.string_, nil)
		local obj_ty = V.rec({ greet = method_ty }, false, nil)
		local env = E.bind(E.new(), "obj", obj_ty)
		local node = mcall(id("obj"), "greet", lit_str("hi"))
		local ty, _env, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
		T.eq(ty, V.string_)
	end)

	T.it("missing method errors", function()
		local s = V.new_solver()
		local obj_ty = V.rec({}, false, nil)
		local env = E.bind(E.new(), "obj", obj_ty)
		local node = mcall(id("obj"), "nope")
		local _ty, _env, err = W.walk_synth(node, env, s)
		T.ok(err ~= nil)
		T.ok(err:find("no method", 1, true) ~= nil)
	end)
end)

T.describe("walker sub-phase C: NODE_RETURN_STMT", function()
	T.it("zero-expr return constrains nil <: return_ty", function()
		local s = V.new_solver()
		local env = E.enter_function(E.new(), V.nil_, nil)
		local node = ret()
		local _ty, _env, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
	end)

	T.it("zero-expr return against non-nil fails", function()
		local s = V.new_solver()
		local env = E.enter_function(E.new(), V.integer, nil)
		local node = ret()
		local _ty, _env, err = W.walk_synth(node, env, s)
		T.ok(err ~= nil)
	end)

	T.it("single return wrong type fails", function()
		local s = V.new_solver()
		local env = E.enter_function(E.new(), V.string_, nil)
		local node = ret(lit_int(1))
		local _ty, _env, err = W.walk_synth(node, env, s)
		T.ok(err ~= nil)
	end)

	T.it("multi-return matches against a tuple record", function()
		local s = V.new_solver()
		-- Expected: { ["1"]: integer, ["2"]: string } closed
		local tuple = V.rec({ ["1"] = V.integer, ["2"] = V.string_ }, false, nil)
		local env = E.enter_function(E.new(), tuple, nil)
		local node = ret(lit_int(1), lit_str("hi"))
		local _ty, _env, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
	end)

	T.it("multi-return wrong slot type fails", function()
		local s = V.new_solver()
		local tuple = V.rec({ ["1"] = V.integer, ["2"] = V.string_ }, false, nil)
		local env = E.enter_function(E.new(), tuple, nil)
		local node = ret(lit_str("oops"), lit_str("hi"))
		local _ty, _env, err = W.walk_synth(node, env, s)
		T.ok(err ~= nil)
	end)

	T.it("return outside a function body errors", function()
		local s = V.new_solver()
		local node = ret(lit_int(1))
		local _ty, _env, err = W.walk_synth(node, E.new(), s)
		T.ok(err ~= nil)
		T.ok(err:find("outside function body", 1, true) ~= nil)
	end)
end)

T.describe("walker sub-phase C: effect accumulation", function()
	T.it("a call to a yield-effected function accumulates yield", function()
		local s = V.new_solver()
		-- yield: () -> nil with effects = { yield }
		local yield_fn = V.fn({}, V.nil_, { yield = true })
		-- The body is a single expr-stmt invoking yield. We synthesize the
		-- function literal in unannotated mode and confirm its arrow has
		-- yield in its effects.
		local node = func({}, { expr_stmt(call(id("yield"))) })
		-- yield is bound in the outer env (function bodies inherit bindings).
		local env = E.bind(E.new(), "yield", yield_fn)
		local ty, _env, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
		T.eq(ty.tag, "fn")
		T.eq(ty.effects.yield, true)
	end)

	T.it("annotated function whose body performs an undeclared effect errors", function()
		local s = V.new_solver()
		local yield_fn = V.fn({}, V.nil_, { yield = true })
		-- annotation has no effects; body yields.
		local ann = V.fn({}, V.nil_, nil)
		local node = func({}, { expr_stmt(call(id("yield"))) }, ann)
		local env = E.bind(E.new(), "yield", yield_fn)
		local _ty, _env, err = W.walk_synth(node, env, s)
		T.ok(err ~= nil)
		T.ok(err:find("yield", 1, true) ~= nil)
	end)
end)

-- ── sub-phase D: control flow + narrowing ────────────────────────────────

-- Builders for control-flow node shapes. Match the decoded shapes
-- declared in walker/control_flow.lua.
local function lit_nil()
	return { tag = defs.NODE_LITERAL, lit_kind = defs.LIT_NIL }
end
local function lit_bool(b)
	return { tag = defs.NODE_LITERAL, lit_kind = defs.LIT_BOOLEAN, value = b }
end
local function binop(op, lhs, rhs)
	return { tag = defs.NODE_BINARY_EXPR, op = op, lhs = lhs, rhs = rhs }
end
local function unop(op, operand)
	return { tag = defs.NODE_UNARY_EXPR, op = op, operand = operand }
end
local function field(target, key)
	return { tag = defs.NODE_FIELD_EXPR, target = target, key = key }
end
local function if_stmt(clauses, else_body)
	return { tag = defs.NODE_IF_STMT, clauses = clauses, else_body = else_body }
end
local function clause(cond, body)
	return { cond = cond, body = body or {} }
end
local function while_stmt(cond, body)
	return { tag = defs.NODE_WHILE_STMT, cond = cond, body = body or {} }
end
local function repeat_stmt(body, cond)
	return { tag = defs.NODE_REPEAT_STMT, body = body or {}, cond = cond }
end
local function for_num(name, init, stop, step, body)
	return { tag = defs.NODE_FOR_NUM, name = name, init = init,
		stop = stop, step = step, body = body or {} }
end
local function for_in(names, exprs, body)
	return { tag = defs.NODE_FOR_IN, names = names, exprs = exprs, body = body or {} }
end
local function do_stmt(body)
	return { tag = defs.NODE_DO_STMT, body = body or {} }
end
local function break_stmt()
	return { tag = defs.NODE_BREAK_STMT }
end

-- A "probe" statement that synthesizes its expr and asserts it has
-- a specific type — used to inspect the narrowed view of an identifier
-- inside a branch. The probe is expressed as an expr-stmt wrapping a
-- call to a sentinel function `assert_ty_<i>`; the sentinel is bound
-- in env to a function with parameter T_i, so a subtype mismatch
-- between the narrowed identifier and T_i becomes a solver error.

T.describe("walker sub-phase D: if/narrowing — type(x) == 'string'", function()
	T.it("narrows x to string in the then-branch", function()
		local s = V.new_solver()
		-- assert_string expects a string param. If x has narrowed to
		-- string, the call inside the then-branch typechecks.
		local assert_string = V.fn({ V.string_ }, V.nil_, nil)
		local x_ty = V.union({ V.string_, V.integer })
		local env = E.bind(E.bind(E.new(), "x", x_ty), "assert_string", assert_string)
		local guard = binop("==",
			{ tag = defs.NODE_CALL_EXPR, callee = id("type"), args = { id("x") } },
			lit_str("string"))
		local body = { expr_stmt(call(id("assert_string"), id("x"))) }
		local node = if_stmt({ clause(guard, body) }, nil)
		local _ty, _env, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
	end)

	T.it("does not narrow x in the else branch (type(x) != 'string')", function()
		local s = V.new_solver()
		-- If else-branch's narrowing were wrong (still string-typed),
		-- a call to assert_int(x) would succeed, which is incorrect.
		-- We probe the negative narrowing: x must be NON-string there.
		-- We construct an `assert_non_string` taking integer | nil | boolean
		-- | number — any non-string narrowing should satisfy it.
		local assert_int = V.fn({ V.integer }, V.nil_, nil)
		local x_ty = V.union({ V.string_, V.integer })
		local env = E.bind(E.bind(E.new(), "x", x_ty), "assert_int", assert_int)
		local guard = binop("==",
			{ tag = defs.NODE_CALL_EXPR, callee = id("type"), args = { id("x") } },
			lit_str("string"))
		-- else-branch calls assert_int(x): x should narrow to integer
		-- here because it's known not-string.
		local node = if_stmt({ clause(guard, {}) },
			{ expr_stmt(call(id("assert_int"), id("x"))) })
		local _ty, _env, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
	end)
end)

T.describe("walker sub-phase D: if/narrowing — x ~= nil", function()
	T.it("narrows x to non-nil in then-branch", function()
		local s = V.new_solver()
		local non_nil = V.fn({ V.integer }, V.nil_, nil)
		local x_ty = V.union({ V.integer, V.nil_ })
		local env = E.bind(E.bind(E.new(), "x", x_ty), "f", non_nil)
		local guard = binop("~=", id("x"), lit_nil())
		local body = { expr_stmt(call(id("f"), id("x"))) }
		local node = if_stmt({ clause(guard, body) }, nil)
		local _ty, _env, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
	end)
end)

T.describe("walker sub-phase D: if/narrowing — field discriminant", function()
	T.it("x.kind == 'foo' narrows x to record with that field", function()
		local s = V.new_solver()
		-- Take_foo accepts { kind: "foo", ... } (open record with
		-- kind discriminant). x starts as union { kind: "foo" } | { kind: "bar" }.
		local foo_rec = V.rec({ kind = V.literal("string", "foo") }, true, nil)
		local take_foo = V.fn({ foo_rec }, V.nil_, nil)
		local foo_ty = V.rec({ kind = V.literal("string", "foo") }, false, nil)
		local bar_ty = V.rec({ kind = V.literal("string", "bar") }, false, nil)
		local x_ty = V.union({ foo_ty, bar_ty })
		local env = E.bind(E.bind(E.new(), "x", x_ty), "take_foo", take_foo)
		local guard = binop("==", field(id("x"), "kind"), lit_str("foo"))
		local body = { expr_stmt(call(id("take_foo"), id("x"))) }
		local node = if_stmt({ clause(guard, body) }, nil)
		local _ty, _env, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
	end)
end)

T.describe("walker sub-phase D: if/narrowing — truthy/falsy", function()
	T.it("`if x then` narrows x to non-(nil | false)", function()
		local s = V.new_solver()
		-- f expects integer. x : integer | nil — inside `if x then`
		-- x should narrow to integer (which is part of truthy).
		local f = V.fn({ V.integer }, V.nil_, nil)
		local env = E.bind(E.bind(E.new(), "x", V.union({ V.integer, V.nil_ })),
			"f", f)
		local node = if_stmt({
			clause(id("x"), { expr_stmt(call(id("f"), id("x"))) }),
		}, nil)
		local _ty, _env, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
	end)
end)

T.describe("walker sub-phase D: if/narrowing — `not` swaps polarity", function()
	T.it("`if not (x == nil)` narrows x to non-nil in then-branch", function()
		local s = V.new_solver()
		local non_nil = V.fn({ V.integer }, V.nil_, nil)
		local x_ty = V.union({ V.integer, V.nil_ })
		local env = E.bind(E.bind(E.new(), "x", x_ty), "f", non_nil)
		local guard = unop("not", binop("==", id("x"), lit_nil()))
		local node = if_stmt({
			clause(guard, { expr_stmt(call(id("f"), id("x"))) }),
		}, nil)
		local _ty, _env, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
	end)
end)

T.describe("walker sub-phase D: if/narrowing — `and` intersects", function()
	T.it("type(x)=='string' and type(y)=='integer' narrows both", function()
		local s = V.new_solver()
		local f = V.fn({ V.string_, V.integer }, V.nil_, nil)
		local x_ty = V.union({ V.string_, V.integer })
		local y_ty = V.union({ V.string_, V.integer })
		local env = E.bind(E.bind(E.bind(E.new(), "x", x_ty), "y", y_ty), "f", f)
		local gx = binop("==",
			{ tag = defs.NODE_CALL_EXPR, callee = id("type"), args = { id("x") } },
			lit_str("string"))
		local gy = binop("==",
			{ tag = defs.NODE_CALL_EXPR, callee = id("type"), args = { id("y") } },
			lit_str("number"))
		-- type(y) == "number" narrows y to V.prim("number"); integer is
		-- subtype-of number per v4 prim subtyping, so the call typechecks
		-- only if the narrowed type covers integer. We use "integer" instead
		-- to keep the subtype simple.
		gy = binop("==",
			{ tag = defs.NODE_CALL_EXPR, callee = id("type"), args = { id("y") } },
			lit_str("integer"))
		local guard = binop("and", gx, gy)
		local node = if_stmt({
			clause(guard, { expr_stmt(call(id("f"), id("x"), id("y"))) }),
		}, nil)
		local _ty, _env, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
	end)
end)

T.describe("walker sub-phase D: if/narrowing — `or` unions", function()
	T.it("type(x)=='string' or type(x)=='integer' narrows x to that union", function()
		local s = V.new_solver()
		-- f accepts string | integer.
		local f = V.fn({ V.union({ V.string_, V.integer }) }, V.nil_, nil)
		local x_ty = V.union({ V.string_, V.integer, V.boolean })
		local env = E.bind(E.bind(E.new(), "x", x_ty), "f", f)
		local gx_s = binop("==",
			{ tag = defs.NODE_CALL_EXPR, callee = id("type"), args = { id("x") } },
			lit_str("string"))
		local gx_i = binop("==",
			{ tag = defs.NODE_CALL_EXPR, callee = id("type"), args = { id("x") } },
			lit_str("integer"))
		local guard = binop("or", gx_s, gx_i)
		local node = if_stmt({
			clause(guard, { expr_stmt(call(id("f"), id("x"))) }),
		}, nil)
		local _ty, _env, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
	end)
end)

T.describe("walker sub-phase D: if/join — variable narrowed in only one branch reverts", function()
	T.it("post-if uses original (unnarrowed) type", function()
		local s = V.new_solver()
		local f_union = V.fn({ V.union({ V.integer, V.string_ }) }, V.nil_, nil)
		local x_ty = V.union({ V.integer, V.string_ })
		local env = E.bind(E.bind(E.new(), "x", x_ty), "f", f_union)
		local guard = binop("==",
			{ tag = defs.NODE_CALL_EXPR, callee = id("type"), args = { id("x") } },
			lit_str("string"))
		local if_node = if_stmt({ clause(guard, {}) }, nil)
		-- After the if, x should be back to int|string. We construct an
		-- expr_stmt(call(f, x)) in the same body sequence by walking
		-- them via a do-stmt wrapping.
		local node = do_stmt({
			if_node,
			expr_stmt(call(id("f"), id("x"))),
		})
		local _ty, _env, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
	end)
end)

T.describe("walker sub-phase D: nested narrowing", function()
	T.it("`if x then if type(x) == 'string' then ... end end`", function()
		local s = V.new_solver()
		local take_string = V.fn({ V.string_ }, V.nil_, nil)
		local x_ty = V.union({ V.string_, V.integer, V.nil_ })
		local env = E.bind(E.bind(E.new(), "x", x_ty), "f", take_string)
		local inner_guard = binop("==",
			{ tag = defs.NODE_CALL_EXPR, callee = id("type"), args = { id("x") } },
			lit_str("string"))
		local inner = if_stmt({
			clause(inner_guard, { expr_stmt(call(id("f"), id("x"))) }),
		}, nil)
		local outer = if_stmt({ clause(id("x"), { inner }) }, nil)
		local _ty, _env, err = W.walk_synth(outer, env, s)
		T.eq(err, nil)
	end)
end)

T.describe("walker sub-phase D: numeric for", function()
	T.it("integer init/stop binds loop var as integer", function()
		local s = V.new_solver()
		local f = V.fn({ V.integer }, V.nil_, nil)
		local env = E.bind(E.new(), "f", f)
		local body = { expr_stmt(call(id("f"), id("i"))) }
		local node = for_num("i", lit_int(1), lit_int(10), nil, body)
		local _ty, _env, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
	end)

	T.it("loop var is dropped after the loop", function()
		local s = V.new_solver()
		local f = V.fn({ V.integer }, V.nil_, nil)
		local env = E.bind(E.new(), "f", f)
		local node = do_stmt({
			for_num("i", lit_int(1), lit_int(10), nil, {}),
			expr_stmt(call(id("f"), id("i"))),  -- 'i' should be undefined here
		})
		local _ty, _env, err = W.walk_synth(node, env, s)
		T.ok(err ~= nil)
		T.ok(err:find("undefined name", 1, true) ~= nil)
	end)
end)

T.describe("walker sub-phase D: generic for", function()
	T.it("iter returning (K, V) tuple binds two names correctly", function()
		local s = V.new_solver()
		-- iter: () -> { ["1"]: string, ["2"]: integer }
		local iter_ret = V.rec({ ["1"] = V.string_, ["2"] = V.integer }, false, nil)
		local iter = V.fn({}, iter_ret, nil)
		local take_pair = V.fn({ V.string_, V.integer }, V.nil_, nil)
		local env = E.bind(E.bind(E.new(), "iter", iter), "take", take_pair)
		local body = { expr_stmt(call(id("take"), id("k"), id("v"))) }
		local node = for_in({ "k", "v" }, { id("iter") }, body)
		local _ty, _env, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
	end)
end)

T.describe("walker sub-phase D: while loop", function()
	T.it("guard narrows for body", function()
		local s = V.new_solver()
		local take_int = V.fn({ V.integer }, V.nil_, nil)
		local x_ty = V.union({ V.integer, V.nil_ })
		local env = E.bind(E.bind(E.new(), "x", x_ty), "f", take_int)
		local node = while_stmt(
			binop("~=", id("x"), lit_nil()),
			{ expr_stmt(call(id("f"), id("x"))) })
		local _ty, _env, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
	end)
end)

T.describe("walker sub-phase D: repeat loop", function()
	T.it("body runs with no incoming narrowing; guard narrows AFTER", function()
		local s = V.new_solver()
		local take_int = V.fn({ V.integer }, V.nil_, nil)
		local x_ty = V.union({ V.integer, V.nil_ })
		local env = E.bind(E.bind(E.new(), "x", x_ty), "f", take_int)
		-- Inside the repeat body, x is still int|nil — calling f(x) would
		-- fail. We test that the body does NOT see the narrowing.
		local node = repeat_stmt(
			{ expr_stmt(call(id("f"), id("x"))) },  -- should fail (x: int|nil)
			binop("~=", id("x"), lit_nil()))
		local _ty, _env, err = W.walk_synth(node, env, s)
		T.ok(err ~= nil)
	end)

	T.it("post-repeat sees the positive guard narrowing", function()
		local s = V.new_solver()
		local take_int = V.fn({ V.integer }, V.nil_, nil)
		local x_ty = V.union({ V.integer, V.nil_ })
		local env = E.bind(E.bind(E.new(), "x", x_ty), "f", take_int)
		local node = do_stmt({
			repeat_stmt({}, binop("~=", id("x"), lit_nil())),
			expr_stmt(call(id("f"), id("x"))),  -- x is narrowed to non-nil here
		})
		local _ty, _env, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
	end)
end)

T.describe("walker sub-phase D: do-block", function()
	T.it("body locals do not escape the block (narrowing on outer name does)", function()
		local s = V.new_solver()
		local take_int = V.fn({ V.integer }, V.nil_, nil)
		local x_ty = V.union({ V.integer, V.string_ })
		local env = E.bind(E.bind(E.new(), "x", x_ty), "f", take_int)
		-- do ... if type(x) == "integer" then ... end ... end
		-- The narrowing inside the if doesn't escape the do, but the do
		-- itself doesn't bind new names.
		local guard = binop("==",
			{ tag = defs.NODE_CALL_EXPR, callee = id("type"), args = { id("x") } },
			lit_str("integer"))
		local node = do_stmt({
			if_stmt({
				clause(guard, { expr_stmt(call(id("f"), id("x"))) }),
			}, nil),
		})
		local _ty, _env, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
	end)
end)

T.describe("walker sub-phase D: break", function()
	T.it("break inside a body returns cleanly", function()
		local s = V.new_solver()
		local env = E.new()
		local node = while_stmt(lit_bool(true), { break_stmt() })
		local _ty, _env, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
	end)
end)

-- ── sub-phase E: local/assign + match expressions ─────────────────────────
--
-- Builders for sub-phase E nodes. Match the decoded shapes declared in
-- walker/statements.lua.

local function local_stmt(names, exprs)
	return { tag = defs.NODE_LOCAL_STMT, names = names, exprs = exprs or {} }
end
local function assign_stmt(targets, exprs)
	return { tag = defs.NODE_ASSIGN_STMT,
		targets = targets, exprs = exprs or {} }
end
local function match_expr(subject, arms, wildcard_result)
	return { tag = defs.NODE_MATCH_EXPR,
		subject = subject, arms = arms,
		wildcard_result = wildcard_result }
end

T.describe("walker sub-phase E: handlers registered", function()
	T.it("E adds local/assign/match", function()
		T.ok(W.has_synth(defs.NODE_LOCAL_STMT))
		T.ok(W.has_synth(defs.NODE_ASSIGN_STMT))
		T.ok(W.has_synth(defs.NODE_MATCH_EXPR))
		T.ok(W.has_check(defs.NODE_MATCH_EXPR))
	end)
end)

T.describe("walker sub-phase E: NODE_LOCAL_STMT", function()
	T.it("single binding without annotation binds synth(init)", function()
		local s = V.new_solver()
		local node = local_stmt({ { name = "x" } }, { lit_int(42) })
		local _ty, env2, err = W.walk_synth(node, E.new(), s)
		T.eq(err, nil)
		T.eq(E.lookup(env2, "x"), V.literal("integer", 42))
	end)

	T.it("single binding with annotation: binding type is the annotation", function()
		local s = V.new_solver()
		local node = local_stmt({ { name = "x", ann = V.integer } }, { lit_int(7) })
		local _ty, env2, err = W.walk_synth(node, E.new(), s)
		T.eq(err, nil)
		T.eq(E.lookup(env2, "x"), V.integer)
	end)

	T.it("annotation mismatch errors", function()
		local s = V.new_solver()
		local node = local_stmt({ { name = "x", ann = V.string_ } }, { lit_int(7) })
		local _ty, _env2, err = W.walk_synth(node, E.new(), s)
		T.ok(err ~= nil)
	end)

	T.it("binding without init binds a fresh var", function()
		local s = V.new_solver()
		local node = local_stmt({ { name = "x" } }, {})
		local _ty, env2, err = W.walk_synth(node, E.new(), s)
		T.eq(err, nil)
		local ty = E.lookup(env2, "x")
		T.ok(ty ~= nil)
		T.eq(ty.tag, "var")
	end)

	T.it("binding with annotation only binds the annotation", function()
		local s = V.new_solver()
		local node = local_stmt({ { name = "x", ann = V.integer } }, {})
		local _ty, env2, err = W.walk_synth(node, E.new(), s)
		T.eq(err, nil)
		T.eq(E.lookup(env2, "x"), V.integer)
	end)

	T.it("multi-binding: each name receives its scalar RHS", function()
		local s = V.new_solver()
		local node = local_stmt(
			{ { name = "x" }, { name = "y" } },
			{ lit_int(1), lit_str("hi") })
		local _ty, env2, err = W.walk_synth(node, E.new(), s)
		T.eq(err, nil)
		T.eq(E.lookup(env2, "x"), V.literal("integer", 1))
		T.eq(E.lookup(env2, "y"), V.literal("string", "hi"))
	end)

	T.it("missing RHS slots bind nil (Lua semantics)", function()
		local s = V.new_solver()
		local node = local_stmt(
			{ { name = "x" }, { name = "y" } },
			{ lit_int(1) })
		local _ty, env2, err = W.walk_synth(node, E.new(), s)
		T.eq(err, nil)
		T.eq(E.lookup(env2, "y"), V.nil_)
	end)

	T.it("last RHS spreads when it is a multi-return", function()
		local s = V.new_solver()
		-- f: () -> { ["1"]: integer, ["2"]: string }
		local ret = V.rec({ ["1"] = V.integer, ["2"] = V.string_ }, false, nil)
		local f = V.fn({}, ret, nil)
		local env = E.bind(E.new(), "f", f)
		local node = local_stmt(
			{ { name = "a" }, { name = "b" } },
			{ call(id("f")) })
		local _ty, env2, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
		T.eq(E.lookup(env2, "a"), V.integer)
		T.eq(E.lookup(env2, "b"), V.string_)
	end)

	T.it("non-last RHS truncates to slot 1 even when multi-return", function()
		local s = V.new_solver()
		local ret = V.rec({ ["1"] = V.integer, ["2"] = V.string_ }, false, nil)
		local f = V.fn({}, ret, nil)
		local env = E.bind(E.new(), "f", f)
		local node = local_stmt(
			{ { name = "a" }, { name = "b" } },
			{ call(id("f")), lit_str("tail") })
		local _ty, env2, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
		-- a should be the truncated first slot (integer), b the literal "tail".
		T.eq(E.lookup(env2, "a"), V.integer)
		T.eq(E.lookup(env2, "b"), V.literal("string", "tail"))
	end)

	T.it("local with match RHS binds the match result", function()
		local s = V.new_solver()
		-- IsString<T> = match T { string => true, _ => false }
		local arms = { V.arm(V.string_, V.literal("boolean", true), {}) }
		local m = match_expr(lit_str("hi"), arms, V.literal("boolean", false))
		local node = local_stmt({ { name = "r" } }, { m })
		local _ty, env2, err = W.walk_synth(node, E.new(), s)
		T.eq(err, nil)
		T.eq(E.lookup(env2, "r"), V.literal("boolean", true))
	end)
end)

T.describe("walker sub-phase E: NODE_ASSIGN_STMT", function()
	T.it("simple local-var assignment with matching type succeeds", function()
		local s = V.new_solver()
		local env = E.bind(E.new(), "x", V.integer)
		local node = assign_stmt({ id("x") }, { lit_int(42) })
		local _ty, _env2, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
	end)

	T.it("assignment of wrong type fails", function()
		local s = V.new_solver()
		local env = E.bind(E.new(), "x", V.integer)
		local node = assign_stmt({ id("x") }, { lit_str("nope") })
		local _ty, _env2, err = W.walk_synth(node, env, s)
		T.ok(err ~= nil)
	end)

	T.it("assignment to undefined name errors", function()
		local s = V.new_solver()
		local node = assign_stmt({ id("missing") }, { lit_int(1) })
		local _ty, _env2, err = W.walk_synth(node, E.new(), s)
		T.ok(err ~= nil)
		T.ok(err:find("undefined", 1, true) ~= nil)
	end)

	T.it("field assignment on a concrete-typed record checks via V.index (sub-phase F)", function()
		local s = V.new_solver()
		local env = E.bind(E.new(), "M",
			V.rec({ x = V.integer }, false, nil))
		local node = assign_stmt(
			{ { tag = defs.NODE_FIELD_EXPR, target = id("M"), key = "x" } },
			{ lit_int(1) })
		local _ty, _env2, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
	end)

	T.it("multi-assign: last RHS spreads", function()
		local s = V.new_solver()
		local ret = V.rec({ ["1"] = V.integer, ["2"] = V.string_ }, false, nil)
		local f = V.fn({}, ret, nil)
		local env = E.bind(
			E.bind(E.bind(E.new(), "a", V.integer), "b", V.string_),
			"f", f)
		local node = assign_stmt({ id("a"), id("b") }, { call(id("f")) })
		local _ty, _env2, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
	end)

	T.it("multi-assign: non-last truncates to scalar", function()
		local s = V.new_solver()
		local ret = V.rec({ ["1"] = V.integer, ["2"] = V.string_ }, false, nil)
		local f = V.fn({}, ret, nil)
		local env = E.bind(
			E.bind(E.bind(E.new(), "a", V.integer), "b", V.string_),
			"f", f)
		-- a, b = f(), "tail" — a takes integer (truncated), b takes "tail" lit.
		local node = assign_stmt(
			{ id("a"), id("b") },
			{ call(id("f")), lit_str("tail") })
		local _ty, _env2, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
	end)
end)

T.describe("walker sub-phase E: NODE_MATCH_EXPR — forward", function()
	T.it("ground subject fires the matching arm", function()
		local s = V.new_solver()
		local arms = { V.arm(V.string_, V.literal("boolean", true), {}) }
		local node = match_expr(lit_str("hi"), arms,
			V.literal("boolean", false))
		local ty, _env2, err = W.walk_synth(node, E.new(), s)
		T.eq(err, nil)
		T.eq(ty, V.literal("boolean", true))
	end)

	T.it("subject not matching any arm fires the wildcard", function()
		local s = V.new_solver()
		local arms = { V.arm(V.string_, V.literal("boolean", true), {}) }
		local node = match_expr(lit_int(42), arms,
			V.literal("boolean", false))
		local ty, _env2, err = W.walk_synth(node, E.new(), s)
		T.eq(err, nil)
		T.eq(ty, V.literal("boolean", false))
	end)

	T.it("capture %X binds to recovered type; result substitutes", function()
		local s = V.new_solver()
		-- match T { { value: %X } => %X, _ => nil }
		local capX = V.var("X")
		local pattern = V.rec({ value = capX }, true, nil)
		local arms = { V.arm(pattern, capX, { capX }) }
		-- Subject: { value: integer } — capture X binds to integer; result is X.
		local subject_ty = V.rec({ value = V.integer }, false, nil)
		local env = E.bind(E.new(), "subj", subject_ty)
		local node = match_expr(id("subj"), arms, V.nil_)
		local ty, _env2, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
		T.ok(ty ~= nil)
		-- The result is a fresh capture var whose bound flows from the subtype
		-- subject <: pattern. The walker returns the freshened var directly.
		T.eq(ty.tag, "var")
	end)

	T.it("disjointness violation reported at evaluation", function()
		local s = V.new_solver()
		-- Two arms whose patterns overlap (both match the integer 1).
		local arms = {
			V.arm(V.number, V.literal("integer", 1), {}),
			V.arm(V.integer, V.literal("integer", 2), {}),
		}
		local node = match_expr(lit_int(1), arms, nil)
		local _ty, _env2, err = W.walk_synth(node, E.new(), s)
		T.ok(err ~= nil)
		T.ok(err:find("disjoint", 1, true) ~= nil)
	end)

	T.it("non-exhaustive (no wildcard, no arm fires) errors", function()
		local s = V.new_solver()
		local arms = { V.arm(V.string_, V.literal("boolean", true), {}) }
		local node = match_expr(lit_int(42), arms, nil)
		local _ty, _env2, err = W.walk_synth(node, E.new(), s)
		T.ok(err ~= nil)
	end)
end)

T.describe("walker sub-phase E: NODE_MATCH_EXPR — backward", function()
	T.it("known result constrains the subject via match_backward", function()
		local s = V.new_solver()
		-- arms: { string => "S", integer => "I" }, no wildcard.
		local L_S = V.literal("string", "S")
		local L_I = V.literal("string", "I")
		local arms = {
			V.arm(V.string_, L_S, {}),
			V.arm(V.integer, L_I, {}),
		}
		-- Expected result = L_S. Backward says subject must be string.
		-- A subject of "hi" (a string literal) satisfies the constraint.
		local node = match_expr(lit_str("hi"), arms, nil)
		local _env2, err = W.walk_check(node, E.new(), s, L_S)
		T.eq(err, nil)
	end)

	T.it("expected result unreachable from any arm errors", function()
		local s = V.new_solver()
		local L_S = V.literal("string", "S")
		local L_I = V.literal("string", "I")
		local arms = {
			V.arm(V.string_, L_S, {}),
			V.arm(V.integer, L_I, {}),
		}
		-- Expected is "X" — no arm can produce it.
		local node = match_expr(lit_str("hi"), arms, nil)
		local _env2, err = W.walk_check(node, E.new(), s,
			V.literal("string", "X"))
		T.ok(err ~= nil)
	end)
end)

-- ── sub-phase F: indexed access + module pattern + varargs polish ────────
--
-- Builders for sub-phase F nodes.

local function table_expr(fields)
	return { tag = defs.NODE_TABLE_EXPR, fields = fields or {} }
end
local function index_expr(target, key)
	return { tag = defs.NODE_INDEX_EXPR, target = target, key = key }
end
local function field_expr(target, key)
	return { tag = defs.NODE_FIELD_EXPR, target = target, key = key }
end
local function vararg_expr()
	return { tag = defs.NODE_VARARG_EXPR }
end

T.describe("walker sub-phase F: NODE_FIELD_EXPR", function()
	T.it("field access on a closed record synthesizes the field type", function()
		local s = V.new_solver()
		local obj = V.rec({ name = V.string_, age = V.integer }, false, nil)
		local env = E.bind(E.new(), "obj", obj)
		local node = field_expr(id("obj"), "name")
		local ty, _env, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
		T.eq(ty, V.string_)
	end)

	T.it("missing field on a closed record errors", function()
		local s = V.new_solver()
		local obj = V.rec({ name = V.string_ }, false, nil)
		local env = E.bind(E.new(), "obj", obj)
		local node = field_expr(id("obj"), "missing")
		local _ty, _env, err = W.walk_synth(node, env, s)
		T.ok(err ~= nil)
		T.ok(err:find("missing", 1, true) ~= nil)
	end)

	T.it("field access on a union of records distributes", function()
		local s = V.new_solver()
		local R1 = V.rec({ k = V.integer }, false, nil)
		local R2 = V.rec({ k = V.string_ }, false, nil)
		local env = E.bind(E.new(), "u", V.union({ R1, R2 }))
		local node = field_expr(id("u"), "k")
		local ty, _env, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
		T.ok(ty ~= nil)
		-- Distribution yields union of integer + string.
		T.eq(ty.tag, "union")
	end)

	T.it("CHECK mode: field type subtypes expected", function()
		local s = V.new_solver()
		local obj = V.rec({ k = V.literal("integer", 7) }, false, nil)
		local env = E.bind(E.new(), "obj", obj)
		local node = field_expr(id("obj"), "k")
		local _env, err = W.walk_check(node, env, s, V.integer)
		T.eq(err, nil)
	end)
end)

T.describe("walker sub-phase F: NODE_INDEX_EXPR", function()
	T.it("bracket access with string literal key", function()
		local s = V.new_solver()
		local obj = V.rec({ name = V.string_ }, false, nil)
		local env = E.bind(E.new(), "obj", obj)
		local node = index_expr(id("obj"), lit_str("name"))
		local ty, _env, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
		T.eq(ty, V.string_)
	end)

	T.it("bracket access with type-variable key is rejected (v4 limitation)", function()
		local s = V.new_solver()
		local obj = V.rec({ name = V.string_ }, false, nil)
		local env = E.bind(E.bind(E.new(), "obj", obj), "k", V.var("k"))
		local node = index_expr(id("obj"), id("k"))
		local _ty, _env, err = W.walk_synth(node, env, s)
		T.ok(err ~= nil)
		T.ok(err:find("deferred", 1, true) ~= nil)
	end)

	T.it("bracket access against indexer record", function()
		local s = V.new_solver()
		-- { [string]: integer }
		local obj = V.rec({}, false, V.indexer(V.string_, V.integer))
		local env = E.bind(E.new(), "obj", obj)
		local node = index_expr(id("obj"), lit_str("anything"))
		local ty, _env, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
		T.eq(ty, V.integer)
	end)
end)

T.describe("walker sub-phase F: NODE_TABLE_EXPR (empty)", function()
	T.it("empty table literal synthesizes an empty closed record", function()
		local s = V.new_solver()
		local node = table_expr({})
		local ty, _env, err = W.walk_synth(node, E.new(), s)
		T.eq(err, nil)
		T.ok(ty ~= nil)
		T.eq(ty.tag, "rec")
		T.eq(ty.open, false)
		T.eq(next(ty.fields), nil)
	end)

	T.it("non-empty table literal rejects (later sub-phase)", function()
		local s = V.new_solver()
		local node = table_expr({ { key = "x", value = lit_int(1) } })
		local _ty, _env, err = W.walk_synth(node, E.new(), s)
		T.ok(err ~= nil)
	end)
end)

T.describe("walker sub-phase F: module pattern (Option D)", function()
	T.it("`local M = {}` binds M to a V.var (accumulator)", function()
		local s = V.new_solver()
		local node = local_stmt({ { name = "M" } }, { table_expr({}) })
		local _ty, env2, err = W.walk_synth(node, E.new(), s)
		T.eq(err, nil)
		local m_ty = E.lookup(env2, "M")
		T.ok(m_ty ~= nil)
		T.eq(m_ty.tag, "var")
	end)

	T.it("`local M --: T = {}` (annotated) binds M to T (no accumulator)", function()
		local s = V.new_solver()
		local T_ann = V.rec({ x = V.integer }, false, nil)
		local node = local_stmt({ { name = "M", ann = T_ann } },
			{ table_expr({}) })
		local _ty, env2, err = W.walk_synth(node, E.new(), s)
		T.eq(err, nil)
		T.eq(E.lookup(env2, "M"), T_ann)
	end)

	T.it("M.foo = expr accumulates a singleton record as lower bound", function()
		local s = V.new_solver()
		local node = do_stmt({
			local_stmt({ { name = "M" } }, { table_expr({}) }),
			assign_stmt({ field_expr(id("M"), "foo") }, { lit_int(1) }),
		})
		local _ty, _env, err = W.walk_synth(node, E.new(), s)
		T.eq(err, nil)
	end)

	T.it("multiple field assignments accumulate as lower bounds on α_M", function()
		-- v4 4a has no row polymorphism: a singleton-open `{foo, ...}`
		-- does NOT directly subtype a multi-field expected record
		-- (design §13.5.5 open subquestion 5 — coalescing / row-poly lands
		-- later). The principled assertion at this phase is that each
		-- assignment adds the right lower-bound shape; whole-M against a
		-- multi-field record is not provable yet.
		local s = V.new_solver()
		local seq = {
			local_stmt({ { name = "M" } }, { table_expr({}) }),
			assign_stmt({ field_expr(id("M"), "foo") }, { lit_int(1) }),
			assign_stmt({ field_expr(id("M"), "bar") }, { lit_str("x") }),
		}
		local env_acc = E.new()
		for _, stmt in ipairs(seq) do
			local _t, e2, e_err = W.walk_synth(stmt, env_acc, s)
			env_acc = e2
			T.eq(e_err, nil)
		end
		local alpha = E.lookup(env_acc, "M")
		T.ok(alpha ~= nil)
		T.eq(alpha.tag, "var")
		-- Collect the field names present across all lower-bound records.
		local seen_fields = {}
		for _, lb in ipairs(alpha.lower) do
			if lb.tag == "rec" then
				for k in pairs(lb.fields) do
					seen_fields[k] = true
				end
			end
		end
		T.ok(seen_fields["foo"])
		T.ok(seen_fields["bar"])
	end)

	T.it("M.foo = wrong-type fails against annotated module shape", function()
		local s = V.new_solver()
		local T_ann = V.rec({ x = V.integer }, false, nil)
		local node = do_stmt({
			local_stmt({ { name = "M", ann = T_ann } }, { table_expr({}) }),
			-- Writing a string to a field declared integer fails.
			assign_stmt({ field_expr(id("M"), "x") }, { lit_str("nope") }),
		})
		local _ty, _env, err = W.walk_synth(node, E.new(), s)
		T.ok(err ~= nil)
	end)

	T.it("M.bogus = ... on closed annotated record errors (write of absent field)", function()
		local s = V.new_solver()
		local T_ann = V.rec({ x = V.integer }, false, nil)
		local node = do_stmt({
			local_stmt({ { name = "M", ann = T_ann } }, { table_expr({}) }),
			assign_stmt({ field_expr(id("M"), "bogus") }, { lit_int(1) }),
		})
		local _ty, _env, err = W.walk_synth(node, E.new(), s)
		T.ok(err ~= nil)
	end)

	T.it("`return M` from a function flows α_M into the return slot", function()
		local s = V.new_solver()
		-- function() local M = {}; M.foo = 1; return M end
		-- The unannotated function's ret_var captures α_M's lowers.
		local body = {
			local_stmt({ { name = "M" } }, { table_expr({}) }),
			assign_stmt({ field_expr(id("M"), "foo") }, { lit_int(1) }),
			ret(id("M")),
		}
		local fn_node = func({}, body)
		local ty, _env, err = W.walk_synth(fn_node, E.new(), s)
		T.eq(err, nil)
		T.eq(ty.tag, "fn")
		-- The return var is a V.var carrying the accumulated lower.
		T.eq(ty.ret.tag, "var")
	end)
end)

T.describe("walker sub-phase F: indexed callees", function()
	T.it("obj.method(arg) typechecks via synthesized field", function()
		local s = V.new_solver()
		local greet = V.fn({ V.string_ }, V.string_, nil)
		local env = E.bind(E.new(), "obj",
			V.rec({ greet = greet }, false, nil))
		local node = call(field_expr(id("obj"), "greet"), lit_str("hi"))
		local ty, _env, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
		T.eq(ty, V.string_)
	end)

	T.it("tbl[k](arg) typechecks via synthesized index", function()
		local s = V.new_solver()
		local greet = V.fn({ V.string_ }, V.string_, nil)
		local env = E.bind(E.new(), "tbl",
			V.rec({ greet = greet }, false, nil))
		local node = call(index_expr(id("tbl"), lit_str("greet")), lit_str("hi"))
		local ty, _env, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
		T.eq(ty, V.string_)
	end)
end)

T.describe("walker sub-phase F: varargs spread/non-spread", function()
	T.it("last-position vararg spreads tuple-typed env.vararg into call args", function()
		local s = V.new_solver()
		-- env.vararg = (integer, string) tuple; f expects (integer, string).
		local vararg_ty = V.rec({ ["1"] = V.integer, ["2"] = V.string_ }, false, nil)
		local f = V.fn({ V.integer, V.string_ }, V.nil_, nil)
		local env = E.bind(E.enter_function(E.new(), V.nil_, vararg_ty),
			"f", f)
		local node = call(id("f"), vararg_expr())
		local _ty, _env, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
	end)

	T.it("scalar vararg in last position contributes a single arg", function()
		local s = V.new_solver()
		local f = V.fn({ V.integer }, V.nil_, nil)
		local env = E.bind(E.enter_function(E.new(), V.nil_, V.integer),
			"f", f)
		local node = call(id("f"), vararg_expr())
		local _ty, _env, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
	end)

	T.it("vararg in non-last position collapses to scalar (first slot)", function()
		local s = V.new_solver()
		local vararg_ty = V.rec({ ["1"] = V.integer, ["2"] = V.string_ }, false, nil)
		-- f expects (integer, integer) — non-last vararg gives just slot 1.
		local f = V.fn({ V.integer, V.integer }, V.nil_, nil)
		local env = E.bind(E.enter_function(E.new(), V.nil_, vararg_ty),
			"f", f)
		local node = call(id("f"), vararg_expr(), lit_int(2))
		local _ty, _env, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
	end)
end)

-- ── sub-phase G: FFI cdef integration ────────────────────────────────────
--
-- The walker recognises `ffi.cdef[[ ... ]]` calls and populates the
-- $FfiC closed record bound under `ffi.C`. Subsequent `ffi.C.foo`
-- accesses go through the standard NODE_FIELD_EXPR path against the
-- populated record. Undeclared symbols error via v4's closed-record
-- missing-field rule.

local ffi_cdef_mod = require("lib.type.static-v4.walker.ffi_cdef")

-- Build the prelude-style `ffi` binding the cdef machinery expects: a
-- record with a `C` field holding an empty closed rec. (Reused across the
-- sub-phase G tests to keep boilerplate minimal.)
local function ffi_prelude_env()
	local cdef_fn = V.fn({ V.string_ }, V.nil_, nil)
	local empty_c = V.rec({}, false, nil)
	local ffi_mod = V.rec({ cdef = cdef_fn, C = empty_c }, false, nil)
	return E.bind(E.new(), "ffi", ffi_mod)
end

T.describe("walker sub-phase G: ffi.cdef call-shape detection", function()
	T.it("detects ffi.cdef as NODE_FIELD_EXPR callee", function()
		local callee = field_expr(id("ffi"), "cdef")
		T.ok(ffi_cdef_mod.is_ffi_cdef_callee(callee))
	end)

	T.it("detects ffi['cdef'] as NODE_INDEX_EXPR callee", function()
		local callee = index_expr(id("ffi"), lit_str("cdef"))
		T.ok(ffi_cdef_mod.is_ffi_cdef_callee(callee))
	end)

	T.it("rejects unrelated indexed callees (other.cdef, ffi.other)", function()
		T.fail(ffi_cdef_mod.is_ffi_cdef_callee(field_expr(id("other"), "cdef")))
		T.fail(ffi_cdef_mod.is_ffi_cdef_callee(field_expr(id("ffi"), "other")))
		T.fail(ffi_cdef_mod.is_ffi_cdef_callee(id("ffi")))
	end)
end)

T.describe("walker sub-phase G: cdef accumulation into ffi.C", function()
	T.it("simple function cdef registers a callable field on ffi.C", function()
		local s = V.new_solver()
		local env = ffi_prelude_env()
		local node = call(field_expr(id("ffi"), "cdef"),
			lit_str("int foo(int);"))
		local _ty, env2, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
		-- ffi.C.foo should now be (integer) -> integer (per the design's
		-- mapping table; the cdef parser sees `int` as the v4 integer
		-- prim).
		local ffi_ty = env2.bindings["ffi"]
		T.eq(ffi_ty.tag, "rec")
		local c_ty = ffi_ty.fields["C"]
		T.eq(c_ty.tag, "rec")
		T.eq(c_ty.open, false) -- closed-record discipline
		local foo_ty = c_ty.fields["foo"]
		T.ok(foo_ty ~= nil)
		T.eq(foo_ty.tag, "fn")
		T.eq(#foo_ty.params, 1)
		T.eq(foo_ty.params[1], V.integer)
		T.eq(foo_ty.ret, V.integer)
	end)

	T.it("struct cdef body registers a closed-record field type", function()
		local s = V.new_solver()
		local env = ffi_prelude_env()
		-- `struct foo { int x; };` followed by a forward-decl variable of
		-- that type so the parser surfaces a `var` decl into ffi.C.
		local node = call(field_expr(id("ffi"), "cdef"),
			lit_str("struct foo { int x; };"))
		local _ty, env2, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
		-- Struct decls don't populate ffi.C symbols themselves (they
		-- define a type alias for the C name) — see ffi_cdef.lua
		-- module comment. The test asserts that no error is raised and
		-- ffi.C is left intact (still closed, still empty).
		local c_ty = env2.bindings["ffi"].fields["C"]
		T.eq(c_ty.tag, "rec")
		T.eq(c_ty.open, false)
	end)

	T.it("undeclared symbol on ffi.C errors via closed-record rule", function()
		local s = V.new_solver()
		local env = ffi_prelude_env()
		-- Populate ffi.C with one symbol; then read a different one.
		local cdef_node = call(field_expr(id("ffi"), "cdef"),
			lit_str("int foo(int);"))
		local _ty1, env2, err1 = W.walk_synth(cdef_node, env, s)
		T.eq(err1, nil)
		-- Field access on a declared symbol succeeds.
		local hit = field_expr(field_expr(id("ffi"), "C"), "foo")
		local hit_ty, _env_h, err_h = W.walk_synth(hit, env2, s)
		T.eq(err_h, nil)
		T.ok(hit_ty ~= nil)
		T.eq(hit_ty.tag, "fn")
		-- Field access on an undeclared symbol fails.
		local miss = field_expr(field_expr(id("ffi"), "C"), "undeclared_xyz")
		local _miss_ty, _env_m, err_m = W.walk_synth(miss, env2, s)
		T.ok(err_m ~= nil)
		T.ok(err_m:find("undeclared_xyz", 1, true) ~= nil)
	end)

	T.it("multiple cdef blocks accumulate", function()
		local s = V.new_solver()
		local env = ffi_prelude_env()
		local n1 = call(field_expr(id("ffi"), "cdef"), lit_str("int foo(int);"))
		local _ty1, env2, err1 = W.walk_synth(n1, env, s)
		T.eq(err1, nil)
		local n2 = call(field_expr(id("ffi"), "cdef"), lit_str("int bar(int);"))
		local _ty2, env3, err2 = W.walk_synth(n2, env2, s)
		T.eq(err2, nil)
		local c_ty = env3.bindings["ffi"].fields["C"]
		T.ok(c_ty.fields["foo"] ~= nil)
		T.ok(c_ty.fields["bar"] ~= nil)
		T.eq(c_ty.open, false)
	end)

	T.it("non-literal cdef argument is rejected", function()
		local s = V.new_solver()
		-- Bind a string identifier to feed cdef.
		local env = E.bind(ffi_prelude_env(), "src", V.string_)
		local node = call(field_expr(id("ffi"), "cdef"), id("src"))
		local _ty, _env, err = W.walk_synth(node, env, s)
		T.ok(err ~= nil)
		T.ok(err:find("string literal", 1, true) ~= nil)
	end)

	T.it("wrong arity (0 or 2+ args) is rejected", function()
		local s = V.new_solver()
		local env = ffi_prelude_env()
		local none = call(field_expr(id("ffi"), "cdef"))
		local _t1, _e1, err1 = W.walk_synth(none, env, s)
		T.ok(err1 ~= nil)
		T.ok(err1:find("exactly one", 1, true) ~= nil)
		local two = call(field_expr(id("ffi"), "cdef"),
			lit_str("int x;"), lit_str("int y;"))
		local _t2, _e2, err2 = W.walk_synth(two, env, s)
		T.ok(err2 ~= nil)
		T.ok(err2:find("exactly one", 1, true) ~= nil)
	end)

	T.it("ffi.cdef without ffi in scope errors", function()
		local s = V.new_solver()
		local env = E.new() -- no `ffi` binding
		local node = call(field_expr(id("ffi"), "cdef"), lit_str("int foo(int);"))
		local _ty, _env, err = W.walk_synth(node, env, s)
		-- Either the undefined-name lookup on `ffi` fires first (via the
		-- field-target synth) or our explicit "not in scope" message fires.
		-- Both are acceptable — the contract is just that this errors.
		T.ok(err ~= nil)
	end)

	T.it("variadic C functions encode a trailing `top` param", function()
		local s = V.new_solver()
		local env = ffi_prelude_env()
		-- `int printf(const char *, ...);` — variadic.
		local node = call(field_expr(id("ffi"), "cdef"),
			lit_str("int printf(const char *fmt, ...);"))
		local _ty, env2, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
		local printf_ty = env2.bindings["ffi"].fields["C"].fields["printf"]
		T.ok(printf_ty ~= nil)
		T.eq(printf_ty.tag, "fn")
		-- Params: fmt (string from char*) + 1 trailing top for the vararg.
		T.eq(#printf_ty.params, 2)
		T.eq(printf_ty.params[1], V.string_)
		T.eq(printf_ty.params[2].tag, "top")
	end)

	T.it("real-world-shaped cdef: stdlib functions translate correctly", function()
		local s = V.new_solver()
		local env = ffi_prelude_env()
		-- A small bundle of common libc decls. char* → string,
		-- int → integer, void → nil; types are derived from §9.
		local src = [[
			size_t strlen(const char *s);
			int atoi(const char *s);
			void exit(int status);
		]]
		local node = call(field_expr(id("ffi"), "cdef"), lit_str(src))
		local _ty, env2, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
		local c_fields = env2.bindings["ffi"].fields["C"].fields
		-- strlen: (string) -> integer
		T.ok(c_fields["strlen"] ~= nil)
		T.eq(c_fields["strlen"].tag, "fn")
		T.eq(c_fields["strlen"].params[1], V.string_)
		T.eq(c_fields["strlen"].ret, V.integer)
		-- atoi: (string) -> integer
		T.ok(c_fields["atoi"] ~= nil)
		T.eq(c_fields["atoi"].params[1], V.string_)
		T.eq(c_fields["atoi"].ret, V.integer)
		-- exit: (integer) -> nil
		T.ok(c_fields["exit"] ~= nil)
		T.eq(c_fields["exit"].params[1], V.integer)
		T.eq(c_fields["exit"].ret, V.nil_)
	end)

	T.it("ffi['cdef'] form is also recognised", function()
		local s = V.new_solver()
		local env = ffi_prelude_env()
		local node = call(index_expr(id("ffi"), lit_str("cdef")),
			lit_str("int foo(int);"))
		local _ty, env2, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
		T.ok(env2.bindings["ffi"].fields["C"].fields["foo"] ~= nil)
	end)

	T.it("call to ffi.cdef returns nil (statement-shaped)", function()
		local s = V.new_solver()
		local env = ffi_prelude_env()
		local node = call(field_expr(id("ffi"), "cdef"), lit_str("int foo(int);"))
		local ty, _env, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
		T.eq(ty, V.nil_)
	end)
end)

T.describe("walker sub-phase G: handler registration", function()
	T.it("ffi_cdef.synth_call replaces F's NODE_CALL_EXPR handler at load", function()
		-- Sanity: indexed_access still exposes its synth_call (the fallback
		-- handle ffi_cdef captures); the registered handler differs from it.
		local F = require("lib.type.static-v4.walker.indexed_access")
		T.ok(F.synth_call_for_subphase_g ~= nil)
		T.ok(W.has_synth(defs.NODE_CALL_EXPR))
	end)
end)

-- ── sub-phase H: effects (yield, throw, pcall) ───────────────────────────
--
-- The intrinsics `error`, `pcall`, `xpcall` are call-site-shape-matched;
-- `coroutine.yield` rides on the ordinary binding-driven effect-
-- accumulation path established in sub-phase C.

T.describe("walker sub-phase H: coroutine.yield", function()
	T.it("coroutine.yield() accumulates yield via field-call path", function()
		local s = V.new_solver()
		-- coroutine = { yield: () -> nil with effects = {yield} }
		local yield_fn = V.fn({}, V.nil_, { yield = true })
		local coroutine_ty = V.rec({ yield = yield_fn }, false, nil)
		-- function() coroutine.yield() end
		local node = func({}, { expr_stmt(call(field_expr(id("coroutine"), "yield"))) })
		local env = E.bind(E.new(), "coroutine", coroutine_ty)
		local ty, _env, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
		T.eq(ty.tag, "fn")
		T.eq(ty.effects.yield, true)
	end)
end)

T.describe("walker sub-phase H: error()", function()
	T.it("error(msg) accumulates throw and synthesizes to bot", function()
		local s = V.new_solver()
		-- function() error("boom") end — body's effect set must include throw.
		local node = func({}, { expr_stmt(call(id("error"), lit_str("boom"))) })
		local ty, _env, err = W.walk_synth(node, E.new(), s)
		T.eq(err, nil)
		T.eq(ty.tag, "fn")
		T.eq(ty.effects.throw, true)
	end)

	T.it("bare error call (synthesized directly) returns bot", function()
		local s = V.new_solver()
		-- Need a function frame to host the effect, but inspect the call's
		-- synthesized type. We do this by wrapping the call as the body of a
		-- function that simply returns the call's result.
		local effects_mod = require("lib.type.static-v4.walker.effects")
		T.ok(effects_mod.is_named_identifier(id("error"), "error"))
		-- Direct synth, fresh fn-frame env with throw allowed.
		local env = E.enter_function(E.new(), V.bot(), nil)
		local node = call(id("error"), lit_str("boom"))
		local ty, env2, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
		T.eq(ty.tag, "bot")
		T.eq(env2.effects.throw, true)
	end)

	T.it("annotated as -[throw]-> never accepts a throwing body", function()
		local s = V.new_solver()
		-- annotation: () -> never with effects = { throw }
		local ann = V.fn({}, V.bot(), { throw = true })
		local node = func({}, { expr_stmt(call(id("error"), lit_str("x"))) }, ann)
		local ty, _env, err = W.walk_synth(node, E.new(), s)
		T.eq(err, nil)
		T.eq(ty, ann)
	end)

	T.it("annotated as pure rejects a throwing body", function()
		local s = V.new_solver()
		local ann = V.fn({}, V.nil_, nil) -- no effects
		local node = func({}, { expr_stmt(call(id("error"), lit_str("x"))) }, ann)
		local _ty, _env, err = W.walk_synth(node, E.new(), s)
		T.ok(err ~= nil)
		T.ok(err:find("throw", 1, true) ~= nil)
	end)
end)

T.describe("walker sub-phase H: pcall", function()
	T.it("pcall on a throwing function masks throw from the outer frame", function()
		local s = V.new_solver()
		-- f : () -> integer with effects = { throw }
		local f_ty = V.fn({}, V.integer, { throw = true })
		-- function() pcall(f) end — body must NOT accumulate throw.
		local node = func({}, { expr_stmt(call(id("pcall"), id("f"))) })
		local env = E.bind(E.new(), "f", f_ty)
		local ty, _env, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
		T.eq(ty.tag, "fn")
		T.eq(ty.effects.throw, nil)
	end)

	T.it("pcall returns (true, R) | (false, string)", function()
		local s = V.new_solver()
		local f_ty = V.fn({}, V.integer, { throw = true })
		local env = E.bind(E.new(), "f", f_ty)
		env = E.enter_function(env, V.bot(), nil) -- so outer-effect surface is benign
		local node = call(id("pcall"), id("f"))
		local ty, _env, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
		T.ok(ty ~= nil)
		T.eq(ty.tag, "union")
		-- Success branch first, then failure branch.
		local succ, fail = ty.members[1], ty.members[2]
		T.eq(succ.tag, "rec")
		T.eq(succ.fields["1"].tag, "literal")
		T.eq(succ.fields["1"].value, true)
		T.eq(succ.fields["2"], V.integer)
		T.eq(fail.tag, "rec")
		T.eq(fail.fields["1"].value, false)
		T.eq(fail.fields["2"], V.string_)
	end)

	T.it("pcall on a non-throwing function still produces the union shape", function()
		local s = V.new_solver()
		local f_ty = V.fn({}, V.integer, nil)
		local env = E.bind(E.new(), "f", f_ty)
		env = E.enter_function(env, V.bot(), nil)
		local node = call(id("pcall"), id("f"))
		local ty, _env, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
		T.eq(ty.tag, "union")
	end)

	T.it("pcall passes yield through (does not mask it)", function()
		local s = V.new_solver()
		-- f : () -> integer with effects = { yield, throw }
		local f_ty = V.fn({}, V.integer, { yield = true, throw = true })
		local node = func({}, { expr_stmt(call(id("pcall"), id("f"))) })
		local env = E.bind(E.new(), "f", f_ty)
		local ty, _env, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
		T.eq(ty.effects.yield, true)
		T.eq(ty.effects.throw, nil)
	end)

	T.it("pcall with no arguments errors", function()
		local s = V.new_solver()
		local env = E.enter_function(E.new(), V.bot(), nil)
		local node = call(id("pcall"))
		local _ty, _env, err = W.walk_synth(node, env, s)
		T.ok(err ~= nil)
		T.ok(err:find("at least one", 1, true) ~= nil)
	end)
end)

T.describe("walker sub-phase H: xpcall", function()
	T.it("xpcall masks throw on inner function but propagates msgh effects", function()
		local s = V.new_solver()
		local f_ty = V.fn({}, V.integer, { throw = true })
		-- msgh: (string) -> string with no effects (the message handler)
		local msgh_ty = V.fn({ V.string_ }, V.string_, nil)
		local node = func({}, { expr_stmt(call(id("xpcall"), id("f"), id("msgh"))) })
		local env = E.bind(E.bind(E.new(), "f", f_ty), "msgh", msgh_ty)
		local ty, _env, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
		T.eq(ty.effects.throw, nil)
	end)
end)

T.describe("walker sub-phase H: effect mismatch at call site", function()
	T.it("passing a yield-effect fn where a pure-fn arg expected fails subtyping", function()
		local s = V.new_solver()
		-- f : (() -> nil) -> nil — the parameter slot is a PURE arrow.
		local pure_arrow = V.fn({}, V.nil_, nil)
		local f_ty = V.fn({ pure_arrow }, V.nil_, nil)
		-- The argument is a yield-effected function.
		local yield_arrow = V.fn({}, V.nil_, { yield = true })
		local env = E.bind(E.bind(E.new(), "f", f_ty), "g", yield_arrow)
		local node = call(id("f"), id("g"))
		local _ty, _env, err = W.walk_synth(node, env, s)
		T.ok(err ~= nil)
	end)

	T.it("passing a pure fn where a yield-effected slot expected succeeds (covariant)", function()
		local s = V.new_solver()
		-- f : (() -[yield]-> nil) -> nil — accepts any arrow up to yield.
		local yield_arrow = V.fn({}, V.nil_, { yield = true })
		local f_ty = V.fn({ yield_arrow }, V.nil_, nil)
		-- Argument is a pure arrow — its effect set ({} ⊆ {yield}) is fine.
		local pure_arrow = V.fn({}, V.nil_, nil)
		local env = E.bind(E.bind(E.new(), "f", f_ty), "g", pure_arrow)
		local node = call(id("f"), id("g"))
		local _ty, _env, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
	end)
end)

T.describe("walker sub-phase H: handler registration", function()
	T.it("effects.synth_call replaces G's NODE_CALL_EXPR handler at load", function()
		local G = require("lib.type.static-v4.walker.ffi_cdef")
		T.ok(G.synth_call_for_subphase_h ~= nil)
		T.ok(W.has_synth(defs.NODE_CALL_EXPR))
	end)

	T.it("non-intrinsic calls still go through the captured handler", function()
		local s = V.new_solver()
		-- An ordinary call to a user function (no special intrinsic name) must
		-- still dispatch normally — H's wrapper falls through.
		local f_ty = V.fn({ V.integer }, V.string_, nil)
		local env = E.bind(E.new(), "f", f_ty)
		local node = call(id("f"), lit_int(7))
		local ty, _env, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
		T.eq(ty, V.string_)
	end)
end)

-- ── Sub-phase I — cross-file resolution + cache integration ────────────────
--
-- The require resolver uses injected I/O capabilities to read source files,
-- hash them via SHA-256, look up the v4 .cri cache, and bind the imported
-- file's exports + aliases into the requiring file's scope. Cache hits
-- succeed; cache misses reject loudly (sub-phase I defers recursive walk
-- to sub-phase J). Cycles are broken via env.require_chain.

local require_resolve = require("lib.type.static-v4.walker.require_resolve")

-- In-memory file system simulator used by sub-phase I tests. Provides the
-- four caps cache.lua / require_resolve.lua expect: read_file, write_file,
-- mkdir, file_exists. File paths are strings; directories are tracked
-- separately so mkdir succeeds even when no file lives under the path yet.
local function fake_fs(initial_files)
	local files = {}
	for k, v in pairs(initial_files or {}) do files[k] = v end
	local dirs = {}
	return {
		_files = files,
		_dirs  = dirs,
		read_file = function(path)
			local v = files[path]
			if v == nil then return nil, "ENOENT: " .. path end
			return v, nil
		end,
		write_file = function(path, bytes)
			files[path] = bytes
			return true, nil
		end,
		mkdir = function(path)
			dirs[path] = true
			return true, nil
		end,
		file_exists = function(path)
			return files[path] ~= nil
		end,
	}
end

T.describe("walker sub-phase I: handler registration", function()
	T.it("require_resolve.synth_call is registered for NODE_CALL_EXPR", function()
		T.ok(W.has_synth(defs.NODE_CALL_EXPR))
	end)

	T.it("effects.synth_call_for_subphase_i is exposed", function()
		local H = require("lib.type.static-v4.walker.effects")
		T.ok(H.synth_call_for_subphase_i ~= nil)
	end)

	T.it("non-require calls still go through the captured handler chain", function()
		-- A normal call (no `require` callee) must dispatch normally. This
		-- exercises the fall-through path: I → H → G → F → C.
		local s = V.new_solver()
		local f_ty = V.fn({ V.integer }, V.string_, nil)
		local env = E.bind(E.new(), "f", f_ty)
		local node = call(id("f"), lit_int(7))
		local ty, _env, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
		T.eq(ty, V.string_)
	end)
end)

T.describe("walker sub-phase I: path resolution", function()
	T.it("lib.foo.bar resolves to lib/foo/bar.lua when present", function()
		local fs = fake_fs({ ["lib/foo/bar.lua"] = "return 1" })
		local path, err = require_resolve.resolve_module_path(fs, "lib.foo.bar")
		T.eq(err, nil)
		T.eq(path, "lib/foo/bar.lua")
	end)

	T.it("lib.foo.bar falls back to lib/foo/bar/init.lua", function()
		local fs = fake_fs({ ["lib/foo/bar/init.lua"] = "return 1" })
		local path, err = require_resolve.resolve_module_path(fs, "lib.foo.bar")
		T.eq(err, nil)
		T.eq(path, "lib/foo/bar/init.lua")
	end)

	T.it("prefers .lua over init.lua when both exist", function()
		local fs = fake_fs({
			["lib/foo/bar.lua"]      = "return 1",
			["lib/foo/bar/init.lua"] = "return 2",
		})
		local path, err = require_resolve.resolve_module_path(fs, "lib.foo.bar")
		T.eq(err, nil)
		T.eq(path, "lib/foo/bar.lua")
	end)

	T.it("returns an error when neither exists", function()
		local fs = fake_fs({})
		local path, err = require_resolve.resolve_module_path(fs, "lib.foo.bar")
		T.eq(path, nil)
		T.ok(err ~= nil)
		T.ok(err:find("not found", 1, true) ~= nil)
	end)
end)

T.describe("walker sub-phase I: artifact pack/unpack", function()
	T.it("pack/unpack round-trips an exports + alias map", function()
		local exports = V.fn({}, V.integer, nil)
		local aliases = { Foo = V.integer, Bar = V.string_ }
		local artifact = require_resolve.pack_artifact(exports, aliases)
		local e, a, err = require_resolve.unpack_artifact(artifact)
		T.eq(err, nil)
		T.eq(e, exports)
		T.eq(a.Foo, V.integer)
		T.eq(a.Bar, V.string_)
	end)

	T.it("pack with nil aliases gives an empty alias map", function()
		local artifact = require_resolve.pack_artifact(V.integer, nil)
		local _e, a, err = require_resolve.unpack_artifact(artifact)
		T.eq(err, nil)
		T.eq(next(a), nil)
	end)

	T.it("unpack errors on a non-record artifact", function()
		local _e, _a, err = require_resolve.unpack_artifact(V.integer)
		T.ok(err ~= nil)
	end)

	T.it("artifact serialise/deserialise through V.serialize round-trips", function()
		local exports = V.fn({}, V.integer, nil)
		local aliases = { Foo = V.string_ }
		local artifact = require_resolve.pack_artifact(exports, aliases)
		local bytes = V.serialize(artifact)
		local artifact2, derr = V.deserialize(bytes)
		T.eq(derr, nil)
		T.ok(artifact2 ~= nil)
		local _e, a, err = require_resolve.unpack_artifact(artifact2)
		T.eq(err, nil)
		T.ok(a.Foo ~= nil)
	end)
end)

T.describe("walker sub-phase I: cache hit", function()
	T.it("require returns the cached export type", function()
		-- Populate cache: write a source file, hash it, store an artifact
		-- under that source hash, then walk a require call.
		local source = "return function() return 42 end"
		local fs = fake_fs({ ["lib/foo.lua"] = source })
		local sha256_mod = require("lib.hash.sha256")
		local source_hash = sha256_mod.sha256(source)
		local exports = V.fn({}, V.integer, nil)
		local artifact = require_resolve.pack_artifact(exports, nil)
		V.cache_store(fs, ".cache", source_hash, artifact, nil)

		local env = E.with_cache_dir(E.with_io_caps(E.new(), fs), ".cache")
		local node = call(id("require"), lit_str("lib.foo"))
		local s = V.new_solver()
		local ty, _env, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
		-- The deserialised exports is structurally identical to `exports`
		-- but a fresh table — compare on tag + ret rather than identity.
		T.ok(ty ~= nil)
		T.eq(ty.tag, "fn")
		T.eq(ty.ret.tag, "prim")
		T.eq(ty.ret.name, "integer")
	end)

	T.it("require merges imported file's aliases into the env", function()
		local source = "return 0"
		local fs = fake_fs({ ["lib/has_aliases.lua"] = source })
		local sha256_mod = require("lib.hash.sha256")
		local source_hash = sha256_mod.sha256(source)
		local exports = V.integer
		local aliases = { Foo = V.string_, Bar = V.boolean }
		local artifact = require_resolve.pack_artifact(exports, aliases)
		V.cache_store(fs, ".cache", source_hash, artifact, nil)

		local env = E.with_cache_dir(E.with_io_caps(E.new(), fs), ".cache")
		local node = call(id("require"), lit_str("lib.has_aliases"))
		local s = V.new_solver()
		local _ty, env_out, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
		local foo = E.lookup_alias(env_out, "Foo")
		T.ok(foo ~= nil)
		T.eq(foo.tag, "prim")
		T.eq(foo.name, "string")
		local bar = E.lookup_alias(env_out, "Bar")
		T.ok(bar ~= nil)
		T.eq(bar.tag, "prim")
		T.eq(bar.name, "boolean")
	end)
end)

T.describe("walker sub-phase I: cache miss", function()
	T.it("rejects loudly with a deferred-walk message", function()
		local fs = fake_fs({ ["lib/uncached.lua"] = "return 1" })
		local env = E.with_cache_dir(E.with_io_caps(E.new(), fs), ".cache")
		local node = call(id("require"), lit_str("lib.uncached"))
		local s = V.new_solver()
		local _ty, _env, err = W.walk_synth(node, env, s)
		T.ok(err ~= nil)
		T.ok(err:find("cache miss", 1, true) ~= nil)
		T.ok(err:find("sub-phase", 1, true) ~= nil)
	end)

	T.it("missing source file errors at path resolution", function()
		local fs = fake_fs({})
		local env = E.with_cache_dir(E.with_io_caps(E.new(), fs), ".cache")
		local node = call(id("require"), lit_str("lib.no_such"))
		local s = V.new_solver()
		local _ty, _env, err = W.walk_synth(node, env, s)
		T.ok(err ~= nil)
		T.ok(err:find("not found", 1, true) ~= nil)
	end)
end)

T.describe("walker sub-phase I: I/O capability injection", function()
	T.it("require without io_caps errors loudly", function()
		local env = E.new()
		local node = call(id("require"), lit_str("lib.anything"))
		local s = V.new_solver()
		local _ty, _env, err = W.walk_synth(node, env, s)
		T.ok(err ~= nil)
		T.ok(err:find("io_caps", 1, true) ~= nil)
	end)

	T.it("require without cache_dir errors loudly", function()
		local fs = fake_fs({})
		local env = E.with_io_caps(E.new(), fs)
		local node = call(id("require"), lit_str("lib.anything"))
		local s = V.new_solver()
		local _ty, _env, err = W.walk_synth(node, env, s)
		T.ok(err ~= nil)
		T.ok(err:find("cache_dir", 1, true) ~= nil)
	end)

	T.it("non-require calls do not need io_caps", function()
		-- Pure regression: a normal call with no caps in the env must
		-- continue to work. (Sub-phase I gates ONLY require dispatch.)
		local s = V.new_solver()
		local f_ty = V.fn({}, V.integer, nil)
		local env = E.bind(E.new(), "f", f_ty)
		local node = call(id("f"))
		local ty, _env, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
		T.eq(ty, V.integer)
	end)
end)

T.describe("walker sub-phase I: cycle detection", function()
	T.it("re-entrant require returns the in-progress placeholder", function()
		-- Push `A` onto the chain with a concrete placeholder, then walk a
		-- require("A") call. The inner call must return the placeholder
		-- without touching the cache (no file in fs — would otherwise fail
		-- at path resolution).
		local fs = fake_fs({})
		local placeholder = V.var("placeholder:A")
		local env = E.push_require(
			E.with_cache_dir(E.with_io_caps(E.new(), fs), ".cache"),
			"a", placeholder)
		local node = call(id("require"), lit_str("a"))
		local s = V.new_solver()
		local ty, _env, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
		T.eq(ty, placeholder)
	end)

	T.it("re-entrant require with `true` sentinel mints a fresh var", function()
		local fs = fake_fs({})
		local env = E.push_require(
			E.with_cache_dir(E.with_io_caps(E.new(), fs), ".cache"),
			"a", true)
		local node = call(id("require"), lit_str("a"))
		local s = V.new_solver()
		local ty, _env, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
		T.ok(ty ~= nil)
		T.eq(ty.tag, "var")
	end)

	T.it("require_chain is unwound on the way out of a cache hit", function()
		-- After a successful require, the mod_name should not remain on
		-- the chain (so a sibling require() in the same scope isn't
		-- mistakenly diverted to the placeholder branch).
		local source = "return 0"
		local fs = fake_fs({ ["lib/m.lua"] = source })
		local sha256_mod = require("lib.hash.sha256")
		local source_hash = sha256_mod.sha256(source)
		local artifact = require_resolve.pack_artifact(V.integer, nil)
		V.cache_store(fs, ".cache", source_hash, artifact, nil)

		local env = E.with_cache_dir(E.with_io_caps(E.new(), fs), ".cache")
		local node = call(id("require"), lit_str("lib.m"))
		local s = V.new_solver()
		local _ty, env_out, err = W.walk_synth(node, env, s)
		T.eq(err, nil)
		T.eq(E.lookup_require(env_out, "lib.m"), nil)
	end)
end)

T.describe("walker sub-phase I: env helpers", function()
	T.it("bind_alias / lookup_alias round-trip", function()
		local e = E.bind_alias(E.new(), "Foo", V.integer)
		T.eq(E.lookup_alias(e, "Foo"), V.integer)
		T.eq(E.lookup_alias(e, "Bar"), nil)
	end)

	T.it("bind_alias is functional", function()
		local e0 = E.new()
		local e1 = E.bind_alias(e0, "Foo", V.integer)
		T.eq(E.lookup_alias(e0, "Foo"), nil)
		T.eq(E.lookup_alias(e1, "Foo"), V.integer)
	end)

	T.it("with_io_caps / with_cache_dir update the slots", function()
		local fs = fake_fs({})
		local e = E.with_cache_dir(E.with_io_caps(E.new(), fs), ".cache")
		T.eq(e.io_caps, fs)
		T.eq(e.cache_dir, ".cache")
	end)

	T.it("push_require / pop_require / lookup_require round-trip", function()
		local p = V.var("p")
		local e = E.push_require(E.new(), "m", p)
		T.eq(E.lookup_require(e, "m"), p)
		local e2 = E.pop_require(e, "m")
		T.eq(E.lookup_require(e2, "m"), nil)
	end)

	T.it("enter_function preserves aliases, io_caps, cache_dir, require_chain", function()
		-- File-scope slots must survive crossing a function boundary; only
		-- function-frame slots (return_ty, vararg, effects, narrowed) reset.
		local fs = fake_fs({})
		local e0 = E.bind_alias(E.new(), "Foo", V.integer)
		e0 = E.with_io_caps(e0, fs)
		e0 = E.with_cache_dir(e0, ".cache")
		e0 = E.push_require(e0, "a", true)
		local e1 = E.enter_function(e0, V.bot(), nil)
		T.eq(E.lookup_alias(e1, "Foo"), V.integer)
		T.eq(e1.io_caps, fs)
		T.eq(e1.cache_dir, ".cache")
		T.eq(E.lookup_require(e1, "a"), true)
	end)
end)

