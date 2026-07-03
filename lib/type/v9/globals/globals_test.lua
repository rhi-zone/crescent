-- lib/type/v9/globals_test.lua
-- The GLOBAL ENVIRONMENT seam end to end: the stdlib declaration data stays
-- inside the checked grammar (zero buckets — asserted, not hoped); stdlib
-- member access flows real types; undeclared-global fires only for genuinely
-- unknown names; per-file `--:: declare` wires; global writes stay policy
-- diags; `type(x) == "…"` tag guards narrow through the same filter shape
-- as truthy/falsy.

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local globals = require("lib.type.v9.globals")
local lattice = require("lib.type.v9.lattice")
local check = require("lib.type.v9.check")

--:: CDiag = { code: string, severity: string, message: string, line: integer, col: integer }

--: ({ [integer]: CDiag }, string) -> CDiag | nil
local function find_diag(diags, code)
    for i = 1, #diags do
        if diags[i].code == code then return diags[i] end
    end
    return nil
end

--: (string) -> { [integer]: CDiag }
local function run(src)
    local diags, err = check.check_source(src, "t.lua", nil)
    T.ok(diags ~= nil, "checked: " .. (err or ""))
    if diags == nil then return {} end
    return diags
end

T.describe("v9 globals — the stdlib declaration source", function()
    T.it("parses with ZERO problems (buckets/parse failures are checker bugs)", function()
        local env = globals.stdlib()
        for i = 1, #env.problems do
            T.ok(false, "stdlib declaration problem: " .. env.problems[i])
        end
        T.eq(#env.problems, 0, "the data file stays inside the checked grammar")
    end)

    T.it("declares the LuaJIT 5.1 surface (and interns: same table every call)", function()
        local env = globals.stdlib()
        local expected = {
            "print", "tostring", "tonumber", "type", "pairs", "ipairs", "pcall",
            "error", "assert", "setmetatable", "select", "unpack", "require",
            "next", "rawget", "rawset", "string", "table", "math", "io", "os",
            "bit", "package", "coroutine", "debug", "jit",
        }
        for i = 1, #expected do
            T.ok(env.globals[expected[i]] ~= nil, "declares " .. expected[i])
        end
        T.eq(env.globals["ffi"], nil, "ffi is NOT a global (it arrives via require)")
        T.ok(globals.stdlib() == env, "memoized: parsed once per process")
        T.ok(globals.lookup("string") == env.globals["string"], "lookup returns the shared At")
    end)

    T.it("atom-metatable `__index` wiring is DATA and its tables are declared", function()
        -- the atom_index map is the whole linkage: every wired atom names a
        -- declared global table (the atom's metatable `__index`); consumers
        -- iterate the map — no per-atom branch anywhere in lowering/check.
        local n = 0
        for atom, gname in pairs(globals.atom_index) do
            T.ok(type(atom) == "string" and type(gname) == "string",
                "atom -> global-name pairs")
            T.ok(globals.lookup(gname) ~= nil,
                "wired table `" .. gname .. "` (for atom `" .. atom .. "`) is declared")
            n = n + 1
        end
        T.eq(globals.atom_index["string"], "string",
            "LuaJIT boot wiring: string's `__index` is the string library")
        T.eq(n, 1, "exactly the wirings LuaJIT establishes at boot (5.1: string)")
    end)
end)

T.describe("v9 globals — stdlib access typed end to end", function()
    T.it("string.format/math.floor round-trip at their declared types", function()
        local diags = run("local s = string.format(\"%d\", 1)\n"
            .. "local t = s .. \"x\"\n"
            .. "local n = math.floor(1.5) + 1\n"
            .. "local p = package.path .. \";x\"\n"
            .. "return t, n, p\n")
        T.eq(#diags, 0, "typed stdlib reads check clean")
    end)

    T.it("stdlib misuse is a REAL finding: wrong-arg-type to a stdlib fn", function()
        local diags = run("local n = math.floor(\"nope\")\nreturn n\n")
        local d = find_diag(diags, "call-mismatch")
        T.ok(d ~= nil, "string into (x: number) flagged")
        if d ~= nil then
            T.ok(d.message:find("number", 1, true) ~= nil, "names the pin: " .. d.message)
        end
        local diags2 = run("local n = string.format(\"%d\", 1) + 1\nreturn n\n")
        T.ok(find_diag(diags2, "op-mismatch") ~= nil,
            "format returns string; string + 1 is op-mismatch")
    end)

    T.it("`...unknown` rest pins are vacuous — no use-before-narrow flood", function()
        local diags = run("--:: declare whatever = unknown\n"
            .. "local x = whatever\nprint(\"a\", 1, x)\nreturn 0\n")
        T.eq(find_diag(diags, "use-before-narrow"), nil,
            "print's rest bound demands nothing")
    end)

    T.it("pcall is the coarse result-open arrow (stated): (boolean, ...)", function()
        local diags = run("local function g() return 1 end\n"
            .. "local ok, v = pcall(g)\nif ok then return v end\nreturn nil\n")
        T.eq(#diags, 0, "boolean first result narrows; the rest is unknown")
        local diags2 = run("local ok = pcall(1)\nreturn ok\n")
        T.ok(find_diag(diags2, "call-mismatch") ~= nil, "pcall(non-function) flagged")
    end)

    T.it("missing stdlib members are missing-field findings", function()
        local diags = run("local x = math.floorr\nreturn x\n")
        T.ok(find_diag(diags, "missing-field") ~= nil, "math.floorr (typo) flagged")
    end)

    T.it("require calls stay the honest cross-module boundary", function()
        local diags = run("local m = require(\"lib.foo\")\nreturn m\n")
        T.ok(find_diag(diags, "unsupported:cross-module") ~= nil, "still the boundary")
        T.eq(find_diag(diags, "undeclared-global"), nil, "require itself is declared")
    end)
end)

T.describe("v9 globals — the undeclared boundary and writes", function()
    T.it("undeclared-global fires ONLY for genuinely unknown names", function()
        local diags = run("local x = totally_unknown_global\nreturn x\n")
        local d = find_diag(diags, "undeclared-global")
        T.ok(d ~= nil, "unknown name flagged")
        local diags2 = run("local a = tostring(1)\nreturn a\n")
        T.eq(find_diag(diags2, "undeclared-global"), nil, "declared names resolve")
    end)

    T.it("global WRITES stay the policy diag, declared or not", function()
        local diags = run("string = 5\nfunction foo() end\nreturn 1\n")
        local count = 0
        for i = 1, #diags do
            if diags[i].code == "global-write" then count = count + 1 end
        end
        T.eq(count, 2, "both the declared (string) and undeclared (foo) writes flagged")
    end)
end)

T.describe("v9 globals — per-file `--:: declare` wiring", function()
    T.it("a file-declared global reads at its declared type, pin-checked at calls", function()
        local diags = run("--:: declare myglob = (x: number) -> string\n"
            .. "local s = myglob(1) .. \"!\"\nreturn s\n")
        T.eq(#diags, 0, "declared arrow flows")
        local diags2 = run("--:: declare myglob = (x: number) -> string\n"
            .. "local s = myglob(\"bad\")\nreturn s\n")
        T.ok(find_diag(diags2, "call-mismatch") ~= nil, "the declare's pin checks arguments")
    end)

    T.it("file declares SHADOW the stdlib declaration", function()
        local diags = run("--:: declare tostring = (x: number) -> number\n"
            .. "local n = tostring(1) + 1\nreturn n\n")
        T.eq(#diags, 0, "the file's tostring returns number here")
    end)

    T.it("an out-of-grammar declare body still DECLARES the name (reads unknown)", function()
        local diags = run("--:: declare weird = $Magic<T>\nlocal x = weird\nreturn x\n")
        T.eq(find_diag(diags, "undeclared-global"), nil, "declared-but-unreadable is not undeclared")
        T.ok(find_diag(diags, "unsupported:annotation-intrinsic") ~= nil,
            "the body's feature is the named bucket")
    end)

    T.it("declares may reference file aliases regardless of position", function()
        local diags = run("--:: declare conf = Conf\n"
            .. "--:: Conf = { host: string, port: number }\n"
            .. "local p = conf.port + 1\nreturn p\n")
        T.eq(#diags, 0, "alias resolved below the declare")
    end)
end)

T.describe("v9 globals — type() tag guards narrow", function()
    T.it("then-branch keeps the tag; the guarded use checks clean", function()
        local diags = run("local function f(x)\n"
            .. "  if type(x) == \"number\" then\n    return x + 1\n  end\n"
            .. "  return 0\nend\nreturn f(1), f(\"s\")\n")
        T.eq(#diags, 0, "x: number | string narrows to number under the guard")
    end)

    T.it("the wrong use inside a LIVE guarded branch still fires", function()
        local diags = run("local function f(x)\n"
            .. "  if type(x) == \"string\" then\n    return x + 1\n  end\n"
            .. "  return 0\nend\nreturn f(\"s\")\n")
        T.ok(find_diag(diags, "op-mismatch") ~= nil, "string + 1 under a string guard")
    end)

    T.it("narrows `unknown` — the guard is how dynamic values enter the discipline", function()
        local diags = run("--:: declare dyn = unknown\nlocal x = dyn\n"
            .. "if type(x) == \"string\" then\n  local y = x .. \"!\"\n  print(y)\nend\nreturn 0\n")
        T.eq(#diags, 0, "unknown narrows to string under the tag guard (no use-before-narrow)")
    end)

    T.it("~= swaps the branches; flipped operand order recognized", function()
        local diags = run("local function f(x)\n"
            .. "  if type(x) ~= \"number\" then\n    return 0\n  else\n    return x + 1\n  end\n"
            .. "end\nreturn f(1), f(\"s\")\n")
        T.eq(find_diag(diags, "parse-error"), nil, "the probe parses")
        T.eq(find_diag(diags, "op-mismatch"), nil, "else-branch keeps number")
        local diags2 = run("--:: declare dyn = unknown\nlocal x = dyn\n"
            .. "if \"table\" == type(x) then\n  local y = x.foo\n  print(y)\nend\nreturn 0\n")
        local d = find_diag(diags2, "use-before-narrow")
        T.ok(d ~= nil and d.message:find("`table`", 1, true) ~= nil,
            "flipped order narrows to the table atom (fields unknown, named as such)")
    end)

    T.it("a local shadowing `type` disables the guard (it is not Lua's type())", function()
        local diags = run("local function type(v) return \"weird\" end\n"
            .. "--:: declare dyn = unknown\nlocal x = dyn\n"
            .. "if type(x) == \"string\" then\n  local y = x .. \"!\"\n  print(y)\nend\nreturn 0\n")
        T.ok(find_diag(diags, "use-before-narrow") ~= nil, "no narrowing through the shadow")
    end)
end)

T.describe("v9 globals — the tag flow ops (lattice level)", function()
    T.it("tag_keep / tag_drop split a union; unknown narrows on keep only", function()
        local ns = lattice.of({ "number", "string" })
        T.eq(lattice.show(lattice.tag_keep(ns, "number")), "number", "keep number")
        T.eq(lattice.show(lattice.tag_drop(ns, "number")), "string", "drop number")
        T.eq(lattice.show(lattice.tag_keep(ns, "table")), "never", "keep of an absent tag is bottom (dead branch)")
        local u = lattice.single("unknown")
        T.eq(lattice.show(lattice.tag_keep(u, "string")), "string", "keep narrows the top")
        T.eq(lattice.show(lattice.tag_drop(u, "string")), "unknown",
            "drop cannot subtract from the top (upper approximation, stated)")
        T.eq(lattice.show(lattice.tag_keep(u, "userdata")), "unknown",
            "atom-less tags keep the top honest")
        T.eq(lattice.show(lattice.tag_keep(ns, "userdata")), "never",
            "atom-less tags on known values are dead branches")
        T.eq(lattice.show(lattice.tag_drop(ns, "userdata")), "number | string",
            "atom-less drops are the identity")
    end)

    T.it("keep/drop respect the rec/fn components", function()
        local rec = lattice.record_of({ x = lattice.single("number") })
        local both = lattice.lattice.join(rec, lattice.single("string")) --: unknown
        T.eq(lattice.show(lattice.tag_keep(both, "table")), "{ x: number }", "keep table keeps the record")
        T.eq(lattice.show(lattice.tag_drop(both, "table")), "string", "drop table drops the record")
    end)
end)
