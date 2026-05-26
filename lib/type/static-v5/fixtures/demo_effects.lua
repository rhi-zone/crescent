-- lib/type/static-v5/fixtures/demo_effects.lua
-- Hand-verification demo for `bin/cr check --v5`.
--
-- Run:  bin/cr check --v5 lib/type/static-v5/fixtures/demo_effects.lua
--
-- Expected output (after 5.F3 fix): 1 error from section 7 (deliberate F2
-- violation — annotated pure function calls io.write via dotted callee).
-- All other sections are clean, including:
--   section 4 (pcall consumes !throw so the outer () -> nil annotation is met)
--   section 6 (coroutine.create wraps a yielding fn; outer fn is pure)
--   section 6b (coroutine with explicit Coroutine<Y,S,R> annotation typechecks)
--
-- Each section exercises a distinct feature of the v5 effect system.

-- ── 1. Pure annotated function — no effects ──────────────────────────────────
--: (number) -> number
local function pure_add(x)
    return x + 1
end

-- ── 2. Unannotated function calling io.write ─────────────────────────────────
-- Effects are inferred and folded into the return type; no F2 check.
local function greet()
    io.write("hello\n")
end

-- ── 3. Direct-binding !io via print ─────────────────────────────────────────
-- print is a directly-bound stdlib name; !io propagates at gen-pass time.
-- Unannotated: effects inferred silently.
local function greet_print()
    print("hello")
end

-- ── 4. pcall consumes !throw (5.F2) ─────────────────────────────────────────
-- pcall wraps a function that throws; the throw is absorbed.
-- The outer function is annotated pure (() -> nil); after 5.F2, the !throw
-- from error() is consumed by pcall and the annotation is satisfied.
--: () -> nil
local function safe_call()
    local ok = pcall(function()
        error("boom")
    end)
    local _ = ok
end

-- ── 4b. pcall return type is the discriminated union (5.F2) ─────────────────
-- pcall returns (true, ...) | (false, string).  The return is unioned into
-- the single binding 'ok'; annotating as unknown passes.
local function pcall_ret_demo()
    --: unknown
    local ok = pcall(function() error("e") end)
    local _ = ok
end

-- ── 5. Unannotated — mixed !io + !throw effects inferred ────────────────────
local function mixed(x)
    if x == nil then error("nil") end
    io.write(tostring(x))
end

-- ── 6. Unannotated coroutine create (5.F3) ──────────────────────────────────
-- coroutine.create wraps a yielding function; !yield is consumed.
-- The outer coro_demo is unannotated so effects are inferred silently.
local function coro_demo()
    local co = coroutine.create(function()
        coroutine.yield(1)
    end)
    local _ = co
end

-- ── 6b. Coroutine create in an annotated pure outer function (5.F3) ──────────
-- coroutine.create consumes !yield from the inner function; the outer function
-- is annotated pure (() -> nil) and should typecheck clean.
--: () -> nil
local function coro_pure_outer()
    local co = coroutine.create(function()
        coroutine.yield(42)
    end)
    local _ = co
end

-- ── 7. Deliberate F2 violation: annotated pure function calls io.write ───────
-- This function is annotated as pure (() -> nil) but calls io.write which
-- carries the !io effect.  After Phase 5.F1, the dotted callee is resolved at
-- gen time and the F2 constraint fires.  This SHOULD produce an error.
--: () -> nil
local function pure_but_writes()
    io.write("this is an F2 violation\n")
end

-- Suppress unused warnings.
local _ = pure_add(0)
local _ = greet
local _ = greet_print
local _ = safe_call
local _ = pcall_ret_demo
local _ = mixed
local _ = coro_demo
local _ = coro_pure_outer
local _ = pure_but_writes
