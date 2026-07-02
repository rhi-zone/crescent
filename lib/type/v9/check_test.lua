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
                T.ok(d.message:find("boolean", 1, true) ~= nil, "names the offender: " .. d.message)
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
        or code == "use-before-narrow" or code == "undeclared-global"
        or code == "global-write" or code == "unused-local" or code == "internal"
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
            local loops = h["unsupported:for-num"] or 0
            T.ok(loops > 0, "base64 has numeric loops -> the boundary shows in the histogram")
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
