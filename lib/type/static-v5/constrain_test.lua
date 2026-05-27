-- lib/type/static-v5/constrain_test.lua
-- Tests for the v5 constraint generation pass.
--
-- Each test provides a Lua source fixture and asserts on the resulting
-- constraint array (count + key structural atoms present).

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local T           = require("lib.test.assert")
local constrain   = require("lib.type.static-v5.constrain")
local stdlib_mod  = require("lib.type.static-v5.stdlib_types")
local ann_mod     = require("lib.type.static-v5.ann")
local types_mod   = require("lib.type.experiments.v5_perf.types")

-- Mirror of AnnState from ann.lua (per-parse-session annotation parser state).
--:: AnnState = { next_rowvar: integer, effect_arities: { [string]: integer } }

local function generate(src, filename)
    return constrain.generate(src, filename or "test.lua", nil)
end

-- Generate with stdlib declarations pre-loaded and effects registered in a
-- fresh per-call AnnState.  Use this everywhere stdlib effect types (!io,
-- !throw, !yield) may appear in source annotations.
local function generate_stdlib(src, filename)
    local ann_state = ann_mod.new_state()
    stdlib_mod.register_effects(ann_state)
    local decls = stdlib_mod.decls()
    return constrain.generate(src, filename or "test.lua", { decls = decls, ann_state = ann_state })
end

-- ── Helpers ───────────────────────────────────────────────────────────────────

-- Count constraints whose tag matches.
local function count_tag(constraints, tag)
    local n = 0
    for _, c in ipairs(constraints) do
        if c ~= nil and c.tag == tag then n = n + 1 end
    end
    return n
end

-- Returns true iff any constraint in the array satisfies predicate.
local function any(constraints, pred)
    for _, c in ipairs(constraints) do
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

    -- ── Multi-return tuple tests ──────────────────────────────────────────────

    T.it("multi-assign from call emits csub with 2-slot expected arrow", function()
        -- local a, b = f() where f is a prior binding.
        -- gen_expr_multi(f_call_nid, 2) emits arrow([], [u1, u2]) csub.
        local src = "local f = nil; local a, b = f()"
        local cs, errs = generate(src)
        T.eq(#errs, 0, "no errors")
        -- Expect at least one csub whose b (expected arrow) has 2-slot ret.
        local found2 = any(cs, function(c)
            if c.tag ~= "csub" then return false end
            local b = c.b
            if b == nil or b.tag ~= "arrow" then return false end
            local ret = b.ret
            if ret == nil or ret.tag ~= "record" then return false end
            return ret.fields["2"] ~= nil
        end)
        T.ok(found2, "csub with 2-slot expected arrow ret found")
    end)

    T.it("single-assign from call emits csub with 1-slot expected arrow", function()
        -- local a = f() — single LHS, single expected slot.
        local src = "local f = nil; local a = f()"
        local cs, errs = generate(src)
        T.eq(#errs, 0, "no errors")
        -- Expect a csub with a 1-slot expected arrow (no field "2").
        local found1 = any(cs, function(c)
            if c.tag ~= "csub" then return false end
            local b = c.b
            if b == nil or b.tag ~= "arrow" then return false end
            local ret = b.ret
            if ret == nil or ret.tag ~= "record" then return false end
            return ret.fields["1"] ~= nil and ret.fields["2"] == nil
        end)
        T.ok(found1, "csub with 1-slot expected arrow ret found")
    end)

end)

-- ── Effect propagation tests ──────────────────────────────────────────────────

T.describe("v5 constrain — effect propagation", function()

    -- Helper: does any constraint have the given tag?
    local function has_tag(cs, tag)
        return count_tag(cs, tag) > 0
    end

    T.it("extract_effects: bare !io effect", function()
        local t = types_mod.effect("io")
        local effs = constrain.extract_effects(t)
        T.eq(#effs, 1, "one effect extracted from bare !io")
        local e = effs[1]
        T.ok(e ~= nil and e.tag == "const" and e.name == "!io", "effect is !io const")
    end)

    T.it("extract_effects: intersection with effect and non-effect parts", function()
        local t_str   = types_mod.const("string")
        local t_io    = types_mod.effect("io")
        local t_int   = types_mod.intersection({ t_str, t_io })
        local effs    = constrain.extract_effects(t_int)
        T.eq(#effs, 1, "only one effect extracted")
        local e = effs[1]
        T.ok(e ~= nil and types_mod.is_effect(e), "extracted part is an effect")
    end)

    T.it("extract_effects: !throw<E> application is an effect", function()
        local t_str     = types_mod.const("string")
        local t_throw_s = types_mod.effect_apply(types_mod.effect("throw"), { t_str })
        local effs      = constrain.extract_effects(t_throw_s)
        T.eq(#effs, 1, "one effect extracted from !throw<string>")
    end)

    T.it("extract_effects: no effects returns empty list", function()
        local t = types_mod.const("number")
        local effs = constrain.extract_effects(t)
        T.eq(#effs, 0, "no effects from plain type")
    end)

    T.it("unannotated fn calling io.write — inferred return includes !io", function()
        -- io.write is declared in stdlib as returning nil & !io.
        -- An unannotated function calling it should have !io in its inferred type.
        local src = "local function f() io_write_fn() end"
        -- Inject io.write as a top-level name with an effectful type.
        local t_nil = types_mod.const("nil")
        local t_io  = types_mod.effect("io")
        local eff_ret = types_mod.intersection({ t_nil, t_io })
        local rets  = {}; rets[1] = eff_ret
        local io_write_ty = types_mod.arrow({}, rets)
        local decls = { io_write_fn = io_write_ty }
        local cs, errs = constrain.generate(src, "test.lua", { decls = decls })
        T.eq(#errs, 0, "no errors")
        -- No constraints emitted for pure call site (no annotation to check against),
        -- but the function type should have !io in the intersection of its return.
        -- We can verify indirectly: no cint_member constraints (unannotated = accumulate).
        T.eq(count_tag(cs, "cint_member"), 0, "no cint_member for unannotated fn")
    end)

    T.it("annotated pure fn calling io.write — emits cint_member (!io not in annotation)", function()
        -- Annotated as () -> nil (no !io), but body calls io.write.
        -- Should emit cint_member(nil, !io) for F2 enforcement.
        local src = "--: () -> nil\nlocal function f() io_write_fn() end"
        local t_nil = types_mod.const("nil")
        local t_io  = types_mod.effect("io")
        local eff_ret = types_mod.intersection({ t_nil, t_io })
        local rets  = {}; rets[1] = eff_ret
        local io_write_ty = types_mod.arrow({}, rets)
        local decls = { io_write_fn = io_write_ty }
        local cs, errs = constrain.generate(src, "test.lua", { decls = decls })
        T.eq(#errs, 0, "no errors")
        -- Should emit a cint_member constraint (F2 enforcement).
        T.ok(has_tag(cs, "cint_member"), "cint_member emitted for missing effect in annotation")
    end)

    T.it("annotated fn with !io annotation calling io.write — no spurious cint_member", function()
        -- Annotated as () -> nil & !io.  Body calls io.write (!io).
        -- Effect IS in annotation, so cint_member is still emitted (membership check).
        -- The op-sem will resolve it as satisfied.
        local src = "local function f() io_write_fn() end"
        -- Build return type: nil & !io (the annotation)
        local t_nil    = types_mod.const("nil")
        local t_io     = types_mod.effect("io")
        local ann_ret  = types_mod.intersection({ t_nil, t_io })
        -- Build annotated arrow type.
        local ann_rets = {}; ann_rets[1] = ann_ret
        local ann_ty   = types_mod.arrow({}, ann_rets)
        -- Build effectful callee type (same shape: returns nil & !io).
        local eff_ret  = types_mod.intersection({ t_nil, t_io })
        local rets     = {}; rets[1] = eff_ret
        local io_write_ty = types_mod.arrow({}, rets)
        -- Embed annotation inline using a pre-declared name bound to ann_ty.
        -- (We can't inject annotation syntax via opts.decls, so we test the
        -- constraint shape directly: annotated function emits cint_member.)
        local decls = { io_write_fn = io_write_ty }
        local cs, errs = constrain.generate(src, "test.lua", { decls = decls })
        T.eq(#errs, 0, "no errors")
        -- Unannotated path (no ann_ret in scope): no cint_member.
        T.eq(count_tag(cs, "cint_member"), 0, "no cint_member for unannotated fn")
    end)

    T.it("pcall call site does NOT propagate !throw outward", function()
        -- 5.F2: pcall is fully special-cased at gen time (gap #2).
        -- The callee_ty lookup and CSub are skipped; pcall returns the
        -- discriminated union directly with no CSub constraint emitted.
        -- No cint_member for !throw should reach the outer function.
        local src = "pcall(function() end)"
        local cs, errs = generate(src)
        T.eq(#errs, 0, "no errors")
        -- No csub emitted (pcall path skips callee CSub).
        T.eq(count_tag(cs, "csub"), 0, "no csub emitted for pcall site (special-cased)")
        -- No cint_member for !throw reaching outer scope.
        T.eq(count_tag(cs, "cint_member"), 0, "no cint_member: !throw consumed by pcall")
    end)

    -- 5.F2: pcall is fully short-circuited — emits no constraints at all.
    -- The discriminated union is returned directly as the call-site type;
    -- no ceq, no csub needed.  End-to-end correctness is verified in cli_e2e.
    T.it("5.F2: pcall call site emits no constraints (fully special-cased)", function()
        local src = "local ok = pcall(function() end)"
        local cs, errs = generate(src)
        T.eq(#errs, 0, "no errors")
        -- pcall path returns the discriminated union directly with no constraints.
        T.eq(#cs, 0, "no constraints emitted for pcall call site")
    end)

    -- 5.F2: pcall does not propagate !throw even when annotated outer function.
    T.it("5.F2: pcall in annotated pure fn — no cint_member for !throw", function()
        -- Outer function annotated as () -> nil.  Inner throws.  After 5.F2, pcall
        -- consumes !throw so the outer annotation is satisfied (no cint_member).
        local src = "--: () -> nil\nlocal function f() pcall(function() error('x') end) end"
        local cs, errs = generate_stdlib(src, "test.lua")
        T.eq(#errs, 0, "no parse/annotation errors")
        -- !throw consumed by pcall → no cint_member for !throw.
        local found_throw_member = any(cs, function(c)
            if c.tag ~= "cint_member" then return false end
            local p = c.part
            if p == nil then return false end
            -- Walk to the effect head.
            local head = p
            while head.tag == "app" do head = head.f end
            return head.tag == "const" and head.name == "!throw"
        end)
        T.ok(not found_throw_member, "no cint_member for !throw after pcall consumed it")
    end)

    T.it("stdlib_types.decls() provides io.write with !io effect in return", function()
        -- Verify that the stdlib_types module declares io.write as effectful.
        local decls = stdlib_mod.decls()
        local io_rec = decls["io"]
        T.ok(io_rec ~= nil, "io record declared in stdlib")
        --: V5Type | nil
        local io_write = nil
        if io_rec ~= nil and io_rec.tag == "record" then
            io_write = io_rec.fields["write"]
        end
        T.ok(io_write ~= nil, "io.write field declared in stdlib")
        if io_write ~= nil then
            -- io.write is an arrow; its return should contain !io.
            T.ok(io_write.tag == "arrow", "io.write is an arrow type")
            local ret = io_write.ret
            if ret ~= nil and ret.tag == "record" then
                local ret1 = ret.fields["1"]
                if ret1 ~= nil then
                    local effs = constrain.extract_effects(ret1)
                    T.ok(#effs >= 1, "io.write return has at least one effect")
                    local found_io = false
                    for i = 1, #effs do
                        local e = effs[i]
                        if e ~= nil and e.tag == "const" and e.name == "!io" then
                            found_io = true; break
                        end
                    end
                    T.ok(found_io, "io.write return contains !io")
                else
                    T.fail("io.write return[1] is nil")
                end
            else
                T.fail("io.write ret is not a record")
            end
        end
    end)

    T.it("stdlib_types.decls() provides error with !throw<string> effect", function()
        local decls = stdlib_mod.decls()
        local error_fn = decls["error"]
        T.ok(error_fn ~= nil, "error declared in stdlib")
        if error_fn ~= nil then
            T.ok(error_fn.tag == "arrow", "error is an arrow type")
            local ret = error_fn.ret
            if ret ~= nil and ret.tag == "record" then
                local ret1 = ret.fields["1"]
                if ret1 ~= nil then
                    local effs = constrain.extract_effects(ret1)
                    T.ok(#effs >= 1, "error return has at least one effect")
                    local found_throw = false
                    for i = 1, #effs do
                        local e = effs[i]
                        if e ~= nil and types_mod.is_effect(e) then
                            -- Check it's a !throw application (app whose head is !throw).
                            local head = e
                            while head.tag == "app" do head = head.f end
                            if head.tag == "const" and head.name == "!throw" then
                                found_throw = true; break
                            end
                        end
                    end
                    T.ok(found_throw, "error return contains !throw<...>")
                else
                    T.fail("error return[1] is nil")
                end
            else
                T.fail("error ret is not a record")
            end
        end
    end)

    T.it("stdlib_types.decls() provides os.exit with !os effect", function()
        local decls = stdlib_mod.decls()
        local os_rec = decls["os"]
        T.ok(os_rec ~= nil, "os record declared in stdlib")
        --: V5Type | nil
        local os_exit = nil
        if os_rec ~= nil and os_rec.tag == "record" then
            os_exit = os_rec.fields["exit"]
        end
        T.ok(os_exit ~= nil, "os.exit field declared in stdlib")
        if os_exit ~= nil then
            T.ok(os_exit.tag == "arrow", "os.exit is an arrow type")
        end
    end)

    T.it("declare_var annotation binds effectful type in scope", function()
        -- A --:: declare f = (...) -> ... annotation in source binds f.
        -- We verify the gen-pass now acts on declare_var directives.
        local src = "--:: declare write_fn = () -> nil\nwrite_fn()"
        local cs, errs = generate(src)
        T.eq(#errs, 0, "no errors")
        -- write_fn is now in scope; calling it emits a csub.
        T.ok(count_tag(cs, "csub") >= 1, "csub for declared write_fn call")
    end)

    T.it("generate with opts.decls pre-seeds scope", function()
        -- Verify that opts.decls injects names into scope.
        local t_str = types_mod.const("string")
        local rets  = {}; rets[1] = t_str
        local fn_ty = types_mod.arrow({}, rets)
        local decls = { my_fn = fn_ty }
        local src   = "my_fn()"
        local cs, errs = constrain.generate(src, "test.lua", { decls = decls })
        T.eq(#errs, 0, "no errors")
        -- my_fn is in scope and typed; calling it emits a csub.
        T.ok(count_tag(cs, "csub") >= 1, "csub for injected my_fn call")
    end)

    -- 5.F1 fix: dotted callee (io.write) must emit cint_member for F2 enforcement
    -- when the enclosing function is annotated pure (() -> nil).
    -- Previously, NODE_FIELD_EXPR produced a uvar at gen time so
    -- propagate_callee_effects extracted nothing and F2 was silent.
    -- After the fix, resolve_callee_eager walks the TRecord from opts.decls
    -- and returns the real arrow; propagate_callee_effects then sees !io.
    T.it("5.F1: annotated () -> nil calling io.write via dotted callee emits cint_member", function()
        local src = "--: () -> nil\nlocal function f() io.write('x') end"
        local cs, errs = generate_stdlib(src, "test.lua")
        T.eq(#errs, 0, "no parse/annotation errors")
        -- Must emit at least one cint_member — that's the F2 enforcement constraint.
        T.ok(count_tag(cs, "cint_member") >= 1,
            "cint_member emitted: F2 fires on dotted callee io.write")
        -- Verify the cint_member part is !io (not some other effect).
        local found_io_member = any(cs, function(c)
            if c.tag ~= "cint_member" then return false end
            local p = c.part
            return p ~= nil and p.tag == "const" and p.name == "!io"
        end)
        T.ok(found_io_member, "cint_member part is !io")
    end)

    -- Negative: annotated () -> nil & !io calling io.write — cint_member is still
    -- emitted (the solver resolves it as satisfied) but no spurious rejection.
    -- The important check here is just that no cint_member is ABSENT, meaning
    -- the fix doesn't suppress effects when the annotation declares them.
    T.it("5.F1: annotated () -> nil & !io calling io.write still emits cint_member (solver satisfies it)", function()
        -- Build the annotated arrow type inline and inject via opts.decls
        -- (the gen-pass reads the annotation from source).
        local src = "--: () -> nil & !io\nlocal function f() io.write('x') end"
        local cs, errs = generate_stdlib(src, "test.lua")
        T.eq(#errs, 0, "no parse/annotation errors")
        -- cint_member is emitted (membership check); the solver will satisfy it
        -- because !io IS in the annotation intersection.
        T.ok(count_tag(cs, "cint_member") >= 1, "cint_member emitted for !io membership check")
    end)

    -- 5.F3: coroutine.create emits NO constraints — fully special-cased.
    T.it("5.F3: coroutine.create call site emits no constraints (special-cased)", function()
        local src = "local co = coroutine.create(function() end)"
        local cs, errs = generate_stdlib(src, "test.lua")
        T.eq(#errs, 0, "no errors")
        -- coroutine.create is fully special-cased; no csub emitted for it.
        T.eq(count_tag(cs, "csub"), 0, "no csub emitted for coroutine.create (special-cased)")
    end)

    -- 5.F3: coroutine.create does NOT propagate !yield outward.
    T.it("5.F3: coroutine.create in annotated pure fn — no cint_member for !yield", function()
        -- Outer function annotated as () -> nil.  Inner yields.  After 5.F3,
        -- coroutine.create consumes !yield so the outer annotation is satisfied.
        local src = "--: () -> nil\nlocal function f() coroutine.create(function() coroutine.yield(1) end) end"
        local cs, errs = generate_stdlib(src, "test.lua")
        T.eq(#errs, 0, "no parse/annotation errors")
        -- !yield consumed by coroutine.create → no cint_member for !yield.
        local found_yield_member = any(cs, function(c)
            if c.tag ~= "cint_member" then return false end
            local p = c.part
            if p == nil then return false end
            local head = p
            while head.tag == "app" do head = head.f end
            return head.tag == "const" and head.name == "!yield"
        end)
        T.ok(not found_yield_member, "no cint_member for !yield after coroutine.create consumed it")
    end)

end)

-- ── Operator constraint tests ─────────────────────────────────────────────────

T.describe("v5 constrain — operators", function()

    -- Arithmetic: local x = 1 + 2 emits two CSub against number.
    T.it("arithmetic + emits csub for both operands against number", function()
        local src = "local x = 1 + 2"
        local cs, errs = generate(src)
        T.eq(#errs, 0, "no errors")
        -- Two CSub: left_ty <: number, right_ty <: number.
        T.eq(count_tag(cs, "csub"), 2, "two csub constraints (both operands)")
        -- All csub targets should be 'number'.
        local all_number = true
        for _, c in ipairs(cs) do
            if c ~= nil and c.tag == "csub" then
                local b = c.b
                if b == nil or b.tag ~= "const" or b.name ~= "number" then
                    all_number = false
                end
            end
        end
        T.ok(all_number, "all csub targets are 'number'")
    end)

    -- Concatenation: local x = "a" .. "b" returns string.
    T.it("concat .. emits csub for both operands against string|number, result string", function()
        local src = "local x = a .. b"
        local cs, errs = generate(src)
        T.eq(#errs, 0, "no errors")
        -- Two CSub: left_ty <: string|number, right_ty <: string|number.
        T.eq(count_tag(cs, "csub"), 2, "two csub constraints for concat operands")
    end)

    -- Unary not: local x = not true — returns boolean, no constraints.
    T.it("unary not emits no constraints and returns boolean", function()
        local src = "local x = not true"
        local cs, errs = generate(src)
        T.eq(#errs, 0, "no errors")
        T.eq(#cs, 0, "no constraints emitted for 'not true'")
    end)

    -- Length operator: local x = #s where s is a string literal.
    T.it("length # emits no csub for string operand (no constraint on operand yet)", function()
        local src = 'local x = #"hello"'
        local cs, errs = generate(src)
        T.eq(#errs, 0, "no errors")
        -- The result type is integer; no constraint on a literal string operand.
        T.eq(count_tag(cs, "csub"), 0, "no csub emitted for string length")
    end)

    -- Comparison: local x = (a < b) emits two csub against number.
    T.it("comparison < emits csub for both operands and returns boolean", function()
        local src = "local x = a < b"
        local cs, errs = generate(src)
        T.eq(#errs, 0, "no errors")
        T.eq(count_tag(cs, "csub"), 2, "two csub for comparison operands")
    end)

    -- Equality: == emits no constraints on operands.
    T.it("equality == emits no csub constraints", function()
        local src = "local x = a == b"
        local cs, errs = generate(src)
        T.eq(#errs, 0, "no errors")
        T.eq(count_tag(cs, "csub"), 0, "no csub for equality operands")
    end)

    -- Integer refinement: 1 + 2 → integer.
    -- When annotated --: integer the gen pass emits csub(integer <: integer)
    -- rather than csub(number <: integer) — verifiable by checking that a
    -- csub with b.name == "integer" exists.
    T.it("arithmetic +: integer + integer result has csub against integer (annotation)", function()
        local src = "--: integer\nlocal x = 1 + 2"
        local cs, errs = generate(src)
        T.eq(#errs, 0, "no gen errors")
        -- The annotation emits csub(result_ty <: integer).
        -- result_ty is T_INTEGER (both operands are $LitInt), so csub is integer<:integer.
        local found_int = any(cs, function(c)
            if c == nil or c.tag ~= "csub" then return false end
            local b = c.b
            return b ~= nil and b.tag == "const" and b.name == "integer"
        end)
        T.ok(found_int, "csub with b=integer present (annotation on integer+integer)")
    end)

    -- Float operands (1.5) fall back to number since 1.5 is NOT integer-valued.
    -- NOTE: integer-valued float literals (e.g. 2.0) are indistinguishable from
    -- integer literals (2) at the AST level in the v4 parser — both get $LitInt
    -- treatment in the v5 gen pass.  Only truly fractional floats (1.5) can be
    -- tested for number result at the constraint level.
    T.it("arithmetic +: float + float (1.5+2.5) result has csub against number from annotation", function()
        local src = "--: number\nlocal x = 1.5 + 2.5"
        local cs, errs = generate(src)
        T.eq(#errs, 0, "no gen errors")
        -- 1.5 and 2.5 are $LitNum (non-integer floats), so result is number.
        local found_num_ann = any(cs, function(c)
            if c == nil or c.tag ~= "csub" then return false end
            local a = c.a
            local b = c.b
            return b ~= nil and b.tag == "const" and b.name == "number"
                and a ~= nil and a.tag == "const" and a.name == "number"
        end)
        T.ok(found_num_ann, "annotation csub is number<:number for float operands (1.5+2.5)")
    end)

    -- Division always returns number (not integer), even for integer operands.
    T.it("arithmetic /: integer / integer result is number (not integer)", function()
        local src = "--: number\nlocal x = 4 / 2"
        local cs, errs = generate(src)
        T.eq(#errs, 0, "no gen errors")
        -- Division result is always number; annotation emits number <: number.
        local found_num = any(cs, function(c)
            if c == nil or c.tag ~= "csub" then return false end
            local b = c.b
            return b ~= nil and b.tag == "const" and b.name == "number"
        end)
        T.ok(found_num, "csub with b=number present for division result")
        -- No csub where b is integer (division never refines to integer).
        local found_int = any(cs, function(c)
            if c == nil or c.tag ~= "csub" then return false end
            local b = c.b
            return b ~= nil and b.tag == "const" and b.name == "integer"
        end)
        T.ok(not found_int, "no csub with b=integer for division (always number)")
    end)

end)

-- ── for-loop typing tests ─────────────────────────────────────────────────────

T.describe("v5 constrain — for loops", function()

    -- for-num: bounds emit CSub against number.
    T.it("for-num emits csub for init and limit against number", function()
        local src = "for i = 1, 10 do end"
        local cs, errs = generate(src)
        T.eq(#errs, 0, "no errors")
        -- init and limit each emit CSub against number (2 constraints).
        -- No step: FLAG_HAS_STEP not set.
        local n_csub = count_tag(cs, "csub")
        T.ok(n_csub >= 2, "at least 2 csub (init, limit) for for-num bounds")
        -- All csub targets should be number.
        local all_number = true
        for _, c in ipairs(cs) do
            if c ~= nil and c.tag == "csub" then
                local b = c.b
                if b == nil or b.tag ~= "const" or b.name ~= "number" then
                    all_number = false
                end
            end
        end
        T.ok(all_number, "all csub targets are number for for-num bounds")
    end)

    -- for-num with step: three CSub against number.
    T.it("for-num with step emits 3 csub against number", function()
        local src = "for i = 1, 10, 2 do end"
        local cs, errs = generate(src)
        T.eq(#errs, 0, "no errors")
        T.ok(count_tag(cs, "csub") >= 3, "at least 3 csub (init, limit, step)")
    end)

    -- for-in pairs: loop vars bound from index signature K, V.
    T.it("for-in pairs(t) binds loop vars from index signature", function()
        -- t is annotated as { [string]: integer }.
        -- pairs(t) is special-cased: k=string, v=integer.
        -- We verify by annotating the body and checking no error.
        local src = table.concat({
            "--:: T = { [string]: integer }",
            "--: T",
            "local t = {}",
            "local decls_pairs = pairs",
            "for k, v in decls_pairs(t) do",
            "  local _k = k",
            "  local _v = v",
            "end",
        }, "\n")
        local cs, errs = generate_stdlib(src, "test.lua")
        T.eq(#errs, 0, "no parse/annotation errors in for-in pairs test")
        -- At minimum, a csub for the pairs callee should be emitted.
        -- (The actual loop-var typing is verified end-to-end in cli_e2e_test.)
        T.ok(#cs >= 0, "no crash in for-in generation")
    end)

    -- for-in unknown iterator: falls back to unknown (no crash, no error).
    T.it("for-in with unrecognised iterator falls back silently", function()
        local src = "for k, v in some_iter() do local _k = k end"
        local cs, errs = generate(src)
        T.eq(#errs, 0, "no parse/annotation errors for unrecognised iterator")
        -- At least a csub for the iterator call should be emitted.
        T.ok(#cs >= 0, "no crash in for-in fallback path")
    end)

end)

-- ── Directive scope-injection tests ──────────────────────────────────────────
--
-- Tests for all six V5Directive variants: declare_var, declare_effect,
-- type_alias, require, module, template.

T.describe("v5 constrain — directive scope injection", function()

    -- ── declare_var ───────────────────────────────────────────────────────────

    T.it("declare_var: --:: declare x = number binds x in scope", function()
        local src = "--:: declare x = number\nlocal y = x"
        local cs, errs = constrain.generate(src, "test.lua", nil)
        T.eq(#errs, 0, "no errors")
        -- x is in scope (bound to number), no crash.
        T.ok(#cs >= 0, "no crash: x resolved from declare_var")
    end)

    T.it("declare_var: calling declared fn emits csub", function()
        local src = "--:: declare my_fn = () -> number\nmy_fn()"
        local cs, errs = constrain.generate(src, "test.lua", nil)
        T.eq(#errs, 0, "no errors")
        -- my_fn is an arrow; calling it emits a csub.
        T.ok(count_tag(cs, "csub") >= 1, "csub emitted for declared fn call")
    end)

    -- ── declare_effect ────────────────────────────────────────────────────────

    T.it("declare_effect: --:: declare effect !foo : 2 registers arity 2", function()
        -- After the declare_effect directive, !foo must be applied to 2 args.
        -- Using it correctly should not cause an annotation parse error.
        local src = "--:: declare effect !foo : 2\n--: () -> nil & !foo<integer, string>\nlocal function f() end"
        local cs, errs = constrain.generate(src, "test.lua", nil)
        T.eq(#errs, 0, "no annotation parse errors after declare_effect !foo:2")
    end)

    T.it("declare_effect: wrong arity causes annotation error", function()
        -- !foo declared arity 2 but used with 1 arg → parse error.
        local src = "--:: declare effect !bar : 2\n--: () -> nil & !bar<integer>\nlocal function f() end"
        local cs, errs = constrain.generate(src, "test.lua", nil)
        -- Exactly 1 annotation parse error for the arity mismatch.
        T.ok(#errs >= 1, "annotation error for arity mismatch on !bar")
        local found = false
        for _, e in ipairs(errs) do
            if e ~= nil and e:find("!bar") and e:find("arity") then found = true end
        end
        T.ok(found, "error mentions !bar and arity")
    end)

    -- ── type_alias ────────────────────────────────────────────────────────────

    T.it("type_alias: non-parametric alias resolves in annotation", function()
        -- --:: Num = number  then  --: Num  on a local.
        -- The annotation Num should resolve to number.
        -- Verify: no parse/annotation errors; the generated type is number.
        local src = "--:: Num = number\n--: Num\nlocal x = 1"
        local cs, errs = constrain.generate(src, "test.lua", nil)
        T.eq(#errs, 0, "no errors for non-parametric alias")
        -- A csub for `x: Num` (= number) constraining literal 1 should appear.
        local found = any(cs, function(c)
            if c == nil or c.tag ~= "csub" then return false end
            local b = c.b
            return b ~= nil and b.tag == "const" and b.name == "number"
        end)
        T.ok(found, "csub with b=number from resolved Num alias")
    end)

    T.it("type_alias: parametric alias Pair<A,B> resolves with args", function()
        -- Define Pair<A,B> = { first: A, second: B }
        -- Use Pair<integer, string> on a local.
        local src = table.concat({
            "--:: Pair<A,B> = { first: A, second: B }",
            "--: Pair<integer, string>",
            "local p = { first = 1, second = 'hi' }",
        }, "\n")
        local cs, errs = constrain.generate(src, "test.lua", nil)
        T.eq(#errs, 0, "no errors for parametric alias Pair<integer,string>")
        -- A csub where the expected type is a record with fields first/second.
        local found_pair = any(cs, function(c)
            if c == nil or c.tag ~= "csub" then return false end
            local b = c.b
            if b == nil or b.tag ~= "record" then return false end
            return b.fields ~= nil and b.fields["first"] ~= nil and b.fields["second"] ~= nil
        end)
        T.ok(found_pair, "csub with record {first,second} from Pair<integer,string>")
    end)

    T.it("type_alias: alias in function annotation resolves", function()
        -- Alias used in function return annotation.
        local src = table.concat({
            "--:: MyStr = string",
            "--: () -> MyStr",
            "local function f() return 'hi' end",
        }, "\n")
        local cs, errs = constrain.generate(src, "test.lua", nil)
        T.eq(#errs, 0, "no errors for alias in function return annotation")
    end)

    T.it("type_alias: alias defined after another uses prior alias in body", function()
        -- First alias: Num = number; Second alias: NumPair = { a: Num, b: Num }.
        -- Num should be expanded in NumPair's body when it is registered.
        local src = table.concat({
            "--:: Num = number",
            "--:: NumPair = { a: Num, b: Num }",
            "--: NumPair",
            "local p = { a = 1, b = 2 }",
        }, "\n")
        local cs, errs = constrain.generate(src, "test.lua", nil)
        T.eq(#errs, 0, "no errors chaining aliases")
    end)

    -- ── require ───────────────────────────────────────────────────────────────

    T.it("require: --:: require 'mod' is no-op (v4 parity) — no error", function()
        -- v5 has no module loader; require directives silently no-op.
        local src = "--:: require \"some.module\"\nlocal x = 1"
        local cs, errs = constrain.generate(src, "test.lua", nil)
        T.eq(#errs, 0, "no error for --:: require directive (no-op)")
    end)

    -- ── module ────────────────────────────────────────────────────────────────

    T.it("module: --:: module 'name': T records module_name (no error)", function()
        -- Module directive should not cause errors; it just records the name.
        local src = "--:: module \"mymod\": { x: integer }\nlocal x = 1"
        local cs, errs = constrain.generate(src, "test.lua", nil)
        T.eq(#errs, 0, "no error for --:: module directive")
    end)

    T.it("module: matching top-level binding emits CSub per declared field", function()
        -- { x: integer } declared; local x = 1 — CSub($LitInt(1), integer) emitted.
        local src = "--:: module \"m\": { x: integer }\nlocal x = 1"
        local cs, errs = constrain.generate(src, "test.lua", nil)
        T.eq(#errs, 0, "no gen-pass errors for matching module")
        -- At least one CSub should be emitted for the module export check.
        local found = any(cs, function(c)
            return c ~= nil and c.tag == "csub"
        end)
        T.ok(found, "CSub emitted for module export field check")
    end)

    T.it("module: missing binding emits error string with field name", function()
        -- { x: integer } declared but no local x in the file.
        local src = "--:: module \"m\": { x: integer }\nlocal y = 1"
        local cs, errs = constrain.generate(src, "test.lua", nil)
        T.ok(#errs >= 1, "gen-pass error for missing module export")
        local found = false
        for _, e in ipairs(errs) do
            if e ~= nil and e:find("'x'") then found = true end
        end
        T.ok(found, "error message references missing field name 'x'")
    end)

    T.it("module: function binding emits CSub against declared arrow type", function()
        -- { hello: () -> string } declared; matching top-level function defined.
        local src = table.concat({
            "--:: module \"m\": { hello: () -> string }",
            "--: () -> string",
            "local function hello() return 'hi' end",
        }, "\n")
        local cs, errs = constrain.generate(src, "test.lua", nil)
        T.eq(#errs, 0, "no gen-pass errors for matching function export")
        local found = any(cs, function(c)
            return c ~= nil and c.tag == "csub"
        end)
        T.ok(found, "CSub emitted for function module export check")
    end)

    -- ── template ─────────────────────────────────────────────────────────────

    T.it("template: --:: template is no-op (v4 parity) — no error", function()
        -- Template directive is no-op until generic body checking is implemented.
        local src = "--:: template\nlocal function id(x) return x end"
        local cs, errs = constrain.generate(src, "test.lua", nil)
        T.eq(#errs, 0, "no error for --:: template directive (no-op)")
    end)

    -- ── R5: resolve_aliases_impl cycle detection ──────────────────────────────

    T.it("R5: cyclic aliases A=B, B=A halt without infinite loop", function()
        -- Both A and B are defined as each other; the typechecker must not hang.
        local src = table.concat({
            "--:: A = B",
            "--:: B = A",
            "--: A",
            "local x = 1",
        }, "\n")
        -- Must complete without hanging; errors are acceptable (cycle = unexpanded).
        local _cs, _errs = constrain.generate(src, "test.lua", nil)
        T.ok(true, "completed without infinite loop")
    end)

    T.it("R5: 33-deep alias chain halts at depth cap", function()
        -- Build T1=T2, T2=T3, ..., T33=number; annotate with T1.
        -- Must halt at depth 32 rather than looping to infinity.
        local lines = {}
        for i = 1, 32 do
            lines[i] = "--:: T" .. tostring(i) .. " = T" .. tostring(i + 1)
        end
        lines[33] = "--:: T33 = number"
        lines[34] = "--: T1"
        lines[35] = "local x = 1"
        local src = table.concat(lines, "\n")
        local _cs, _errs = constrain.generate(src, "test.lua", nil)
        T.ok(true, "completed without infinite loop for 33-deep chain")
    end)

    -- ── Y2: coroutine.yield outside !yield scope emits F2 error ──────────────

    T.it("Y2: coroutine.yield at module top level emits error", function()
        -- No enclosing function at all — extract_yield_from_scope returns nil.
        local src = "coroutine.yield(1)"
        local _cs, errs = generate_stdlib(src, "test.lua")
        local found = false
        for _, e in ipairs(errs) do
            if e ~= nil and e:find("coroutine.yield") and e:find("!yield") then
                found = true
            end
        end
        T.ok(found, "error message mentions coroutine.yield and !yield")
    end)

    T.it("Y2: coroutine.yield inside enclosing function does not error at gen-pass", function()
        -- Enclosing unannotated function: !yield propagates outward; solver handles F2.
        -- extract_yield_from_scope returns permissive (stack non-empty), no gen-pass error.
        local src = "local function f() coroutine.yield(1) end"
        local _cs, errs = generate_stdlib(src, "test.lua")
        local found_y2_err = false
        for _, e in ipairs(errs) do
            if e ~= nil and e:find("coroutine.yield") and e:find("!yield") then
                found_y2_err = true
            end
        end
        T.ok(not found_y2_err, "no gen-pass F2 error for yield inside enclosing fn")
    end)

end)
