-- Tests for lib/type/static-v4/stdlib_types_v4.lua — K3 MVP.
--
-- Verifies binding existence, signature spot-checks (constructor tags, params,
-- return), effects fields, alias resolution for parametric aliases, and a
-- walker integration smoke test (tostring(42) synthesizes string).

if not package.path:find("?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local V       = require("lib.type.static-v4")
local stdlib  = require("lib.type.static-v4.stdlib_types_v4")
local E       = require("lib.type.static-v4.walker.env")
local W       = require("lib.type.static-v4.walker.walker")
local defs    = require("lib.type.static.defs")
local T       = require("lib.test.assert")

-- ── Top-level shape ──────────────────────────────────────────────────────

T.describe("stdlib_types_v4: module shape", function()
	T.it("exports bindings/aliases/parametric_aliases/intrinsics", function()
		T.ok(type(stdlib.bindings) == "table")
		T.ok(type(stdlib.aliases) == "table")
		T.ok(type(stdlib.parametric_aliases) == "table")
		T.ok(type(stdlib.intrinsics) == "table")
	end)
end)

-- ── Walker-mandatory globals ────────────────────────────────────────────

T.describe("stdlib_types_v4: walker-mandatory bindings", function()
	T.it("error is a function with throw effect, returning never", function()
		local f = stdlib.bindings.error
		T.ok(f ~= nil)
		T.eq(f.tag, "fn")
		T.eq(f.ret.tag, "bot")
		T.ok(f.effects[V.EFFECT_THROW] == true)
	end)

	T.it("pcall is a function with no leaked effects", function()
		local f = stdlib.bindings.pcall
		T.ok(f ~= nil)
		T.eq(f.tag, "fn")
		-- pcall masks throw; its declared effects must be empty.
		T.eq(next(f.effects), nil)
	end)

	T.it("xpcall is a function with no leaked effects", function()
		local f = stdlib.bindings.xpcall
		T.ok(f ~= nil)
		T.eq(f.tag, "fn")
		T.eq(next(f.effects), nil)
	end)

	T.it("require : (string) -> unknown — fallback shape per design §3", function()
		local f = stdlib.bindings.require
		T.eq(f.tag, "fn")
		T.eq(#f.params, 1)
		T.eq(f.params[1], V.string_)
		T.eq(f.ret.tag, "top")
	end)

	T.it("type returns a literal union including 'string' and 'cdata'", function()
		local f = stdlib.bindings.type
		T.eq(f.tag, "fn")
		T.eq(f.ret.tag, "union")
		local seen = {}
		for _, m in ipairs(f.ret.members) do
			if m.tag == "literal" then seen[m.value] = true end
		end
		T.ok(seen["string"])
		T.ok(seen["nil"])
		T.ok(seen["cdata"])
		T.ok(seen["table"])
	end)

	T.it("coroutine.yield carries the yield effect", function()
		local cor = stdlib.bindings.coroutine
		T.eq(cor.tag, "rec")
		local y = cor.fields.yield
		T.ok(y ~= nil)
		T.eq(y.tag, "fn")
		T.ok(y.effects[V.EFFECT_YIELD] == true)
	end)

	T.it("ffi table has cdef and an empty closed C rec", function()
		local ffi = stdlib.bindings.ffi
		T.eq(ffi.tag, "rec")
		T.eq(ffi.fields.cdef.tag, "fn")
		T.eq(ffi.fields.C.tag, "rec")
		T.eq(ffi.fields.C.open, false)
		T.eq(next(ffi.fields.C.fields), nil)
	end)
end)

-- ── Plain-shape utility ─────────────────────────────────────────────────

T.describe("stdlib_types_v4: utility bindings", function()
	T.it("tostring : (unknown) -> string", function()
		local f = stdlib.bindings.tostring
		T.eq(f.tag, "fn")
		T.eq(#f.params, 1)
		T.eq(f.params[1].tag, "top")
		T.eq(f.ret, V.string_)
	end)

	T.it("tonumber : (unknown, integer | nil) -> number | nil", function()
		local f = stdlib.bindings.tonumber
		T.eq(f.tag, "fn")
		T.eq(#f.params, 2)
		T.eq(f.ret.tag, "union")
	end)

	T.it("assert is a forall returning T & ~(nil | false)", function()
		local f = stdlib.bindings.assert
		T.eq(f.tag, "forall")
		T.eq(f.body.tag, "fn")
		-- Return type is an intersection of T and a complement.
		T.eq(f.body.ret.tag, "inter")
	end)

	T.it("select is an intersection of two arrow shapes", function()
		local f = stdlib.bindings.select
		T.eq(f.tag, "inter")
		T.eq(#f.members, 2)
		for _, m in ipairs(f.members) do T.eq(m.tag, "fn") end
	end)

	T.it("next, pairs, ipairs are forall", function()
		T.eq(stdlib.bindings.next.tag,   "forall")
		T.eq(stdlib.bindings.pairs.tag,  "forall")
		T.eq(stdlib.bindings.ipairs.tag, "forall")
	end)

	T.it("setmetatable, getmetatable are forall", function()
		T.eq(stdlib.bindings.setmetatable.tag, "forall")
		T.eq(stdlib.bindings.getmetatable.tag, "forall")
	end)

	T.it("rawget, rawset are forall; rawequal, rawlen are plain fn", function()
		T.eq(stdlib.bindings.rawget.tag,  "forall")
		T.eq(stdlib.bindings.rawset.tag,  "forall")
		T.eq(stdlib.bindings.rawequal.tag, "fn")
		T.eq(stdlib.bindings.rawlen.tag,   "fn")
	end)

	T.it("unpack is forall over V", function()
		T.eq(stdlib.bindings.unpack.tag, "forall")
	end)

	T.it("print : (unknown) -> nil", function()
		local f = stdlib.bindings.print
		T.eq(f.tag, "fn")
		T.eq(f.ret, V.nil_)
	end)

	T.it("_VERSION is a string", function()
		T.eq(stdlib.bindings._VERSION, V.string_)
	end)
end)

-- ── Tables: string / table / math / coroutine / bit / ffi / jit / package

T.describe("stdlib_types_v4: standard tables", function()
	T.it("string table has format, find, match, sub, byte, char, etc.", function()
		local s = stdlib.bindings.string
		T.eq(s.tag, "rec")
		for _, name in ipairs({ "format", "find", "match", "gmatch", "gsub", "sub",
			"byte", "char", "upper", "lower", "rep", "reverse", "len" }) do
			T.ok(s.fields[name] ~= nil, "string." .. name)
		end
	end)

	T.it("table table has insert, remove, concat, sort, unpack, move, maxn", function()
		local t = stdlib.bindings.table
		T.eq(t.tag, "rec")
		for _, name in ipairs({ "insert", "remove", "concat", "sort",
			"unpack", "move", "maxn" }) do
			T.ok(t.fields[name] ~= nil, "table." .. name)
		end
	end)

	T.it("math table has abs, floor, ceil, sqrt, min, max, huge, pi, random, etc.", function()
		local m = stdlib.bindings.math
		for _, name in ipairs({ "abs", "floor", "ceil", "sqrt", "min", "max",
			"huge", "pi", "random", "randomseed", "sin", "cos", "tan", "exp",
			"log", "pow", "fmod", "modf" }) do
			T.ok(m.fields[name] ~= nil, "math." .. name)
		end
		-- Constants are direct primitives.
		T.eq(m.fields.huge, V.number)
		T.eq(m.fields.pi,   V.number)
	end)

	T.it("coroutine table has create, resume, yield, wrap, status, running, isyieldable", function()
		local c = stdlib.bindings.coroutine
		for _, name in ipairs({ "create", "resume", "yield", "wrap", "status",
			"running", "isyieldable" }) do
			T.ok(c.fields[name] ~= nil, "coroutine." .. name)
		end
	end)

	T.it("bit table has tobit, tohex, bnot, band, bor, bxor, lshift, rshift, arshift", function()
		local b = stdlib.bindings.bit
		for _, name in ipairs({ "tobit", "tohex", "bnot", "band", "bor", "bxor",
			"lshift", "rshift", "arshift", "bswap", "rol", "ror" }) do
			T.ok(b.fields[name] ~= nil, "bit." .. name)
		end
	end)

	T.it("ffi table has cdef, C, new, cast, sizeof, typeof, etc.", function()
		local f = stdlib.bindings.ffi
		for _, name in ipairs({ "cdef", "C", "new", "cast", "sizeof", "typeof",
			"string", "gc", "metatype", "istype", "alignof", "offsetof",
			"abi", "errno", "load", "copy", "fill" }) do
			T.ok(f.fields[name] ~= nil, "ffi." .. name)
		end
	end)

	T.it("jit table has version, version_num, os, arch", function()
		local j = stdlib.bindings.jit
		T.eq(j.fields.version,     V.string_)
		T.eq(j.fields.version_num, V.integer)
		T.eq(j.fields.os,          V.string_)
		T.eq(j.fields.arch,        V.string_)
	end)

	T.it("package table has path, cpath, loaded, preload", function()
		local p = stdlib.bindings.package
		T.eq(p.fields.path,  V.string_)
		T.eq(p.fields.cpath, V.string_)
		T.eq(p.fields.loaded.tag,  "rec")
		T.eq(p.fields.preload.tag, "rec")
	end)
end)

-- ── _G ($GlobalScope) — built from bindings ─────────────────────────────

T.describe("stdlib_types_v4: _G ($GlobalScope)", function()
	T.it("_G is a closed rec mirroring bindings (minus _G itself)", function()
		local g = stdlib.bindings._G
		T.eq(g.tag, "rec")
		T.eq(g.open, false)
		T.ok(g.fields._G == nil, "_G should not reference itself")
		T.ok(g.fields.print     ~= nil)
		T.ok(g.fields.string    ~= nil)
		T.ok(g.fields.coroutine ~= nil)
	end)
end)

-- ── Excluded I/O caps (CLAUDE.md caps-first) ────────────────────────────

T.describe("stdlib_types_v4: caps-excluded symbols", function()
	T.it("io is not declared in the default stdlib", function()
		T.eq(stdlib.bindings.io, nil)
	end)
	T.it("os is not declared in the default stdlib", function()
		T.eq(stdlib.bindings.os, nil)
	end)
	T.it("debug is not declared in the default stdlib", function()
		T.eq(stdlib.bindings.debug, nil)
	end)
	T.it("dofile / loadfile / loadstring / load / newproxy / collectgarbage / gcinfo are not declared", function()
		for _, name in ipairs({ "dofile", "loadfile", "loadstring", "load",
			"newproxy", "collectgarbage", "gcinfo" }) do
			T.eq(stdlib.bindings[name], nil, "unexpected: " .. name)
		end
	end)
end)

-- ── Aliases (nullary) ───────────────────────────────────────────────────

T.describe("stdlib_types_v4: nullary aliases", function()
	T.it("thread is an opaque rec with sentinel", function()
		local th = stdlib.aliases.thread
		T.eq(th.tag, "rec")
		T.eq(th.open, false)
		T.ok(th.fields.__opaque ~= nil)
	end)
end)

-- ── Parametric aliases (Lua functions) ──────────────────────────────────

T.describe("stdlib_types_v4: parametric aliases", function()
	T.it("Arr<T> is { [integer]: T, ... }", function()
		local r = stdlib.parametric_aliases.Arr(V.integer)
		T.eq(r.tag, "rec")
		T.eq(r.open, true)
		T.ok(r.indexer ~= nil)
		T.eq(r.indexer.key, V.integer)
		T.eq(r.indexer.value, V.integer)
	end)

	T.it("Ptr<T> is intersection of T and { [0]: T }", function()
		local r = stdlib.parametric_aliases.Ptr(V.integer)
		T.eq(r.tag, "inter")
		T.eq(#r.members, 2)
	end)

	T.it("PcallReturn<F> is a union of two closed records", function()
		local F = V.fn({ V.integer }, V.string_, nil)
		local r = stdlib.parametric_aliases.PcallReturn(F)
		T.eq(r.tag, "union")
		T.eq(#r.members, 2)
		T.eq(r.members[1].tag, "rec")
		T.eq(r.members[2].tag, "rec")
	end)

	T.it("Ctype<T> is intersection of opaque rec and callable", function()
		local r = stdlib.parametric_aliases.Ctype(V.integer)
		T.eq(r.tag, "inter")
	end)

	T.it("Keys / Values / MetaOf / Open / Closed / PairsReturn / IpairsReturn exist", function()
		for _, name in ipairs({ "Keys", "Values", "MetaOf", "Open", "Closed",
			"PairsReturn", "IpairsReturn" }) do
			T.ok(stdlib.parametric_aliases[name] ~= nil, "missing: " .. name)
			T.ok(type(stdlib.parametric_aliases[name]) == "function")
		end
	end)
end)

-- ── Intrinsics ──────────────────────────────────────────────────────────

T.describe("stdlib_types_v4: intrinsics", function()
	T.it("$Require is walker-override", function()
		T.eq(stdlib.intrinsics["$Require"].kind, "walker-override")
	end)
	T.it("$FfiC is walker-rewrite", function()
		T.eq(stdlib.intrinsics["$FfiC"].kind, "walker-rewrite")
	end)
	T.it("$Opaque is structural-encoding", function()
		T.eq(stdlib.intrinsics["$Opaque"].kind, "structural-encoding")
	end)
	T.it("$GlobalScope is build-from-bindings", function()
		T.eq(stdlib.intrinsics["$GlobalScope"].kind, "build-from-bindings")
	end)
	T.it("$PatternReturn / $FindReturn are flagged as walker-override-pending", function()
		T.eq(stdlib.intrinsics["$PatternReturn"].kind, "walker-override-pending")
		T.eq(stdlib.intrinsics["$FindReturn"].kind,    "walker-override-pending")
	end)
end)

-- ── Walker integration smoke test ───────────────────────────────────────

T.describe("stdlib_types_v4: walker integration", function()
	T.it("a walker env loaded with stdlib synthesizes tostring(42) as string", function()
		-- Build a NODE_CALL_EXPR : tostring(42) — using the POJO node shape
		-- the walker handlers consume (NODE_IDENTIFIER callee, NODE_LITERAL
		-- argument). Tags come from lib/type/static/defs.lua.
		local callee = {
			tag  = defs.NODE_IDENTIFIER,
			name = "tostring",
			line = 1, col = 1,
		}
		local arg = {
			tag      = defs.NODE_LITERAL,
			lit_kind = defs.LIT_INTEGER,
			value    = 42,
			line = 1, col = 12,
		}
		local node = {
			tag    = defs.NODE_CALL_EXPR,
			callee = callee,
			args   = { arg },
			line = 1, col = 1,
		}

		-- Inject the stdlib `tostring` binding into a fresh env.
		local env = E.new()
		env = E.bind(env, "tostring", stdlib.bindings.tostring)

		local solver = V.new_solver()
		local ty, _env_out, err = W.walk_synth(node, env, solver)
		T.eq(err, nil)
		T.eq(ty, V.string_)
	end)
end)
