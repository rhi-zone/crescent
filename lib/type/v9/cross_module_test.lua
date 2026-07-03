-- lib/type/v9/cross_module_test.lua
-- CROSS-MODULE SUMMARIES end to end: the session (demand-driven, cached,
-- cycle-cut), the resolution seam (dot -> slash, init.lua fallback), the
-- declaration-driven `$Require<1>` wiring (no name-keying — proven by
-- wiring a NON-require name through the same declaration form), `--::
-- require` type-only alias imports, summary immutability, and the
-- `unannotated-module-boundary` policy dial. All over injected fake caps —
-- no io, fully hermetic.

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local check = require("lib.type.v9.check")
local modules = require("lib.type.v9.modules")

--:: CDiag = { code: string, severity: string, message: string, line: integer, col: integer }

--: ({ [integer]: CDiag }, string) -> CDiag | nil
local function find_diag(diags, code)
    for i = 1, #diags do
        if diags[i].code == code then return diags[i] end
    end
    return nil
end

-- Fake filesystem caps: a path -> source map behind the ONE injected cap.
--: ({ [string]: string }) -> { read_file: (string) -> (string | nil, string | nil) }
local function fake_caps(files)
    --: (path: string) -> (string | nil, string | nil)
    local function read_file(path)
        local src = files[path]
        if src == nil then return nil, path .. ": no such file" end
        return src, nil
    end
    return { read_file = read_file }
end

local B_SRC = [[
--:: Point = { x: number, y: number }
local M = {}
--: (a: number, b: number) -> number
function M.add(a, b)
    return a + b
end
return M
]]

T.describe("v9 cross-module — module resolution seam", function()
    T.it("dot -> slash, then the init.lua fallback; misses are (nil, errmsg)", function()
        local caps = fake_caps({
            ["libx/flat.lua"] = "return 1\n",
            ["libx/pkg/init.lua"] = "return 2\n",
        })
        local r = modules.resolver(caps)
        local flat = r.resolve("libx.flat")
        T.ok(flat ~= nil, "flat file resolves")
        if flat ~= nil then T.eq(flat.path, "libx/flat.lua", "dot -> slash + .lua") end
        local pkg = r.resolve("libx.pkg")
        T.ok(pkg ~= nil, "package resolves through the fallback")
        if pkg ~= nil then T.eq(pkg.path, "libx/pkg/init.lua", "init.lua fallback") end
        local missing, err = r.resolve("libx.nope")
        T.ok(missing == nil, "a miss is data, not a throw")
        T.ok(err ~= nil and err:find("libx/nope.lua", 1, true) ~= nil
            and err:find("libx/nope/init.lua", 1, true) ~= nil,
            "the error names both tried paths: " .. tostring(err))
    end)
end)

T.describe("v9 cross-module — require summaries (A requires B)", function()
    T.it("B's returned record's fields are TYPED in A; wrong args are call-mismatch; absent fields are missing-field", function()
        local caps = fake_caps({
            ["libx/b.lua"] = B_SRC,
            ["libx/a.lua"] = "local m = require(\"libx.b\")\n"
                .. "local ok = m.add(1, 2)\n"
                .. "local bad = m.add(1, true)\n"
                .. "local miss = m.nope\n"
                .. "return ok, bad, miss\n",
        })
        local session = check.session(caps, nil)
        local diags, err = session.check_file("libx/a.lua")
        T.ok(diags ~= nil, "checked: " .. (err or ""))
        if diags ~= nil then
            T.ok(find_diag(diags, "unsupported:cross-module") == nil,
                "the require site RESOLVED (no boundary bucket)")
            T.ok(find_diag(diags, "use-before-narrow") == nil,
                "m is B's record, not unknown")
            local cm = find_diag(diags, "call-mismatch")
            T.ok(cm ~= nil, "cross-module arg mismatch found")
            if cm ~= nil then
                T.eq(cm.line, 3, "at the bad call")
                T.ok(cm.message:find("`true`", 1, true) ~= nil,
                    "names the offending argument: " .. cm.message)
            end
            local mf = find_diag(diags, "missing-field")
            T.ok(mf ~= nil, "absent field on B's record found")
            if mf ~= nil then T.eq(mf.line, 4, "at the read") end
        end
    end)

    T.it("requiring a package resolves through init.lua", function()
        local caps = fake_caps({
            ["libx/pkg/init.lua"] = B_SRC,
            ["libx/a.lua"] = "local m = require(\"libx.pkg\")\n"
                .. "local bad = m.add(true, 2)\nreturn bad\n",
        })
        local session = check.session(caps, nil)
        local diags = session.check_file("libx/a.lua")
        T.ok(diags ~= nil, "checked")
        if diags ~= nil then
            T.ok(find_diag(diags, "unsupported:cross-module") == nil, "resolved")
            T.ok(find_diag(diags, "call-mismatch") ~= nil, "typed through the fallback")
        end
    end)

    T.it("a missing module is the honest unsupported:cross-module diag; the result reads unknown", function()
        local caps = fake_caps({
            ["libx/a.lua"] = "local m = require(\"libx.gone\")\n"
                .. "local x = m.f()\nreturn x\n",
        })
        local session = check.session(caps, nil)
        local diags = session.check_file("libx/a.lua")
        T.ok(diags ~= nil, "checked")
        if diags ~= nil then
            local d = find_diag(diags, "unsupported:cross-module")
            T.ok(d ~= nil, "named boundary")
            if d ~= nil then
                T.ok(d.message:find("libx.gone", 1, true) ~= nil, "names the module: " .. d.message)
            end
            T.ok(find_diag(diags, "use-before-narrow") ~= nil, "the result is honest unknown")
        end
    end)

    T.it("a DYNAMIC module name is the honest boundary (no literal, no summary)", function()
        local caps = fake_caps({
            ["libx/a.lua"] = "local name = \"libx.b\"\nlocal m = require(name)\nreturn m\n",
            ["libx/b.lua"] = B_SRC,
        })
        local session = check.session(caps, nil)
        local diags = session.check_file("libx/a.lua")
        T.ok(diags ~= nil, "checked")
        if diags ~= nil then
            local d = find_diag(diags, "unsupported:cross-module")
            T.ok(d ~= nil and d.message:find("dynamic", 1, true) ~= nil,
                "named as the dynamic-require boundary")
        end
    end)

    T.it("without a session (no deps injected), require stays the honest boundary", function()
        local diags = check.check_source(
            "local m = require(\"libx.b\")\nreturn m\n", "a.lua", nil)
        T.ok(diags ~= nil, "checked")
        if diags ~= nil then
            T.ok(find_diag(diags, "unsupported:cross-module") ~= nil,
                "single-file checks keep the pre-summary behavior")
        end
    end)

    T.it("`require(42)` is a call-mismatch — the declared `module: string` pin checks the argument", function()
        local caps = fake_caps({ ["libx/a.lua"] = "local m = require(42)\nreturn m\n" })
        local session = check.session(caps, nil)
        local diags = session.check_file("libx/a.lua")
        T.ok(diags ~= nil, "checked")
        if diags ~= nil then
            T.ok(find_diag(diags, "call-mismatch") ~= nil,
                "the ordinary call machinery checked the argument")
        end
    end)
end)

T.describe("v9 cross-module — cycles (never a hang)", function()
    T.it("a self-require is cut with unsupported:cross-module-cycle", function()
        local caps = fake_caps({
            ["libx/a.lua"] = "local me = require(\"libx.a\")\nreturn me\n",
        })
        local session = check.session(caps, nil)
        local diags = session.check_file("libx/a.lua")
        T.ok(diags ~= nil, "checked (terminated)")
        if diags ~= nil then
            T.ok(find_diag(diags, "unsupported:cross-module-cycle") ~= nil,
                "the named cycle cut")
        end
    end)

    T.it("a mutual A <-> B cycle terminates; the participant that re-enters sees the cut", function()
        local caps = fake_caps({
            ["libx/a.lua"] = "local b = require(\"libx.b\")\nlocal M = {}\nM.b = b\nreturn M\n",
            ["libx/b.lua"] = "local a = require(\"libx.a\")\nlocal M = {}\nM.a = a\nreturn M\n",
        })
        local session = check.session(caps, nil)
        local adiags = session.check_file("libx/a.lua")
        local bdiags = session.check_file("libx/b.lua")
        T.ok(adiags ~= nil and bdiags ~= nil, "both checked (terminated)")
        if adiags ~= nil and bdiags ~= nil then
            -- checking A computes B mid-flight; B's require of A hits the
            -- in-progress set — the cycle diag lands in B (cached, so B's
            -- later direct check returns the same evidence).
            local cut = find_diag(bdiags, "unsupported:cross-module-cycle")
            T.ok(cut ~= nil, "the re-entering participant carries the cut diag")
            T.ok(find_diag(adiags, "unsupported:cross-module") == nil,
                "A's require of B resolved (B's summary is honest-wider, not absent)")
        end
    end)
end)

T.describe("v9 cross-module — `--:: require` type-only alias imports", function()
    T.it("an imported alias resolves (no annotation-unknown-name); a mismatch proves it carries the real type", function()
        local caps = fake_caps({
            ["libx/b.lua"] = B_SRC,
            ["libx/a.lua"] = "--:: require \"libx.b\"\n"
                .. "local p = { x = 1, y = 2 } --: Point\n"
                .. "local q = 3 --: Point\n"
                .. "return p, q\n",
        })
        local session = check.session(caps, nil)
        local diags = session.check_file("libx/a.lua")
        T.ok(diags ~= nil, "checked")
        if diags ~= nil then
            T.ok(find_diag(diags, "unsupported:annotation-unknown-name") == nil,
                "Point resolved through the import")
            local am = find_diag(diags, "annotation-mismatch")
            T.ok(am ~= nil, "the imported alias is the REAL record type")
            if am ~= nil then T.eq(am.line, 3, "the number, not the record") end
        end
    end)

    T.it("own aliases SHADOW imported ones", function()
        local caps = fake_caps({
            ["libx/b.lua"] = B_SRC,
            ["libx/a.lua"] = "--:: require \"libx.b\"\n"
                .. "--:: Point = number\n"
                .. "local q = 3 --: Point\n"
                .. "return q\n",
        })
        local session = check.session(caps, nil)
        local diags = session.check_file("libx/a.lua")
        T.ok(diags ~= nil, "checked")
        if diags ~= nil then
            T.ok(find_diag(diags, "annotation-mismatch") == nil,
                "the local alias (number) won; 3 satisfies it")
        end
    end)

    T.it("an unresolvable import is the honest boundary; the name stays the unknown-name bucket", function()
        local caps = fake_caps({
            ["libx/a.lua"] = "--:: require \"libx.gone\"\n"
                .. "local q = 3 --: Point\n"
                .. "return q\n",
        })
        local session = check.session(caps, nil)
        local diags = session.check_file("libx/a.lua")
        T.ok(diags ~= nil, "checked")
        if diags ~= nil then
            T.ok(find_diag(diags, "unsupported:cross-module") ~= nil, "import miss named")
            T.ok(find_diag(diags, "unsupported:annotation-unknown-name") ~= nil,
                "Point honestly unresolved")
        end
    end)
end)

T.describe("v9 cross-module — declaration-driven (no name-keying)", function()
    T.it("a per-file declared NON-require name with `$Require<1>` gets the same machinery", function()
        local caps = fake_caps({
            ["libx/b.lua"] = B_SRC,
            ["libx/a.lua"] = "--:: declare load_mod = (m: string) -> $Require<1>\n"
                .. "local m = load_mod(\"libx.b\")\n"
                .. "local bad = m.add(1, true)\n"
                .. "return bad\n",
        })
        local session = check.session(caps, nil)
        local diags = session.check_file("libx/a.lua")
        T.ok(diags ~= nil, "checked")
        if diags ~= nil then
            T.ok(find_diag(diags, "call-mismatch") ~= nil,
                "the summary flowed from the DECLARATION, not the name 'require'")
        end
    end)

    T.it("a local shadowing `require` does NOT engage the machinery (no declared arrow)", function()
        local caps = fake_caps({
            ["libx/b.lua"] = B_SRC,
            ["libx/a.lua"] = "local require = function(x) return x end\n"
                .. "local m = require(\"libx.b\")\n"
                .. "return m\n",
        })
        local session = check.session(caps, nil)
        local diags = session.check_file("libx/a.lua")
        T.ok(diags ~= nil, "checked")
        if diags ~= nil then
            T.ok(find_diag(diags, "unsupported:cross-module") == nil
                and find_diag(diags, "call-mismatch") == nil,
                "the shadowing local is an ordinary call")
        end
    end)
end)

-- Canonical deep snapshot for immutability comparison (sorted keys).
--: (unknown) -> string
local function snap(x)
    if type(x) ~= "table" then return tostring(x) end
    local t = x --: { [string]: unknown }
    local keys = {} --: { [integer]: string }
    for k in pairs(t) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local parts = {} --: { [integer]: string }
    for i = 1, #keys do
        parts[#parts + 1] = keys[i] .. "=" .. snap(t[keys[i]])
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

T.describe("v9 cross-module — summary immutability + the policy dial", function()
    T.it("checking importers never mutates B's cached summary", function()
        local caps = fake_caps({
            ["libx/b.lua"] = B_SRC,
            ["libx/a.lua"] = "--:: require \"libx.b\"\n"
                .. "local m = require(\"libx.b\")\nreturn m\n",
            ["libx/c.lua"] = "--:: require \"libx.b\"\n"
                .. "--:: Point = number\n"
                .. "local m = require(\"libx.b\")\nlocal q = m.add(1, 2)\nreturn q\n",
        })
        local session = check.session(caps, nil)
        local bsum = session.summary("libx.b")
        T.ok(bsum ~= nil, "B's summary computed")
        local before = snap(bsum)
        session.check_file("libx/a.lua")
        session.check_file("libx/c.lua")
        local after = snap(session.summary("libx.b"))
        T.eq(after, before, "byte-identical snapshot after two importers (one with a conflicting own alias)")
    end)

    T.it("unannotated-module-boundary: off by default, fires when dialed, silent for annotated modules", function()
        local files = {
            ["libx/b.lua"] = B_SRC, -- returns an UNANNOTATED local
            ["libx/ann.lua"] = "local M = { add = 1 } --: { add: number }\nreturn M\n",
            ["libx/a.lua"] = "local m = require(\"libx.b\")\nreturn m\n",
            ["libx/a2.lua"] = "local m = require(\"libx.ann\")\nreturn m\n",
        }
        local caps = fake_caps(files)
        -- default: allowed (off) — the diag never surfaces.
        local s1 = check.session(caps, nil)
        local d1 = s1.check_file("libx/a.lua")
        T.ok(d1 ~= nil and find_diag(d1, "unannotated-module-boundary") == nil,
            "default policy admits inferred summaries silently")
        -- dialed up: the require of the INFERRED module surfaces.
        local strict = check.default_policy()
        strict["unannotated-module-boundary"] = "warn"
        local s2 = check.session(caps, { policy = strict, mode = nil, deps = nil })
        local d2 = s2.check_file("libx/a.lua")
        T.ok(d2 ~= nil, "checked")
        if d2 ~= nil then
            local d = find_diag(d2, "unannotated-module-boundary")
            T.ok(d ~= nil, "the dial is real")
            if d ~= nil then
                T.eq(d.severity, "warn", "at the dialed severity")
                T.ok(d.message:find("libx.b", 1, true) ~= nil, "names the module")
            end
        end
        -- an ANNOTATION-PINNED module return crosses silently even dialed up.
        local d3 = s2.check_file("libx/a2.lua")
        T.ok(d3 ~= nil and find_diag(d3, "unannotated-module-boundary") == nil,
            "an annotated module boundary is pinned, not contextual — no diag")
    end)
end)
