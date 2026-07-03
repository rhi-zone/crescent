-- lib/type/v9/lower_test.lua
-- The total lowering over REAL Lua syntax: the and/or derivation (regression
-- for the historic hardcoded `foo and bar -> boolean|nil` bug), truthiness
-- narrowing with join-at-merge, the honest unsupported boundary with
-- line/col, the havoc fence, and the 30-kind totality roster.

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local frontend = require("lib.type.v9.frontend")
local lower = require("lib.type.v9.lower")
local engine = require("lib.type.v9.engine.engine")
local lattice = require("lib.type.v9.lattice")
local check = require("lib.type.v9.check")

-- Lower + solve a snippet; return rendered types of top-level locals plus
-- the lowering diags. Fails the test on parse/solve errors.
--: (string) -> ({ [string]: string }, { [integer]: { code: string, severity: string, message: string, line: integer, col: integer } })
local function infer(src)
    local ast, perr = frontend.parse(src, "test.lua")
    if ast == nil then error("parse failed: " .. (perr or "?")) end
    local res = lower.lower(ast)
    local sol, serr = engine.solve(res.graph)
    if sol == nil then error("solve failed: " .. (serr or "?")) end
    local out = {} --: { [string]: string }
    for name, cell in pairs(res.vars) do
        out[name] = lattice.show(sol.values[cell])
    end
    return out, res.diags
end

--: ({ [integer]: { code: string, severity: string, message: string, line: integer, col: integer } }, string) -> { code: string, severity: string, message: string, line: integer, col: integer } | nil
local function find_diag(diags, code)
    for i = 1, #diags do
        if diags[i].code == code then return diags[i] end
    end
    return nil
end

-- Full check (lower + solve + OBLIGATION evaluation): infer()'s diags are
-- the lowering's structural diags only — assertions about post-solve codes
-- (op-mismatch on obligations, field-write-mismatch, call-non-function)
-- need this path.
--: (string) -> { [integer]: { code: string, severity: string, message: string, line: integer, col: integer } }
local function checked(src)
    local diags, err = check.check_source(src, "test.lua", nil)
    if diags == nil then error("check failed: " .. (err or "?")) end
    return diags
end

T.describe("v9 lowering — and/or DERIVED from truthy/falsy (the historic bug site)", function()
    T.it("foo and bar : type(bar) when foo is never-falsy (NOT boolean|nil)", function()
        local tys = infer("local foo = 1\nlocal bar = 'b'\nlocal x = foo and bar\nreturn x\n")
        T.eq(tys.x, "string", "number is never falsy, so `foo and bar` is exactly bar's type")
    end)

    T.it("a and b : falsy(a) | type(b) when a is optional", function()
        local tys = infer("local a = nil\nlocal x = a and 1\nreturn x\n")
        T.eq(tys.x, "nil | number", "falsy(nil) | number")
    end)

    T.it("a or b : truthy(a) | type(b) (default-value idiom)", function()
        local tys = infer("local a = nil\nlocal x = a or 'd'\nreturn x\n")
        T.eq(tys.x, "string", "truthy(nil) = never, so the default's type wins")
    end)

    T.it("a or b keeps a's truthy part when a can be truthy", function()
        local tys = infer("local a = 1\nlocal x = a or 'd'\nreturn x\n")
        T.eq(tys.x, "number | string", "truthy(number) | string")
    end)

    T.it("cond and a or b : type(a) | type(b) when a is never falsy (the classic idiom)", function()
        -- pre-split this leaked `boolean | number` (falsy(boolean) was the
        -- whole boolean atom); with literal atoms falsy(boolean) = false and
        -- truthy(false | number) = number.
        local tys = infer("local c = 1 == 2\nlocal x = c and 1 or 2\nreturn x\n")
        T.eq(tys.x, "number", "no phantom boolean leaks out of the ternary idiom")
    end)

    T.it("boolean literals are the true/false literal atoms", function()
        local tys = infer("local t = true\nlocal f = false\nlocal b = 1 == 1\nreturn t, f, b\n")
        T.eq(tys.t, "true", "the literal atom, not the boolean top")
        T.eq(tys.f, "false", "same for false")
        T.eq(tys.b, "boolean", "a comparison is the full pair (renders collapsed)")
    end)
end)

T.describe("v9 lowering — nil-equality guards (the == nil / ~= nil idiom)", function()
    T.it("`if x ~= nil then` narrows x in the then-arm; `== nil` swaps", function()
        local src = "local c = true\nlocal x = nil\nif c then x = 1 end\n"
            .. "local y = 0\nif x ~= nil then y = x end\n"
            .. "local z = nil\nif x == nil then z = x end\nreturn y, z\n"
        local tys = infer(src)
        T.eq(tys.y, "number", "x ~= nil drops nil in the then-arm")
        T.eq(tys.z, "nil", "x == nil keeps only nil in the then-arm")
    end)

    T.it("either operand order works (nil == x)", function()
        local src = "local c = true\nlocal x = nil\nif c then x = 's' end\n"
            .. "local y = 0\nif nil ~= x then y = x end\nreturn y\n"
        local tys = infer(src)
        T.eq(tys.y, "number | string", "swapped operands narrow the same way")
    end)
end)

T.describe("v9 lowering — compound-condition narrowing (and/or chains)", function()
    T.it("`if a and b then` narrows EVERY conjunct on the then-path", function()
        local src = "local c = true\nlocal x = nil\nlocal y = nil\n"
            .. "if c then x = 1 end\nif c then y = 's' end\n"
            .. "local a = nil\nlocal b = nil\n"
            .. "if x and y then a = x b = y end\nreturn a, b\n"
        local tys = infer(src)
        T.eq(tys.a, "nil | number", "first conjunct truthy-narrowed (joined with initial nil)")
        T.eq(tys.b, "nil | string", "second conjunct truthy-narrowed too")
    end)

    T.it("the `if limit and #x > limit` repro: no op-mismatch, for-bound is number", function()
        local src = "local c = true\nlocal limit = nil\nif c then limit = 2 end\n"
            .. "local s = 'abc'\nlocal n = 0\n"
            .. "if limit and #s > limit then\n  for i = 1, limit do n = i end\nend\nreturn n\n"
        local diags = checked(src)
        T.ok(find_diag(diags, "op-mismatch") == nil,
            "the RHS comparison and the for-bound both see the truthy-narrowed limit")
    end)

    T.it("and-chain conjuncts compose on the SAME decl (~= nil, then a tag test)", function()
        local src = "local c = true\nlocal x = nil\nif c then x = 1 end\nif c then x = 's' end\n"
            .. "local y = nil\nif x ~= nil and type(x) == 'number' then y = x end\nreturn y\n"
        local tys = infer(src)
        T.eq(tys.y, "nil | number", "both filters chain: drop:nil then keep:number")
    end)

    T.it("`a and b` narrows NOTHING on the else-path (¬a ∨ ¬b refutes no conjunct)", function()
        local src = "local c = true\nlocal x = nil\nif c then x = 1 end\n"
            .. "local y = nil\nif x and c then else y = x end\nreturn y\n"
        local tys = infer(src)
        T.eq(tys.y, "nil | number", "else-arm keeps x's full type")
    end)

    T.it("`if a or b then` narrows BOTH duals on the else-path only", function()
        local src = "local c = true\nlocal x = nil\nlocal y = nil\n"
            .. "if c then x = 1 end\nif c then y = 's' end\n"
            .. "local a = true\nlocal b = true\nlocal t = true\n"
            .. "if x or y then t = x else a = x b = y end\nreturn a, b, t\n"
        local tys = infer(src)
        T.eq(tys.a, "nil | true", "else-arm: falsy(x) = nil")
        T.eq(tys.b, "nil | true", "else-arm: falsy(y) = nil")
        T.eq(tys.t, "nil | number | true", "then-arm does NOT invent a positive (x may be nil when y holds)")
    end)

    T.it("`not (a and b)` swaps the branch lists", function()
        local src = "local c = true\nlocal x = nil\nlocal y = nil\n"
            .. "if c then x = 1 end\nif c then y = 's' end\n"
            .. "local a = nil\nlocal b = nil\n"
            .. "if not (x and y) then else a = x b = y end\nreturn a, b\n"
        local tys = infer(src)
        T.eq(tys.a, "nil | number", "the else of `not (x and y)` is the then of `x and y`")
        T.eq(tys.b, "nil | string", "both conjuncts narrowed there")
    end)

    T.it("the guarded-access idiom `opts and opts.f` types nil | field, no phantom op-mismatch", function()
        local src = "local c = true\nlocal opts = nil\nif c then opts = { f = 1 } end\n"
            .. "local f = opts and opts.f\nreturn f\n"
        local tys = infer(src)
        T.eq(tys.f, "nil | number", "falsy(opts) | typeof(opts.f) under the truthy guard")
        local diags = checked(src)
        T.ok(find_diag(diags, "op-mismatch") == nil,
            "the RHS field read sees the truthy-narrowed opts (no nil-target op-mismatch)")
    end)

    T.it("the RHS of `or` lowers under the falsy guard (sound, and genuinely right)", function()
        -- `x or #x` is a runtime error whenever the RHS runs (x is nil/false
        -- there): the guard makes the checker SAY so instead of missing it.
        local src = "local c = true\nlocal x = nil\nif c then x = 's' end\n"
            .. "local n = x or #x\nreturn n\n"
        local diags = checked(src)
        local d = find_diag(diags, "op-mismatch")
        T.ok(d ~= nil, "operand of unary # is falsy(x) = nil on the or-RHS path")
    end)

    T.it("FIELD places are NOT narrowed (pinned v0 decision: locals only)", function()
        -- `if t.f then t.f end` — the second read is NOT filtered by the
        -- guard: a field is not a stable place under mutation/aliasing.
        -- Narrow through a local (`local f = t.f; if f then`).
        local src = "local t = { f = nil } --: { f: number | nil }\n"
            .. "local y = 0\nif t.f then y = t.f end\nreturn y\n"
        local tys = infer(src)
        T.eq(tys.y, "nil | number", "the guarded field read keeps its full declared type")
    end)

    T.it("a while-loop and-chain condition narrows into the body", function()
        local src = "local c = true\nlocal limit = nil\nif c then limit = 3 end\n"
            .. "local i = 1\nwhile limit and i < limit do i = i + 1 end\nreturn i\n"
        local diags = checked(src)
        T.ok(find_diag(diags, "op-mismatch") == nil,
            "the comparison and the body see the truthy-narrowed limit")
    end)
end)

T.describe("v9 lowering — truthiness narrowing + join at merge", function()
    T.it("branch versions join to a union at the if-merge", function()
        local tys = infer("local x = 1\nlocal c = true\nif c then\n  x = 's'\nelse\n  x = 2\nend\nreturn x\n")
        T.eq(tys.x, "number | string", "phi(x) = string | number")
    end)

    T.it("if x then narrows x truthy; else keeps the falsy part", function()
        -- y captures the narrowed x inside each arm.
        local src = "local x = nil\nlocal c = true\nif c then x = 1 end\n"
            .. "local y = nil\nlocal z = nil\nif x then y = x else z = x end\nreturn y, z\n"
        local tys = infer(src)
        T.eq(tys.y, "nil | number", "then-arm sees truthy(x) = number (joined with y's initial nil)")
        T.eq(tys.z, "nil", "else-arm sees falsy(x) = nil")
    end)

    T.it("`not x` swaps the arms", function()
        local src = "local x = nil\nlocal c = true\nif c then x = 1 end\n"
            .. "local y = nil\nif not x then y = x end\nreturn y\n"
        local tys = infer(src)
        T.eq(tys.y, "nil", "then-arm of `not x` sees falsy(x)")
    end)

    T.it("elseif chains narrow per clause", function()
        local src = "local x = nil\nlocal c = true\nif c then x = 1 end\n"
            .. "local y = nil\nif c then y = 0 elseif x then y = x end\nreturn y\n"
        local tys = infer(src)
        T.eq(tys.y, "nil | number", "elseif arm sees truthy(x); merge joins with nil")
    end)
end)

T.describe("v9 lowering — reachability at the merge (early-exit narrowing)", function()
    T.it("`if type(x) ~= 'string' then return end` narrows x AFTER the if", function()
        local src = "local x = whatever\nif type(x) ~= 'string' then return end\n"
            .. "local y = x\nreturn y\n"
        local tys = infer(src)
        T.eq(tys.y, "string", "the diverging then-arm contributes nothing; the else filter survives")
    end)

    T.it("`if x == nil then return end` drops nil after the if (the (nil, errmsg) guard)", function()
        local src = "local c = true\nlocal x = nil\nif c then x = 1 end\n"
            .. "if x == nil then return end\nlocal y = x\nreturn y\n"
        local tys = infer(src)
        T.eq(tys.y, "number", "keep:nil diverges; drop:nil falls through")
    end)

    T.it("a declared-never call (`error`) is a diverging branch tail", function()
        local src = "local x = whatever\nif type(x) ~= 'number' then error('bad') end\n"
            .. "local y = x + 1\nreturn y\n"
        local tys, diags = infer(src)
        T.eq(tys.y, "number", "error() cannot fall through, so x is number after the guard")
        T.eq(find_diag(diags, "op-mismatch"), nil, "x + 1 is clean")
    end)

    T.it("both arms diverging makes the merge unreachable (bottom, not a lie)", function()
        local src = "local x = 1\nlocal c = true\n"
            .. "if c then return 1 else return 2 end\nlocal y = x\nreturn y\n"
        local tys = infer(src)
        T.eq(tys.y, "never", "dead code is checked against no values")
    end)

    T.it("a non-diverging if still merges both arms (no false divergence)", function()
        local src = "local x = 1\nlocal c = true\nif c then x = 's' end\nlocal y = x\nreturn y\n"
        local tys = infer(src)
        T.eq(tys.y, "number | string", "fall-through branches still phi")
    end)
end)

T.describe("v9 lowering — loops (head phi, back edge, reachable exits)", function()
    T.it("a loop-body assignment joins at the head phi and the exit", function()
        local tys = infer("local x = 1\nlocal c = true\nwhile c do\n  x = 's'\nend\nreturn x\n")
        T.eq(tys.x, "number | string", "pre-loop and back-edge versions join")
    end)

    T.it("`while true do … break` exits ONLY through the break (reachability)", function()
        local tys = infer("local x = 1\nwhile true do\n  x = 's'\n  break\nend\nlocal y = x\nreturn y\n")
        T.eq(tys.y, "string", "the break snapshot IS the exit; no phantom cond-false edge")
    end)

    T.it("`while true` without a break diverges (code after is unreachable)", function()
        local tys = infer("local x = 1\nwhile true do\n  x = x\nend\nlocal y = x\nreturn y\n")
        T.eq(tys.y, "never", "an exitless loop cannot fall through")
    end)

    T.it("the condition narrows into the body; its complement narrows the exit", function()
        local src = "local c = true\nlocal x = nil\nif c then x = 1 end\n"
            .. "local y = 0\nwhile x do\n  y = x\n  x = nil\nend\nlocal z = x\nreturn y, z\n"
        local tys = infer(src)
        T.eq(tys.y, "number", "the body sees truthy(x)")
        T.eq(tys.z, "nil", "the normal exit sees falsy(x)")
    end)

    T.it("a break inside a narrowed arm carries the narrowing to the exit (search idiom)", function()
        local src = "local x = nil\nlocal c = true\nwhile true do\n"
            .. "  if c then x = 1 end\n  if x then break end\nend\nlocal y = x\nreturn y\n"
        local tys = infer(src)
        T.eq(tys.y, "number", "the break snapshot captures the truthy-narrowed version")
    end)

    T.it("for-num: the loop var is a number; the body checks against it", function()
        local tys, diags = infer("local s = 0\nfor i = 1, 10 do\n  s = s + i\nend\nreturn s\n")
        T.eq(tys.s, "number", "number + number through the loop")
        T.eq(find_diag(diags, "op-mismatch"), nil, "no operand complaints")
    end)

    T.it("for-num: a non-number bound is rejected with line/col", function()
        local diags = checked("for i = 1, 'x' do\n  local _ = i\nend\nreturn 1\n")
        local d = find_diag(diags, "op-mismatch")
        T.ok(d ~= nil, "the string limit is rejected")
        if d ~= nil then
            T.eq(d.line, 1, "line of the bound")
            T.eq(d.col, 12, "col of the bound")
            T.ok(d.message:find("limit", 1, true) ~= nil, "names the position: " .. d.message)
        end
    end)

    T.it("for-num: exit joins the zero-iteration path", function()
        local tys = infer("local last = nil\nfor i = 1, 3 do\n  last = i\nend\nreturn last\n")
        T.eq(tys.last, "nil | number", "the range can be empty; nil survives the exit")
    end)

    T.it("for-in over ipairs: the index var is a number (nil-dropped result 1)", function()
        local src = "local t = { x = 1 }\nlocal i0 = nil\nlocal v0 = nil\n"
            .. "for i, v in ipairs(t) do\n  i0 = i\n  v0 = v\nend\nreturn i0, v0\n"
        local tys = infer(src)
        T.eq(tys.i0, "nil | number", "ipairs' integer|nil first result, nil-dropped, joins i0's nil")
        T.eq(tys.v0, "unknown", "the value position is the iterator's declared unknown (absorbs the nil init)")
    end)

    T.it("for-in over pairs: the key var rides the declared iterator arrow", function()
        local src = "local t = { x = 1 }\nlocal n = 0\n"
            .. "for k in pairs(t) do\n  n = n + 1\nend\nreturn n\n"
        local tys, diags = infer(src)
        T.eq(tys.n, "number", "the body checks; the loop protocol is wired")
        T.eq(find_diag(diags, "call-non-function"), nil, "pairs(t) IS an iterator call")
    end)

    T.it("for-in over a non-function is a real call-non-function finding", function()
        local diags = checked("local t = { x = 1 }\nfor k in t do\n  local _ = k\nend\nreturn 1\n")
        local d = find_diag(diags, "call-non-function")
        T.ok(d ~= nil, "`for k in t` calls t: flagged")
    end)

    T.it("repeat-until: the until sees body locals (the Lua scope quirk)", function()
        local src = "local n = 0\nrepeat\n  local done = n > 3\n  n = n + 1\nuntil done\nreturn n\n"
        local tys, diags = infer(src)
        T.eq(tys.n, "number", "the counter stays a number through the back edge")
        T.eq(find_diag(diags, "undeclared-global"), nil, "`done` resolves in the until")
        T.eq(find_diag(diags, "unused-local"), nil, "`done` is read by the until")
    end)

    T.it("repeat-until: the exit sees the truthy condition; breaks still merge", function()
        local src = "local c = true\nlocal x = nil\nif c then x = 1 end\n"
            .. "repeat\n  x = nil\nuntil x == nil\nlocal y = x\nreturn y\n"
        local tys = infer(src)
        T.eq(tys.y, "nil", "until x == nil exits with keep:nil applied")
    end)

    T.it("loop-driven value growth TERMINATES via the clipped back edge", function()
        -- t = { next = t } deepens one level per iteration; the clipped
        -- back edge bounds the ascent. The head phi's width join of {} and
        -- { next: … } is {} (common fields only) — the honest merge; the
        -- assertion here is TERMINATION, not shape.
        local src = "local t = {}\nlocal c = true\nwhile c do\n  t = { next = t }\nend\nreturn t\n"
        local tys = infer(src)
        T.eq(tys.t, "{}", "the fixpoint terminates; the exit is the width join")
    end)

    T.it("nested loops with breaks keep their frames separate", function()
        -- every path to the outer break passes through the inner loop, whose
        -- only exit sets x = 's' — the precise exit type IS string (the
        -- inner break landed in the inner frame, the outer in the outer).
        local src = "local x = 1\nlocal c = true\nwhile true do\n"
            .. "  while true do\n    x = 's'\n    break\n  end\n"
            .. "  if c then break end\nend\nlocal y = x\nreturn y\n"
        local tys = infer(src)
        T.eq(tys.y, "string", "the outer exit sees the inner loop's exit version")
    end)
end)

T.describe("v9 lowering — the honest dynamism boundary", function()
    T.it("unsupported constructs produce structured diags with line/col", function()
        local _, diags = infer("local a = 1\n::top::\na = a + 1\ngoto top\n")
        local d = find_diag(diags, "unsupported:goto-stmt")
        T.ok(d ~= nil, "goto is flagged, not crashed on or silently passed")
        if d ~= nil then
            T.eq(d.line, 4, "line of the goto")
            T.eq(d.col, 1, "col of the goto")
        end
    end)

    T.it("undeclared globals are flagged at the use site", function()
        local _, diags = infer("local x = whatever\nreturn x\n")
        local d = find_diag(diags, "undeclared-global")
        T.ok(d ~= nil, "undeclared global flagged")
        if d ~= nil then
            T.eq(d.line, 1, "line")
            T.eq(d.col, 11, "col of the identifier")
        end
    end)

    T.it("unused locals are flagged at the declaration (params + _names exempt)", function()
        local _, diags = infer("local unused = 1\nlocal _ignored = 2\nlocal f = function(cb) return 0 end\nreturn f\n")
        local d = find_diag(diags, "unused-local")
        T.ok(d ~= nil and d.line == 1, "unused local flagged at its declaration")
        local count = 0
        for i = 1, #diags do
            if diags[i].code == "unused-local" then count = count + 1 end
        end
        T.eq(count, 1, "_ignored and the param cb are exempt")
    end)
end)

T.describe("v9 lowering — structural records", function()
    T.it("constructor -> field read roundtrip", function()
        local tys = infer("local t = { x = 1, s = 'a' }\nlocal y = t.x\nlocal z = t.s\nreturn y, z, t\n")
        T.eq(tys.t, "{ s: string, x: number }", "the constructor IS a record type")
        T.eq(tys.y, "number", "t.x projects the field type")
        T.eq(tys.z, "string", "t.s projects the field type")
    end)

    T.it("the module idiom: `function M.f()` accretes fields flow-sensitively", function()
        local tys, diags = infer("local M = {}\nfunction M.f() return 1 end\nM.g = 2\nlocal h = M.f\nreturn M, h\n")
        T.eq(tys.M, "{ f: () -> number, g: number }", "field writes extend the open record (arrows precise)")
        T.eq(tys.h, "() -> number", "reading an accreted field keeps the arrow")
        T.eq(find_diag(diags, "unsupported:field-assign"), nil, "field-assign is no longer a boundary bucket")
    end)

    T.it("phi of two records joins pointwise on common fields", function()
        local src = "local c = true\nlocal t = nil\n"
            .. "if c then t = { a = 1, b = 2 } else t = { a = 's', b = 3 } end\nreturn t\n"
        local tys = infer(src)
        T.eq(tys.t, "{ a: number | string, b: number }", "pointwise join at the merge")
    end)

    T.it("records ride the existing truthiness narrowing (optional-table idiom)", function()
        local src = "local c = true\nlocal t = nil\nif c then t = { x = 1 } end\n"
            .. "local v = nil\nif t then v = t.x end\nreturn v, t\n"
        local tys = infer(src)
        T.eq(tys.t, "nil | { x: number }", "nil | record stays precise at the merge")
        T.eq(tys.v, "nil | number", "truthy(t) is the record; t.x projects inside the guard")
    end)

    T.it("`local v = t.x; if v then` narrows the projected value", function()
        local src = "local c = true\nlocal t = { x = 1 }\nif c then t = { x = nil } end\n"
            .. "local v = t.x\nlocal y = nil\nif v then y = v end\nreturn y, t\n"
        local tys = infer(src)
        T.eq(tys.y, "nil | number", "the guard drops v's nil part (joined with y's initial nil)")
    end)

    T.it("field writes inside a loop body are CHECKED (no havoc fence anymore)", function()
        local tys = infer("local t = { x = 1 }\nlocal c = true\nwhile c do\n  t.x = 2\nend\nreturn t\n")
        T.eq(tys.t, "{ x: number }", "an in-bound write keeps the record precise through the loop")
        local ok_diags = checked("local t = { x = 1 }\nlocal c = true\nwhile c do\n  t.x = 2\nend\nreturn t\n")
        T.eq(find_diag(ok_diags, "field-write-mismatch"), nil, "the in-bound write is clean")
        local bad = checked("local t = { x = 1 }\nlocal c = true\nwhile c do\n  t.x = 's'\nend\nreturn t\n")
        local d = find_diag(bad, "field-write-mismatch")
        T.ok(d ~= nil, "an out-of-bound write inside the loop is rejected")
        if d ~= nil then T.eq(d.line, 4, "at the write's line") end
    end)

    T.it("dynamic keys on a PLAIN record are the index-without-signature boundary", function()
        local diags = checked("local t = { x = 1 }\nlocal k = 'x'\nlocal v = t[k]\nreturn v\n")
        local d = find_diag(diags, "index-without-signature")
        T.ok(d ~= nil, "non-literal index on an unbounded record is flagged, not guessed at")
        if d ~= nil then
            T.eq(d.line, 3, "line of the index")
            T.eq(d.severity, "warn", "warn in v0 (dial up as index annotations spread)")
        end
    end)

    T.it("t[\"x\"] IS t.x (literal-string index = field)", function()
        local tys, diags = infer("local t = { x = 1 }\nlocal v = t[\"x\"]\nreturn v\n")
        T.eq(tys.v, "number", "literal-string keys project like dot access")
        T.eq(find_diag(diags, "unsupported:dynamic-index"), nil, "no boundary diag")
    end)

    T.it("the array part IS a `[number]` index part (bucket retired)", function()
        local tys, diags = infer("local t = { 1, 2, named = 's' }\nlocal v = t.named\nreturn v, t\n")
        T.eq(find_diag(diags, "unsupported:table-array-part"), nil, "no boundary bucket")
        T.eq(tys.v, "string", "named fields of a mixed constructor still check")
        T.eq(tys.t, "{ named: string, [number]: number }",
            "positional values join into the number part; string keys beyond `named` are claimed absent")
    end)
end)

T.describe("v9 lowering — index signatures (dynamic keys, arrays, iteration)", function()
    T.it("an annotated map read is `T | nil` (non-negotiable) and narrows", function()
        local src = "local m = {} --: { [string]: number }\nlocal k = 'a'\n"
            .. "local v = m[k]\nlocal n = 0\nif v then n = v end\nreturn n, v\n"
        local tys = infer(src)
        T.eq(tys.v, "nil | number", "an absent key IS nil in Lua — the read carries it")
        T.eq(tys.n, "number", "the truthy guard narrows the nil away")
        T.eq(#checked(src), 0, "the declared read + narrowed use is clean")
    end)

    T.it("an out-of-bound index write is index-write-mismatch with line/col", function()
        local diags = checked("local m = {} --: { [string]: number }\nlocal k = 'a'\nm[k] = 'oops'\nreturn m\n")
        local d = find_diag(diags, "index-write-mismatch")
        T.ok(d ~= nil, "the write is checked against the part's invariant w bound")
        if d ~= nil then
            T.eq(d.severity, "error", "mutation soundness is an error, like field writes")
            T.eq(d.line, 3, "at the write's line")
            T.eq(d.col, 2, "at the write's col")
        end
    end)

    T.it("named fields take precedence AND join into dynamic reads (sound)", function()
        local src = "local m = { n = 'label' } --: { n: string, [string]: number }\n"
            .. "local k = 'a'\nlocal v = m[k]\nreturn v\n"
        local tys = infer(src)
        T.eq(tys.v, "nil | number | string",
            "a dynamic key may hit the named field — its type joins in with the part + nil")
    end)

    T.it("array constructors build the `[number]` part; ipairs elems are `T`, not `T | nil`", function()
        local src = "local a = { 1, 2, 3 }\nlocal s = 0\n"
            .. "for i, v in ipairs(a) do s = s + v end\nreturn s, a\n"
        local tys = infer(src)
        T.eq(tys.a, "{ [number]: number }", "positional values join into the number part")
        T.eq(tys.s, "number", "the loop var is number — ipairs stops at the first nil (Lua semantics)")
        T.eq(#checked(src), 0, "the whole sum loop is clean — no phantom nil in `s + v`")
    end)

    T.it("pairs over a declared map types both loop vars via $Keys/$Values", function()
        local src = "local m = {} --: { [string]: number }\nlocal ks = ''\nlocal sum = 0\n"
            .. "for k, v in pairs(m) do ks = ks .. k sum = sum + v end\nreturn ks, sum\n"
        T.eq(#checked(src), 0, "k concatenates (string), v adds (number) — both flow")
    end)

    T.it("`#` on an array-part record is number", function()
        local src = "local a = { 1, 2 }\nlocal n = #a\nreturn n\n"
        local tys = infer(src)
        T.eq(tys.n, "number", "length of a table")
        T.eq(#checked(src), 0, "no op-mismatch")
    end)

    T.it("heterogeneous array parts join elementwise", function()
        local tys = infer("local a = { 1, 'two' }\nreturn a\n")
        T.eq(tys.a, "{ [number]: number | string }", "join(elems), no arity/tuple tracking (stated)")
    end)

    T.it("the annotation `{ [string]: T }` roundtrips through show", function()
        local tys = infer("local m = {} --: { [string]: number }\nreturn m\n")
        T.eq(tys.m, "{ [string]: number }", "the declared index part renders back")
        local arr = infer("local m = {} --: string[]\nlocal v = m[1]\nreturn v, m\n")
        T.eq(arr.m, "{ [number]: string }", "T[] is sugar for { [number]: T }")
        T.eq(arr.v, "nil | string", "and reads through it are T | nil")
    end)

    T.it("the build idiom grows an index part (the new-index-on-write concession)", function()
        local src = "local t = {}\nlocal k = 1\nt[k] = 5\nlocal v = t[k]\nreturn v, t\n"
        local tys = infer(src)
        T.eq(tys.t, "{ [number]: number }", "the write grew the num part on the writer's version")
        T.eq(tys.v, "nil | number", "the read-back is T | nil")
        T.eq(#checked(src), 0, "silent by default (the concession dial is off)")
        local strict = check.default_policy()
        strict["new-index-on-write"] = "error"
        local d2 = check.check_source(src, "t.lua", { policy = strict, mode = nil })
        T.ok(d2 ~= nil and find_diag(d2, "new-index-on-write") ~= nil,
            "dialed up, the concession is named at the write")
    end)

    T.it("PINNED boundary: growing through a LOOP-head phi loses the part (annotate instead)", function()
        -- join(plain {}, grown) drops idx — a plain open record admits keys
        -- at any type, so the joined view cannot claim boundedness (sound).
        -- The actionable fix IS the diagnostic's advice: annotate the decl.
        local src = "local out = {}\nfor i = 1, 3 do out[i] = i * 2 end\nlocal x = out[1]\nreturn x\n"
        local d = find_diag(checked(src), "index-without-signature")
        T.ok(d ~= nil, "the post-loop read reports the missing signature")
        local ann = "local out = {} --: { [number]: number }\n"
            .. "for i = 1, 3 do out[i] = i * 2 end\nlocal x = out[1]\nreturn x\n"
        T.eq(#checked(ann), 0, "the annotated build loop is fully checked and clean")
    end)

    T.it("`t[k] = nil` is DELETION — always legal (reads already carry | nil)", function()
        local src = "local m = {} --: { [string]: number }\nlocal k = 'a'\n"
            .. "m[k] = 1\nm[k] = nil\nreturn m\n"
        T.eq(find_diag(checked(src), "index-write-mismatch"), nil,
            "writing nil removes the key; it never enters the part's ref")
        local maybe = "local m = {} --: { [string]: number }\nlocal k = 'a'\n"
            .. "local v = m[k]\nm[k] = v\nreturn m\n"
        T.eq(find_diag(checked(maybe), "index-write-mismatch"), nil,
            "a maybe-nil write is a conditional deletion — the non-nil part fits")
    end)

    T.it("append idiom: a fresh constructor write checks under initialization ordering", function()
        local src = "local xs = {} --: { [number]: { id: number, tag: string | nil } }\n"
            .. "xs[1] = { id = 1, tag = 's' }\nxs[2] = { id = 2 }\nreturn xs\n"
        T.eq(find_diag(checked(src), "index-write-mismatch"), nil,
            "leq_init: absence of the optional field is nil, refs re-typed by the bound")
        local bad = "local xs = {} --: { [number]: { id: number } }\n"
            .. "xs[1] = { id = 'nope' }\nreturn xs\n"
        T.ok(find_diag(checked(bad), "index-write-mismatch") ~= nil,
            "a genuinely wrong constructor still fails the bound")
    end)

    T.it("keys outside string/number stay the honest dynamic-index boundary", function()
        local src = "local t = { 1 }\nlocal k = true\nlocal v = t[k]\nreturn v\n"
        local d = find_diag(checked(src), "unsupported:dynamic-index")
        T.ok(d ~= nil, "a boolean-typed key is outside the v0 index discipline")
    end)

    T.it("an unknown key must be narrowed first", function()
        local src = "local t = { 1 }\nlocal k = whatever\nlocal v = t[k]\nreturn v\n"
        local d = find_diag(checked(src), "use-before-narrow")
        T.ok(d ~= nil, "the key, not the target, is the unnarrowed value here")
    end)

    T.it("a `{ [string]: T }` record suppresses missing-field on unnamed reads", function()
        local src = "local m = {} --: { [string]: number }\nlocal v = m.anything\nreturn v\n"
        local tys = infer(src)
        T.eq(tys.v, "nil | number", "a named read through the part is the same T | nil projection")
        T.eq(find_diag(checked(src), "missing-field"), nil, "not a missing field — the part covers it")
    end)
end)

T.describe("v9 lowering — function types + intra-file inference", function()
    T.it("params are inferred from call sites (cells-as-unknowns)", function()
        local tys = infer("local function f(a) return a end\nlocal x = f(1)\nlocal y = f('s')\nreturn x, y\n")
        T.eq(tys.f, "(?) -> number | string", "param cell joins the call-site arguments")
        T.eq(tys.x, "number | string", "the result flows back out")
    end)

    T.it("return types are inferred from return statements", function()
        local tys = infer("local c = true\nlocal function f()\n  if c then return 1 end\n  return 's'\nend\nlocal r = f()\nreturn r\n")
        T.eq(tys.f, "() -> number | string", "both returns join at the result cell")
        T.eq(tys.r, "number | string", "call result is the arrow's result")
    end)

    T.it("multi-return: contextual truncation + nil extension", function()
        local src = "local function f() return 1, 's' end\n"
            .. "local a = f()\nlocal b, c, d = f()\nreturn a, b, c, d\n"
        local tys = infer(src)
        T.eq(tys.f, "() -> (number, string)", "two result positions")
        T.eq(tys.a, "number", "expression position truncates to the first result")
        T.eq(tys.b, "number", "spread position 1")
        T.eq(tys.c, "string", "spread position 2")
        T.eq(tys.d, "nil", "past the arity: Lua pads with nil, NOT unknown")
    end)

    T.it("mixed return arities pad the short return with nil", function()
        local tys = infer("local c = true\nlocal function f()\n  if c then return 1 end\n  return 1, 's'\nend\nlocal _, b = f()\nreturn b\n")
        T.eq(tys.f, "() -> (number, nil | string)", "position 2 is nil on the short path")
    end)

    T.it("a call in last return position marks the arrow result-OPEN", function()
        local src = "local function g() return 1 end\nlocal function f() return g() end\n"
            .. "local a, b = f()\nreturn a, b\n"
        local tys = infer(src)
        T.eq(tys.a, "number", "the forwarded first result is precise")
        T.eq(tys.b, "unknown", "positions beyond are unknown (forwarding is open), not nil")
    end)

    T.it("arguments beyond the param list are checked-lowered but dropped; missing args pad nil", function()
        local tys = infer("local function f(a, b) return b end\nlocal r = f(1)\nreturn r\n")
        T.eq(tys.r, "nil", "the missing argument reaches the body as nil")
    end)

    T.it("`require(...)` is the honest cross-module boundary", function()
        local _, diags = infer("local m = require('lib.foo')\nreturn m\n")
        local d = find_diag(diags, "unsupported:cross-module")
        T.ok(d ~= nil, "require flagged as the module boundary")
        T.eq(find_diag(diags, "undeclared-global"), nil,
            "not double-reported as an undeclared global")
        local tys = infer("local m = require('lib.foo')\nreturn m\n")
        T.eq(tys.m, "unknown", "the required module's type is unknown (no summaries yet)")
    end)

    T.it("phi of two different functions collapses to the function top (calls unchecked but flagged)", function()
        local src = "local c = true\nlocal function f(a) return 1 end\nlocal function g(a) return 's' end\n"
            .. "local h = nil\nif c then h = f else h = g end\nlocal r = h(1)\nreturn r\n"
        local tys = infer(src)
        T.eq(tys.h, "function", "different arrows join to the function top")
        T.eq(tys.r, "unknown", "calls through the top are unknown (narrow to check)")
    end)

    T.it("higher-order flow: a function passed as an argument is callable inside", function()
        local src = "local function apply(fn) return fn(2) end\n"
            .. "local function double(n) return n end\nlocal r = apply(double)\nreturn r\n"
        local tys = infer(src)
        T.eq(tys.r, "number", "the callback's arrow flows through the param cell")
    end)
end)

T.describe("v9 lowering — totality roster", function()
    T.it("routes ALL 30 node kinds (checked / boundary / container)", function()
        local n = 0
        for tag = 0, frontend.NODE_KIND_COUNT - 1 do
            local route = lower.ROUTE[tag]
            T.ok(route == "checked" or route == "boundary" or route == "container",
                "kind " .. frontend.node_name(tag) .. " is routed (" .. tostring(route) .. ")")
            n = n + 1
        end
        T.eq(n, 30, "all 30 kinds routed")
    end)

    T.it("local function recursion terminates and infers honestly", function()
        -- f never returns a value along any path that terminates: its result
        -- is genuinely `never` (a bottom cycle), and the trailing-call spread
        -- marks the arrow result-open. The fixpoint TERMINATES (clip bounds
        -- the recursion-created value cycle).
        local tys = infer("local function f(n)\n  return f(n)\nend\nlocal r = f(1)\nreturn r\n")
        T.eq(tys.f, "(?) -> (never, ...)", "local function binds itself; param inferred from the call sites")
        T.eq(tys.r, "never", "a call that provably never returns has result never")
    end)
end)
