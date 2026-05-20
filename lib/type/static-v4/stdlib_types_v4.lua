-- v4 stdlib type declarations — K3, MVP per docs/typechecker-v4-stdlib-design.md.
--
-- Exports a StdlibBindings record consumed by the driver via Option B
-- (driver design §3): a top-level `require` builds this once per process and
-- the driver re-injects it into every per-file env via E.bind / E.bind_alias
-- in inject_stdlib.
--
--   bindings           — { [name]: V4Type } — nullary stdlib globals.
--   aliases            — { [name]: V4Type } — nullary type aliases.
--   parametric_aliases — { [name]: (V4Type, ...) -> V4Type } — parametric
--                          aliases. v4 has no type-level lambda or
--                          deferred-match constructor today; storing them as
--                          Lua functions is the honest encoding. The driver
--                          / annotation-parser bridge that consumes
--                          parametric aliases does not yet exist (sub-phase
--                          J's annotation bridge is the consumer). Until
--                          then, signatures that would mention `Keys<T>`,
--                          `Values<T>`, `MetaOf<T>`, etc. in their result
--                          types degrade to `unknown`, with per-symbol
--                          inline comments flagging the loss.
--   intrinsics         — { [name]: { kind: string, resolved_by: string } }
--                          — intrinsic markers. None of the crescent `$`-
--                          intrinsics has a first-class V4Type constructor
--                          in 4a–4g; each is either:
--                            * walker-resolved (require, ffi.cdef, ffi.C,
--                              string.match, string.gmatch, string.find)
--                              — the stdlib's declared type is a thin
--                              fallback the walker overrides at the call
--                              site; or
--                            * encoded structurally (Opaque → closed rec
--                              with sentinel field; GlobalScope → closed
--                              rec mirroring `bindings`).
--                          `$Throw` / `$Catch` / `$EachField` are OUT of
--                          MVP per design doc §4; not listed here at all.
--
-- The design doc §1.2 deliberately excludes `io`, `os`, `debug`, `dofile`,
-- `loadfile`, `loadstring`, `load`, `newproxy`, `collectgarbage`, `gcinfo`
-- per CLAUDE.md "Caps-first, everywhere". A future `stdlib_types_v4_caps.lua`
-- adds those for `--caps full` runs. We do NOT include them here, even with
-- a TODO — the exclusion IS the design.

if not package.path:find("?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local V = require("lib.type.static-v4")
-- Bring V4Type into alias scope (same pattern as walker/env.lua).
local _types = require("lib.type.static-v4.types")
local _ = _types

-- The exports are intentionally annotation-free at function signatures;
-- same rationale as effects.lua / ffi_cdef.lua (cross-module --:: alias
-- resolution limitation). Concrete table shapes are documented at the top
-- of this file and exercised by stdlib_types_v4_test.lua.

-- Tables that will become bindings / aliases / parametric_aliases /
-- intrinsics. Assembled into M at the bottom in a single literal so the
-- v4 typechecker sees a fixed hidden class.
local bindings           = {}
local aliases            = {}
local parametric_aliases = {}
local intrinsics         = {}

-- ── Short-name aliases for readability ───────────────────────────────────

local STR  = V.string_
local NUM  = V.number
local INT  = V.integer
local BOOL = V.boolean
local NIL  = V.nil_
local TOP  = V.top()  -- "unknown"
local BOT  = V.bot()  -- "never"
local CD   = V.cdata

--: (V4Type) -> V4Type
local function opt(t) return V.union({ t, NIL }) end

--: (V4Type[]) -> V4Type
local function u(ms) return V.union(ms) end

--: (V4Type, V4Type) -> V4Type
local function arr_of(k, v) return V.rec({}, true, V.indexer(k, v)) end

-- An open record `{ [integer]: T, ... }`. Used pervasively.
--: (V4Type) -> V4Type
local function array_t(t) return V.rec({}, true, V.indexer(INT, t)) end

-- ── Nominal "Opaque" newtype encoding (design §4 / $Opaque) ──────────────
-- v4 has no nominal tag in V.prim. The design's encoding: closed rec with a
-- sentinel field `__opaque = "<key>"` that prevents structural equality with
-- bare T. The MVP needs `thread` and `Ctype<T>`.
--: (string) -> V4Type
local function opaque0(key)
	return V.rec({ __opaque = V.literal("string", key) }, false, nil)
end

-- ── Aliases — nullary ─────────────────────────────────────────────────────

-- $Opaque<"Thread"> — for coroutine functions.
local THREAD_TY = opaque0("Thread")
aliases.thread = THREAD_TY

-- ── Aliases — parametric (Lua-function form; see top-of-file note) ────────
--
-- v4 has no first-class match-type-as-data constructor, so these aliases
-- are stored as Lua functions and APPLIED at user-side annotation
-- resolution time. The annotation-parser bridge (sub-phase J consumer)
-- must look here when it encounters `Arr<T>`, `Ptr<T>`, etc.
-- Until that bridge exists, signatures below that need parametric aliases
-- in result position degrade to `unknown` and the degradation is noted at
-- each site.

-- Arr<T> = { [integer]: T, ... }
--: (V4Type) -> V4Type
function parametric_aliases.Arr(T) return array_t(T) end

-- Ptr<T> = T & { [0]: T }
--: (V4Type) -> V4Type
function parametric_aliases.Ptr(T)
	return V.inter({ T, V.rec({ ["0"] = T }, false, nil) })
end

-- Keys<T>, Values<T>, PairsReturn<T>, IpairsReturn<T>, MetaOf<T>, Open<T>,
-- Closed<T> — all require `match` on the subject's structure. v4's
-- `V.match` evaluates eagerly when called; calling it with a `V.var("T")`
-- subject SUSPENDS (per match.lua's mentions_free_var discipline). That
-- means we cannot precompute the alias body and store it; we must apply
-- on demand.

-- Keys<T> = match T { { ...[%K]: %V } => K }
--: (V4Type) -> V4Type
function parametric_aliases.Keys(T)
	-- Forward-evaluate against T. On a concrete record this produces the
	-- union of its key types. On a free var it returns nil + a suspension
	-- error — we fall back to `unknown` so callers don't trip on the
	-- still-incomplete bridge. Once the bridge defers properly this
	-- function gets called with concrete subjects only.
	local K = V.var("%K")
	local Vv = V.var("%V")
	local pat = V.rec({}, true, V.indexer(K, Vv))
	local arms = { V.arm(pat, K, { K, Vv }) }
	local r = V.match(T, arms, nil)
	if r == nil then return TOP end
	return r
end

-- Values<T> = match T { { ...[%K]: %V } => V }
--: (V4Type) -> V4Type
function parametric_aliases.Values(T)
	local K = V.var("%K")
	local Vv = V.var("%V")
	local pat = V.rec({}, true, V.indexer(K, Vv))
	local arms = { V.arm(pat, Vv, { K, Vv }) }
	local r = V.match(T, arms, nil)
	if r == nil then return TOP end
	return r
end

-- MetaOf<T> — match T { { #...%M } => M, _ => nil }. v4 has no meta-slot
-- match pattern (the {#...%M} pattern isn't in the constructor surface);
-- this remains a known gap. Always returns `unknown | nil` as the honest
-- fallback. Degradation: callers of getmetatable see `unknown | nil`
-- instead of the precise meta type.
--: (V4Type) -> V4Type
function parametric_aliases.MetaOf(_T) return opt(TOP) end

-- Open<T> / Closed<T> — open-vs-closed row manipulation. v4's
-- {...%Rest} rest-capture pattern is not exposed as a V.arm pattern
-- constructor in 4a–4d. Fallback: identity. Degradation: callers lose
-- the open/closed flag transition. Flagged in design §1.3.
--: (V4Type) -> V4Type
function parametric_aliases.Open(T) return T end
--: (V4Type) -> V4Type
function parametric_aliases.Closed(T) return T end

-- IpairsReturn / PairsReturn — also need {...[%K]:%V} distribution to
-- produce a tuple result. v4 has no tuple-result type today (per design
-- §7 open question #1); the legacy `(K, V)` multi-return shape has no
-- direct V4Type encoding. Fallback returns `unknown` for the iterator
-- value. Degradation: `for k, v in pairs(t) do ... end` sees both as
-- `unknown` instead of the real types — flagged as the same spread-
-- result gap.
--: (V4Type) -> V4Type
function parametric_aliases.PairsReturn(_T) return TOP end
--: (V4Type) -> V4Type
function parametric_aliases.IpairsReturn(_T) return TOP end

-- PcallReturn<F> — design accepts the effects.lua positional-record
-- encoding. We provide a function that, given F, produces the union of
-- two closed records. F must be a V.fn; otherwise we fall back to the
-- generic `(boolean, unknown)` shape.
--: (V4Type) -> V4Type
function parametric_aliases.PcallReturn(F)
	local R --[[: V4Type ]] = TOP
	if F.tag == "fn" then R = F.ret end
	local success = V.rec({ ["1"] = V.literal("boolean", true),  ["2"] = R   }, false, nil)
	local failure = V.rec({ ["1"] = V.literal("boolean", false), ["2"] = STR }, false, nil)
	return V.union({ success, failure })
end

-- Ctype<T> = $Opaque<T> & ((...unknown) -> T) — callable opaque newtype.
-- v4's "callable record" semantics: V.inter of a rec and an fn. The
-- apply_arrow path through inter is implementation-tested in functions.lua
-- via its overload handling — design §7 OQ #7 acknowledged this needs
-- verification but the constructor itself is sound (intersection is the
-- correct operator for "is both X and Y").
--: (V4Type) -> V4Type
function parametric_aliases.Ctype(T)
	local opq = V.rec({ __opaque = V.literal("string", "Ctype"), value = T }, false, nil)
	local callable = V.fn({ TOP }, T, nil)  -- variadic loss; see flag below
	-- DEGRADATION: legacy says `(...unknown) -> T`; v4 has no spread param
	-- syntax for V.fn — encoded as a single TOP param. Callers passing 0
	-- or N args will type-mismatch on arity. Flagged per design §1.3 /
	-- §7 open question #1.
	return V.inter({ opq, callable })
end

-- ── Walker-mandatory globals ─────────────────────────────────────────────

-- error : <T>(unknown, integer | nil) -[throw]-> never
bindings.error = V.fn({ TOP, opt(INT) }, BOT, { V.EFFECT_THROW })

-- pcall  : (((...never) -> unknown), ...unknown) -> (boolean, unknown)
--   DEGRADATION: the precise legacy type is
--   `<F: (...unknown) -> unknown>(F, ...unknown) -> PcallReturn<F>`;
--   v4 has no bounded forall, no spread params, and no first-class
--   tuple-with-spread result. The walker (effects.lua) overrides this
--   binding at the call site with the real PcallReturn encoding —
--   the binding only matters for aliased calls like `local p = pcall`.
bindings.pcall = V.fn(
	{ V.fn({ TOP }, TOP, nil), TOP },
	V.union({
		V.rec({ ["1"] = V.literal("boolean", true),  ["2"] = TOP }, false, nil),
		V.rec({ ["1"] = V.literal("boolean", false), ["2"] = STR }, false, nil),
	}),
	nil)

-- xpcall : same shape as pcall plus a handler. Same degradation.
bindings.xpcall = V.fn(
	{ V.fn({ TOP }, TOP, nil), V.fn({ STR }, STR, nil), TOP },
	V.union({
		V.rec({ ["1"] = V.literal("boolean", true),  ["2"] = TOP }, false, nil),
		V.rec({ ["1"] = V.literal("boolean", false), ["2"] = STR }, false, nil),
	}),
	nil)

-- require : (string) -> unknown — placeholder; require_resolve.lua's
-- identifier dispatch overrides on direct `require("<literal>")` calls
-- and replaces the call with the cached export type (design §3, Option B).
-- Aliased indirect calls (`local r = require; r(x)`) intentionally get
-- `unknown` — the price of aliasing.
bindings.require = V.fn({ STR }, TOP, nil)

-- type : (unknown) -> ("nil" | "boolean" | ... | "cdata")
-- Load-bearing: control_flow.lua extracts the comparison RHS's literal
-- and intersects with the argument. The return MUST be a literal union,
-- not `string`.
bindings.type = V.fn({ TOP }, V.union({
	V.literal("string", "nil"),
	V.literal("string", "boolean"),
	V.literal("string", "number"),
	V.literal("string", "string"),
	V.literal("string", "userdata"),
	V.literal("string", "function"),
	V.literal("string", "table"),
	V.literal("string", "thread"),
	V.literal("string", "cdata"),
}), nil)

-- ── Plain-shape utility globals ──────────────────────────────────────────

bindings.tostring = V.fn({ TOP }, STR, nil)
bindings.tonumber = V.fn({ TOP, opt(INT) }, opt(NUM), nil)

-- assert : <T>(T, ...unknown) -> T & ~(nil | false)
--   v4 has no spread params; second param is `unknown | nil` to approximate
--   "optional extra args". Return is `T & ~(nil | false)` — the narrowing
--   form (typechecker-reference.md narrowing intersect-with-complement).
--   DEGRADATION: extra args beyond the second are not type-checked. Flag.
bindings.assert = V.forall({ "T" }, function(vars)
	local T = vars[1]
	if T == nil then T = TOP end
	local truthy = V.inter({ T, V.neg(V.union({ NIL, V.literal("boolean", false) })) })
	return V.fn({ T, opt(TOP) }, truthy, nil)
end)

-- select : intersection of the two call shapes — design §2.
--   DEGRADATION: tail-typing by literal index is not encodable (design §7 #2).
--   Variadic result encoded as a single `unknown` return.
bindings.select = V.inter({
	V.fn({ V.literal("string", "#") }, INT, nil),
	V.fn({ INT, TOP }, TOP, nil),
})

-- next : <T>(T, Keys<T> | nil) -> (Keys<T> | nil, Values<T> | nil)
--   DEGRADATION: parametric aliases aren't applied here (no bridge); both
--   key and value degrade to `unknown`. Single-return encoded; multi-return
--   tuple has no V4Type form (design §7 #1).
bindings.next = V.forall({ "T" }, function(vars)
	local T = vars[1]
	if T == nil then T = TOP end
	return V.fn({ T, opt(TOP) }, opt(TOP), nil)
end)

-- ipairs : <T>(T) -> IpairsReturn<T> — see PairsReturn degradation note.
bindings.ipairs = V.forall({ "T" }, function(vars)
	local T = vars[1]
	if T == nil then T = TOP end
	return V.fn({ T }, TOP, nil)
end)

-- pairs : <T>(T) -> PairsReturn<T> — see degradation.
bindings.pairs = V.forall({ "T" }, function(vars)
	local T = vars[1]
	if T == nil then T = TOP end
	return V.fn({ T }, TOP, nil)
end)

-- setmetatable : <T, MT>(T, MT) -> T & MT & { #...MT }
--   DEGRADATION: meta-slot spread `{ #...MT }` has no V4Type form.
--   Encoded as `T & MT` only — meta slots are not propagated structurally.
bindings.setmetatable = V.forall({ "T", "MT" }, function(vars)
	local T  = vars[1] or TOP
	local MT = vars[2] or TOP
	return V.fn({ T, MT }, V.inter({ T, MT }), nil)
end)

-- getmetatable : <T>(T) -> MetaOf<T>
--   DEGRADATION: parametric MetaOf is `unknown | nil` (no meta pattern).
bindings.getmetatable = V.forall({ "T" }, function(vars)
	local T = vars[1] or TOP
	return V.fn({ T }, opt(TOP), nil)
end)

-- rawget : <T>(T, unknown) -> Values<T> | nil — degraded to `unknown | nil`.
bindings.rawget = V.forall({ "T" }, function(vars)
	local T = vars[1] or TOP
	return V.fn({ T, TOP }, opt(TOP), nil)
end)

-- rawset : <T>(T, unknown, unknown) -> T
bindings.rawset = V.forall({ "T" }, function(vars)
	local T = vars[1] or TOP
	return V.fn({ T, TOP, TOP }, T, nil)
end)

bindings.rawequal = V.fn({ TOP, TOP }, BOOL, nil)
bindings.rawlen   = V.fn({ V.union({ STR, array_t(TOP) }) }, INT, nil)

-- unpack : <V>({ [integer]: V, ... }, integer | nil, integer | nil) -> ...V
--   DEGRADATION: spread-fn-result not available; return degrades to
--   `unknown`. Legacy returns `...(V)`. Per design §7 #1.
bindings.unpack = V.forall({ "V" }, function(vars)
	local Vv = vars[1] or TOP
	return V.fn({ array_t(Vv), opt(INT), opt(INT) }, TOP, nil)
end)

bindings.print    = V.fn({ TOP }, NIL, nil)  -- DEGRADATION: ...unknown → TOP single param.
bindings._VERSION = STR

-- ── string table ─────────────────────────────────────────────────────────
-- string.match / gmatch / find use $PatternReturn / $FindReturn — walker
-- override required (design §4). Stdlib declares plain fallback types;
-- the walker override hook is not yet implemented (design §7 #3) but the
-- declaration is stable today.
bindings.string = V.rec({
	format  = V.fn({ STR, TOP }, STR, nil),  -- DEGRADATION: ...unknown collapsed to single TOP.
	len     = V.fn({ STR }, INT, nil),
	sub     = V.fn({ STR, INT, opt(INT) }, STR, nil),
	-- find/match/gmatch fallbacks: walker overrides will resolve precise
	-- $PatternReturn<P> / $FindReturn<P> at call sites with literal patterns.
	find    = V.fn({ STR, STR, opt(INT), opt(BOOL) }, opt(TOP), nil),
	match   = V.fn({ STR, STR, opt(INT) }, opt(TOP), nil),
	gmatch  = V.fn({ STR, STR }, V.fn({}, opt(STR), nil), nil),
	gsub    = V.fn(
		{ STR, STR, V.union({ STR, V.fn({ STR }, opt(STR), nil), arr_of(STR, STR) }), opt(INT) },
		V.rec({ ["1"] = STR, ["2"] = INT }, false, nil), nil),
	rep     = V.fn({ STR, INT, opt(STR) }, STR, nil),
	byte    = V.inter({
		V.fn({ STR, opt(INT) }, opt(INT), nil),
		V.fn({ STR, INT, INT }, INT, nil),  -- DEGRADATION: legacy is ...integer; single INT return.
	}),
	char    = V.fn({ INT }, STR, nil),  -- DEGRADATION: ...integer collapsed.
	upper   = V.fn({ STR }, STR, nil),
	lower   = V.fn({ STR }, STR, nil),
	reverse = V.fn({ STR }, STR, nil),
}, false, nil)

-- ── table table ──────────────────────────────────────────────────────────
bindings.table = V.rec({
	insert = V.forall({ "V" }, function(vars)
		local Vv = vars[1] or TOP
		return V.fn({ array_t(Vv), Vv }, NIL, nil)
	end),
	remove = V.forall({ "V" }, function(vars)
		local Vv = vars[1] or TOP
		return V.fn({ array_t(Vv), opt(INT) }, opt(Vv), nil)
	end),
	concat = V.fn({ array_t(V.union({ STR, NUM })), opt(STR), opt(INT), opt(INT) }, STR, nil),
	sort   = V.forall({ "V" }, function(vars)
		local Vv = vars[1] or TOP
		return V.fn({ array_t(Vv), opt(V.fn({ Vv, Vv }, BOOL, nil)) }, NIL, nil)
	end),
	unpack = bindings.unpack,
	move   = V.forall({ "V" }, function(vars)
		local Vv = vars[1] or TOP
		return V.fn({ array_t(Vv), INT, INT, INT, opt(array_t(Vv)) }, array_t(Vv), nil)
	end),
	maxn   = V.fn({ array_t(TOP) }, INT, nil),
}, false, nil)

-- ── math table ───────────────────────────────────────────────────────────
bindings.math = V.rec({
	abs        = V.fn({ NUM }, NUM, nil),
	floor      = V.fn({ NUM }, INT, nil),
	ceil       = V.fn({ NUM }, INT, nil),
	sqrt       = V.fn({ NUM }, NUM, nil),
	min        = V.inter({
		V.fn({ INT, INT }, INT, nil),  -- DEGRADATION: legacy ...integer / ...number.
		V.fn({ NUM, NUM }, NUM, nil),
	}),
	max        = V.inter({
		V.fn({ INT, INT }, INT, nil),
		V.fn({ NUM, NUM }, NUM, nil),
	}),
	random     = V.fn({ opt(INT), opt(INT) }, NUM, nil),
	randomseed = V.fn({ NUM }, NIL, nil),
	huge       = NUM,
	pi         = NUM,
	sin        = V.fn({ NUM }, NUM, nil),
	cos        = V.fn({ NUM }, NUM, nil),
	tan        = V.fn({ NUM }, NUM, nil),
	exp        = V.fn({ NUM }, NUM, nil),
	log        = V.fn({ NUM }, NUM, nil),
	pow        = V.fn({ NUM, NUM }, NUM, nil),
	fmod       = V.fn({ NUM, NUM }, NUM, nil),
	-- DEGRADATION: modf legacy returns (number, number) multi-return — encoded
	-- as positional rec, no spread.
	modf       = V.fn({ NUM }, V.rec({ ["1"] = NUM, ["2"] = NUM }, false, nil), nil),
}, false, nil)

-- ── coroutine table ──────────────────────────────────────────────────────
-- yield carries the yield effect; effects.lua expects this on the binding.
bindings.coroutine = V.rec({
	yield       = V.fn({ TOP }, TOP, { V.EFFECT_YIELD }),  -- DEGRADATION: spread args/return collapsed.
	create      = V.fn({ V.fn({ BOT }, TOP, nil) }, THREAD_TY, nil),
	-- resume / wrap return shapes are spread-bearing; degrade to single TOP.
	resume      = V.fn({ THREAD_TY, TOP }, V.rec({ ["1"] = BOOL, ["2"] = TOP }, false, nil), nil),
	wrap        = V.fn({ V.fn({ BOT }, TOP, nil) }, V.fn({ BOT }, TOP, nil), nil),
	status      = V.fn({ THREAD_TY }, V.union({
		V.literal("string", "running"),
		V.literal("string", "suspended"),
		V.literal("string", "normal"),
		V.literal("string", "dead"),
	}), nil),
	running     = V.fn({}, V.rec({ ["1"] = opt(THREAD_TY), ["2"] = BOOL }, false, nil), nil),
	isyieldable = V.fn({}, BOOL, nil),
}, false, nil)

-- ── bit table (LuaJIT) ───────────────────────────────────────────────────
bindings.bit = V.rec({
	tobit   = V.fn({ NUM }, INT, nil),
	tohex   = V.fn({ NUM, opt(INT) }, STR, nil),
	bnot    = V.fn({ INT }, INT, nil),
	band    = V.fn({ INT, INT }, INT, nil),  -- DEGRADATION: ...integer collapsed.
	bor     = V.fn({ INT, INT }, INT, nil),
	bxor    = V.fn({ INT, INT }, INT, nil),
	lshift  = V.fn({ INT, INT }, INT, nil),
	rshift  = V.fn({ INT, INT }, INT, nil),
	arshift = V.fn({ INT, INT }, INT, nil),
	bswap   = V.fn({ INT }, INT, nil),
	rol     = V.fn({ INT, INT }, INT, nil),
	ror     = V.fn({ INT, INT }, INT, nil),
}, false, nil)

-- ── ffi table ────────────────────────────────────────────────────────────
-- `C` starts as an empty closed rec; ffi_cdef.lua rewrites the binding
-- after each ffi.cdef call to add the cdecl'd symbols.
local CTYPE_UNK = parametric_aliases.Ctype(TOP)
local PTR_INT   = parametric_aliases.Ptr(INT)

bindings.ffi = V.rec({
	cdef     = V.fn({ STR }, NIL, nil),
	C        = V.rec({}, false, nil),  -- ffi_cdef.lua rewrites
	new      = V.fn({ STR, opt(TOP) }, CD, nil),  -- DEGRADATION: legacy is a 4-way intersection over Ctype/CTypeMap/cdata variants; v4 has no CTypeMap match — collapsed.
	cast     = V.fn({ V.union({ STR, CTYPE_UNK }), TOP }, CD, nil),  -- same degradation
	sizeof   = V.fn({ V.union({ STR, CTYPE_UNK }) }, INT, nil),
	typeof   = V.inter({
		V.fn({ CTYPE_UNK }, CTYPE_UNK, nil),
		V.fn({ STR }, CTYPE_UNK, nil),
	}),
	string   = V.fn({ PTR_INT, opt(INT) }, STR, nil),
	gc       = V.forall({ "T" }, function(vars)
		local T = vars[1] or TOP
		return V.fn({ T, opt(V.fn({ T }, NIL, nil)) }, T, nil)
	end),
	metatype = V.forall({ "T" }, function(vars)
		local T = vars[1] or TOP
		return V.fn(
			{ parametric_aliases.Ctype(T), V.rec({}, true, V.indexer(STR, TOP)) },
			parametric_aliases.Ctype(T), nil)
	end),
	istype   = V.fn({ V.union({ STR, CTYPE_UNK }), TOP }, BOOL, nil),
	alignof  = V.fn({ V.union({ STR, CTYPE_UNK }) }, INT, nil),
	offsetof = V.fn({ V.union({ STR, CTYPE_UNK }), STR }, INT, nil),
	abi      = V.fn({ STR }, BOOL, nil),
	errno    = V.fn({ opt(INT) }, INT, nil),
	-- load returns $FfiC fallback (empty closed rec). The walker may
	-- rewrite based on the loaded library's actual cdefs later.
	load     = V.fn({ STR, opt(BOOL) }, V.rec({}, false, nil), nil),
	copy     = V.forall({ "T", "U" }, function(vars)
		local T = vars[1] or TOP
		local U = vars[2] or TOP
		return V.fn({ parametric_aliases.Ptr(T), parametric_aliases.Ptr(U), INT }, NIL, nil)
	end),
	fill     = V.forall({ "T" }, function(vars)
		local T = vars[1] or TOP
		return V.fn({ parametric_aliases.Ptr(T), INT, opt(INT) }, NIL, nil)
	end),
}, false, nil)

-- ── jit table ────────────────────────────────────────────────────────────
bindings.jit = V.rec({
	version     = STR,
	version_num = INT,
	os          = STR,
	arch        = STR,
}, false, nil)

-- ── package table ────────────────────────────────────────────────────────
bindings.package = V.rec({
	path    = STR,
	cpath   = STR,
	loaded  = V.rec({}, true, V.indexer(STR, TOP)),
	preload = V.rec({}, true, V.indexer(STR, V.fn({ STR }, TOP, nil))),
}, false, nil)

-- ── _G ($GlobalScope) ────────────────────────────────────────────────────
-- Per design §4 (b): closure of bindings at the bottom of the file.
-- A user binding that shadows a stdlib name later does NOT appear here —
-- acceptable for MVP (design §7 #5).
--: () -> V4Type
local function build_global_scope()
	local fields = {} --[[: { [string]: V4Type } ]]
	for k, v in pairs(bindings) do
		if k ~= "_G" and v ~= nil then fields[k] = v --[[: V4Type ]] end
	end
	return V.rec(fields, false, nil)
end
bindings._G = build_global_scope()

-- ── Per-primitive method-dispatch registry ──────────────────────────────
-- Mirrors the legacy `ctx.prim_index` (per prelude.lua:299-323): maps a
-- primitive's base tag to the V4Type used as that primitive's `__index`
-- for method lookups (e.g. `("abc"):upper()` resolves through the entry
-- under `"string"`). Keyed by tag, NOT by source-level binding name —
-- user-shadowing the `string` global must not break `:upper()` dispatch.
--
-- Legacy registers exactly ONE entry: TAG_STRING → the `string` library.
-- Number / integer / boolean have operator-meta tables (`prim_meta`,
-- legacy: number_meta / integer_meta) but no method-dispatch `__index`,
-- so they are intentionally absent here. Adding number/integer entries
-- would lie about Lua semantics (`(42):floor()` is a runtime error).
local prim_index = {
	string = bindings.string,
}

-- ── Intrinsic markers (informational; consumers branch on `resolved_by`) ─
intrinsics["$Require"]  = { kind = "walker-override",   resolved_by = "walker/require_resolve.lua" }
intrinsics["$FfiC"]     = { kind = "walker-rewrite",    resolved_by = "walker/ffi_cdef.lua" }
intrinsics["$Opaque"]   = { kind = "structural-encoding", resolved_by = "rec-with-sentinel-field (this file)" }
intrinsics["$GlobalScope"] = { kind = "build-from-bindings", resolved_by = "this file's _G binding" }
intrinsics["$PatternReturn"] = { kind = "walker-override-pending", resolved_by = "walker hook NOT YET IMPLEMENTED (design §7 #3)" }
intrinsics["$FindReturn"]    = { kind = "walker-override-pending", resolved_by = "walker hook NOT YET IMPLEMENTED (design §7 #3)" }

-- ── Final assembly ───────────────────────────────────────────────────────

local M = {
	bindings           = bindings,
	aliases            = aliases,
	parametric_aliases = parametric_aliases,
	intrinsics         = intrinsics,
	prim_index         = prim_index,
}

return M
