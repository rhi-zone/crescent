-- lib/lua2ts/lua2ts_harden_test.lua
-- Tests for harden mode: null-proto records, bounded methods, JS-hazard
-- identifier blocklist.

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local lua2ts = require("lib.lua2ts")

local function transpile_h(src)
    return lua2ts.transpile(src, { filename = "test.lua", harden = true })
end

local function transpile_plain(src)
    return lua2ts.transpile(src, { filename = "test.lua" })
end

local function has(ts, sub, desc)
    T.ok(ts ~= nil, desc .. " (transpile result not nil)")
    if ts then
        T.ok(ts:find(sub, 1, true) ~= nil,
            desc .. ": expected " .. string.format("%q", sub) .. " in:\n" .. ts)
    end
end

local function hasnt(ts, sub, desc)
    T.ok(ts ~= nil, desc .. " (transpile result not nil)")
    if ts then
        T.ok(ts:find(sub, 1, true) == nil,
            desc .. ": did not expect " .. string.format("%q", sub) .. " in:\n" .. ts)
    end
end

-- ---------------------------------------------------------------------------
-- Null-prototype records
-- ---------------------------------------------------------------------------

T.describe("harden: record table → __rec({...})", function()
    local ts = transpile_h([[local r = { a = 1, b = 2 }]])
    has(ts, "__rec({", "record wrapped with __rec")
    has(ts, "a: 1", "field a preserved")
    has(ts, "b: 2", "field b preserved")
    has(ts, "const __rec = ", "helper emitted")
end)

T.describe("harden: pure-array table unchanged", function()
    local ts = transpile_h([[local a = { 1, 2, 3 }]])
    has(ts, "[1, 2, 3]", "array literal preserved")
    hasnt(ts, "__rec(", "no __rec wrap on array")
end)

-- Mixed array+keyed tables: the existing emitter routes them through the
-- object branch (positional entries become numeric keys). Harden mode
-- therefore wraps the whole object in __rec — the simplest and safest
-- choice. Document the call here.
T.describe("harden: mixed table → object branch wrapped in __rec", function()
    local ts = transpile_h([[local m = { 1, x = 2 }]])
    has(ts, "__rec({", "mixed table wrapped with __rec (whole-object form)")
end)

T.describe("harden: empty table unchanged (nothing to protect)", function()
    local ts = transpile_h([[local e = {}]])
    has(ts, "{}", "empty table emitted as {}")
    hasnt(ts, "__rec({})", "no __rec wrap on empty")
end)

T.describe("plain mode: no __rec wrap", function()
    local ts = transpile_plain([[local r = { a = 1, b = 2 }]])
    hasnt(ts, "__rec(", "plain mode does not wrap records")
    hasnt(ts, "const __rec", "plain mode does not emit __rec helper")
end)

-- ---------------------------------------------------------------------------
-- Memory-bounded JS methods
-- ---------------------------------------------------------------------------

-- Note: `s:repeat(n)` is unwriteable in Lua (`repeat` is a reserved word)
-- so we can't exercise the repeat rewrite from a Lua source. The rewrite
-- entry is retained in HARDEN_METHOD_REWRITE for completeness; the other
-- three helpers (padStart, padEnd, join) cover the test surface.
T.describe("harden: padStart triggers __MAX_OUTPUT and helper emission", function()
    local ts = transpile_h([[local r = s:padStart(10, " ")]])
    has(ts, "const __safe_pad_start = ", "helper emitted")
    has(ts, "__MAX_OUTPUT", "MAX constant emitted")
    has(ts, "__safe_pad_start(s, 10", "call site rewritten to helper")
end)

T.describe("harden: s:padStart and s:padEnd rewritten", function()
    local ts1 = transpile_h([[local r = s:padStart(10, " ")]])
    has(ts1, "__safe_pad_start(s, 10", "padStart rewritten")
    local ts2 = transpile_h([[local r = s:padEnd(10, " ")]])
    has(ts2, "__safe_pad_end(s, 10", "padEnd rewritten")
end)

T.describe("harden: arr:join(sep) → __safe_join(arr, sep)", function()
    local ts = transpile_h([[local r = arr:join(",")]])
    has(ts, '__safe_join(arr, ","', "join rewritten")
    has(ts, "const __safe_join = ", "helper emitted")
end)

T.describe("harden: unrelated method names pass through", function()
    local ts = transpile_h([[local r = obj:foo(1, 2)]])
    has(ts, "obj.foo(1, 2)", "non-bounded method unchanged")
    hasnt(ts, "__safe_", "no safe helper for unrelated method")
end)

T.describe("plain mode: no method rewrites", function()
    local ts = transpile_plain([[local r = s:padStart(10, " ")]])
    has(ts, "s.padStart(10", "plain mode keeps direct method call")
    hasnt(ts, "__safe_pad_start", "plain mode does not emit helper")
end)

-- ---------------------------------------------------------------------------
-- JS-hazard identifier blocklist
-- ---------------------------------------------------------------------------

T.describe("harden: free identifier 'globalThis' → transpile error", function()
    local ts, err = lua2ts.transpile([[local x = globalThis]],
        { filename = "test.lua", harden = true })
    T.eq(ts, nil, "no output produced")
    T.ok(err and err:find("E_HARDEN_BLOCKED_IDENT", 1, true) ~= nil,
        "error mentions E_HARDEN_BLOCKED_IDENT (got: " .. tostring(err) .. ")")
    T.ok(err and err:find("globalThis", 1, true) ~= nil,
        "error names the identifier")
end)

T.describe("harden: 'fetch' as free identifier → transpile error", function()
    local _, err = lua2ts.transpile([[local x = fetch("/")]],
        { filename = "test.lua", harden = true })
    T.ok(err and err:find("fetch", 1, true) ~= nil,
        "fetch blocked")
end)

T.describe("harden: blocklist name as field is allowed", function()
    -- x.globalThis is a field access, NOT a global identifier reference.
    local ts, err = lua2ts.transpile([[local y = x.globalThis]],
        { filename = "test.lua", harden = true })
    T.ok(ts ~= nil, "field-of-globalThis allowed (err: " .. tostring(err) .. ")")
    if ts then
        has(ts, "x.globalThis", "field access preserved")
    end
end)

-- Design choice: a `local globalThis = ...` binding still errors. Shadowing
-- a JS hazard name in projection code is suspicious and the spec calls
-- for an error here. The check fires at the binding site (LOCAL_STMT
-- name iteration), independent of any RHS reference.
T.describe("harden: local binding of blocklist name still errors", function()
    local _, err = lua2ts.transpile([[local globalThis = 1]],
        { filename = "test.lua", harden = true })
    T.ok(err and err:find("globalThis", 1, true) ~= nil,
        "local binding of globalThis errors (suspicious shadowing)")
end)

T.describe("harden: Lua-only names like _G pass through", function()
    -- _G is not a JS global; at runtime it's an undefined-identifier
    -- ReferenceError, not a sandbox-escape. Not lua2ts's job to police.
    local ts, err = lua2ts.transpile([[local x = _G]],
        { filename = "test.lua", harden = true })
    T.ok(ts ~= nil, "_G allowed in harden mode (err: " .. tostring(err) .. ")")
    if ts then has(ts, "_G", "_G emitted unchanged") end
end)

T.describe("harden: 'os' and 'io' pass through", function()
    local ts1 = transpile_h([[local t = os.time]])
    T.ok(ts1 ~= nil, "os.time allowed")
    local ts2 = transpile_h([[local f = io.open]])
    T.ok(ts2 ~= nil, "io.open allowed")
end)

T.describe("plain mode: blocklist names allowed", function()
    local ts, err = lua2ts.transpile([[local x = globalThis]],
        { filename = "test.lua" })
    T.ok(ts ~= nil, "plain mode allows globalThis (err: " .. tostring(err) .. ")")
end)

-- ---------------------------------------------------------------------------
-- Helper emission
-- ---------------------------------------------------------------------------

T.describe("harden: helpers emitted exactly once", function()
    local ts = transpile_h([[
local r1 = { a = 1 }
local r2 = { b = 2 }
local s1 = x:padStart(2, " ")
local s2 = y:padStart(3, " ")
]])
    -- Count occurrences of the helper definitions. Each should appear once.
    local function count(haystack, needle)
        local n, i = 0, 1
        while true do
            local s, e = haystack:find(needle, i, true)
            if not s then return n end
            n = n + 1
            i = e + 1
        end
    end
    T.eq(count(ts, "const __rec = "), 1, "__rec defined once")
    T.eq(count(ts, "const __safe_pad_start = "), 1, "__safe_pad_start defined once")
    T.eq(count(ts, "const __MAX_OUTPUT = "), 1, "__MAX_OUTPUT defined once")
end)

T.describe("harden: helpers appear at top of output", function()
    local ts = transpile_h([[local r = { a = 1 }]])
    -- __rec definition must precede the use in `const r = __rec({...})`.
    local def = ts:find("const __rec = ", 1, true)
    local use = ts:find("__rec({", 1, true)
    T.ok(def ~= nil and use ~= nil and def < use,
        "__rec defined before first use")
end)

T.describe("harden: no helpers emitted when none triggered", function()
    -- A purely scalar program should emit no helpers.
    local ts = transpile_h([[local x = 1 + 2]])
    hasnt(ts, "const __rec", "no __rec helper when no records")
    hasnt(ts, "const __safe_", "no safe helpers when no methods")
    hasnt(ts, "__MAX_OUTPUT", "no MAX constant when no safe helpers")
end)

-- ---------------------------------------------------------------------------
-- Blocklist export
-- ---------------------------------------------------------------------------

T.describe("M.JS_HAZARDS exported for auditability", function()
    T.ok(type(lua2ts.JS_HAZARDS) == "table", "JS_HAZARDS is a table")
    local found = {}
    for _, n in ipairs(lua2ts.JS_HAZARDS) do found[n] = true end
    T.ok(found.globalThis == true, "globalThis listed")
    T.ok(found.eval == true, "eval listed")
    T.ok(found.fetch == true, "fetch listed")
    T.ok(found.setTimeout == true, "setTimeout listed")
    T.ok(found._G ~= true, "_G not in JS hazards")
    T.ok(found.os ~= true, "os not in JS hazards")
end)
