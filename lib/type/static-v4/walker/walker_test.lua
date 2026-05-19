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

	T.it("only sub-phase B handlers are registered by default", function()
		-- Sub-phase B installs SYNTHESIZE handlers for literals, identifiers,
		-- and varargs at module load time. Tags for later sub-phases must
		-- remain unregistered.
		T.ok(W.has_synth(defs.NODE_LITERAL))
		T.ok(W.has_synth(defs.NODE_IDENTIFIER))
		T.ok(W.has_synth(defs.NODE_VARARG_EXPR))
		for _, tag in pairs({
			defs.NODE_CALL_EXPR, defs.NODE_LOCAL_STMT,
			defs.NODE_IF_STMT, defs.NODE_CHUNK,
		}) do
			T.fail(W.has_synth(tag))
			T.fail(W.has_check(tag))
		end
		-- No CHECK handlers registered yet — every CHECK goes through the
		-- default synth+constrain rule in sub-phase B.
		T.fail(W.has_check(defs.NODE_LITERAL))
		T.fail(W.has_check(defs.NODE_IDENTIFIER))
		T.fail(W.has_check(defs.NODE_VARARG_EXPR))
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
