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
-- 1. Modes drive scheduling for real, but NOT uniformly across judgments —
--    this was the single most interesting finding. Initially every "in"
--    position was pool-gated (deferred until resolved). That deadlocks:
--    Sub and Unify are perfectly capable of running against an unresolved
--    unification variable (that's what eager unification IS — bind the
--    var and move on), so gating them on "in" meant a Sub whose only path
--    to resolution was itself running would wait forever on itself
--    transitively (see the CLI-shaped test: dispatch's generic handler
--    type only ever gets pinned down by the very Sub obligation checking
--    a handler literal against it). The fix: blocking is declared
--    per-producer, per-argument-index at registration (`pool:register(...,
--    {1})`), not hardcoded per judgment name in the pool loop — and in
--    this toy only Instantiate's scheme position actually needs it, because
--    a scheme is atomic (there's no such thing as "half a scheme" the way
--    a partially-bound type is meaningful). Unify/Sub/Infer/Check/
--    Generalize never block. So: the in/out distinction is load-bearing
--    everywhere (out positions get written by exactly one producer, in
--    positions are read-only to their producer) but scheduling-by-mode
--    (deferral) is load-bearing only at the Instantiate boundary. Honestly
--    flagging this per the task brief: don't take "modes drive scheduling"
--    to mean every judgment needs pool-level blocking — most don't, in a
--    substrate built on mutable unification cells.
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
-- OWNER-CALL C — Sub against an unresolved unification variable. A fully
-- principled bidirectional-subtyping engine tracks upper/lower BOUND SETS
-- per uvar and defers a Sub obligation until enough is known to check
-- soundly. This toy instead collapses Sub to Unify (equality) the instant
-- either side derefs to an unresolved uvar. Chosen because bound-set
-- tracking is real substrate this sketch doesn't have; the cost is
-- genuine lost precision (Sub(int, ?x) forces ?x := int outright instead
-- of recording "?x >= int" and staying open to also unify ?x with
-- `number` later from a different call site).
--
-- This fork turned out to be sharper than expected. First cut: never
-- block Sub at all (let the collapse-to-Unify fallback run immediately
-- against whatever's there). That's actually UNSOUND against ordering:
-- check_expr's fallback submits Infer(expr, fresh) and Sub(fresh,
-- expected) as FIFO siblings, and Sub could pop and collapse-bind `fresh`
-- straight to `expected` before the sibling Infer ever got to write
-- fresh's real inferred type into it — a race that silently produces the
-- wrong bind (caught by the SHOULD-FAIL string/int test only by luck: it
-- turned into a Unify mismatch instead of the intended Sub refutation,
-- which was the tell that something was wrong). The fix, now in place:
-- Sub blocks on position 1 (the "actual" value being checked) but never
-- on position 2 (the "expected"/upper-bound side). That's a real,
-- principled asymmetry — position 1 has to be genuinely known before
-- "is this a subtype of X" means anything, while position 2 is allowed to
-- still be an open variable that Sub itself pins (exactly the pattern the
-- CLI-shaped test needs: a generic handler-map's value type gets pinned
-- by the Sub checking a concrete handler literal against it). Still not
-- full bound-set tracking — a second, differently-shaped actual value
-- checked against the same still-open expected-side var later would
-- clobber rather than widen — but it's no longer ordering-dependent.
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
-- ── WHAT WOULD BREAK FIRST IF EXTENDED ────────────────────────────────────
-- Real let-polymorphism (generalizing over unification variables that
-- happen not to escape into the surrounding env) would immediately need
-- OWNER-CALL C's bound-set tracking to be done properly first — the
-- current Sub-collapses-to-Unify shortcut would silently over-constrain
-- inferred types the moment two different call sites want to instantiate
-- the same let-bound value at different subtypes. Records/field
-- projection would need a genuine 7th judgment (or an env-like
-- side-channel of the same OWNER-CALL-A shape) and is the next thing
-- someone will reach for once the map-only stand-in stops being enough.

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
