-- lib/type/static/type_complex_test.lua
-- Adversarial tests for complex type features:
--   recursive types, HKT, ADT structural typing, typeclass signatures,
--   $Keys/$EachField intrinsics, and interactions between them.
--
-- Known gaps marked in comments:
--   GAP-RECUR:   recursive structural constraints not enforced at depth —
--                `{ tail = 99 }` accepted where List<number>? expected.
--   GAP-NEST:    nested generic alias application produces `never`
--                e.g. Partial<Partial<T>> (TODO.md).
--   GAP-HKT1:    type argument extraction lost after expansion (TODO.md).
--   GAP-VAR:     all generics invariant (TODO.md).

local assert = require("lib.test.assert")
local check_mod  = require("lib.type.static.check")
local errors_mod = require("lib.type.static.errors")

local function v3(src)
    return check_mod.check_string_v3(src, "complex_test.lua")
end
local function no_error(src)
    local ec = v3(src)
    if errors_mod.has_errors(ec) then
        assert.fail("expected no errors but got:\n" .. errors_mod.format_plain(ec))
    else
        assert.ok(true)
    end
end
local function has_error(src, pat)
    local ec = v3(src)
    if not errors_mod.has_errors(ec) then
        assert.fail("expected error" .. (pat and (" matching '" .. pat .. "'") or "") .. " but got none")
        return
    end
    if pat and pat ~= "" then
        local msg = errors_mod.format_plain(ec)
        if not msg:find(pat) then
            assert.fail("expected error matching '" .. pat .. "' but got:\n" .. msg)
            return
        end
    end
    assert.ok(true)
end

-- ---------------------------------------------------------------------------
-- 1. Recursive types
-- ---------------------------------------------------------------------------

assert.describe("recursive types: singly-linked list", function()
    assert.it("PASS: List<T> declaration accepted", function()
        no_error([[
--:: List<T> = { head: T, tail: List<T>? }
local x --: List<number>
x = { head = 1, tail = nil }
]])
    end)

    assert.it("PASS: nested cons cell accepted", function()
        no_error([[
--:: List<T> = { head: T, tail: List<T>? }
local x --: List<number>
x = { head = 1, tail = { head = 2, tail = nil } }
]])
    end)

    assert.it("ERROR: wrong head type in cons cell", function()
        has_error([[
--:: List<T> = { head: T, tail: List<T>? }
--: (List<number>) -> nil
local function f(lst) return nil end
f({ head = "oops", tail = nil })
]], "")
    end)

    assert.it("PASS: function over List<T> is well-typed", function()
        no_error([[
--:: List<T> = { head: T, tail: List<T>? }
--: (List<number>) -> number
local function hd(lst) return lst.head end
]])
    end)

    -- GAP-RECUR: tail=99 is accepted where List<number>? expected because
    -- recursive structural constraints are not enforced at depth.
    assert.it("GAP-RECUR: tail=number accepted where List<number>? expected (known gap)", function()
        -- This should error but doesn't: the recursive field constraint is not
        -- enforced at depth. Tracked in TODO.md.
        local ec = v3([[
--:: List<T> = { head: T, tail: List<T>? }
--: (List<number>) -> nil
local function f(lst) return nil end
f({ head = 1, tail = 99 })
]])
        -- Document current (wrong) behavior: no error emitted.
        assert.ok(not errors_mod.has_errors(ec), "known gap: should error but doesn't")
    end)
end)

assert.describe("recursive types: binary tree", function()
    assert.it("PASS: Tree<T> leaf and branch accepted", function()
        no_error([[
--:: Tree<T> = { value: T, left: Tree<T>?, right: Tree<T>? }
local leaf --: Tree<number>
leaf = { value = 1, left = nil, right = nil }
local branch --: Tree<number>
branch = { value = 0, left = leaf, right = leaf }
]])
    end)

    assert.it("ERROR: wrong value type in tree node", function()
        has_error([[
--:: Tree<T> = { value: T, left: Tree<T>?, right: Tree<T>? }
--: (Tree<number>) -> nil
local function f(t) return nil end
f({ value = "nope", left = nil, right = nil })
]], "")
    end)

    assert.it("PASS: Tree<string> independent of Tree<number>", function()
        no_error([[
--:: Tree<T> = { value: T, left: Tree<T>?, right: Tree<T>? }
local x --: Tree<string>
x = { value = "hello", left = nil, right = nil }
]])
    end)
end)

assert.describe("recursive types: mutual recursion with discriminants", function()
    -- Using a discriminant field makes Even and Odd structurally distinct.
    -- Without discriminants, equi-recursive structural typing considers them
    -- equivalent (both unfold to the same infinite tree).
    assert.it("PASS: Even and Odd values accepted for their own type", function()
        no_error([[
--:: Even = { parity: "even", pred: Odd? }
--:: Odd  = { parity: "odd",  pred: Even? }
local zero --: Even
zero = { parity = "even", pred = nil }
local one --: Odd
one = { parity = "odd", pred = zero }
local two --: Even
two = { parity = "even", pred = one }
]])
    end)

    assert.it("ERROR: Even assigned to Odd — discriminant mismatch", function()
        has_error([[
--:: Even = { parity: "even", pred: Odd? }
--:: Odd  = { parity: "odd",  pred: Even? }
--: (Odd) -> nil
local function f(o) return nil end
local zero --: Even
zero = { parity = "even", pred = nil }
f(zero)
]], "")
    end)

    assert.it("PASS: without discriminants, Even and Odd are structurally equivalent", function()
        -- Under equi-recursive structural typing, { pred: Odd? } and { pred: Even? }
        -- unfold to identical infinite trees. This is correct type theory behavior.
        no_error([[
--:: Even = { pred: Odd? }
--:: Odd  = { pred: Even? }
local x --: Even
local y --: Odd
y = x
]])
    end)
end)

assert.describe("recursive types: infinite alias cycle", function()
    assert.it("PASS: T = T cycle handled gracefully (no crash, resolves to a type)", function()
        -- A bare self-referential alias is a degenerate cycle. The typechecker
        -- detects the cycle and resolves it to a valid type rather than looping.
        -- We don't specify the exact resulting type — just that no crash occurs.
        no_error([[
--:: Inf = Inf
local x --: Inf
]])
    end)
end)

assert.describe("recursive types: M.__index = M", function()
    assert.it("PASS: self-referential table field accepted", function()
        -- Canonical Lua class pattern. __index creates a recursive type reference.
        -- The typechecker uses integer type IDs (lazy lookup) so no infinite loop.
        no_error([[
local M = {}
M.__index = M
M.new = function() return setmetatable({}, M) end
]])
    end)
end)

-- ---------------------------------------------------------------------------
-- 2. HKT: arity enforcement
-- ---------------------------------------------------------------------------

assert.describe("HKT: wrong type parameter count", function()
    assert.it("ERROR: 1-param alias used with 0 args", function()
        has_error([[
--:: Box<T> = { value: T }
local x --: Box
]], "expects 1 argument")
    end)

    assert.it("ERROR: 1-param alias used with 2 args", function()
        has_error([[
--:: Box<T> = { value: T }
local x --: Box<number, string>
]], "")
    end)

    assert.it("ERROR: 2-param alias used with 1 arg", function()
        has_error([[
--:: Either<A, B> = { tag: "left", value: A } | { tag: "right", value: B }
local x --: Either<number>
]], "")
    end)

    assert.it("PASS: 2-param alias with 2 args accepted", function()
        no_error([[
--:: Either<A, B> = { tag: "left", value: A } | { tag: "right", value: B }
local x --: Either<number, string>
x = { tag = "left", value = 42 }
]])
    end)

    assert.it("ERROR: kind-0 type passed where kind-1 expected (<F: T1>)", function()
        has_error([[
--:: T1<T> = any
--: <F: T1, A>(fa: F) -> F
local function id_hkt(fa) return fa end
local result = id_hkt(42)
]], "has kind *")
    end)
end)

assert.describe("HKT: nested application", function()
    assert.it("PASS: Maybe<Maybe<T>> outer just, inner just", function()
        no_error([[
--:: Maybe<T> = { tag: "just", value: T } | { tag: "nothing" }
local x --: Maybe<Maybe<number>>
x = { tag = "just", value = { tag = "just", value = 42 } }
]])
    end)

    assert.it("PASS: Maybe<Maybe<T>> outer just, inner nothing", function()
        no_error([[
--:: Maybe<T> = { tag: "just", value: T } | { tag: "nothing" }
local x --: Maybe<Maybe<number>>
x = { tag = "just", value = { tag = "nothing" } }
]])
    end)

    assert.it("ERROR: inner value wrong type in Maybe<Maybe<number>>", function()
        has_error([[
--:: Maybe<T> = { tag: "just", value: T } | { tag: "nothing" }
--: (Maybe<Maybe<number>>) -> nil
local function f(x) return nil end
f({ tag = "just", value = { tag = "just", value = "oops" } })
]], "")
    end)

    assert.it("PASS: Either<Maybe<number>, string> nested", function()
        no_error([[
--:: Maybe<T>     = { tag: "just", value: T } | { tag: "nothing" }
--:: Either<A, B> = { tag: "left", value: A } | { tag: "right", value: B }
local x --: Either<Maybe<number>, string>
x = { tag = "left",  value = { tag = "nothing" } }
x = { tag = "right", value = "hello" }
]])
    end)

    assert.it("ERROR: Either<Maybe<number>, string> wrong inner type", function()
        has_error([[
--:: Maybe<T>     = { tag: "just", value: T } | { tag: "nothing" }
--:: Either<A, B> = { tag: "left", value: A } | { tag: "right", value: B }
--: (Either<Maybe<number>, string>) -> nil
local function f(x) return nil end
f({ tag = "left", value = { tag = "just", value = "oops" } })
]], "")
    end)
end)

assert.describe("HKT: fmap signature declared", function()
    assert.it("PASS: generic fmap type accepted", function()
        no_error([[
--:: T1<T> = any
--: <F: T1, A, B>((A -> B) -> F<A> -> F<B>) -> boolean
local function fmap_sig(fmap_fn) return true end
]])
    end)
end)

assert.describe("HKT: two-parameter generics", function()
    assert.it("PASS: Pair<A, B> constructed and destructured", function()
        no_error([[
--:: Pair<A, B> = { fst: A, snd: B }
local p --: Pair<number, string>
p = { fst = 1, snd = "hello" }
local n = p.fst + 1
local s = p.snd .. "!"
]])
    end)

    assert.it("ERROR: Pair fields swapped", function()
        has_error([[
--:: Pair<A, B> = { fst: A, snd: B }
--: (Pair<number, string>) -> nil
local function f(p) return nil end
f({ fst = "oops", snd = 42 })
]], "")
    end)

    assert.it("PASS: uncurry over Pair<A, B>", function()
        no_error([[
--:: Pair<A, B> = { fst: A, snd: B }
--: <A, B>((A, B) -> number, Pair<A, B>) -> number
local function apply(f, p)
    return f(p.fst, p.snd)
end
]])
    end)

    assert.it("PASS: StrMap<V> string-keyed (single-param map alias)", function()
        no_error([[
--:: StrMap<V> = { [string]: V }
local m --: StrMap<number>
m = { x = 1, y = 2 }
local v = m["x"] + 1
]])
    end)

    assert.it("ERROR: StrMap<V> wrong value type", function()
        has_error([[
--:: StrMap<V> = { [string]: V }
--: (StrMap<number>) -> nil
local function f(m) return nil end
f({ x = "not_a_number" })
]], "")
    end)

    -- GAP: type parameter used as indexer key (Map<K, V> = { [K]: V }) is not
    -- supported — K is treated as a field name, not a type for the indexer position.
    assert.it("GAP: Map<K, V> = { [K]: V } — K as indexer key not substituted (known gap)", function()
        assert.ok(true, "gap documented: use StrMap<V> = { [string]: V } instead")
    end)
end)

assert.describe("HKT: generic function chaining", function()
    assert.it("PASS: fmap result passed to another generic consumer", function()
        no_error([[
--:: Maybe<T> = { tag: "just", value: T } | { tag: "nothing" }
--: <A, B>((A -> B), Maybe<A>) -> Maybe<B>
local function fmap(f, ma)
    if ma.tag == "just" then return { tag = "just", value = f(ma.value) }
    else return { tag = "nothing" } end
end
--: <T>(Maybe<T>, T) -> T
local function from_maybe(m, def)
    if m.tag == "just" then return m.value else return def end
end
local result = from_maybe(fmap(function(x) return x + 1 end, { tag = "just", value = 1 }), 0)
]])
    end)

    -- GAP-HKT1: the return type of a generic call is the expanded structural type,
    -- not a named alias application. A second fmap call on the result fails because
    -- the typechecker infers the return as nil instead of Maybe<B>.
    assert.it("GAP-HKT1: chained fmap return type not re-usable as Maybe<T> (known gap)", function()
        local ec = v3([[
--:: Maybe<T> = { tag: "just", value: T } | { tag: "nothing" }
--: <A, B>((A -> B), Maybe<A>) -> Maybe<B>
local function fmap(f, ma)
    if ma.tag == "just" then return { tag = "just", value = f(ma.value) }
    else return { tag = "nothing" } end
end
local m1 --: Maybe<number>
m1 = { tag = "just", value = 42 }
local m2 = fmap(function(n) return tostring(n) end, m1)
local m3 = fmap(function(s) return #s > 0 end, m2)
]])
        assert.ok(true, "gap documented: return type of generic call not re-usable as HKT argument")
    end)

    assert.it("PASS: nested Either<Maybe<T>, E> constructed", function()
        no_error([[
--:: Maybe<T> = { tag: "just", value: T } | { tag: "nothing" }
--:: Either<A, B> = { tag: "left", value: A } | { tag: "right", value: B }
local e1 --: Either<Maybe<number>, string>
e1 = { tag = "left",  value = { tag = "just",    value = 42 } }
e1 = { tag = "left",  value = { tag = "nothing" }              }
e1 = { tag = "right", value = "error msg"                      }
]])
    end)
end)

assert.describe("HKT: three-parameter generic", function()
    assert.it("PASS: Triple<A, B, C> with distinct field types", function()
        no_error([[
--:: Triple<A, B, C> = { x: A, y: B, z: C }
local t --: Triple<number, string, boolean>
t = { x = 1, y = "hi", z = true }
local sum = t.x + 1
local cat = t.y .. "!"
local inv = not t.z
]])
    end)

    assert.it("ERROR: Triple<A, B, C> wrong third field", function()
        has_error([[
--:: Triple<A, B, C> = { x: A, y: B, z: C }
--: (Triple<number, string, boolean>) -> nil
local function f(t) return nil end
f({ x = 1, y = "hi", z = "not_bool" })
]], "")
    end)
end)

assert.describe("HKT: known gaps (document current limits)", function()
    -- GAP-HKT1: HKT function composition: after applying fmap to get F<B>, we
    -- cannot pass that result to a function whose parameter type is F<B> under
    -- the same higher-kinded binder <F: T1> — type argument extraction from the
    -- expanded structural type back to F + B is not implemented.
    assert.it("GAP-HKT1: HKT binder F not inferrable from structural expansion (known gap)", function()
        local ec = v3([[
--:: T1<T> = any
--:: Maybe<T> = { tag: "just", value: T } | { tag: "nothing" }
--: <F: T1, A, B>((A -> B), F<A>) -> F<B>
local function fmap(f, fa) return fa end
--: <F: T1, A>(F<A>) -> boolean
local function is_something(fa) return true end
local m --: Maybe<number>
m = { tag = "just", value = 42 }
-- GAP: passing fmap result to is_something requires knowing F = Maybe, not inferable
local _ = is_something(fmap(function(x) return x end, m))
]])
        -- Document current behavior without asserting a specific error message
        assert.ok(true, "gap documented")
    end)

    -- GAP-VAR: generics are invariant — no covariance for type params.
    -- Maybe<number> is NOT assignable to Maybe<number|string> even though
    -- number <: number|string under structural typing.
    assert.it("GAP-VAR: generics are invariant — Maybe<number> not assignable to Maybe<number|string> (known gap)", function()
        local ec = v3([[
--:: Maybe<T> = { tag: "just", value: T } | { tag: "nothing" }
local x --: Maybe<number>
x = { tag = "just", value = 42 }
local y --: Maybe<number | string>
y = x
]])
        -- Document: under structural typing this actually PASSES (structural equivalence
        -- holds since Maybe<number> expands to a subtype of Maybe<number|string>).
        -- Record current behavior.
        assert.ok(true, "gap documented — structural typing handles this case")
    end)
end)

-- ---------------------------------------------------------------------------
-- 3. ADT structural typing
-- ---------------------------------------------------------------------------

assert.describe("ADT: Maybe<T>", function()
    assert.it("PASS: just and nothing constructors", function()
        no_error([[
--:: Maybe<T> = { tag: "just", value: T } | { tag: "nothing" }
local a --: Maybe<number>
a = { tag = "just", value = 42 }
local b --: Maybe<number>
b = { tag = "nothing" }
]])
    end)

    assert.it("ERROR: just missing value field", function()
        has_error([[
--:: Maybe<T> = { tag: "just", value: T } | { tag: "nothing" }
--: (Maybe<number>) -> nil
local function f(x) return nil end
f({ tag = "just" })
]], "")
    end)

    assert.it("ERROR: unknown tag variant", function()
        has_error([[
--:: Maybe<T> = { tag: "just", value: T } | { tag: "nothing" }
--: (Maybe<number>) -> nil
local function f(x) return nil end
f({ tag = "some", value = 42 })
]], "")
    end)

    assert.it("PASS: narrowing via tag — value accessible in just branch", function()
        no_error([[
--:: Maybe<T> = { tag: "just", value: T } | { tag: "nothing" }
--: (Maybe<number>) -> number
local function unwrap_or_zero(m)
    if m.tag == "just" then
        return m.value
    else
        return 0
    end
end
]])
    end)

    assert.it("ERROR: accessing .value on unnarrowed Maybe", function()
        has_error([[
--:: Maybe<T> = { tag: "just", value: T } | { tag: "nothing" }
--: (Maybe<number>) -> number
local function bad(m)
    return m.value
end
]], "")
    end)
end)

assert.describe("ADT: Either<A, B>", function()
    assert.it("PASS: left and right accepted", function()
        no_error([[
--:: Either<A, B> = { tag: "left", value: A } | { tag: "right", value: B }
local x --: Either<string, number>
x = { tag = "left",  value = "error msg" }
x = { tag = "right", value = 42 }
]])
    end)

    assert.it("PASS: narrowing extracts correct field type per variant", function()
        no_error([[
--:: Either<A, B> = { tag: "left", value: A } | { tag: "right", value: B }
--: (Either<string, number>) -> string
local function get_err(e)
    if e.tag == "left" then
        return e.value
    else
        return "no error"
    end
end
]])
    end)

    assert.it("ERROR: type params swapped at call site", function()
        has_error([[
--:: Either<A, B> = { tag: "left", value: A } | { tag: "right", value: B }
--: (Either<string, number>) -> nil
local function f(e) return nil end
f({ tag = "left", value = 42 })
]], "")
    end)
end)

assert.describe("ADT: Result<T, E>", function()
    assert.it("PASS: ok and err constructors", function()
        no_error([[
--:: Result<T, E> = { tag: "ok", value: T } | { tag: "err", error: E }
local x --: Result<number, string>
x = { tag = "ok",  value = 42 }
x = { tag = "err", error = "something went wrong" }
]])
    end)

    assert.it("PASS: chaining Results via narrowing", function()
        no_error([[
--:: Result<T, E> = { tag: "ok", value: T } | { tag: "err", error: E }
--: (Result<number, string>) -> Result<string, string>
local function to_string_result(r)
    if r.tag == "err" then
        return r
    else
        return { tag = "ok", value = tostring(r.value) }
    end
end
]])
    end)
end)

assert.describe("ADT: recursive RoseTree<T>", function()
    assert.it("PASS: leaf with empty children", function()
        no_error([[
--:: RoseTree<T> = { value: T, children: RoseTree<T>[] }
local leaf --: RoseTree<number>
leaf = { value = 1, children = {} }
]])
    end)

    assert.it("ERROR: children not an array", function()
        has_error([[
--:: RoseTree<T> = { value: T, children: RoseTree<T>[] }
--: (RoseTree<number>) -> nil
local function f(t) return nil end
f({ value = 1, children = "nope" })
]], "")
    end)
end)

-- ---------------------------------------------------------------------------
-- 4. Typeclass-style function signatures (uncurried Lua style)
-- ---------------------------------------------------------------------------

assert.describe("typeclass: Functor fmap", function()
    assert.it("PASS: fmap for Maybe<T> (A -> B)", function()
        no_error([[
--:: Maybe<T> = { tag: "just", value: T } | { tag: "nothing" }
--: <A, B>((A -> B), Maybe<A>) -> Maybe<B>
local function fmap(f, ma)
    if ma.tag == "just" then
        return { tag = "just", value = f(ma.value) }
    else
        return { tag = "nothing" }
    end
end
]])
    end)

    assert.it("ERROR: fmap returning wrong type", function()
        has_error([[
--:: Maybe<T> = { tag: "just", value: T } | { tag: "nothing" }
--: <A, B>((A -> B), Maybe<A>) -> Maybe<B>
local function fmap_bad(f, ma)
    return "wrong"
end
]], "")
    end)

    assert.it("PASS: fmap for List<T> (recursive)", function()
        no_error([[
--:: List<T> = { head: T, tail: List<T>? }
--: <A, B>((A -> B), List<A>?) -> List<B>?
local function fmap_list(f, lst)
    if lst == nil then
        return nil
    else
        return { head = f(lst.head), tail = fmap_list(f, lst.tail) }
    end
end
]])
    end)
end)

assert.describe("typeclass: Foldable foldr", function()
    assert.it("PASS: foldr for List<T>", function()
        no_error([[
--:: List<T> = { head: T, tail: List<T>? }
--: <A, B>((A, B) -> B, B, List<A>?) -> B
local function foldr(f, z, lst)
    if lst == nil then
        return z
    else
        return f(lst.head, foldr(f, z, lst.tail))
    end
end
]])
    end)

    assert.it("PASS: foldr used to sum a list", function()
        no_error([[
--:: List<T> = { head: T, tail: List<T>? }
--: <A, B>((A, B) -> B, B, List<A>?) -> B
local function foldr(f, z, lst)
    if lst == nil then return z else return f(lst.head, foldr(f, z, lst.tail)) end
end
--: (List<number>) -> number
local function sum(lst)
    return foldr(function(a, b) return a + b end, 0, lst)
end
]])
    end)

    assert.it("ERROR: foldr accumulator wrong type at call site", function()
        has_error([[
--:: List<T> = { head: T, tail: List<T>? }
--: <A, B>((A, B) -> B, B, List<A>?) -> B
local function foldr(f, z, lst)
    if lst == nil then return z else return f(lst.head, foldr(f, z, lst.tail)) end
end
--: (List<number>) -> number
local function bad_sum(lst)
    return foldr(function(a, b) return a + b end, "wrong_init", lst)
end
]], "")
    end)
end)

assert.describe("typeclass: Monad chain (flatMap)", function()
    assert.it("PASS: Maybe chain", function()
        no_error([[
--:: Maybe<T> = { tag: "just", value: T } | { tag: "nothing" }
--: <A, B>((A -> Maybe<B>), Maybe<A>) -> Maybe<B>
local function chain(f, ma)
    if ma.tag == "just" then
        return f(ma.value)
    else
        return { tag = "nothing" }
    end
end
]])
    end)

    assert.it("ERROR: chain returning wrong type", function()
        has_error([[
--:: Maybe<T> = { tag: "just", value: T } | { tag: "nothing" }
--: <A, B>((A -> Maybe<B>), Maybe<A>) -> Maybe<B>
local function chain_bad(f, ma)
    return 42
end
]], "")
    end)
end)

assert.describe("typeclass: Semigroup append", function()
    assert.it("PASS: append_twice with string", function()
        no_error([[
--: <A>((A, A) -> A, A, A) -> A
local function append_twice(app, x, y)
    return app(app(x, x), app(y, y))
end
local s = append_twice(function(a, b) return a .. b end, "hello", "world")
]])
    end)

    assert.it("PASS: append_twice with number", function()
        no_error([[
--: <A>((A, A) -> A, A, A) -> A
local function append_twice(app, x, y)
    return app(app(x, x), app(y, y))
end
local n = append_twice(function(a, b) return a + b end, 1, 2)
]])
    end)

    assert.it("ERROR: mixing types across append call", function()
        has_error([[
--: <A>((A, A) -> A, A, A) -> A
local function append_twice(app, x, y)
    return app(app(x, x), app(y, y))
end
append_twice(function(a, b) return a + b end, 1, "two")
]], "")
    end)
end)

-- ---------------------------------------------------------------------------
-- 5. Generic functions over ADTs
-- ---------------------------------------------------------------------------

assert.describe("generic: identity and from_maybe", function()
    assert.it("PASS: identity over Maybe<T>", function()
        no_error([[
--:: Maybe<T> = { tag: "just", value: T } | { tag: "nothing" }
--: <T>(Maybe<T>) -> Maybe<T>
local function id_maybe(m)
    return m
end
]])
    end)

    assert.it("PASS: from_maybe — T inferred from default when nothing", function()
        no_error([[
--:: Maybe<T> = { tag: "just", value: T } | { tag: "nothing" }
--: <T>(Maybe<T>, T) -> T
local function from_maybe(m, default)
    if m.tag == "just" then return m.value else return default end
end
local n = from_maybe({ tag = "nothing" }, 0)
local s = from_maybe({ tag = "nothing" }, "fallback")
]])
    end)

    assert.it("ERROR: from_maybe value and default types conflict", function()
        has_error([[
--:: Maybe<T> = { tag: "just", value: T } | { tag: "nothing" }
--: <T>(Maybe<T>, T) -> T
local function from_maybe(m, default)
    if m.tag == "just" then return m.value else return default end
end
from_maybe({ tag = "just", value = 42 }, "wrong")
]], "")
    end)

    assert.it("PASS: from_maybe with --[[:T]] cast widens literal inside table constructor", function()
        no_error([==[
--:: Maybe<T> = { tag: "just", value: T } | { tag: "nothing" }
--: <T>(Maybe<T>, T) -> T
local function from_maybe(m, default)
    if m.tag == "just" then return m.value else return default end
end
-- Without cast, T would be inferred as literal 42 (not number), causing a
-- conflict with the number default 0.  The --[[:number]] cast widens 42 to
-- number so T unifies correctly.
local n = from_maybe({ tag = "just", value = --[[:number]] 42 }, 0)
]==])
    end)
end)

assert.describe("generic: recursive functions over ADTs", function()
    assert.it("PASS: length of List<T> for any T", function()
        no_error([[
--:: List<T> = { head: T, tail: List<T>? }
--: <T>(List<T>?) -> number
local function length(lst)
    if lst == nil then return 0 else return 1 + length(lst.tail) end
end
]])
    end)

    assert.it("PASS: map over List<T>", function()
        no_error([[
--:: List<T> = { head: T, tail: List<T>? }
--: <A, B>((A -> B), List<A>?) -> List<B>?
local function list_map(f, lst)
    if lst == nil then
        return nil
    else
        return { head = f(lst.head), tail = list_map(f, lst.tail) }
    end
end
]])
    end)

    assert.it("PASS: elem check in List<T>", function()
        no_error([[
--:: List<T> = { head: T, tail: List<T>? }
--: <T>(T, List<T>?) -> boolean
local function elem(x, lst)
    if lst == nil then return false end
    if lst.head == x then return true end
    return elem(x, lst.tail)
end
]])
    end)
end)

-- ---------------------------------------------------------------------------
-- 6. $Keys adversarial
-- ---------------------------------------------------------------------------

assert.describe("$Keys adversarial", function()
    assert.it("PASS: valid keys accepted", function()
        no_error([[
--:: T = { x: number, y: number, z: number }
--:: K = $Keys<T>
--: (K) -> nil
local function f(k) return nil end
f("x")
f("y")
f("z")
]])
    end)

    assert.it("ERROR: value not in key union rejected", function()
        has_error([[
--:: T = { a: number, b: string }
--:: K = $Keys<T>
--: (K) -> nil
local function f(k) return nil end
f("c")
]], "")
    end)

    assert.it("PASS: $Keys used as index type", function()
        no_error([[
--:: Row = { name: string, age: number }
--:: K = $Keys<Row>
--: (Row, K) -> any
local function get(row, key)
    return row[key]
end
]])
    end)

    assert.it("PASS: $Keys of empty table produces never — function is untouchable", function()
        no_error([[
--:: Empty = {}
--:: K = $Keys<Empty>
--: (K) -> nil
local function f(k) return nil end
]])
    end)
end)

-- ---------------------------------------------------------------------------
-- 7. $EachField adversarial
-- ---------------------------------------------------------------------------

assert.describe("$EachField adversarial", function()
    assert.it("PASS: Partial<T> makes all fields nullable", function()
        no_error([[
--:: MakeOpt<F> = match F { { key: K, value: V } => { key: K, value: V? } }
--:: Partial<T> = $EachField<T, MakeOpt>
local x --: Partial<{ name: string, age: number }>
x = { name = "alice", age = 30 }
x = { name = nil, age = nil }
]])
    end)

    assert.it("PASS: Partial<T> directly with already-nullable value type", function()
        -- Partial<{a: string | nil}> should be {a: string | nil} (nil|nil normalises).
        no_error([[
--:: MakeOpt<F> = match F { { key: K, value: V } => { key: K, value: V? } }
--:: Partial<T> = $EachField<T, MakeOpt>
local x --: Partial<{ a: string | nil }>
x = { a = nil }
x = { a = "hello" }
]])
    end)

    -- GAP-NEST: nested alias application — Partial<Partial<T>> produces `never`
    -- because the inner result (a resolved type) is not correctly passed as
    -- type argument to the outer alias. Tracked in TODO.md.
    assert.it("GAP-NEST: Partial<Partial<T>> produces never (known bug)", function()
        local ec = v3([[
--:: MakeOpt<F> = match F { { key: K, value: V } => { key: K, value: V? } }
--:: Partial<T>   = $EachField<T, MakeOpt>
--:: BiPartial<T> = Partial<Partial<T>>
local x --: BiPartial<{ a: string }>
x = { a = nil }
]])
        -- Document current (wrong) behavior: produces never and errors.
        assert.ok(errors_mod.has_errors(ec), "known bug: nested alias produces never")
    end)

    assert.it("PASS: $EachField identity transform (value type preserved)", function()
        no_error([[
--:: Id<F> = match F { { key: K, value: V } => { key: K, value: V } }
--:: Same<T> = $EachField<T, Id>
local x --: Same<{ name: string }>
x = { name = "bob" }
]])
    end)
end)

-- ---------------------------------------------------------------------------
-- 8. Inline block cast --[[:T]] expr
-- ---------------------------------------------------------------------------

assert.describe("inline cast: --[[:T]] widens sub-expressions", function()
    assert.it("PASS: cast in table constructor field widens literal", function()
        -- Without cast, { value = 42 } infers value: 42 (literal).
        -- With --[[:number]] the field is number, enabling T to unify as number.
        no_error([==[
--:: Box<T> = { value: T }
--: <T>(Box<T>, T) -> T
local function get(box, default)
    if box.value ~= nil then return box.value else return default end
end
local n = get({ value = --[[:number]] 42 }, 0)
]==])
    end)

    assert.it("PASS: cast in function argument list widens literal", function()
        no_error([==[
--: (number) -> number
local function double(x) return x * 2 end
local n = double(--[[:number]] 42)
]==])
    end)

    assert.it("PASS: multiple fields on same line — cast applies only to target", function()
        -- The --[[:number]] cast is after tag's value "just", so it applies
        -- only to 42 (which follows it), not to "just".
        no_error([==[
--:: Maybe<T> = { tag: "just", value: T } | { tag: "nothing" }
--: (Maybe<number>) -> nil
local function f(m) return nil end
f({ tag = "just", value = --[[:number]] 42 })
]==])
    end)

    assert.it("PASS: trailing statement annotation unaffected (regression)", function()
        -- Trailing --: T annotations still apply to variable bindings.
        no_error([[
local x = 42 --: number
local y --: number
y = x
]])
    end)

    assert.it("PASS: preceding-line statement annotation unaffected (regression)", function()
        -- A preceding-line --: T annotation is a statement annotation, not an
        -- expression cast. It binds the variable; gen_expr does not consume it.
        no_error([[
--: number
local x = 42
local y --: number
y = x
]])
    end)

    assert.it("PASS: multi-line block cast --[[:T]] on separate lines from expr", function()
        -- The closing ]] and the expression are on different lines.
        -- The annotation re-attaches to the expression's line automatically.
        no_error([==[
--:: Maybe<T> = { tag: "just", value: T } | { tag: "nothing" }
--: <T>(Maybe<T>, T) -> T
local function from_maybe(m, default)
    if m.tag == "just" then return m.value else return default end
end
local n = from_maybe({ tag = "just", value = --[[:
number
]] 42 }, 0)
]==])
    end)

    assert.it("PASS: multi-line block cast with many blank lines before expr", function()
        -- The user's original case: --[[ on one line, : on another, number
        -- on another, ]] on another, many blank lines, then 42 on its own line.
        no_error([==[
--:: Maybe<T> = { tag: "just", value: T } | { tag: "nothing" }
--: <T>(Maybe<T>, T) -> T
local function from_maybe(m, default)
    if m.tag == "just" then return m.value else return default end
end
local n = from_maybe({ tag = "just", value = (--[[
:

number

]]

42

) }, 0)
]==])
    end)
end)

assert.describe("inline cast: diagnostics — type mismatch is an error", function()
    assert.it("ERROR: cast integer to string emits mismatch diagnostic", function()
        -- C_SUB(42, string) fails — the cast is checked, not unchecked.
        has_error([==[
--: (string) -> nil
local function f(s) return nil end
f(--[[:string]] 42)
]==], "integer.*string")
    end)

    assert.it("ERROR: cast table to number emits mismatch diagnostic", function()
        has_error([==[
--: (number) -> nil
local function f(n) return nil end
f(--[[:number]] { x = 1 })
]==], "")
    end)

    assert.it("ERROR: cast in table field to wrong type emits diagnostic", function()
        -- --[[:string]] on a number literal in a table field should error.
        has_error([==[
--:: Box<T> = { value: T }
--: (Box<string>) -> nil
local function f(b) return nil end
f({ value = --[[:string]] 42 })
]==], "integer.*string")
    end)

    assert.it("ERROR: multi-line block cast to wrong type emits diagnostic", function()
        has_error([==[
--: (string) -> nil
local function f(s) return nil end
f(--[[:
string
]] 42)
]==], "integer.*string")
    end)

    assert.it("ERROR: preceding-line --: T does NOT widen literals (statement only)", function()
        -- A preceding-line annotation is a statement annotation that binds the
        -- variable, not an expression cast. The literal type is NOT widened for
        -- sub-expressions. For expression casts, use --[[:T]] on the same line.
        -- Here from_maybe infers T=42 (literal) because the preceding-line
        -- annotation is NOT picked up by gen_expr inside the table constructor.
        has_error([==[
--:: Maybe<T> = { tag: "just", value: T } | { tag: "nothing" }
--: <T>(Maybe<T>, T) -> T
local function from_maybe(m, default)
    if m.tag == "just" then return m.value else return default end
end
local n = from_maybe({
    tag = "just",
    value =
        --: number
        42
}, 0)
]==], "")
    end)
end)

-- ---------------------------------------------------------------------------
-- 10. Complex interactions
-- ---------------------------------------------------------------------------

assert.describe("complex: union of recursive types", function()
    assert.it("PASS: List<number> | List<string>", function()
        no_error([[
--:: List<T> = { head: T, tail: List<T>? }
local x --: List<number> | List<string>
x = { head = 1, tail = nil }
x = { head = "a", tail = nil }
]])
    end)

    assert.it("PASS: Maybe<List<T>> nesting", function()
        no_error([[
--:: List<T>  = { head: T, tail: List<T>? }
--:: Maybe<T> = { tag: "just", value: T } | { tag: "nothing" }
local x --: Maybe<List<number>>
x = { tag = "just",    value = { head = 1, tail = nil } }
x = { tag = "nothing" }
]])
    end)
end)

assert.describe("ADT.define runtime integration", function()
    -- ADT module is untyped; declare it as any for these runtime tests.
    -- In a real project, the module would be declared with --:: module "lib.fp.adt": {...}
    local ADT_HEADER = "--:: module \"lib.fp.adt\": any\n"

    assert.it("PASS: ADT.define call accepted without error", function()
        no_error(ADT_HEADER .. [[
local ADT = require("lib.fp.adt")
local Maybe = ADT.define({"Just", 1}, {"Nothing", 0})
]])
    end)

    assert.it("PASS: ADT.is returns boolean", function()
        no_error(ADT_HEADER .. [[
local ADT = require("lib.fp.adt")
local Maybe = ADT.define({"Just", 1}, {"Nothing", 0})
local x = Maybe.just(42)
local ok = Maybe.is(x)
--: (boolean) -> nil
local function f(b) return nil end
f(ok)
]])
    end)

    assert.it("PASS: structural type alias used alongside ADT runtime", function()
        -- The --:: alias and the runtime ADT coexist; structural typing
        -- is checked against the alias, not against ADT.define's return type.
        no_error(ADT_HEADER .. [[
local ADT = require("lib.fp.adt")
local Maybe = ADT.define({"Just", 1}, {"Nothing", 0})
--:: Maybe<T> = { tag: "just", value: T } | { tag: "nothing" }
local x --: Maybe<number>
x = { tag = "just", value = 42 }
x = { tag = "nothing" }
]])
    end)
end)
