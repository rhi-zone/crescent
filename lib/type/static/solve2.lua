-- lib/type/static/solve2.lua
-- Outside-In/X constraint solver core (Phase 1).
--
-- Coexists with solve.lua. This file lands the data shapes the rewrite
-- design (docs/typechecker-solver-rewrite.md, commit 710a8084) requires
-- — `Implication`, `Wanted`, the `simplify` scheduling loop, the `wake`
-- chokepoint — and a `solve_one` entry the smoke test exercises end-to-end.
--
-- The production path (M.solve in solve.lua) is unchanged in P1; nothing
-- in constrain.lua or check.lua routes through this file yet. Per-kind
-- handler porting happens in P2 onwards.
--
-- The vocabulary follows Vytiniotis et al. (2011) "OutsideIn(X)":
--
--   Implication { skolems, givens, wanteds, parent }
--     A scope. `skolems` lists rigid type variables introduced by this
--     scope (sub-solve parameters). `givens` are facts already known
--     inside the scope (saturated before any wanted runs — fundamental
--     #4, given-priority). `wanteds` are obligations to discharge.
--     `parent` is the enclosing implication, or nil at the root.
--
--   Wanted { kind, payload, status, blocked_on, evidence }
--     A single constraint. `kind` is the legacy C_* tag (constrain.C_UNIFY
--     etc.) so P1 can route through the existing handler dispatch table.
--     `payload` is the legacy constraint tuple. `status` is one of
--     "active" | "parked" | "retired". `blocked_on` carries the TV id this
--     wanted is currently parked on (only meaningful when status=="parked").
--     `evidence` is a placeholder for the proof term once we stop sharing
--     state with the legacy solver.
--
-- `simplify(ctx, impl)` is the defining scheduling contract:
--   1. Saturate givens to fixpoint (fundamental #4: givens before wanteds).
--   2. Drain active wanteds. Each is dispatched to the legacy handler in
--      P1; the handler's return shape (boolean | { solved, emit, await })
--      is preserved verbatim so the routing is observable from the inside.
--   3. Quiescence (fundamental #2): loop exits when the active queue is
--      empty AND no bind happened this round.
--
-- `wake(ctx, tv_id)` is the sleeper-wakeup chokepoint (fundamental #3).
-- In P1 only the smoke test invokes it; in P2 it becomes a peer to
-- `wake_waiters` inside `unify.bind_var_to_type`.

local constrain = require("lib.type.static.constrain")
local types_mod = require("lib.type.static.types")

local find = types_mod.find

-- Lazy require for solve.lua to avoid a require cycle (solve.lua requires
-- this file at its top so P2's per-kind dispatch can route into it). The
-- legacy handler table is materialised on first use, after both modules
-- have finished loading.
--: () -> { [integer]: ((Ctx, { [integer]: unknown, ... }) -> unknown) | nil, ... }
local function legacy_handlers()
    local solve = require("lib.type.static.solve") --[[: { get_handlers: () -> { [integer]: ((Ctx, { [integer]: unknown, ... }) -> unknown) | nil, ... }, ... } ]]
    return solve.get_handlers()
end

local M = {}

-- ---------------------------------------------------------------------------
-- Record types
-- ---------------------------------------------------------------------------
--
-- Both Implication and Wanted are plain Lua tables. Documented shape:
--
--   Wanted = {
--     kind:        integer,                       -- constrain.C_* tag
--     payload:     { [integer]: unknown, ... },   -- legacy constraint tuple
--     status:      "active" | "parked" | "retired",
--     blocked_on:  integer | nil,                 -- TV id when parked
--     evidence:    unknown | nil,                 -- proof-term placeholder
--   }
--
--   Implication = {
--     skolems: { [integer]: integer, ... },       -- rigid TV ids owned here
--     givens:  { [integer]: Wanted, ... },        -- saturated before wanteds
--     wanteds: { [integer]: Wanted, ... },
--     parent:  Implication | nil,
--   }

--: (unknown, { [integer]: unknown, ... }) -> { kind: unknown, payload: { [integer]: unknown, ... }, status: string, blocked_on: integer | nil, evidence: unknown | nil }
local function new_wanted(kind, payload)
    return {
        kind       = kind,
        payload    = payload,
        status     = "active",
        blocked_on = nil,
        evidence   = nil,
    }
end
M.new_wanted = new_wanted

--: ({ skolems: { [integer]: integer, ... }, givens: { [integer]: { kind: unknown, payload: { [integer]: unknown, ... }, status: string, blocked_on: integer | nil, evidence: unknown | nil }, ... }, wanteds: { [integer]: { kind: unknown, payload: { [integer]: unknown, ... }, status: string, blocked_on: integer | nil, evidence: unknown | nil }, ... }, parent: unknown | nil } | nil) -> { skolems: { [integer]: integer, ... }, givens: { [integer]: { kind: unknown, payload: { [integer]: unknown, ... }, status: string, blocked_on: integer | nil, evidence: unknown | nil }, ... }, wanteds: { [integer]: { kind: unknown, payload: { [integer]: unknown, ... }, status: string, blocked_on: integer | nil, evidence: unknown | nil }, ... }, parent: unknown | nil }
local function new_implication(parent)
    return {
        skolems = {},
        givens  = {},
        wanteds = {},
        parent  = parent,
    }
end
M.new_implication = new_implication

-- ---------------------------------------------------------------------------
-- Handler dispatch
-- ---------------------------------------------------------------------------
--
-- A handler returns either a boolean (true = solved, false = parked) or a
-- structured { solved, emit, await } table (the legacy `await` shape from
-- solve.M.await). We translate both into Wanted-level state transitions:
--
--   solved  → status = "retired"; not requeued.
--   parked  → status = "parked"; blocked_on set from the `await` slot when
--             present. The wanted stays in `impl.wanteds` but is skipped on
--             subsequent rounds until a bind wakes it.
--   emit    → each emitted constraint becomes a new Wanted appended to
--             `impl.wanteds`.

--: (Ctx, { skolems: { [integer]: integer, ... }, givens: { [integer]: { kind: unknown, payload: { [integer]: unknown, ... }, status: string, blocked_on: integer | nil, evidence: unknown | nil }, ... }, wanteds: { [integer]: { kind: unknown, payload: { [integer]: unknown, ... }, status: string, blocked_on: integer | nil, evidence: unknown | nil }, ... }, parent: unknown | nil }, { kind: unknown, payload: { [integer]: unknown, ... }, status: string, blocked_on: integer | nil, evidence: unknown | nil }) -> string
local function run_handler(ctx, impl, w)
    local handlers = legacy_handlers()
    local h = handlers[w.kind]
    if not h then
        -- Unknown kind: retire. Mirrors solve_range's c._solved = true for
        -- handler-less constraints — keeps the rewrite's scheduling loop
        -- byte-compatible with the legacy fallback when a new kind lands
        -- before its handler is ported.
        return "solved"
    end
    local result = h(ctx, w.payload)
    if type(result) == "boolean" then
        if result then return "solved" else return "parked" end
    end
    -- Structured form. The legacy handler return shape from solve.M.await
    -- is `{ solved: boolean, emit?, await? }`. Narrow via type guard, not
    -- a force cast: the typechecker can prove `result` is a table here.
    if type(result) == "table" then
        local res = result
        local emit_field = res.emit
        if type(emit_field) == "table" then
            for _, nc in ipairs(emit_field) do
                if type(nc) == "table" then
                    impl.wanteds[#impl.wanteds + 1] = new_wanted(nc[1], nc)
                end
            end
        end
        local solved_field = res.solved
        if solved_field == false then
            -- The handler also registered the legacy constraint on
            -- ctx.tv_waiters via solve.await (see solve.lua's `await`),
            -- so wake_waiters continues to drive re-runs through the
            -- legacy worklist when the TV binds. P2 doesn't capture the
            -- await TV id into blocked_on because the P2 ported kinds
            -- (C_UNIFY, C_SUB) are terminal — they never park — so the
            -- capture would be dead code. The handler dispatch table
            -- also erases the per-kind return shape (result arrives as
            -- `unknown`), and the legacy await contract states integer
            -- but the typechecker can only narrow to `number` via
            -- `type(x) == "number"`. P3 ports await-emitting kinds and
            -- types the handler return shape, at which point blocked_on
            -- capture lands without a force cast.
            return "parked"
        end
        return "solved"
    end
    -- Defensive: unknown return shape is treated as retired so the loop
    -- doesn't spin. P2's handler port replaces this dispatch entirely.
    return "solved"
end

-- ---------------------------------------------------------------------------
-- simplify
-- ---------------------------------------------------------------------------
--
-- Saturate givens, then drain wanteds, until quiescence. Returns the
-- implication for fluent inspection by callers (smoke test, future P2+).

--: (Ctx, { skolems: { [integer]: integer, ... }, givens: { [integer]: { kind: unknown, payload: { [integer]: unknown, ... }, status: string, blocked_on: integer | nil, evidence: unknown | nil }, ... }, wanteds: { [integer]: { kind: unknown, payload: { [integer]: unknown, ... }, status: string, blocked_on: integer | nil, evidence: unknown | nil }, ... }, parent: unknown | nil }) -> { skolems: { [integer]: integer, ... }, givens: { [integer]: { kind: unknown, payload: { [integer]: unknown, ... }, status: string, blocked_on: integer | nil, evidence: unknown | nil }, ... }, wanteds: { [integer]: { kind: unknown, payload: { [integer]: unknown, ... }, status: string, blocked_on: integer | nil, evidence: unknown | nil }, ... }, parent: unknown | nil }
function M.simplify(ctx, impl)
    -- Publish the implication so unify.bind_var_to_type → M.wake_ctx can
    -- transfer any wanted parked on a newly-bound TV back to "active" in
    -- the same loop turn. Stack-allocated so nested simplify (P3+
    -- sub-solve) inherits and restores ordering.
    --: { [integer]: { skolems: { [integer]: integer, ... }, givens: { [integer]: { kind: unknown, payload: { [integer]: unknown, ... }, status: string, blocked_on: integer | nil, evidence: unknown | nil }, ... }, wanteds: { [integer]: { kind: unknown, payload: { [integer]: unknown, ... }, status: string, blocked_on: integer | nil, evidence: unknown | nil }, ... }, parent: unknown | nil }, ... }
    local stack = ctx._solve2_impls --[[: { [integer]: { skolems: { [integer]: integer, ... }, givens: { [integer]: { kind: unknown, payload: { [integer]: unknown, ... }, status: string, blocked_on: integer | nil, evidence: unknown | nil }, ... }, wanteds: { [integer]: { kind: unknown, payload: { [integer]: unknown, ... }, status: string, blocked_on: integer | nil, evidence: unknown | nil }, ... }, parent: unknown | nil }, ... } | nil]] or {}
    ctx._solve2_impls = stack
    stack[#stack + 1] = impl

    -- Givens-first (fundamental #4). Run every given to fixpoint before
    -- any wanted gets a turn. In P1 nothing populates givens, but the
    -- loop is present so P2+ inherits the correct order of operations.
    local g_progress = true
    while g_progress do
        g_progress = false
        for _, gw in ipairs(impl.givens) do
            if gw.status == "active" then
                local st = run_handler(ctx, impl, gw)
                if st == "solved" then
                    gw.status = "retired"
                    g_progress = true
                else
                    gw.status = "parked"
                end
            end
        end
    end

    -- Wanteds. Quiescence: a round where no wanted retired AND no TV bind
    -- occurred. The bind generation counter is the same one the legacy
    -- solver uses; reading it keeps the two schedulers observing the same
    -- progress signal during the P1-P5 cohabitation window.
    while true do
        local gen_before = ctx._bind_generation or 0
        local solved_this_round = false
        for _, w in ipairs(impl.wanteds) do
            if w.status == "active" then
                local st = run_handler(ctx, impl, w)
                if st == "solved" then
                    w.status = "retired"
                    solved_this_round = true
                else
                    w.status = "parked"
                end
            end
        end
        local gen_after = ctx._bind_generation or 0
        if not solved_this_round and gen_after == gen_before then
            break
        end
    end

    -- Pop the implication. rawset to bypass index-signature nil rejection
    -- on the trailing slot.
    rawset(stack, #stack, nil)
    return impl
end

-- ---------------------------------------------------------------------------
-- wake
-- ---------------------------------------------------------------------------
--
-- Sleeper-wakeup chokepoint (fundamental #3). Transfers any wanteds in
-- `impl` parked on `tv_id` (or any TV unioned with it via union-find)
-- back to the active queue by flipping status from "parked" to "active".
--
-- P1 invokes this only from the smoke test. P2 wires it into
-- unify.bind_var_to_type as a peer to wake_waiters.

--: (Ctx, { skolems: { [integer]: integer, ... }, givens: { [integer]: { kind: unknown, payload: { [integer]: unknown, ... }, status: string, blocked_on: integer | nil, evidence: unknown | nil }, ... }, wanteds: { [integer]: { kind: unknown, payload: { [integer]: unknown, ... }, status: string, blocked_on: integer | nil, evidence: unknown | nil }, ... }, parent: unknown | nil }, integer) -> ()
function M.wake(ctx, impl, tv_id)
    local root = find(ctx, tv_id)
    for _, w in ipairs(impl.wanteds) do
        if w.status == "parked" then
            local b = w.blocked_on
            if b ~= nil and (b == tv_id or find(ctx, b) == root) then
                w.status = "active"
                w.blocked_on = nil
            end
        end
    end
end

-- Ctx-level wake (peer of unify.wake_waiters at the bind_var_to_type
-- chokepoint, per P2 of docs/typechecker-solver-rewrite.md). Iterates
-- every active implication on the stack and flips parked wanteds whose
-- blocked_on matches the bound TV. No-op if no implications are live —
-- this is what makes the call safe on the legacy code path.
--: (Ctx, integer) -> ()
function M.wake_ctx(ctx, tv_id)
    local stack = ctx._solve2_impls
    if not stack then return end
    for i = 1, #stack do
        M.wake(ctx, stack[i], tv_id)
    end
end

-- ---------------------------------------------------------------------------
-- solve_one (test entry)
-- ---------------------------------------------------------------------------
--
-- Wraps a single legacy-format constraint tuple in a one-Wanted root
-- implication, runs simplify, returns the implication. Used by the smoke
-- test to exercise the new core end-to-end. Production code does not call
-- this in P1.

--: (Ctx, { [integer]: unknown, ... }) -> { skolems: { [integer]: integer, ... }, givens: { [integer]: { kind: unknown, payload: { [integer]: unknown, ... }, status: string, blocked_on: integer | nil, evidence: unknown | nil }, ... }, wanteds: { [integer]: { kind: unknown, payload: { [integer]: unknown, ... }, status: string, blocked_on: integer | nil, evidence: unknown | nil }, ... }, parent: unknown | nil }
function M.solve_one(ctx, c)
    local impl = new_implication(nil)
    impl.wanteds[1] = new_wanted(c[1], c)
    return M.simplify(ctx, impl)
end

-- ---------------------------------------------------------------------------
-- dispatch_one (per-kind dispatch entry from solve_range, P2)
-- ---------------------------------------------------------------------------
--
-- Routes a single legacy constraint through `simplify` and reports the
-- outcome to solve_range. The fresh implication is short-lived: every
-- ported kind currently in P2 (C_UNIFY, C_SUB) is terminal and never
-- emits children — so the wanted retires or parks in one round and
-- `simplify` exits at quiescence. When P3+ ports kinds that emit, they
-- emit ported kinds only, which are absorbed inside the same simplify
-- drain; legacy never sees them.
--
-- Returns true if the wanted retired (caller marks c._solved), false if
-- parked (caller marks c._deferred). The handler's call into solve.await
-- has already registered c on ctx.tv_waiters, so wake_waiters drives the
-- legacy worklist re-run when the awaited TV binds — same channel the
-- pre-P2 path uses. The new Outside-In/X wake (M.wake_ctx) is structural
-- in P2: no P2-ported kind parks, so there is nothing for it to flip.
--: (Ctx, { [integer]: unknown, ... }) -> boolean
function M.dispatch_one(ctx, c)
    local impl = new_implication(nil)
    local w = new_wanted(c[1], c)
    impl.wanteds[1] = w
    M.simplify(ctx, impl)
    return w.status == "retired"
end

-- Convenience predicates for tests / future inert-set work.

--: ({ kind: unknown, payload: { [integer]: unknown, ... }, status: string, blocked_on: integer | nil, evidence: unknown | nil }) -> boolean
function M.is_retired(w)
    return w.status == "retired"
end

--: ({ kind: unknown, payload: { [integer]: unknown, ... }, status: string, blocked_on: integer | nil, evidence: unknown | nil }) -> boolean
function M.is_parked(w)
    return w.status == "parked"
end

-- Expose constraint kind constants so smoke / unit tests don't need to
-- pull constrain.lua separately.
M.C_UNIFY = constrain.C_UNIFY
M.C_SUB   = constrain.C_SUB

-- Set of constraint kinds that solve_range routes through `dispatch_one`
-- instead of the legacy handler dispatch. Expanded one kind at a time
-- per the rewrite phases (P3 adds C_BOUND/C_NARROW_NIL/C_ESCAPE_CHECK/C_OR;
-- P4 the call-path family; P5 the rest). Uniform predicate — no
-- per-kind carve-outs in solve_range.
--: { [integer]: boolean, ... }
M.PORTED = {
    [constrain.C_UNIFY] = true,
    [constrain.C_SUB]   = true,
}

return M
