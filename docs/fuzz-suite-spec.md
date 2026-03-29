# Invariant-Based Fuzz Suite Spec

## Goal

A test file `lib/type/static/fuzz_test.lua` that encodes the type system's invariants as fuzz targets. Programs are generated randomly; each invariant asserts a property that must hold across all inputs. Bugs are found when an invariant fails on a generated input.

The invariants encode the **spirit** of the type system from first principles — not mirroring the implementation. The implementation may be wrong; the invariants are the ground truth.

## Structure

```lua
-- lib/type/static/fuzz_test.lua
local check = require("lib.type.static.check")
local arb = require("lib.test.arb")
local fuzz = require("lib.test.fuzz")

-- Run with: luajit lib/test/cli.lua lib/type/static/fuzz_test.lua
-- Or: FUZZ_SEED=12345 luajit lib/test/cli.lua lib/type/static/fuzz_test.lua
```

## Helper: `typechecks(src)` and `rejects(src)`

```lua
local function typechecks(src)
    local errs = check.check_string(src)
    return #errs == 0
end

local function rejects(src)
    local errs = check.check_string(src)
    return #errs > 0
end

local function errors_count(src)
    return #check.check_string(src)
end
```

## Invariant 1: Subtyping (reflexivity)

Any value accepted where its own type is expected:

```lua
fuzz.it("subtyping: every type is a subtype of itself", function(rng)
    -- generate a type annotation T and a value v of type T
    -- assert: v accepted where T expected
    local T = arb_type(rng)
    local v = arb_value_of_type(rng, T)
    local src = ("local x --: %s = %s"):format(T, v)
    assert(typechecks(src), "value of type T rejected where T expected: " .. src)
end, { n = 500 })
```

## Invariant 2: Union introduction

A value of type A is assignable to `A | B`:

```lua
fuzz.it("union intro: A assignable to A | B", function(rng)
    local A, B = arb_base_type(rng), arb_base_type(rng)
    local v = arb_value_of_type(rng, A)
    local src = ("local x --: %s | %s = %s"):format(A, B, v)
    assert(typechecks(src), src)
end, { n = 500 })
```

## Invariant 3: Function type soundness

Calling with correct arg type always typechecks; calling with wrong type always errors:

```lua
fuzz.it("function: correct arg accepted", function(rng)
    local A, B = arb_base_type(rng), arb_base_type(rng)
    local v = arb_value_of_type(rng, A)
    local src = ("local f --: (%s) -> %s\nf(%s)"):format(A, B, v)
    assert(typechecks(src), src)
end, { n = 500 })

fuzz.it("function: wrong arg rejected", function(rng)
    local A, B = arb_distinct_types(rng)  -- A ~= B, neither is any/unknown
    local v = arb_value_of_type(rng, B)
    local src = ("local f --: (%s) -> nil\nf(%s)"):format(A, v)
    assert(rejects(src), "wrong arg not rejected: " .. src)
end, { n = 500 })
```

## Invariant 4: Narrowing correctness

After a nil check, the non-nil branch has the non-nil type:

```lua
fuzz.it("narrowing: non-nil branch excludes nil", function(rng)
    local T = arb_base_type(rng)
    -- x: T | nil; after `if x then`, x: T
    local src = ([[
        local x --: %s | nil
        if x then
            local y --: %s = x
        end
    ]]):format(T, T)
    assert(typechecks(src), src)
end, { n = 500 })
```

## Invariant 5: Literal type precision

A literal value has its specific literal type, not just the base type:

```lua
fuzz.it("literal: assigned to specific literal type", function(rng)
    local n = rng:int(0, 100)
    assert(typechecks(("local x --: %d = %d"):format(n, n)))
    assert(rejects(("local x --: %d = %d"):format(n, n + 1)))
end, { n = 200 })
```

## Invariant 6: Generic instantiation

A generic function called with type A produces a value of type A:

```lua
fuzz.it("generic: instantiation preserves type", function(rng)
    local T = arb_base_type(rng)
    local v = arb_value_of_type(rng, T)
    local src = ([[
        local id --: <T>(T) -> T
        local x --: %s = id(%s)
    ]]):format(T, v)
    assert(typechecks(src), src)
end, { n = 300 })
```

## Invariant 7: No errors on valid programs (false positive check)

A corpus of known-valid programs must typecheck with 0 errors:

```lua
local valid_corpus = {
    "local x = 1",
    "local x --: integer = 1",
    "local x --: string = 'hello'",
    "local function f(x --: integer) return x + 1 end",
    -- ... more from existing passing tests
}
fuzz.it("no false positives on valid corpus", function(rng)
    local src = valid_corpus[rng:int(1, #valid_corpus)]
    assert(typechecks(src), "valid program rejected: " .. src)
end, { n = #valid_corpus * 10 })
```

## Generators Needed

```lua
-- arb_base_type(rng) -> "integer" | "number" | "string" | "boolean" | "nil"
-- arb_type(rng) -> base type, union, optional, function type
-- arb_value_of_type(rng, type_str) -> Lua literal string matching type_str
-- arb_distinct_types(rng) -> (A, B) where A ~= B and neither is any/unknown
```

These are string-level generators (they produce Lua source fragments), not type-level. Start simple: `arb_base_type` picks from {"integer", "number", "string", "boolean"}. `arb_value_of_type("integer")` returns a random integer literal. Build up from there.

## Performance Gate

```lua
-- At the end of fuzz_test.lua:
local t0 = os.clock()
-- run the full suite on a fixed 1000-program corpus
local t1 = os.clock()
local throughput = 1000 / (t1 - t0)
assert(throughput > 500, ("throughput %d programs/sec < 500 threshold"):format(throughput))
```

Threshold of 500 programs/sec is a starting point — calibrate against actual measurement and the tsgo benchmark.

## Files to Create

- `lib/type/static/fuzz_test.lua` — the fuzz suite
- `lib/type/static/fuzz_arb.lua` — Lua source fragment generators (separate file for reuse)

## Running

```bash
luajit lib/test/cli.lua lib/type/static/fuzz_test.lua
FUZZ_SEED=42 luajit lib/test/cli.lua lib/type/static/fuzz_test.lua  # replay
```
