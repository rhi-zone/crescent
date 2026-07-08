if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

-- toy_checker — a moded-obligation claim IR + saturation-pool scheduler,
-- as a substrate for typechecking a tiny toy language. This is a
-- deliberately small, clean-room SKETCH built to test one hypothesis: can
-- "obligation = judgment + (in/out)-moded positions, solved by
-- pattern-matched producers on a worklist" carry real typing rules
-- (unification, subtyping, bidirectional infer/check, let-bound
-- generics)? It is NOT a refactor of lib/declc or lib/type, shares no code
-- with them, and is not meant to be extended into production. Read this
-- comment before touching producers.lua or pool.lua.
--
-- ── WHAT'S HERE ──────────────────────────────────────────────────────────
-- ir.lua        types, toy-AST shapes (informally, as comments), and the
--               judgment-name -> fixed mode-signature table.
-- pool.lua       the worklist: submit/run, provenance trail, and the
--               wake/waiter mechanism for deferred obligations.
-- producers.lua  the four registered producers (Unify, Sub,
--               Instantiate+Generalize, Infer+Check) — Infer+Check is
--               where the toy language's actual typing rules live.
--
-- ── SEMANTIC CHOICES AND WHY ─────────────────────────────────────────────
--
-- 1. Three mode kinds — in, out, accumulate — drive scheduling, but with
--    different mechanisms. Static pool-level blocking (declared at
--    registration via `pool:register(..., {1})`) only applies to
--    Instantiate's scheme position, because a scheme is atomic. Sub uses
--    "accumulate" mode dynamically: when one operand is a uvar, it records
--    the known side as a lower/upper bound on the uvar and returns
--    "proved" immediately; when both operands are uvars it returns
--    "deferred" with the left uvar's id, and the pool puts it in waiters.
--    Unify/Infer/Check/Generalize never block. The in/out distinction is
--    load-bearing everywhere (out positions get written by exactly one
--    producer, in positions are read-only) but scheduling-by-mode takes
--    three forms: static pool blocking (Instantiate), dynamic producer
--    deferral (Sub both-uvar), and immediate accumulation (Sub one-uvar).
--
-- 2. Generalize is a real HM-style computation (free tyvars of the type,
--    minus free tyvars of the env), not a degenerate wrapper around an
--    explicit list — its `env` argument is genuinely read. It only ever
--    runs on rigid tyvars introduced by a function's own explicit
--    `type_params`, since this toy has no let-generalization over
--    unification variables (see punt list below); that keeps it simple
--    without making it decorative.
--
-- 3. If/then/else branch-join is done by handing both branches' Infer the
--    *same* `out` uvar rather than a dedicated join judgment — two
--    producers converging on one out-cell via Unify is already a join.
--    Pleasant emergent property of the moded-cell design, not something
--    that needed extra machinery.
--
-- ── OWNER-CALL (genuine forks, picked one way, flagging the other) ───────
--
-- OWNER-CALL A — environment/context threading. A typing context (var ->
-- type/scheme) has to reach every Infer/Check obligation, but it isn't a
-- claim to be solved, it's read-only ambient state. Two defensible,
-- semantically-diverging choices: (a) thread it as an auxiliary `env`
-- field on the obligation, outside the formal moded-args list [chosen],
-- or (b) reify it as a first-class judgment (e.g. `Lookup(env:in,
-- name:in, type:out)`) so *everything* including context lookup flows
-- through the moded-obligation substrate. (a) is far less code and was
-- chosen for a toy of this size, but it means the claims engine is not
-- fully self-contained — some semantic content (scoping) rides in on the
-- side rather than being expressed as claims. If the hypothesis under
-- test is "can EVERYTHING be a moded obligation", (b) is the honest
-- answer and this toy punts on it.
--
-- OWNER-CALL B — generic type-constructor argument variance in Sub. No
-- per-parameter variance annotations exist, so Sub(Store<A>, Store<B>)
-- needs a default. Chose invariant (recurse via Unify, requiring exact
-- equality of A and B) over covariant (recurse via Sub, which would admit
-- e.g. Store<int> <: Store<number>). Invariant is the safe default and is
-- what the ECS-shaped test actually exercises (generic params get pinned
-- by Unify at instantiation, never by subtyping between two different
-- instantiations) — but covariant is equally defensible for a read-only
-- container and the two diverge in real programs.
--
-- OWNER-CALL C — RESOLVED. Sub against an unresolved unification variable
-- now uses CLP-style bound accumulation ("accumulate" mode) instead of
-- collapsing to Unify. Sub(ground, ?x) records ground as a lower bound;
-- Sub(?x, ground) records ground as an upper bound; Sub(?x, ?y) defers
-- until the left side resolves. Cross-checks (every new bound vs all
-- opposite-side bounds) are submitted as Sub obligations, catching
-- contradictions structurally. When a fully-ground lower bound arrives,
-- the uvar auto-resolves to it (see OWNER-CALL D in pool.lua for the
-- resolution strategy). Compound bounds (e.g. Store<?a>) trigger
-- structural decomposition through the normal Sub/Unify machinery when
-- cross-checked against opposite-side bounds — no special compound-merge
-- code, just the existing structural producers re-entered on the children.
--
-- The previous asymmetric-blocking-on-position-1 approach and the
-- collapse-to-Unify fallback are both removed. The ordering issue that
-- motivated position-1 blocking (Sub racing against a sibling Infer on
-- the same fresh uvar) is now handled by accumulate: Sub(?fresh, expected)
-- records an upper bound on ?fresh without needing ?fresh to be resolved;
-- when Infer later resolves ?fresh via Unify, bind verifies the bound.
--
-- Known limitation: if a non-ground lower bound later becomes ground
-- (because an internal uvar resolves), _try_resolve is NOT re-triggered
-- on the outer uvar. The typical resolution path for compound-typed
-- uvars is through Unify (structural matching), not bound accumulation.
--
-- ── PUNTED (stated limitations, not ambiguous forks) ─────────────────────
-- - No parser/lexer — programs are hand-built Lua-table ASTs.
-- - No let-polymorphism / Hindley-Milner generalization over ordinary
--   `let`. Generics only via explicit `type_params` on a `fn` literal that
--   is the direct RHS of a `let`, and such a function must have a fully
--   annotated return type (no inferring it before generalizing).
-- - No explicit type-application syntax (`f<Int>(x)`); all instantiation
--   is automatic via fresh uvars at Instantiate.
-- - No records / field projection — dropped entirely rather than adding
--   an ad-hoc 7th judgment or hand-wiring projection outside the claims
--   engine; nothing in the required test programs needs it (the CLI
--   test's "handlers" are modeled as a homogeneous string-keyed map, not
--   a record, sidestepping projection).
-- - No width subtyping on maps/records (none exist besides the map type,
--   which is homogeneous by construction).
-- - Bidirectional Check does not push expected types down into
--   if/let/map_lit for better error locality; it's a uniform
--   infer-then-subtype "switch" rule everywhere.
--
-- OWNER-CALL D — uvar resolution strategy. When a uvar accumulates a
-- fully-ground lower bound, _try_resolve auto-resolves the uvar to that
-- bound. Alternatives not chosen: resolve to the GLB/LUB (requires
-- lattice machinery); never auto-resolve (breaks existing tests); delay
-- until both lower and upper bounds exist (too conservative). The cost:
-- auto-resolve is eager, so a uvar resolved from its first ground lower
-- bound cannot later be widened by a second lower bound arriving through
-- a different path. See pool.lua _try_resolve for the full rationale.
--
-- ── WHAT WOULD BREAK FIRST IF EXTENDED ────────────────────────────────────
-- Real let-polymorphism (generalizing over unification variables that
-- happen not to escape into the surrounding env) would need OWNER-CALL D's
-- resolution strategy to be less eager — currently a uvar auto-resolves
-- on the first ground lower bound, which forecloses widening from a
-- second call site. Records/field projection would need a genuine 7th
-- judgment (or an env-like side-channel of the same OWNER-CALL-A shape)
-- and is the next thing someone will reach for once the map-only stand-in
-- stops being enough.

local ir = require("lib.toy_checker.ir")
local Pool = require("lib.toy_checker.pool")
local producers = require("lib.toy_checker.producers")

--:: require "lib.toy_checker.ir"
--:: require "lib.toy_checker.pool"

local M = {}

M.ir = ir
M.Pool = Pool

-- Optional fields (`?:`, not `: T | nil`) so `{}` alone is a valid CheckOpts —
-- `field: T | nil` requires the key to be present (with value nil); `field?:
-- T` allows the key to be omitted entirely, which is what an opts-table
-- default (`opts = opts or {}`) needs.
--:: CheckOpts = { expected?: Type, env?: Env }

-- Build a fresh pool with all producers registered.
--: () -> PoolObj
function M.new_checker()
	local p = Pool.new() --[[: PoolObj]] -- cross-module return-type inference gap, see producers.lua's doc comment
	producers.register_all(p)
	return p
end

-- Mirrors pool.lua's RunResult exactly, except the "proved" case additionally
-- carries the resolved `type` (RunResult's own "proved" variant doesn't need
-- one — pool.lua is judgment-agnostic and has no notion of "the" answer type;
-- that's check_verbose's job to attach here).
--:: CheckResult = { verdict: "proved", type: Type } | { verdict: "refuted", message: string, obligation: Obligation, trail: { [integer]: string } } | { verdict: "stuck", message: string, obligations: { [integer]: Obligation } }

-- Typecheck `expr` (an Infer, unless opts.expected is given, in which case
-- a Check against that type). opts.env sets the initial typing context
-- (e.g. builtins) — nil means empty.
--: (Expr, CheckOpts | nil) -> CheckResult
function M.check_verbose(expr, opts)
	-- Unpack into two individually-optional locals rather than defaulting
	-- the whole opts table (`local o = opts or {}`). The latter was tried
	-- first and doesn't typecheck: once `opts: CheckOpts | nil` is merged
	-- with `{}` into a fresh local, `if o.expected then ... o.expected ...`
	-- stops narrowing away the `nil` on the second use — confirmed via a
	-- 10-line repro (an `Opts | nil` parameter combined with `or {}` loses
	-- optional-field narrowing even on the very next statement; the
	-- identical narrowing on a directly-typed, non-defaulted `Opts`
	-- parameter works fine). Splitting into separate locals up front
	-- sidesteps it entirely.
	local expected = opts and opts.expected
	local env = opts and opts.env
	local p = M.new_checker()
	if expected then
		p:submit("Check", { expr, expected }, nil, "program", env)
		local result = p:run()
		if result.verdict == "proved" then
			return { verdict = "proved", type = ir.deref(expected) }
		end
		return result --[[: CheckResult]]
	else
		local out = ir.mk_uvar() --[[: Type]]
		p:submit("Infer", { expr, out }, nil, "program", env)
		local result = p:run()
		if result.verdict == "proved" then
			return { verdict = "proved", type = ir.deref(out) }
		end
		return result --[[: CheckResult]]
	end
end

-- Convention-compliant primary entry point: (nil, errmsg) on failure
-- (refutation OR stuck), the resolved type on success.
--: (Expr, CheckOpts | nil) -> (Type | nil, string | nil)
function M.check(expr, opts)
	local r = M.check_verbose(expr, opts)
	if r.verdict == "proved" then return r.type end
	if r.verdict == "refuted" then
		local lines = { r.message }
		for _, line in ipairs(r.trail) do
			lines[#lines + 1] = "  from " .. line
		end
		return nil, table.concat(lines, "\n")
	end
	return nil, r.message
end

return M
