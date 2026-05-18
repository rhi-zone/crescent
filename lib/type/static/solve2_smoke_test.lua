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
end)
