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
