-- lib/type/static/solve2_smoke_test.lua
-- Smoke test for solve2.lua (Outside-In/X core, P1 of the rewrite —
-- docs/typechecker-solver-rewrite.md).
--
-- Exercises a single C_UNIFY end-to-end through M.solve_one: build a
-- minimal ctx, allocate two compatible types, wrap them in a wanted, and
-- assert the new core retires the wanted with no diagnostics emitted.

local assert      = require("lib.test.assert")
local intern      = require("lib.type.static.intern")
local types_mod   = require("lib.type.static.types")
local env_mod     = require("lib.type.static.env")
local errors_mod  = require("lib.type.static.errors")
local constrain   = require("lib.type.static.constrain")
local solve2      = require("lib.type.static.solve2")
local solve_mod   = require("lib.type.static.solve")
local unify_mod   = require("lib.type.static.unify")
local defs        = require("lib.type.static.defs")

-- Minimal ctx factory. Mirrors cdef_test.lua's new_ctx but also wires the
-- fields solve handlers read: err sink, filename, tv_waiters (already on
-- new_ctx), bind generation counter.
local function new_ctx()
    local pool = intern.new()
    local ctx  = types_mod.new_ctx(pool)
    ctx.scope  = env_mod.new(0)
    ctx.err    = errors_mod.new_ctx()
    ctx.filename = "<smoke>"
    ctx._bind_generation = 0
    return ctx
end

assert.describe("solve2: smoke", function()
    assert.it("retires a C_UNIFY between two compatible types", function()
        local ctx = new_ctx()
        -- integer ~ integer is trivially solvable; the only outcome that
        -- matters for P1 is that the wanted lands in `solved` state with
        -- no diagnostics in ctx.err.
        local c = constrain.make_unify(ctx.T_INTEGER, ctx.T_INTEGER, 1, 1)
        local impl = solve2.solve_one(ctx, c)
        assert.eq(#impl.wanteds, 1, "exactly one wanted should remain on the impl")
        local w = impl.wanteds[1]
        assert.eq(solve2.is_retired(w), true, "wanted should be retired (solved)")
        assert.eq(solve2.is_parked(w), false, "wanted should not be parked")
        assert.eq(#ctx.err.errors, 0, "no errors should be emitted")
        assert.eq(#ctx.err.warnings, 0, "no warnings should be emitted")
    end)

    assert.it("reports a type mismatch via the legacy handler", function()
        local ctx = new_ctx()
        -- integer vs string: the legacy solve_unify emits a diagnostic and
        -- returns true (terminal). P1 mirrors that — the wanted is retired
        -- and the error reaches ctx.err.
        local c = constrain.make_unify(ctx.T_INTEGER, ctx.T_STRING, 2, 3)
        local impl = solve2.solve_one(ctx, c)
        assert.eq(solve2.is_retired(impl.wanteds[1]), true,
            "failed wanted is still retired (legacy contract)")
        assert.ok(#ctx.err.errors >= 1, "at least one error should be emitted")
    end)

    assert.it("wake clears blocked_on for matching TV", function()
        local ctx = new_ctx()
        local impl = solve2.new_implication(nil)
        local w = solve2.new_wanted(constrain.C_UNIFY, { constrain.C_UNIFY, 0, 0, 1, 1 })
        w.status = "parked"
        w.blocked_on = 42
        impl.wanteds[1] = w
        solve2.wake(ctx, impl, 42)
        assert.eq(w.blocked_on, nil, "wake should clear blocked_on for matching TV")
        assert.eq(w.status, "active", "wake should flip status to active")
    end)

    assert.it("wake leaves unrelated parked wanteds untouched", function()
        local ctx = new_ctx()
        local impl = solve2.new_implication(nil)
        local w = solve2.new_wanted(constrain.C_UNIFY, { constrain.C_UNIFY, 0, 0, 1, 1 })
        w.status = "parked"
        w.blocked_on = 99
        impl.wanteds[1] = w
        solve2.wake(ctx, impl, 42)
        assert.eq(w.blocked_on, 99, "unrelated park should not be woken")
        assert.eq(w.status, "parked", "unrelated park keeps parked status")
    end)

    -- P2: dispatch_one is the per-kind entry from solve_range. C_UNIFY and
    -- C_SUB are both terminal — they return true on success, emit no
    -- children. The boolean return drives solve_range.run_one's
    -- _solved/_deferred flagging.
    assert.it("dispatch_one solves C_UNIFY between compatible types", function()
        local ctx = new_ctx()
        local c = constrain.make_unify(ctx.T_INTEGER, ctx.T_INTEGER, 1, 1)
        local solved = solve2.dispatch_one(ctx, c)
        assert.eq(solved, true, "C_UNIFY of integer~integer should solve")
        assert.eq(#ctx.err.errors, 0, "no error from successful unify")
    end)

    assert.it("dispatch_one routes failure through to ctx.err", function()
        local ctx = new_ctx()
        local c = constrain.make_unify(ctx.T_INTEGER, ctx.T_STRING, 1, 1)
        local solved = solve2.dispatch_one(ctx, c)
        -- Legacy handler emits a diagnostic and returns true (terminal);
        -- dispatch_one mirrors that — the wanted retires and the error
        -- reaches ctx.err exactly once.
        assert.eq(solved, true, "failed unify is terminal-solved (legacy contract)")
        assert.ok(#ctx.err.errors >= 1, "error reaches ctx.err")
    end)

    -- P3: a deferring handler returns `{ solved=false, await=tv }`, and
    -- the new dispatcher captures the awaited TV into `Wanted.blocked_on`
    -- so wake_ctx can flip the wanted back to active without consulting
    -- the legacy tv_waiters channel. We exercise C_BOUND because it goes
    -- through `await(ctx, c, actual)` whenever the bounded TV is still
    -- free — a deterministic park.
    assert.it("blocked_on is captured when a handler awaits a free TV", function()
        local ctx = new_ctx()
        -- Free TV (the "actual" type being bound-checked) and a concrete
        -- bound type that doesn't matter because the handler defers on
        -- the free actual TV first.
        local free_tv = types_mod.make_var(ctx, 0)
        local c = constrain.make_bound(free_tv, ctx.T_INTEGER, 1, 1)
        local impl = solve2.new_implication(nil)
        local w = solve2.new_wanted(c[1], c)
        impl.wanteds[1] = w
        solve2.simplify(ctx, impl)
        assert.eq(w.status, "parked", "C_BOUND on free TV must park")
        assert.eq(w.blocked_on, free_tv, "blocked_on captured from await()")
    end)

    -- P2: M.PORTED is the per-kind dispatch table solve_range checks.
    -- C_UNIFY and C_SUB are both included; nothing else (yet).
    assert.it("PORTED set contains the P2 + P3 + P4 ported kinds", function()
        -- P2: terminal kinds.
        assert.eq(solve2.PORTED[constrain.C_UNIFY], true, "C_UNIFY is ported")
        assert.eq(solve2.PORTED[constrain.C_SUB], true, "C_SUB is ported")
        -- P3: deferring kinds (use blocked_on capture).
        assert.eq(solve2.PORTED[constrain.C_BOUND], true, "C_BOUND is ported")
        assert.eq(solve2.PORTED[constrain.C_NARROW_NIL], true, "C_NARROW_NIL is ported")
        assert.eq(solve2.PORTED[constrain.C_ESCAPE_CHECK], true, "C_ESCAPE_CHECK is ported")
        assert.eq(solve2.PORTED[constrain.C_OR], true, "C_OR is ported")
        -- P4: call-path family routed through simplify with TV ownership.
        assert.eq(solve2.PORTED[constrain.C_CALLABLE], true, "C_CALLABLE is ported")
        assert.eq(solve2.PORTED[constrain.C_CHECK_ARGS], true, "C_CHECK_ARGS is ported")
        assert.eq(solve2.PORTED[constrain.C_INSTANTIATE_AT_CALL], true, "C_INSTANTIATE_AT_CALL is ported")
        assert.eq(solve2.PORTED[constrain.C_BIND_GENERICS], true, "C_BIND_GENERICS is ported")
        -- P5 candidates: not yet ported.
        assert.eq(solve2.PORTED[constrain.C_INDEX], nil, "C_INDEX not yet ported")
    end)

    -- P2: wake_ctx walks the per-ctx implication stack pushed by simplify.
    -- With no implications live (no simplify on the stack), it is a no-op.
    -- This is what makes the call safe to invoke unconditionally from
    -- unify.bind_var_to_type.
    assert.it("wake_ctx is a no-op with no live implications", function()
        local ctx = new_ctx()
        solve2.wake_ctx(ctx, 42)  -- must not error
        assert.eq(ctx._solve2_impls, nil, "no implication stack created")
    end)

    -- P2: simplify publishes its implication on ctx._solve2_impls so
    -- wake_ctx (called from bind_var_to_type) can flip parked wanteds.
    -- A bind happening during simplify reaches the parked wanted in the
    -- same loop turn.
    -- TV ownership (cross-constraint dependency tracking — Phase F-blocker fix).
    --
    -- claim/is_owned/release are the primitive trio. A producer that has
    -- committed to writing a TV later calls `claim`; readers check
    -- `is_owned` before falling through to eager unify; the bind
    -- chokepoints (unify.bind_var_to_type, solve.bind_to) call `release`
    -- so the ownership clears in lockstep with the actual bind.
    assert.it("claim/is_owned/release form a coherent trio", function()
        local ctx = new_ctx()
        local tv = types_mod.make_var(ctx, 0)
        assert.eq(solve_mod.is_owned(ctx, tv), false, "fresh TV starts unowned")
        local owner = { constrain.C_CALLABLE } --: { [integer]: unknown, ... }
        solve_mod.claim(ctx, tv, owner)
        assert.eq(solve_mod.is_owned(ctx, tv), true, "is_owned reflects the claim")
        solve_mod.release(ctx, tv)
        assert.eq(solve_mod.is_owned(ctx, tv), false, "release clears ownership")
    end)

    -- The Phase F-blocker check: bind_var_to_type must clear ownership.
    -- Without this, a producer that completes its commitment would leave
    -- a stale claim behind, parking any subsequent reader forever.
    assert.it("bind_var_to_type releases TV ownership at the chokepoint", function()
        local ctx = new_ctx()
        local tv = types_mod.make_var(ctx, 0)
        local owner = { constrain.C_CALLABLE } --: { [integer]: unknown, ... }
        solve_mod.claim(ctx, tv, owner)
        assert.eq(solve_mod.is_owned(ctx, tv), true, "TV claimed before bind")
        unify_mod.bind_var_to_type(ctx, tv, ctx.T_INTEGER)
        assert.eq(solve_mod.is_owned(ctx, tv), false,
            "bind_var_to_type clears the claim — Phase F-blocker invariant")
    end)

    -- A cross-statement C_SUB whose `actual` is a still-pending call's
    -- ret_TV must defer (not eagerly unify). With ownership in place,
    -- solve_sub returns { solved=false, await=<root> } instead of
    -- binding ret_TV to whatever the next statement annotated.
    assert.it("solve_sub defers on a claimed ret_TV instead of eager binding", function()
        local ctx = new_ctx()
        ctx.tv_waiters = ctx.tv_waiters or {}
        local ret_tv = types_mod.make_var(ctx, 0)
        local pending_call = { constrain.C_CALLABLE } --: { [integer]: unknown, ... }
        solve_mod.claim(ctx, ret_tv, pending_call)
        -- C_SUB(ret_tv <: string): the reader pattern the blocker doc names.
        local sub_c = constrain.make_sub(ret_tv, ctx.T_STRING, 1, 1, false)
        local handlers = solve_mod.get_handlers()
        local result = handlers[constrain.C_SUB](ctx, sub_c)
        -- The handler returns the await record; the reader has parked.
        assert.eq(type(result), "table",
            "owned ret_TV must defer (not boolean retire)")
        local r = result --[[: { solved: boolean, await: integer | nil, emit: { [integer]: { [integer]: unknown, ... }, ... } | nil }]]
        assert.eq(r.solved, false, "deferral signaled via solved=false")
        assert.eq(r.await, ret_tv,
            "await targets the owned ret_TV — solve_sub did NOT bind it")
        -- And: ret_TV is still free (not bound to string).
        local rt = ctx.types:get(ret_tv)
        assert.eq(rt.tag == defs.TAG_VAR, true,
            "ret_TV unmodified — the producer's later bind is what writes it")
    end)

    -- Reader-side parity with solve_sub: solve_index has the same eager
    -- fast-paths that bind res_tid unconditionally. An owned res_tid must
    -- defer until the producer releases.
    assert.it("solve_index defers on a claimed res_TV instead of eager binding", function()
        local ctx = new_ctx()
        ctx.tv_waiters = ctx.tv_waiters or {}
        local res_tv = types_mod.make_var(ctx, 0)
        local pending_call = { constrain.C_CALLABLE } --: { [integer]: unknown, ... }
        solve_mod.claim(ctx, res_tv, pending_call)
        -- C_INDEX(obj, key=lit_int(0), res_tv): a tuple-slot projection of a
        -- still-pending call's return. Without the guard, solve_index would
        -- walk into the integer-key fast-paths and bind res_tv.
        local obj_tv = types_mod.make_var(ctx, 0)
        local key_tid = types_mod.make_literal(ctx, defs.LIT_INTEGER, 0)
        local idx_c = constrain.make_index(obj_tv, key_tid, res_tv, 1, 1)
        local handlers = solve_mod.get_handlers()
        local result = handlers[constrain.C_INDEX](ctx, idx_c)
        assert.eq(type(result), "table",
            "owned res_TV must defer (not boolean retire)")
        local r = result --[[: { solved: boolean, await: integer | nil, emit: { [integer]: { [integer]: unknown, ... }, ... } | nil }]]
        assert.eq(r.solved, false, "deferral signaled via solved=false")
        assert.eq(r.await, res_tv,
            "await targets the owned res_TV — solve_index did NOT bind it")
        local rt = ctx.types:get(res_tv)
        assert.eq(rt.tag == defs.TAG_VAR, true,
            "res_TV unmodified — the producer's later bind is what writes it")
    end)

    assert.it("simplify publishes impl on ctx for wake_ctx visibility", function()
        local ctx = new_ctx()
        local impl = solve2.new_implication(nil)
        local w = solve2.new_wanted(constrain.C_UNIFY, { constrain.C_UNIFY, 0, 0, 1, 1 })
        w.status = "parked"
        w.blocked_on = 77
        impl.wanteds[1] = w
        -- We can't call simplify directly without it draining; instead
        -- exercise wake_ctx by manually publishing the impl.
        ctx._solve2_impls = { impl }
        solve2.wake_ctx(ctx, 77)
        assert.eq(w.status, "active", "wake_ctx flips matching parked wanted")
        assert.eq(w.blocked_on, nil, "wake_ctx clears blocked_on")
    end)
end)
