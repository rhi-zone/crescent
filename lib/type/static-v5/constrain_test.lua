-- lib/type/static-v5/constrain_test.lua
-- Tests for the v5 constraint generation pass.
--
-- Each test provides a Lua source fixture and asserts on the resulting
-- constraint array (count + key structural atoms present).

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local T         = require("lib.test.assert")
local constrain = require("lib.type.static-v5.constrain")

local function generate(src, filename)
    return constrain.generate(src, filename or "test.lua", nil)
end

-- ── Helpers ───────────────────────────────────────────────────────────────────

-- Count constraints whose tag matches.
local function count_tag(constraints, tag)
    local n = 0
    for i = 1, #constraints do
        local c = constraints[i]
        if c ~= nil and c.tag == tag then n = n + 1 end
    end
    return n
end

-- Returns true iff any constraint in the array satisfies predicate.
local function any(constraints, pred)
    for i = 1, #constraints do
        local c = constraints[i]
        if c ~= nil and pred(c) then return true end
    end
    return false
end

-- ── Tests ─────────────────────────────────────────────────────────────────────

T.describe("v5 constrain", function()

    T.it("bare local x = 1 emits no constraints", function()
        local cs, errs = generate("local x = 1")
        T.eq(#errs, 0, "no errors")
        -- A bare integer literal binding needs no structural constraints.
        T.eq(#cs, 0, "no constraints emitted for bare literal")
    end)

    T.it("annotated local emits sub constraint", function()
        local src = "--: number\nlocal x = 1"
        local cs, errs = generate(src)
        T.eq(#errs, 0, "no errors")
        -- Annotation triggers a sub constraint: inferred_type <: number
        T.ok(count_tag(cs, "csub") >= 1, "at least one csub emitted")
    end)

    T.it("record table constructor has no constraints", function()
        -- { x = 1, y = 2 } is a closed record; gen_table_expr does not emit
        -- constraints — it returns a record type.
        local cs, errs = generate("local t = { x = 1, y = 2 }")
        T.eq(#errs, 0, "no errors")
        T.eq(#cs, 0, "no constraints for plain record literal")
    end)

    T.it("annotated local function emits sub constraint", function()
        local src = "--: (number) -> number\nlocal function f(x) return x end"
        local cs, errs = generate(src)
        T.eq(#errs, 0, "no errors")
        -- Annotation on function declaration: sub(fn_ty, ann_ty)
        T.ok(count_tag(cs, "csub") >= 1, "at least one csub emitted")
    end)

    T.it("unannotated local function f(x) return x end — no constraints", function()
        local src = "local function f(x) return x end"
        local cs, errs = generate(src)
        T.eq(#errs, 0, "no errors")
        -- No annotation: no sub constraints; the function body has a return but
        -- no annotation to sub-constrain against.
        T.eq(#cs, 0, "no constraints for unannotated identity function")
    end)

    T.it("method call obj:method() emits crow_extend + csub", function()
        local src = "local obj = {}\nobj:method(1, 2)"
        local cs, errs = generate(src)
        T.eq(#errs, 0, "no errors")
        -- method call emits:
        --   1. crow_extend for recv_ty["method"] = method_ty
        --   2. csub(method_ty, arrow(...))
        T.ok(count_tag(cs, "crow_extend") >= 1, "at least one crow_extend")
        T.ok(count_tag(cs, "csub") >= 1, "at least one csub (method arrow sub)")
        -- Both together
        T.ok(#cs >= 2, "at least 2 constraints total")
    end)

    T.it("field access t.x emits crow_extend", function()
        local src = "local t = {}\nlocal y = t.x"
        local cs, errs = generate(src)
        T.eq(#errs, 0, "no errors")
        T.ok(count_tag(cs, "crow_extend") >= 1, "crow_extend for field access")
        -- Check that at least one crow_extend has key == "x".
        local found = any(cs, function(c)
            return c.tag == "crow_extend" and c.key == "x"
        end)
        T.ok(found, "crow_extend with key 'x' present")
    end)

    T.it("function call f(1, 2) emits csub with arrow", function()
        local src = "local function f(x, y) end\nf(1, 2)"
        local cs, errs = generate(src)
        T.eq(#errs, 0, "no errors")
        -- f(1,2) emits a sub(callee_ty, arrow([arg1_ty, arg2_ty], [ret_ty]))
        T.ok(count_tag(cs, "csub") >= 1, "at least one csub for call")
    end)

    T.it("assignment a.b = v emits crow_extend", function()
        local src = "local a = {}\na.b = 42"
        local cs, errs = generate(src)
        T.eq(#errs, 0, "no errors")
        local found = any(cs, function(c)
            return c.tag == "crow_extend" and c.key == "b"
        end)
        T.ok(found, "crow_extend with key 'b' for assignment target")
    end)

    T.it("declare_var annotation binds in scope", function()
        -- The --:: declare x = number directive should pre-populate 'x' in scope,
        -- so a subsequent annotation-derived sub is emitted when assigning.
        local src = "--:: declare x = number\nlocal y = x"
        local cs, errs = generate(src)
        -- No parse errors expected.
        T.eq(#errs, 0, "no errors")
        -- 'x' should resolve via declare_var; 'y' gets x's type (number).
        -- No sub constraint because y's annotation doesn't specify a different type.
        T.eq(count_tag(cs, "csub"), 0, "no sub constraints (no annotation on y)")
    end)

    T.it("function with multiple return values records all", function()
        local src = "local function f() return 1, 2 end"
        local cs, errs = generate(src)
        T.eq(#errs, 0, "no errors")
        -- No annotation → no constraints; function type is inferred from returns.
        T.eq(#cs, 0, "no constraints for multi-return unannotated function")
    end)

    T.it("annotated fn with return emits sub for return type", function()
        -- The annotation arrow ret type causes a sub from each collected return.
        local src = "--: () -> number\nlocal function g() return 1 end"
        local cs, errs = generate(src)
        T.eq(#errs, 0, "no errors")
        -- fn sub + return sub
        T.ok(count_tag(cs, "csub") >= 1, "at least one csub")
    end)

end)
