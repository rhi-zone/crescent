-- lib/type/static-v5/fixtures/demo_effects.lua
-- Hand-verification demo for `bin/cr check --v5`.
--
-- Run:  bin/cr check --v5 lib/type/static-v5/fixtures/demo_effects.lua
--
-- Expected output: clean (0 errors).
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

-- ── 4. pcall consumes !throw ─────────────────────────────────────────────────
-- pcall wraps a function that throws; the throw is absorbed.
local function safe_call()
    local ok = pcall(function()
        error("boom")
    end)
    local _ = ok
end

-- ── 5. Unannotated — mixed !io + !throw effects inferred ────────────────────
local function mixed(x)
    if x == nil then error("nil") end
    io.write(tostring(x))
end

-- ── 6. Unannotated coroutine create ─────────────────────────────────────────
local function coro_demo()
    local co = coroutine.create(function()
        coroutine.yield(1)
    end)
    local _ = co
end

-- Suppress unused warnings.
local _ = pure_add(0)
local _ = greet
local _ = greet_print
local _ = safe_call
local _ = mixed
local _ = coro_demo
