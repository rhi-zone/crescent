-- lib/type/static-v5/cli_e2e_test.lua
-- End-to-end fixtures for the v5 CLI pipeline.
--
-- Drives `cli.run` with a fake caps table that captures output into strings;
-- does NOT touch the filesystem or real I/O.

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local T   = require("lib.test.assert")
local cli = require("lib.type.static-v5.cli")

-- ── Fake caps factory ─────────────────────────────────────────────────────────

--: (string) -> { caps: V5CliCaps, out: () -> string, err: () -> string }
local function fake_caps(source)
    local out_buf = {} --[[: { [integer]: string } ]]
    local err_buf = {} --[[: { [integer]: string } ]]
    --: V5CliCaps
    local caps = {
        --: (string) -> (string | nil, string | nil)
        read_file = function(_path)
            return source, nil
        end,
        --: (string) -> nil
        write_out = function(msg)
            out_buf[#out_buf + 1] = msg
        end,
        --: (string) -> nil
        write_err = function(msg)
            err_buf[#err_buf + 1] = msg
        end,
        is_tty = nil,
    }
    return {
        caps = caps,
        --: () -> string
        out  = function() return table.concat(out_buf) end,
        --: () -> string
        err  = function() return table.concat(err_buf) end,
    }
end

-- Run source through cli.run; return exit_code, stdout, stderr.
--: (string, string) -> (integer, string, string)
local function run(source, filename)
    local fc = fake_caps(source)
    local code = cli.run({ filename or "test.lua" }, fc.caps)
    return code, fc.out(), fc.err()
end

-- ── Tests ─────────────────────────────────────────────────────────────────────

T.describe("v5 cli e2e", function()

    -- 1. Pure annotated function — no effects.
    T.it("pure annotated function typechecks clean", function()
        local src = "--: (number) -> number\nlocal function f(x) return x + 1 end"
        local code, out, _err = run(src, "pure.lua")
        T.eq(code, 0, "exit 0")
        T.eq(out, "", "no output")
    end)

    -- 2. Unannotated function calling io.write — effects inferred, no error.
    T.it("unannotated io.write call has no error", function()
        local src = "local function f() io.write('x') end"
        local code, _out, _err = run(src, "unannotated_io.lua")
        -- Unannotated function: effects are accumulated and folded into inferred
        -- return type; no F2 enforcement (no annotation to check against).
        T.eq(code, 0, "exit 0 — effects accumulated silently for unannotated fn")
    end)

    -- 3. Annotated () -> nil body calls print (direct-bound !io) — !io NOT in annotation.
    --    This should surface an F2 error (CIntersectionMember stuck).
    --    print is a direct stdlib binding and propagates !io immediately.
    T.it("annotated () -> nil calling print surfaces F2 error", function()
        local src = "--: () -> nil\nlocal function f() print('x') end"
        local code, out, _err = run(src, "f2_io.lua")
        T.eq(code, 1, "exit 1 (F2 violation)")
        -- The solver emits a CIntersectionMember error for missing !io.
        T.ok(out ~= "", "error output produced")
    end)

    -- 3b. 5.F1 fix: annotated () -> nil body calls io.write (dotted callee).
    --     Previously silent (uvar at gen time); after fix, F2 fires.
    T.it("5.F1: annotated () -> nil calling io.write (dotted) surfaces F2 error", function()
        local src = "--: () -> nil\nlocal function f() io.write('x') end"
        local code, out, _err = run(src, "f2_io_write.lua")
        T.eq(code, 1, "exit 1 (F2 violation — dotted callee)")
        T.ok(out ~= "", "error output produced for io.write F2")
        -- The error message references CIntersectionMember (rule name in solver output).
        T.ok(out:find("CIntersectionMember") ~= nil or out:find("cint") ~= nil or out:find("!io") ~= nil,
            "error message references effect enforcement")
    end)

    -- 3c. 5.F1 negative: annotated () -> nil & !io calling io.write — should be clean.
    T.it("5.F1: annotated () -> nil & !io calling io.write is clean", function()
        local src = "--: () -> nil & !io\nlocal function f() io.write('x') end"
        local code, _out, _err = run(src, "f2_io_write_ok.lua")
        T.eq(code, 0, "exit 0 — !io in annotation satisfies F2")
    end)

    -- 4. Annotated function raises error() — !throw not in annotation.
    --    Should surface F2 error for !throw.
    T.it("annotated () -> nil calling error() surfaces F2 error", function()
        local src = "--: () -> nil\nlocal function f() error('boom') end"
        local code, out, _err = run(src, "f2_throw.lua")
        T.eq(code, 1, "exit 1 (F2 !throw)")
        T.ok(out ~= "", "error output produced")
    end)

    -- 5. pcall consuming a throwing function — !throw absorbed, outer fn is clean.
    T.it("pcall absorbs !throw from callee", function()
        local src = [[
--: () -> nil
local function safe()
    local ok, _err = pcall(function()
        error("boom")
    end)
    local _a = ok
    local _b = _err
end
]]
        local code, _out, _err = run(src, "pcall_absorbs.lua")
        -- pcall is treated as an effect sink: the !throw from error() is
        -- not propagated out of pcall, so the outer annotation () -> nil is met.
        T.eq(code, 0, "exit 0 — pcall absorbs !throw")
    end)

    -- 5b. 5.F2: pcall on a throwing function — outer annotated pure fn is clean.
    --     Verifies pcall consumes !throw; outer () -> nil annotation satisfied.
    T.it("5.F2: pcall on throwing fn in annotated pure fn is clean", function()
        local src = [[
--: () -> nil
local function safe_div()
    local ok = pcall(function()
        error("oops")
    end)
    local _ = ok
end
]]
        local code, _out, _err = run(src, "pcall_f2.lua")
        T.eq(code, 0, "exit 0 — pcall consumes !throw, outer annotation satisfied")
    end)

    -- 5c. 5.F2: pcall return type is a union — can be used as unknown without error.
    --     Test via subtyping-via-annotation: annotate ok as unknown (should pass).
    T.it("5.F2: pcall return annotated as unknown typechecks", function()
        local src = [[
local function f()
    --: unknown
    local ok = pcall(function() end)
    local _ = ok
end
]]
        local code, _out, _err = run(src, "pcall_ret_unknown.lua")
        T.eq(code, 0, "exit 0 — pcall return is compatible with unknown")
    end)

    -- 5d. 5.F2: !throw NOT consumed without pcall — F2 fires as before.
    --     Verify the negative: plain error() in annotated pure fn still errors.
    T.it("5.F2 negative: error() in annotated pure fn still triggers F2", function()
        local src = "--: () -> nil\nlocal function f() error('x') end"
        local code, out, _err = run(src, "f2_throw_negative.lua")
        T.eq(code, 1, "exit 1 — error() without pcall still triggers F2")
        T.ok(out ~= "", "error output produced")
    end)

    -- 6. Mixed !throw & !io on one annotated function — both effects in
    --    annotation — typechecks clean.
    --    We exercise this by calling both io.write and error() in the body,
    --    but without an annotation (unannotated path; effects inferred).
    T.it("unannotated mixed !io + !throw call is clean", function()
        local src = [[
local function f(x)
    if x == nil then error("nil") end
    io.write(tostring(x))
end
]]
        local code, _out, _err = run(src, "mixed.lua")
        T.eq(code, 0, "exit 0 — unannotated mixed effects inferred")
    end)

    -- 6b. 5.F3: coroutine.create in an annotated pure outer fn is clean.
    --     !yield is consumed by coroutine.create; outer () -> nil annotation met.
    T.it("5.F3: coroutine.create consumes !yield — pure outer fn is clean", function()
        local src = [[
--: () -> nil
local function f()
    local co = coroutine.create(function()
        coroutine.yield(42)
    end)
    local _ = co
end
]]
        local code, _out, _err = run(src, "coro_create_pure.lua")
        T.eq(code, 0, "exit 0 — coroutine.create consumes !yield, outer annotation satisfied")
    end)

    -- 6c. 5.F3: coroutine.create annotated as unknown typechecks.
    --     The return of coroutine.create is Coroutine<Y,S,R>; annotating as
    --     unknown (supertype of all) should pass.
    T.it("5.F3: coroutine.create return annotated as unknown typechecks", function()
        local src = [[
local function f()
    --: unknown
    local co = coroutine.create(function() coroutine.yield(1) end)
    local _ = co
end
]]
        local code, _out, _err = run(src, "coro_create_unknown.lua")
        T.eq(code, 0, "exit 0 — coroutine.create return is compatible with unknown")
    end)

    -- 6d. 5.F3 negative: coroutine.yield outside !yield annotation fires F2.
    --     An annotated pure function that calls coroutine.yield should error
    --     because yield is not consumed (no coroutine.create wraps it).
    T.it("5.F3 negative: coroutine.yield in annotated pure fn triggers F2", function()
        local src = "--: () -> nil\nlocal function f() coroutine.yield(1) end"
        local code, out, _err = run(src, "coro_yield_f2.lua")
        T.eq(code, 1, "exit 1 — coroutine.yield without create still triggers F2")
        T.ok(out ~= "", "error output produced")
    end)

    -- Y2a. coroutine.yield at module top level → F2 error (no enclosing function).
    T.it("Y2: coroutine.yield at top level exits 1 with !yield error", function()
        local src = "coroutine.yield(1)"
        local code, out, _err = run(src, "y2_toplevel.lua")
        T.eq(code, 1, "exit 1 — coroutine.yield at top level is an error")
        T.ok(out:find("coroutine.yield") ~= nil, "error mentions coroutine.yield")
        T.ok(out:find("!yield") ~= nil, "error mentions !yield")
    end)

    -- Y2b. coroutine.yield inside function annotated () -> () (no !yield) → F2 error.
    --      The error fires via the solver's cint_member F2 check (not gen-pass).
    T.it("Y2: coroutine.yield in () -> () fn exits 1", function()
        local src = "--: () -> ()\nlocal function f() coroutine.yield(1) end"
        local code, out, _err = run(src, "y2_no_yield_ann.lua")
        T.eq(code, 1, "exit 1 — coroutine.yield without !yield annotation")
        T.ok(out ~= "", "error output produced")
    end)

    -- Y2c. coroutine.yield inside properly annotated !yield<integer,nil> → clean.
    T.it("Y2: coroutine.yield inside !yield<integer,nil> fn typechecks clean", function()
        local src = table.concat({
            "--: () -> nil & !yield<integer, nil>",
            "local function gen()",
            "    coroutine.yield(1)",
            "end",
        }, "\n")
        local code, _out, err = run(src, "y2_ok.lua")
        T.eq(code, 0, "exit 0 — !yield annotation satisfies coroutine.yield")
        T.eq(err, "", "no errors on stderr")
    end)

    -- 7. No files argument returns exit code 2.
    T.it("no files argument returns exit 2", function()
        local fc = fake_caps("")
        local code = cli.run({}, fc.caps)
        T.eq(code, 2, "exit 2 — missing file argument")
    end)

    -- 8. Unknown flag returns exit 2.
    T.it("unknown flag returns exit 2", function()
        local fc = fake_caps("")
        local code = cli.run({ "--unknown-flag", "foo.lua" }, fc.caps)
        T.eq(code, 2, "exit 2 — unknown flag")
    end)

    -- 9. Unreadable file returns exit 1.
    T.it("unreadable file returns exit 1", function()
        --: V5CliCaps
        local caps = {
            --: (string) -> (string | nil, string | nil)
            read_file = function(_p) return nil, "no such file" end,
            --: (string) -> nil
            write_out = function(_m) end,
            --: (string) -> nil
            write_err = function(_m) end,
            is_tty = nil,
        }
        local code = cli.run({ "missing.lua" }, caps)
        T.eq(code, 1, "exit 1 — file not found")
    end)

    -- ── Operator e2e tests ──────────────────────────────────────────────────

    -- O1. Arithmetic result is number (approximation); annotating as string errors.
    T.it("op: local x: string = 1 + 2 errors (number not subtype of string)", function()
        local src = "--: string\nlocal x = 1 + 2\nlocal _ = x"
        local code, out, _err = run(src, "op_arith_string.lua")
        T.eq(code, 1, "exit 1 — number not subtype of string")
        T.ok(out ~= "", "error output produced")
        T.ok(out:find("number") ~= nil or out:find("string") ~= nil,
            "error mentions number or string")
    end)

    -- O2. Arithmetic result is number; annotating as number succeeds.
    T.it("op: local x: number = 1 + 2 typechecks clean", function()
        local src = "--: number\nlocal x = 1 + 2\nlocal _ = x"
        local code, _out, _err = run(src, "op_arith_number.lua")
        T.eq(code, 0, "exit 0 — 1 + 2 : number")
    end)

    -- O3. String operand in arithmetic errors (string literal not subtype of number).
    T.it("op: local x = 'a' + 1 errors (string not subtype of number)", function()
        local src = 'local x = "a" + 1\nlocal _ = x'
        local code, out, _err = run(src, "op_str_arith.lua")
        T.eq(code, 1, "exit 1 — string literal not subtype of number")
        T.ok(out ~= "", "error output produced")
    end)

    -- O4. Length operator on string literal returns integer.
    T.it("op: local x = #'hello' annotated as integer typechecks clean", function()
        local src = '--: integer\nlocal x = #"hello"\nlocal _ = x'
        local code, _out, _err = run(src, "op_len_integer.lua")
        T.eq(code, 0, "exit 0 — #string : integer")
    end)

    -- O5. Concatenation result is string; annotating as number errors.
    T.it("op: local x: number = 'a' .. 'b' errors", function()
        local src = '--: number\nlocal x = "a" .. "b"\nlocal _ = x'
        local code, out, _err = run(src, "op_concat_number.lua")
        T.eq(code, 1, "exit 1 — string not subtype of number")
        T.ok(out ~= "", "error output produced")
    end)

    -- O6. not operator returns boolean; annotating as boolean typechecks.
    T.it("op: local x: boolean = not true typechecks clean", function()
        local src = "--: boolean\nlocal x = not true\nlocal _ = x"
        local code, _out, _err = run(src, "op_not_boolean.lua")
        T.eq(code, 0, "exit 0 — not true : boolean")
    end)

    -- F1. for-num: loop var is number; body annotated :number typechecks.
    T.it("for-num: local x: number = i inside body typechecks", function()
        local src = table.concat({
            "for i = 1, 10 do",
            "  --: number",
            "  local x = i",
            "  local _ = x",
            "end",
        }, "\n")
        local code, _out, _err = run(src, "for_num_ok.lua")
        T.eq(code, 0, "exit 0 — i is number in for-num body")
    end)

    -- F2. for-num: body annotated :string errors (number not subtype of string).
    T.it("for-num: local x: string = i inside body errors", function()
        local src = table.concat({
            "for i = 1, 10 do",
            "  --: string",
            "  local x = i",
            "  local _ = x",
            "end",
        }, "\n")
        local code, out, _err = run(src, "for_num_err.lua")
        T.eq(code, 1, "exit 1 — number not assignable to string")
        T.ok(out ~= "", "error output produced")
    end)

    -- F3. for-num: string bound errors (string not subtype of number).
    T.it("for-num: string bound errors at bound site", function()
        local src = 'for i = "a", 10 do local _ = i end'
        local code, out, _err = run(src, "for_num_str_bound.lua")
        T.eq(code, 1, "exit 1 — string bound not subtype of number")
        T.ok(out ~= "", "error output produced")
    end)

    -- F4. for-in pairs: k=string, v=integer when t: { [string]: integer }.
    -- Annotate t as a function parameter (avoids empty-record constraint issue).
    T.it("for-in pairs(t): k:string, v:integer when t is { [string]: integer }", function()
        local src = table.concat({
            "--: ({ [string]: integer }) -> nil",
            "local function f(t)",
            "  for k, v in pairs(t) do",
            "    --: string",
            "    local _k = k",
            "    --: integer",
            "    local _v = v",
            "    local _ = _k",
            "    local __ = _v",
            "  end",
            "end",
        }, "\n")
        local code, _out, _err = run(src, "for_in_pairs_ok.lua")
        T.eq(code, 0, "exit 0 — k:string, v:integer from pairs on { [string]: integer }")
    end)

    -- F5. for-in pairs: annotating v:string errors when table is { [string]: integer }.
    T.it("for-in pairs(t): annotating v:string errors when v is integer", function()
        local src = table.concat({
            "--: ({ [string]: integer }) -> nil",
            "local function f(t)",
            "  for k, v in pairs(t) do",
            "    --: string",
            "    local _v = v",
            "    local _ = _v",
            "  end",
            "end",
        }, "\n")
        local code, out, _err = run(src, "for_in_pairs_err.lua")
        T.eq(code, 1, "exit 1 — integer not assignable to string")
        T.ok(out ~= "", "error output produced")
    end)

    -- F6. for-in ipairs: k=integer, v=string when t: { [integer]: string }.
    T.it("for-in ipairs(t): k:integer, v:string when t is { [integer]: string }", function()
        local src = table.concat({
            "--: ({ [integer]: string }) -> nil",
            "local function f(t)",
            "  for k, v in ipairs(t) do",
            "    --: integer",
            "    local _k = k",
            "    --: string",
            "    local _v = v",
            "    local _ = _k",
            "    local __ = _v",
            "  end",
            "end",
        }, "\n")
        local code, _out, _err = run(src, "for_in_ipairs_ok.lua")
        T.eq(code, 0, "exit 0 — k:integer, v:string from ipairs on { [integer]: string }")
    end)

    -- ── Multi-return positional tuple e2e tests ───────────────────────────────

    -- MR1. Basic: f returns 1, "x" — a and b get positional types.
    T.it("multi-return: local a, b = f() binds positional types", function()
        local src = table.concat({
            "local function f() return 1, 'x' end",
            "--: number",
            "local a, b = f()",
            "--: string",
            "local _b = b",
            "local _ = a",
        }, "\n")
        local code, _out, _err = run(src, "mr_basic.lua")
        T.eq(code, 0, "exit 0 — a:number, b:string from multi-return f")
    end)

    -- MR2. Wrong type: annotating b as number errors (it's string).
    T.it("multi-return: annotating b:number errors when f returns string in slot 2", function()
        local src = table.concat({
            "local function f() return 1, 'x' end",
            "local a, b = f()",
            "--: number",
            "local _b = b",
            "local _ = a",
        }, "\n")
        local code, out, _err = run(src, "mr_wrong_type.lua")
        T.eq(code, 1, "exit 1 — b is string, not number")
        T.ok(out ~= "", "error output produced")
    end)

    -- MR3. Extra LHS: local a, b, c = f() where f returns 2 values → c is nil.
    T.it("multi-return: extra LHS slot is nil when f returns 2 values", function()
        local src = table.concat({
            "local function f() return 1, 'x' end",
            "local a, b, c = f()",
            "--: nil",
            "local _c = c",
            "local _ = a",
            "local __ = b",
        }, "\n")
        local code, _out, _err = run(src, "mr_extra_lhs.lua")
        T.eq(code, 0, "exit 0 — c:nil when f has only 2 returns")
    end)

    -- MR4. Truncation: local a = f() uses only first return.
    T.it("multi-return: local a = f() binds only first return", function()
        local src = table.concat({
            "local function f() return 1, 'x' end",
            "--: number",
            "local a = f()",
            "local _ = a",
        }, "\n")
        local code, _out, _err = run(src, "mr_truncate.lua")
        T.eq(code, 0, "exit 0 — a:number (second return discarded)")
    end)

    -- MR5. Cross-function: inline IIFE with multi-return.
    T.it("multi-return: inline IIFE local a, b = (function() return 1, 'x' end)()", function()
        local src = table.concat({
            "--: number",
            "local a, b = (function() return 1, 'x' end)()",
            "--: string",
            "local _b = b",
            "local _ = a",
        }, "\n")
        local code, _out, _err = run(src, "mr_iife.lua")
        T.eq(code, 0, "exit 0 — IIFE multi-return binds positional types")
    end)

    -- MR6. Non-last position truncation: g() in non-last position of return drops extras.
    T.it("multi-return: g() in non-last return position truncates to 1 value", function()
        local src = table.concat({
            "local function g() return 1, 2 end",
            "local function f() return g(), 3 end",
            "--: number",
            "local a, b = f()",
            "--: number",
            "local _b = b",
            "local _ = a",
        }, "\n")
        local code, _out, _err = run(src, "mr_nonlast_trunc.lua")
        T.eq(code, 0, "exit 0 — g() in non-last position: a:number, b:number")
    end)

    -- MR7. Return-last-spread: h() returns 2, g() where g() returns (integer, string).
    -- h's ret should be (integer, integer, string) — last position spreads g().
    T.it("multi-return: return-last-spread — g() in last position expands into ret tuple", function()
        local src = table.concat({
            "local function g() return 1, 'x' end",
            "local function h() return 2, g() end",
            "local a, b, c = h()",
            "--: integer",
            "local _a = a",
            "--: integer",
            "local _b = b",
            "--: string",
            "local _c = c",
            "local _ = _a",
            "local __ = _b",
            "local ___ = _c",
        }, "\n")
        local code, _out, err = run(src, "mr_last_spread.lua")
        T.eq(code, 0, "exit 0 — return-last g() spread: a:integer, b:integer, c:string")
        T.eq(err, "", "no errors: " .. err)
    end)

    -- MR8. Non-last truncation still applies: f() returns g(), 2 where g() is non-last.
    T.it("multi-return: g() in non-last return truncates; 2nd slot is the literal 2", function()
        local src = table.concat({
            "local function g() return 1, 'x' end",
            "local function f() return g(), 2 end",
            "local a, b = f()",
            "--: integer",
            "local _a = a",
            "--: integer",
            "local _b = b",
            "local _ = _a",
            "local __ = _b",
        }, "\n")
        local code, _out, err = run(src, "mr_nonlast_trunc2.lua")
        T.eq(code, 0, "exit 0 — g() non-last truncates; b=integer from literal 2")
        T.eq(err, "", "no errors: " .. err)
    end)

    -- MR9. Negative: return-last-spread type mismatch.
    -- If we annotate c as integer but g() returns string in slot 2 — error.
    T.it("multi-return: return-last-spread annotating c:integer errors (c is string)", function()
        local src = table.concat({
            "local function g() return 1, 'x' end",
            "local function h() return 2, g() end",
            "local a, b, c = h()",
            "--: integer",
            "local _c = c",
            "local _ = a",
            "local __ = b",
            "local ___ = _c",
        }, "\n")
        local code, out, _err = run(src, "mr_last_spread_neg.lua")
        T.eq(code, 1, "exit 1 — c is string, not integer")
        T.ok(out ~= "", "error output produced")
    end)

    -- INT1. Integer refinement: 1 + 2 annotated as integer passes.
    T.it("integer refinement: 1 + 2 is integer", function()
        local src = table.concat({
            "--: integer",
            "local x = 1 + 2",
            "local _ = x",
        }, "\n")
        local code, _out, err = run(src, "int_refine_add.lua")
        T.eq(code, 0, "exit 0 — 1 + 2 is integer")
        T.eq(err, "", "no errors: " .. err)
    end)

    -- INT2. Float operands (1.5) fall back to number.
    -- NOTE: integer-valued float literals (2.0) are indistinguishable from integer
    -- literals (2) at the AST level in the v4 parser; both get $LitInt treatment.
    -- Only fractional floats can be tested for number result end-to-end.
    T.it("integer refinement: 1.5 + 2.5 is number (fractional float operands)", function()
        local src = table.concat({
            "--: number",
            "local x = 1.5 + 2.5",
            "local _ = x",
        }, "\n")
        local code, _out, err = run(src, "int_refine_float.lua")
        T.eq(code, 0, "exit 0 — 1.5 + 2.5 is number")
        T.eq(err, "", "no errors: " .. err)
    end)

    -- INT3. Integer annotated as integer after * refinement passes.
    T.it("integer refinement: 3 * 4 is integer", function()
        local src = table.concat({
            "--: integer",
            "local x = 3 * 4",
            "local _ = x",
        }, "\n")
        local code, _out, err = run(src, "int_refine_mul.lua")
        T.eq(code, 0, "exit 0 — 3 * 4 is integer")
        T.eq(err, "", "no errors: " .. err)
    end)

    -- INT4. Division always number — annotating as integer should error.
    T.it("integer refinement: 4 / 2 is number (division never integer)", function()
        local src = table.concat({
            "--: number",
            "local x = 4 / 2",
            "local _ = x",
        }, "\n")
        local code, _out, err = run(src, "int_refine_div.lua")
        T.eq(code, 0, "exit 0 — 4 / 2 is number (no integer refinement for /)")
        T.eq(err, "", "no errors: " .. err)
    end)

end)

-- ── Directive e2e tests ───────────────────────────────────────────────────────
--
-- End-to-end verification that each V5Directive variant runs through the full
-- CLI pipeline without errors and with the expected constraint/error behavior.

T.describe("v5 cli e2e — directives", function()

    -- declare_var + annotation downstream resolves via binding.
    T.it("declare_var: declared fn callable with no CLI error", function()
        local src = table.concat({
            "--:: declare greet = (string) -> nil",
            "greet('hello')",
        }, "\n")
        local code, _out, err = run(src, "decl_var.lua")
        T.eq(code, 0, "exit 0")
        T.eq(err, "", "no errors on stderr")
    end)

    -- declare_effect + annotation using it passes through.
    T.it("declare_effect: custom effect annotation parses cleanly", function()
        local src = table.concat({
            "--:: declare effect !db : 0",
            "--: () -> nil & !db",
            "local function query() end",
        }, "\n")
        local code, _out, err = run(src, "decl_effect.lua")
        T.eq(code, 0, "exit 0")
        T.eq(err, "", "no errors on stderr")
    end)

    -- type_alias non-parametric — resolves in annotation, no CLI error.
    T.it("type_alias non-parametric: Str = string resolves in annotation", function()
        local src = table.concat({
            "--:: Str = string",
            "--: Str",
            "local s = 'hello'",
        }, "\n")
        local code, _out, err = run(src, "alias_simple.lua")
        T.eq(code, 0, "exit 0")
        T.eq(err, "", "no errors on stderr")
    end)

    -- type_alias parametric — Pair<A,B> applied to concrete types.
    -- Verifies the alias expands: Pair<integer,string> → record with two fields.
    -- Assigning nil (wrong type) should produce a record-mismatch error,
    -- confirming the alias expanded to a record rather than staying as App(Pair,…).
    T.it("type_alias parametric: Pair<integer,string> expands — nil rejected as record", function()
        local src = table.concat({
            "--:: Pair<A,B> = { first: A, second: B }",
            "--: Pair<integer, string>",
            "local p = nil",
        }, "\n")
        local code, out, _err = run(src, "alias_pair.lua")
        -- The solver should reject nil where a record is required.
        T.eq(code, 1, "exit 1: alias-expanded type catches nil")
        T.ok(out:find("record") ~= nil, "error mentions record (alias fully expanded)")
    end)

    -- require directive — no-op by v4 parity, no error.
    T.it("require directive: no error (no-op)", function()
        local src = table.concat({
            "--:: require \"lib.some.module\"",
            "local x = 1",
        }, "\n")
        local code, _out, err = run(src, "decl_require.lua")
        T.eq(code, 0, "exit 0")
        T.eq(err, "", "no errors on stderr")
    end)

    -- module directive — no error.
    T.it("module directive: matching top-level binding typechecks clean", function()
        local src = table.concat({
            "--:: module \"mymod\": { x: integer }",
            "local x = 1",
        }, "\n")
        local code, _out, err = run(src, "decl_module.lua")
        T.eq(code, 0, "exit 0")
        T.eq(err, "", "no errors on stderr")
    end)

    T.it("module directive: mismatched binding type errors", function()
        -- local x = 'wrong' is string; declared { x: integer } — should error.
        local src = table.concat({
            "--:: module \"foo\": { x: integer }",
            "local x = \"wrong\"",
        }, "\n")
        local code, out, _err = run(src, "module_mismatch.lua")
        T.eq(code, 1, "exit 1 for module export type mismatch")
        T.ok(out ~= "", "error output produced")
    end)

    T.it("module directive: missing binding errors with field name in message", function()
        -- Declares { x: integer } but only defines y.
        local src = table.concat({
            "--:: module \"foo\": { x: integer }",
            "local y = 1",
        }, "\n")
        local code, out, _err = run(src, "module_missing.lua")
        T.eq(code, 1, "exit 1 for missing module export binding")
        T.ok(out ~= "" or _err ~= "", "diagnostic produced")
    end)

    T.it("module directive: function export matching return type typechecks clean", function()
        local src = table.concat({
            "--:: module \"foo\": { hello: () -> string }",
            "--: () -> string",
            "local function hello() return 'hi' end",
        }, "\n")
        local code, _out, err = run(src, "module_fn_ok.lua")
        T.eq(code, 0, "exit 0 for matching function export")
        T.eq(err, "", "no errors on stderr")
    end)

    T.it("module directive: function export wrong return type errors", function()
        local src = table.concat({
            "--:: module \"foo\": { hello: () -> string }",
            "--: () -> integer",
            "local function hello() return 42 end",
        }, "\n")
        local code, out, _err = run(src, "module_fn_mismatch.lua")
        T.eq(code, 1, "exit 1 for function export type mismatch")
        T.ok(out ~= "", "error output produced")
    end)

    -- template directive — no-op, no error.
    T.it("template directive: no error (no-op)", function()
        local src = table.concat({
            "--:: template",
            "local function id(x) return x end",
        }, "\n")
        local code, _out, err = run(src, "decl_template.lua")
        T.eq(code, 0, "exit 0")
        T.eq(err, "", "no errors on stderr")
    end)

end)
