-- lib/platform/apps/system_dashboard/projections/projection_types_test.lua
-- End-to-end test for the projection prelude:
--
--   1. Typechecks example_text.lua against the prelude (clean).
--   2. Typechecks several intentionally-broken projections and asserts the
--      expected category of error fires.
--   3. Transpiles example_text.lua via lib/lua2ts with harden = true and
--      asserts the JS output has the expected structural shape and lacks JS
--      hazards.

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local T       = require("lib.test.assert")
local check   = require("lib.type.static.check")
local lua2ts  = require("lib.lua2ts")

local PROJECTION_DIR = "lib/platform/apps/system_dashboard/projections/"
local EXAMPLE_PATH   = PROJECTION_DIR .. "example_text.lua"

-- The full globals stack a projection author sees: stdlib, the shared Primitive
-- declarations, and the projection prelude (dom, Element, Ctx, text, etc.).
local GLOBALS_FILES = {
    "lib/type/static/stdlib_types.lua",
    "lib/js_types/init.lua",
    "lib/platform/apps/system_dashboard/primitive_types.lua",
    PROJECTION_DIR .. "projection_types.lua",
}

local function read_file(path)
    local f = assert(io.open(path, "r"))
    local s = f:read("*a")
    f:close()
    return s
end

local function check_src(src, filename)
    local err_ctx = check.check_string(src, filename or "test.lua",
        nil, nil, nil, { globals_files = GLOBALS_FILES })
    return err_ctx
end

local function any_error_matches(err_ctx, pattern)
    for _, e in ipairs(err_ctx.errors) do
        local msg = e.msg or e.message or ""
        if msg:find(pattern, 1, true) then return true end
    end
    return false
end

-- ── 1. Good example typechecks clean ────────────────────────────────────────

T.describe("projection_types: example_text typechecks against prelude", function()
    T.it("no errors, no warnings", function()
        local src = read_file(EXAMPLE_PATH)
        local err_ctx = check_src(src, EXAMPLE_PATH)
        T.eq(#err_ctx.errors, 0,
            "expected zero errors but got: " ..
            (err_ctx.errors[1] and (err_ctx.errors[1].msg or err_ctx.errors[1].message) or ""))
        T.eq(#err_ctx.warnings, 0)
    end)
end)

-- ── 2. Bad projections produce expected diagnostics ─────────────────────────

T.describe("projection_types: rejects undeclared dom tag", function()
    T.it("dom.marquee is not in the allowlist", function()
        local err_ctx = check_src([[
local x = dom.marquee({}, {})
return x
]], "bad_tag.lua")
        T.ok(#err_ctx.errors > 0, "expected at least one error")
        T.ok(any_error_matches(err_ctx, "marquee"),
            "expected an error mentioning the unknown tag `marquee`")
    end)
end)

T.describe("projection_types: rejects wrong-typed prop argument", function()
    T.it("dom.span(42, ...) — props must be a record", function()
        local err_ctx = check_src([[
local x = dom.span(42, {})
return x
]], "bad_props.lua")
        T.ok(#err_ctx.errors > 0, "expected at least one error")
        T.ok(any_error_matches(err_ctx, "is not assignable"),
            "expected a structural assignability error")
    end)
end)

T.describe("projection_types: rejects non-Element return", function()
    T.it("annotated projection that returns a string", function()
        local err_ctx = check_src([[
local function bad(value, ctx) --: (Text, Ctx) -> Element
    return "not an element"
end
return bad
]], "bad_return.lua")
        T.ok(#err_ctx.errors > 0, "expected at least one error")
        T.ok(any_error_matches(err_ctx, "return type mismatch") or
             any_error_matches(err_ctx, "not assignable"),
            "expected a return-type mismatch")
    end)
end)

-- ── 3. Transpilation produces hardened JS with the expected shape ───────────

T.describe("projection_types: example_text transpiles to hardened JS", function()
    local src = read_file(EXAMPLE_PATH)
    local ts0, err = lua2ts.transpile(src, {
        filename = EXAMPLE_PATH,
        harden   = true,
    })
    T.ok(ts0 ~= nil, "transpile failed: " .. tostring(err))
    local ts = ts0 or ""

    T.it("emits __rec for record literal props", function()
        T.ok(ts:find("__rec(", 1, true) ~= nil,
            "expected '__rec(' in output:\n" .. ts)
        T.ok(ts:find("const __rec = ", 1, true) ~= nil,
            "expected '__rec' helper definition in output")
    end)

    T.it("does not reference JS hazard identifiers", function()
        for _, hazard in ipairs(lua2ts.JS_HAZARDS) do
            T.ok(ts:find(hazard, 1, true) == nil,
                "hazard '" .. hazard .. "' must not appear in output:\n" .. ts)
        end
    end)

    T.it("preserves the projection function shape", function()
        T.ok(ts:find("project_text", 1, true) ~= nil,
            "expected projection function name in output")
        T.ok(ts:find("dom.span", 1, true) ~= nil,
            "expected dom.span call to be preserved")
        -- Default module mode is ESM; a bare top-level `return` is a
        -- SyntaxError there, so the chunk's trailing return is emitted as
        -- `export default` instead of `return`.
        T.ok(ts:find("export default project_text", 1, true) ~= nil,
            "expected the function to be the module's default export")
    end)
end)
