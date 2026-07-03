-- lib/type/v9/check_test.lua
-- The runner end-to-end: source/file -> policy-stamped diagnostics with
-- line/col; the owner power dial (named policy rules); caps-first file
-- access; REAL lib files checked without crashes, internal-invariant
-- violations, or unknown diagnostic kinds; a bounded totality smoke.

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local check = require("lib.type.v9.check")

--:: CDiag = { code: string, severity: string, message: string, line: integer, col: integer }

--: ({ [integer]: CDiag }, string) -> CDiag | nil
local function find_diag(diags, code)
    for i = 1, #diags do
        if diags[i].code == code then return diags[i] end
    end
    return nil
end

T.describe("v9 check — supported-discipline diagnostics", function()
    T.it("op-mismatch is an error with line/col", function()
        local diags, err = check.check_source("local a = 1 + true\nreturn a\n", "t.lua", nil)
        T.ok(diags ~= nil, "checked: " .. (err or ""))
        if diags ~= nil then
            local d = find_diag(diags, "op-mismatch")
            T.ok(d ~= nil, "op-mismatch found")
            if d ~= nil then
                T.eq(d.severity, "error", "default policy: error")
                T.eq(d.line, 1, "line")
                T.eq(d.col, 15, "col of the boolean operand")
                T.ok(d.message:find("`true`", 1, true) ~= nil,
                    "names the offender at literal precision: " .. d.message)
            end
        end
    end)

    T.it("calling a non-function is an error", function()
        local diags = check.check_source("local x = 1\nlocal y = x()\nreturn y\n", "t.lua", nil)
        T.ok(diags ~= nil, "checked")
        if diags ~= nil then
            local d = find_diag(diags, "call-non-function")
            T.ok(d ~= nil, "flagged")
            if d ~= nil then
                T.eq(d.severity, "error", "error severity")
                T.eq(d.line, 2, "line of the call")
            end
        end
    end)

    T.it("parse errors are diagnostics with position, not throws", function()
        local diags = check.check_source("local = nonsense((\n", "t.lua", nil)
        T.ok(diags ~= nil, "returned diags")
        if diags ~= nil then
            local d = find_diag(diags, "parse-error")
            T.ok(d ~= nil, "parse-error diag")
            if d ~= nil then
                T.eq(d.severity, "error", "error severity")
                T.eq(d.line, 1, "position recovered from the parser message")
            end
        end
    end)
end)

T.describe("v9 check — the power dial (named policy rules)", function()
    T.it("use-before-narrow warns by default, errors when dialed", function()
        local src = "local f = whatever\nlocal x = f + 1\nreturn x\n"
        local diags = check.check_source(src, "t.lua", nil)
        T.ok(diags ~= nil, "checked")
        if diags ~= nil then
            local d = find_diag(diags, "use-before-narrow")
            T.ok(d ~= nil, "unknown used dynamically is flagged, not silently passed")
            if d ~= nil then T.eq(d.severity, "warn", "default: warn (v0 cannot narrow it yet)") end
        end
        local strict = check.default_policy()
        strict["use-before-narrow"] = "error"
        local diags2 = check.check_source(src, "t.lua", { policy = strict, mode = nil })
        if diags2 ~= nil then
            local d2 = find_diag(diags2, "use-before-narrow")
            T.ok(d2 ~= nil and d2.severity == "error", "the dial is owner-decidable data")
        end
    end)

    T.it("unsupported buckets resolve through the prefix family", function()
        T.eq(check.severity_of(check.default_policy(), "unsupported:for-num"), "warn", "prefix fallback")
        local p = check.default_policy()
        p["unsupported:for-num"] = "error"
        T.eq(check.severity_of(p, "unsupported:for-num"), "error", "per-bucket override wins")
        T.eq(check.severity_of(p, "unsupported:vararg"), "warn", "others keep the family default")
    end)
end)

T.describe("v9 check — structural records (obligations end to end)", function()
    T.it("width is free; a provably absent field is missing-field with line/col", function()
        local ok_diags = check.check_source(
            "local t = { x = 1, y = 2 }\nlocal a = t.x + t.y\nreturn a\n", "t.lua", nil)
        T.ok(ok_diags ~= nil and #ok_diags == 0, "extra fields never hurt (open records)")
        local diags = check.check_source(
            "local t = { x = 1 }\nlocal y = t.z\nreturn y, t\n", "t.lua", nil)
        T.ok(diags ~= nil, "checked")
        if diags ~= nil then
            local d = find_diag(diags, "missing-field")
            T.ok(d ~= nil, "t.z flagged")
            if d ~= nil then
                T.eq(d.severity, "warn", "default policy: warn (v0 absence evidence)")
                T.eq(d.line, 2, "line of the read")
                T.eq(d.col, 12, "col of the read")
                T.ok(d.message:find("'z'", 1, true) ~= nil, "names the field: " .. d.message)
            end
        end
    end)

    T.it("WRITE VARIANCE: a widened-alias write is rejected; the narrow alias stays sound", function()
        -- The classic unsoundness under naive covariant writes: u aliases t,
        -- writing "s" through u would make `t.x + 1` explode at runtime while
        -- checking clean. The invariant write bound rejects the WRITE instead.
        local src = "local t = { x = 1 }\nlocal u = t\nu.x = 's'\nlocal n = t.x + 1\nreturn n, u\n"
        local diags = check.check_source(src, "t.lua", nil)
        T.ok(diags ~= nil, "checked")
        if diags ~= nil then
            local d = find_diag(diags, "field-write-mismatch")
            T.ok(d ~= nil, "the unsound write is rejected")
            if d ~= nil then
                T.eq(d.severity, "error", "mutation soundness is an error by default")
                T.eq(d.line, 3, "line of the write")
            end
            T.eq(find_diag(diags, "op-mismatch"), nil,
                "t.x + 1 stays clean: the field type was never relaxed by the write")
        end
    end)

    T.it("writes through a phi'd view must be safe for EVERY branch (w = meet)", function()
        local src = "local a = { x = 1 }\nlocal b = { x = 's' }\nlocal c = true\nlocal t = nil\n"
            .. "if c then t = a else t = b end\nif t then t.x = 1 end\nreturn t, a, b\n"
        local diags = check.check_source(src, "t.lua", nil)
        T.ok(diags ~= nil, "checked")
        if diags ~= nil then
            local d = find_diag(diags, "field-write-mismatch")
            T.ok(d ~= nil, "even a number write is rejected (b.x readers rely on string)")
        end
        local ok_src = "local t = { x = 1 }\nt.x = 2\nreturn t\n"
        local ok_diags = check.check_source(ok_src, "t.lua", nil)
        T.ok(ok_diags ~= nil and #ok_diags == 0, "in-bound writes are clean")
    end)

    T.it("new-field-on-write is the named concession: off by default, dialable", function()
        local src = "local M = {}\nM.f = 1\nreturn M\n"
        local diags = check.check_source(src, "t.lua", nil)
        T.ok(diags ~= nil and #diags == 0, "the module idiom is admitted silently by default")
        local strict = check.default_policy()
        strict["new-field-on-write"] = "error"
        local diags2 = check.check_source(src, "t.lua", { policy = strict, mode = nil })
        T.ok(diags2 ~= nil, "checked")
        if diags2 ~= nil then
            local d = find_diag(diags2, "new-field-on-write")
            T.ok(d ~= nil and d.severity == "error", "dialed up, the concession is refusable")
        end
    end)

    T.it("method-call sugar: t:m() is a field read + a call", function()
        local ok_diags = check.check_source(
            "local M = {}\nfunction M:greet() return 1 end\nlocal r = M:greet()\nreturn r\n", "t.lua", nil)
        T.ok(ok_diags ~= nil and #ok_diags == 0, "declared method calls clean")
        local diags = check.check_source(
            "local t = { m = 1 }\nlocal r = t:m()\nreturn r\n", "t.lua", nil)
        T.ok(diags ~= nil, "checked")
        if diags ~= nil then
            local d = find_diag(diags, "call-non-function")
            T.ok(d ~= nil, "calling a number field is call-non-function")
        end
        local diags2 = check.check_source(
            "local t = { x = 1 }\nlocal r = t:nope()\nreturn r\n", "t.lua", nil)
        if diags2 ~= nil then
            local d2 = find_diag(diags2, "missing-field")
            T.ok(d2 ~= nil and d2.message:find("'nope'", 1, true) ~= nil, "missing method named")
        end
    end)

    T.it("string methods resolve through the DECLARED string table (the metatable)", function()
        -- LuaJIT sets the string metatable's __index to the string library;
        -- v9 wires string-typed member access to the DECLARED `string`
        -- table — declaration-driven, never a hardcoded method list.
        local diags = check.check_source("local s = 'a'\nlocal r = s:sub(1)\nreturn r\n", "t.lua", nil)
        T.ok(diags ~= nil and #diags == 0, "s:sub(1) checks clean (was the string-method bucket)")
        local chain = check.check_source(
            "local r = ('x'):upper():lower()\nlocal n = #r + r:len()\nreturn n\n", "t.lua", nil)
        T.ok(chain ~= nil and #chain == 0, "upper():lower() roundtrips; #s and s:len() are numbers")
        local multi = check.check_source(
            "local s, n = ('ab'):gsub('a', 'b')\nlocal m = n + 1\nlocal t = s .. '!'\nreturn m, t\n",
            "t.lua", nil)
        T.ok(multi ~= nil and #multi == 0, "gsub's multi-return carries (string, integer)")
    end)

    T.it("string members are CHECKED, not just admitted", function()
        local missing = check.check_source("local s = 'a'\nlocal r = s:nope()\nreturn r\n", "t.lua", nil)
        T.ok(missing ~= nil, "checked")
        if missing ~= nil then
            local d = find_diag(missing, "missing-field")
            T.ok(d ~= nil and d.message:find("'nope'", 1, true) ~= nil,
                "an undeclared string method is missing-field, not silence")
            T.eq(find_diag(missing, "unsupported:string-method"), nil, "the bucket is retired")
        end
        local badarg = check.check_source(
            "local s = 'a'\nlocal r = s:rep({})\nreturn r\n", "t.lua", nil)
        T.ok(badarg ~= nil, "checked")
        if badarg ~= nil then
            T.ok(find_diag(badarg, "call-mismatch") ~= nil,
                "a bad argument to a string method is a real call-mismatch")
        end
        local write = check.check_source("local s = 'a'\ns.x = 1\nreturn s\n", "t.lua", nil)
        T.ok(write ~= nil, "checked")
        if write ~= nil then
            T.ok(find_diag(write, "op-mismatch") ~= nil,
                "writing a field on a string is op-mismatch (no __newindex)")
        end
    end)

    T.it("field access on non-tables is op-mismatch at the use site", function()
        local diags = check.check_source("local n = 1\nlocal v = n.x\nreturn v\n", "t.lua", nil)
        T.ok(diags ~= nil, "checked")
        if diags ~= nil then
            local d = find_diag(diags, "op-mismatch")
            T.ok(d ~= nil, "number.x flagged")
            if d ~= nil then
                T.ok(d.message:find("number", 1, true) ~= nil, "names the offender: " .. d.message)
            end
        end
    end)
end)

T.describe("v9 check — function boundary honesty", function()
    T.it("a parameter no call reaches is ONE honest diagnostic, not a per-use flood", function()
        local diags = check.check_source(
            "local function f(x)\n  local y = x.field\n  return y\nend\nreturn f\n", "t.lua", nil)
        T.ok(diags ~= nil, "checked")
        if diags ~= nil then
            local d = find_diag(diags, "unsupported:unconstrained-param")
            T.ok(d ~= nil, "the unchecked-body boundary is named")
            if d ~= nil then
                T.ok(d.message:find("'x'", 1, true) ~= nil, "names the parameter: " .. d.message)
            end
            T.eq(find_diag(diags, "use-before-narrow"), nil,
                "no per-use unknown flood for a body checked against no inputs")
        end
    end)

    T.it("a called function's params take evidence from the call, and the body is checked with it", function()
        local diags = check.check_source(
            "local function f(x) return x + 1 end\nlocal r = f('s')\nreturn r\n", "t.lua", nil)
        T.ok(diags ~= nil, "checked")
        if diags ~= nil then
            local d = find_diag(diags, "op-mismatch")
            T.ok(d ~= nil, "the string argument surfaces at the body's `+`")
            T.eq(find_diag(diags, "unsupported:unconstrained-param"), nil, "param IS constrained")
        end
    end)
end)

T.describe("v9 check — control-flow precision (the recorded false-positive classes)", function()
    T.it("the math/init.lua:11 idiom: `== nil` early exit narrows for the stdlib pin", function()
        -- tonumber -> number|nil; the guard + diverging branch leave number.
        local src = "local n = tonumber('42')\nif n == nil then return nil end\n"
            .. "local i = math.floor(n)\nreturn i\n"
        local diags = check.check_source(src, "t.lua", nil)
        T.ok(diags ~= nil, "checked")
        if diags ~= nil then
            T.eq(find_diag(diags, "call-mismatch"), nil,
                "math.floor(n) is clean after the nil guard")
        end
    end)

    T.it("the pagination:384 idiom: `cond and 1 or math.ceil(...)` is a number", function()
        local src = "local total = 0\nlocal per = 10\n"
            .. "local tp = total == 0 and 1 or math.ceil(total / per)\n"
            .. "local c = math.min(1, tp)\nreturn c\n"
        local diags = check.check_source(src, "t.lua", nil)
        T.ok(diags ~= nil, "checked")
        if diags ~= nil then
            T.eq(find_diag(diags, "call-mismatch"), nil,
                "no phantom boolean reaches the stdlib pin")
            T.eq(find_diag(diags, "op-mismatch"), nil, "no operand complaint either")
        end
    end)

    T.it("the early-exit string guard checks the fall-through use", function()
        local src = "local function f(x)\n  if type(x) ~= 'string' then return nil end\n"
            .. "  return x .. '!'\nend\nlocal r = f('a')\nreturn r\n"
        local diags = check.check_source(src, "t.lua", nil)
        T.ok(diags ~= nil, "checked")
        if diags ~= nil then
            T.eq(#diags, 0, "the idiom is clean end to end")
        end
    end)
end)

T.describe("v9 check — caps-first file access", function()
    T.it("reads through injected caps only", function()
        local caps = {
            --: (string) -> (string | nil, string | nil)
            read_file = function(path)
                if path == "mem.lua" then return "local a = 1\nreturn a\n", nil end
                return nil, path .. ": not found"
            end,
        }
        local diags, err = check.check_file(caps, "mem.lua", nil)
        T.ok(diags ~= nil and #diags == 0, "clean in-memory file checks clean: " .. (err or ""))
        local none, err2 = check.check_file(caps, "missing.lua", nil)
        T.eq(none, nil, "missing file is (nil, errmsg)")
        T.ok(err2 ~= nil, "errmsg present")
    end)
end)

-- ── real files ─────────────────────────────────────────────────────────────
-- The vertical slice's point: REAL code from this repo, end to end. The
-- assertions are stability-safe (no exact counts): no crashes, no `internal`
-- invariant violations, positions on every diag, and only KNOWN diagnostic
-- kinds — the totality claim in test form.

local REAL_FILES = {
    "lib/base64/init.lua",
    "lib/uuid/init.lua",
    "lib/queue/init.lua",
    "lib/semver/init.lua",
}

--: (string) -> boolean
local function known_code(code)
    if code:sub(1, 12) == "unsupported:" then return true end
    return code == "parse-error" or code == "op-mismatch" or code == "call-non-function"
        or code == "call-mismatch" or code == "use-before-narrow" or code == "undeclared-global"
        or code == "global-write" or code == "unused-local" or code == "internal"
        or code == "missing-field" or code == "field-write-mismatch"
        or code == "new-field-on-write" or code == "annotation-mismatch"
        or code == "cast-mismatch" or code == "force-cast"
        or code == "index-without-signature" or code == "index-write-mismatch"
        or code == "new-index-on-write"
end

--: (string) -> (string | nil, string | nil)
local function read_file(path)
    local f = io.open(path, "r")
    if f == nil then return nil, path .. ": cannot open" end
    local s = f:read("*a")
    f:close()
    if s == nil then return nil, path .. ": cannot read" end
    return s, nil
end

T.describe("v9 check — real lib files, end to end", function()
    T.it("checks real files: positions everywhere, no internals, known kinds only", function()
        local caps = { read_file = read_file }
        for i = 1, #REAL_FILES do
            local path = REAL_FILES[i]
            local diags, err = check.check_file(caps, path, nil)
            T.ok(diags ~= nil, path .. " checked without crashing: " .. (err or ""))
            if diags ~= nil then
                T.ok(#diags > 0, path .. " produces diagnostics (v0 boundary is honest)")
                local bad_pos = 0
                local unknown_kind = 0
                local internals = 0
                for j = 1, #diags do
                    local d = diags[j]
                    if d.line < 1 or d.col < 1 then bad_pos = bad_pos + 1 end
                    if not known_code(d.code) then unknown_kind = unknown_kind + 1 end
                    if d.code == "internal" then internals = internals + 1 end
                end
                T.eq(bad_pos, 0, path .. ": every diag has line/col")
                T.eq(unknown_kind, 0, path .. ": only known diagnostic kinds")
                T.eq(internals, 0, path .. ": no lowering invariant violations")
            end
        end
    end)

    T.it("histogram counts by code and sums to the diag count", function()
        local caps = { read_file = read_file }
        local diags = check.check_file(caps, "lib/base64/init.lua", nil)
        T.ok(diags ~= nil, "checked")
        if diags ~= nil then
            local h = check.histogram(diags)
            local sum = 0
            for _, n in pairs(h) do sum = sum + n end
            T.eq(sum, #diags, "histogram is a partition of the diags")
            T.eq(h["unsupported:for-num"], nil,
                "base64's numeric loops are CHECKED now, not a boundary bucket")
        end
    end)

    T.it("bounded totality smoke: a slice of lib/ lowers without crashes", function()
        -- The full-tree run lives in smoke.lua (tool); this keeps a bounded
        -- always-on regression: every v9/engine/frontend file + the real
        -- validation files, parse+lower mode.
        local caps = { read_file = read_file }
        local sample = {
            "lib/type/v9/check.lua",
            "lib/type/v9/lower.lua",
            "lib/type/v9/lattice.lua",
            "lib/type/v9/frontend/init.lua",
            "lib/type/v9/engine/engine.lua",
            "lib/type/v9/engine/domain/types.lua",
            "lib/type/v9/engine/domain/liveness.lua",
            "lib/type/v9/engine/domain/constprop.lua",
            "lib/base64/init.lua",
            "lib/uuid/init.lua",
            "lib/queue/init.lua",
            "lib/semver/init.lua",
        }
        local crashes = 0
        for i = 1, #sample do
            local diags = check.check_file(caps, sample[i], { mode = "lower", policy = nil })
            if diags == nil then crashes = crashes + 1 end
        end
        T.eq(crashes, 0, "zero crashes across the sample")
    end)
end)
