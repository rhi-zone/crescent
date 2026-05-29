-- lib/type/static-v5/decl_instantiation_test.lua
-- Phase 2.4.5 proof-of-mechanism tests: call-site declared-return
-- instantiation + per-call-site match lowering.
--
-- A declared function whose RETURN references its PARAMETERS (via the TParam
-- leaf) must, AT EACH CALL SITE, get the actual argument types substituted into
-- those parameter binders, then any resulting TMatch lowered to a CMatchEval and
-- reduced — yielding the correct per-call-site result type.
--
-- These tests drive the FULL pipeline (generate -> op_sem solve) on
-- hand-written stdlib-style declarations injected via opts.decls, NOT through
-- the real pcall/coroutine/pairs handlers.  The declarations are shape-only:
-- the gen-pass triggers the mechanism solely because the declared return
-- contains a TParam, never because of the function's name.

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local T          = require("lib.test.assert")
local constrain  = require("lib.type.static-v5.constrain")
local op_sem     = require("lib.type.static-v5.op_sem")
local types_mod  = require("lib.type.experiments.v5_perf.types")

-- ── Full-pipeline helper ──────────────────────────────────────────────────────

-- check(src, decls): run the gen-pass then op_sem to quiescence.  Returns
-- (gen_errors, solver_errors) so a test can assert both phases.
--: (string, { [string]: V5Type }) -> (string[], OpSemError[])
local function check(src, decls)
    local constraints, gen_errors = constrain.generate(src, "test.lua", { decls = decls })
    local st = op_sem.new_state()
    for i = 1, #constraints do
        local c = constraints[i]
        if c ~= nil then op_sem.emit(st, c) end
    end
    op_sem.run(st)
    return gen_errors, st.errors
end

-- ── Synthetic declarations ────────────────────────────────────────────────────

local LIT_TRUE  = types_mod.literal("boolean", true)
local LIT_FALSE = types_mod.literal("boolean", false)
local STR       = types_mod.const("string")
local INT       = types_mod.const("integer")
local NUM       = types_mod.const("number")

-- disc(b) : (%1) -> match %1 { true => string, false => integer }
-- A discriminated return: the result type depends on whether the boolean
-- argument is the `true` or `false` literal.  TParam(1) is the scrutinee.
--: () -> V5Type
local function make_disc()
    local scrut = types_mod.param(1)
    local arms = {} --[[: TMatchArm[] ]]
    arms[1] = { pattern = LIT_TRUE,  result = STR }
    arms[2] = { pattern = LIT_FALSE, result = INT }
    local ret = types_mod.match(scrut, arms)
    -- arg position is `boolean` (accepts either literal); return is the match.
    return types_mod.arrow({ types_mod.const("boolean") }, { ret })
end

-- ════════════════════════════════════════════════════════════════════════════
-- Core mechanism: per-call-site declared-return instantiation + match lowering
-- ════════════════════════════════════════════════════════════════════════════

T.describe("v5 2.4.5 — call-site declared-return instantiation", function()

    T.it("disc(true) reduces to string (arm 1 fires)", function()
        local decls = { disc = make_disc() }
        -- Annotate the binding as `string`: must typecheck cleanly because the
        -- per-call-site instantiation reduces disc(true)'s return to string.
        local src = "--: string\nlocal a = disc(true)"
        local gen_errs, solv_errs = check(src, decls)
        T.eq(#gen_errs, 0, "no gen errors for disc(true): string")
        T.eq(#solv_errs, 0, "disc(true) reduces to string; annotation satisfied")
    end)

    T.it("disc(false) reduces to integer (arm 2 fires)", function()
        local decls = { disc = make_disc() }
        local src = "--: integer\nlocal b = disc(false)"
        local gen_errs, solv_errs = check(src, decls)
        T.eq(#gen_errs, 0, "no gen errors for disc(false): integer")
        T.eq(#solv_errs, 0, "disc(false) reduces to integer; annotation satisfied")
    end)

    T.it("two call sites with different args reduce to DIFFERENT types", function()
        -- The SAME declaration, called with different literal args, must yield
        -- per-site results: disc(true) <: string ok, disc(false) <: integer ok.
        local decls = { disc = make_disc() }
        local src = table.concat({
            "--: string",
            "local a = disc(true)",
            "--: integer",
            "local b = disc(false)",
        }, "\n")
        local gen_errs, solv_errs = check(src, decls)
        T.eq(#gen_errs, 0, "no gen errors across two call sites")
        T.eq(#solv_errs, 0, "each call site reduces to its own per-site result")
    end)

    T.it("disc(true) annotated as integer is REJECTED (string ≠ integer)", function()
        -- Proves the per-site result is genuinely `string`, not a loose fallback:
        -- annotating the true-arm result as integer must fail.
        local decls = { disc = make_disc() }
        local src = "--: integer\nlocal a = disc(true)"
        local gen_errs, solv_errs = check(src, decls)
        T.eq(#gen_errs, 0, "no gen errors")
        T.ok(#solv_errs > 0, "disc(true)=string is NOT <: integer; must error")
    end)

    T.it("disc(false) annotated as string is REJECTED (integer ≠ string)", function()
        local decls = { disc = make_disc() }
        local src = "--: string\nlocal b = disc(false)"
        local gen_errs, solv_errs = check(src, decls)
        T.eq(#gen_errs, 0, "no gen errors")
        T.ok(#solv_errs > 0, "disc(false)=integer is NOT <: string; must error")
    end)

    T.it("a non-TParam declared arrow is unaffected (mechanism is shape-gated)", function()
        -- id : (number) -> number — no TParam in the return, so the 2.4.5 path
        -- must NOT trigger; the ordinary generic call path applies.
        local id = types_mod.arrow({ NUM }, { NUM })
        local decls = { id = id }
        local src = "--: number\nlocal a = id(1)"
        local gen_errs, solv_errs = check(src, decls)
        T.eq(#gen_errs, 0, "no gen errors for plain id(1)")
        T.eq(#solv_errs, 0, "plain arrow call still works")
    end)

    T.it("TParam in a tuple return position is substituted (identity-of-arg)", function()
        -- echo(x) : (%1) -> %1 — the return IS the argument type, no match.
        -- echo(1) must reduce to the literal/number of the argument.
        local echo = types_mod.arrow({ NUM }, { types_mod.param(1) })
        local decls = { echo = echo }
        local src = "--: number\nlocal a = echo(2)"
        local gen_errs, solv_errs = check(src, decls)
        T.eq(#gen_errs, 0, "no gen errors for echo(2)")
        T.eq(#solv_errs, 0, "echo(2) return = arg type <: number")
    end)
end)

-- ════════════════════════════════════════════════════════════════════════════
-- Shape-driven for-in: loop vars from an index signature / declared return pack
-- ════════════════════════════════════════════════════════════════════════════

-- idxrec(K, V): a record carrying a single index signature `{ [K]: V }`.
--: (V5Type, V5Type) -> V5Type
local function idxrec(key, value)
    local idxs = {} --[[: TIndex[] ]]
    idxs[1] = types_mod.index(key, value, false)
    local empty = {} --[[: { [string]: TField } ]]
    return types_mod.record_full(empty, idxs, nil)
end

T.describe("v5 2.4.5 — shape-driven for-in", function()

    T.it("for k,v in <record-with-index-sig> binds k:K, v:V (no name)", function()
        -- The iterable is a bare value with an index signature { [string]: number }.
        -- The loop binds k:string, v:number purely from the index signature shape.
        -- Body annotation asserts k flows where a string is required.
        local tbl = idxrec(STR, NUM)
        local decls = { tbl = tbl }
        local src = table.concat({
            "for k, v in tbl do",
            "  --: string",
            "  local kk = k",
            "  --: number",
            "  local vv = v",
            "end",
        }, "\n")
        local gen_errs, solv_errs = check(src, decls)
        T.eq(#gen_errs, 0, "no gen errors for index-signature for-in")
        T.eq(#solv_errs, 0, "k:string and v:number bound from index signature")
    end)

    T.it("index-signature for-in: wrong loop-var annotation is REJECTED", function()
        -- k is string; annotating it as number must fail — proving the bind is
        -- the real K, not a loose unknown.
        local tbl = idxrec(STR, NUM)
        local decls = { tbl = tbl }
        local src = table.concat({
            "for k, v in tbl do",
            "  --: number",
            "  local kk = k",
            "end",
        }, "\n")
        local gen_errs, solv_errs = check(src, decls)
        T.eq(#gen_errs, 0, "no gen errors")
        T.ok(#solv_errs > 0, "k:string is NOT <: number; must error")
    end)

    T.it("for v in <iterator-call> binds vars from the declared return pack", function()
        -- The iterator is a call to a function whose declared return pack is
        -- (string, number) — loop vars bind positionally from the return arity,
        -- read off the declared return shape (not the callee name).
        local iter = types_mod.arrow({}, { STR, NUM })
        local decls = { iter = iter }
        local src = table.concat({
            "for a, b in iter() do",
            "  --: string",
            "  local aa = a",
            "  --: number",
            "  local bb = b",
            "end",
        }, "\n")
        local gen_errs, solv_errs = check(src, decls)
        T.eq(#gen_errs, 0, "no gen errors for iterator-call for-in")
        T.eq(#solv_errs, 0, "a:string b:number bound from declared return pack")
    end)
end)

return true
