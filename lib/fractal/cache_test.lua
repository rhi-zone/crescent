-- lib/fractal/cache_test.lua
-- Tests for lib/fractal/cache.lua (the IR fingerprinting primitives).

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T     = require("lib.test.assert")
local cache = require("lib.fractal.cache")

local ENTRY = "/repo/src/api.ts"

T.describe("lib.fractal.cache", function()

  T.describe("compute_leaf_fingerprint", function()

    T.it("returns a hex sha256", function()
      local fp = cache.compute_leaf_fingerprint(ENTRY, { input = { kind = "string" } })
      T.eq(type(fp), "string")
      T.eq(#fp, 64)
      T.ok(fp:match("^%x+$") ~= nil, "fingerprint is hex")
    end)

    T.it("is stable across repeated calls on equal input", function()
      local a = cache.compute_leaf_fingerprint(ENTRY, { input = { kind = "string" }, output = { kind = "number" } })
      local b = cache.compute_leaf_fingerprint(ENTRY, { input = { kind = "string" }, output = { kind = "number" } })
      T.eq(a, b)
    end)

    T.it("does not depend on table construction order", function()
      -- The determinism requirement: a map's key order must not reach the
      -- hash, since LuaJIT's pairs() order is not stable per process.
      local a = cache.compute_leaf_fingerprint(ENTRY, { alpha = 1, beta = 2, gamma = 3 })
      local b = cache.compute_leaf_fingerprint(ENTRY, { gamma = 3, beta = 2, alpha = 1 })
      T.eq(a, b)
    end)

    T.it("many-key maps hash identically regardless of insertion order", function()
      local forward = {}
      local backward = {}
      for i = 1, 40 do forward["k" .. i] = i end
      for i = 40, 1, -1 do backward["k" .. i] = i end
      T.eq(cache.compute_leaf_fingerprint(ENTRY, forward),
           cache.compute_leaf_fingerprint(ENTRY, backward))
    end)

    T.it("changes when a value changes", function()
      local a = cache.compute_leaf_fingerprint(ENTRY, { kind = "string" })
      local b = cache.compute_leaf_fingerprint(ENTRY, { kind = "number" })
      T.ok(a ~= b, "a changed IR must change the fingerprint")
    end)

    T.it("changes when a key is added", function()
      local a = cache.compute_leaf_fingerprint(ENTRY, { kind = "object" })
      local b = cache.compute_leaf_fingerprint(ENTRY, { kind = "object", optional = true })
      T.ok(a ~= b, "an added field must change the fingerprint")
    end)

    T.it("array order IS significant", function()
      local a = cache.compute_leaf_fingerprint(ENTRY, { fields = { "a", "b" } })
      local b = cache.compute_leaf_fingerprint(ENTRY, { fields = { "b", "a" } })
      T.ok(a ~= b, "list order is data, not incidental ordering")
    end)

    T.it("distinguishes a string from a number that prints the same", function()
      local a = cache.compute_leaf_fingerprint(ENTRY, { v = "1" })
      local b = cache.compute_leaf_fingerprint(ENTRY, { v = 1 })
      T.ok(a ~= b, "type must reach the hash")
    end)

    T.it("distinguishes nested structure from a flat key", function()
      local a = cache.compute_leaf_fingerprint(ENTRY, { a = { b = 1 } })
      local b = cache.compute_leaf_fingerprint(ENTRY, { a = "b:1" })
      T.ok(a ~= b, "structure must reach the hash")
    end)

    T.it("handles booleans and nested lists", function()
      local fp = cache.compute_leaf_fingerprint(ENTRY, {
        optional = true,
        variants = { { kind = "string" }, { kind = "number" } },
      })
      T.eq(#(fp or ""), 64)
    end)

    -- ── declarationFile relativization ──────────────────────────────────

    T.it("relativizes a declarationFile against the entry's directory", function()
      local a = cache.compute_leaf_fingerprint("/repo/src/api.ts",
        { declarationFile = "/repo/src/types.ts" })
      local b = cache.compute_leaf_fingerprint("/elsewhere/src/api.ts",
        { declarationFile = "/elsewhere/src/types.ts" })
      T.eq(a, b) -- same repo, two checkout locations
    end)

    T.it("a genuinely different declarationFile still differs", function()
      local a = cache.compute_leaf_fingerprint(ENTRY, { declarationFile = "/repo/src/types.ts" })
      local b = cache.compute_leaf_fingerprint(ENTRY, { declarationFile = "/repo/src/other.ts" })
      T.ok(a ~= b, "a different declaring file must change the fingerprint")
    end)

    T.it("relativizes a declarationFile at any nesting depth", function()
      local a = cache.compute_leaf_fingerprint("/repo/src/api.ts",
        { input = { meta = { declarationFile = "/repo/src/types.ts" } } })
      local b = cache.compute_leaf_fingerprint("/elsewhere/src/api.ts",
        { input = { meta = { declarationFile = "/elsewhere/src/types.ts" } } })
      T.eq(a, b)
    end)

    T.it("relativizes a declarationFile inside a list element", function()
      local a = cache.compute_leaf_fingerprint("/repo/src/api.ts",
        { defs = { { declarationFile = "/repo/src/types.ts" } } })
      local b = cache.compute_leaf_fingerprint("/elsewhere/src/api.ts",
        { defs = { { declarationFile = "/elsewhere/src/types.ts" } } })
      T.eq(a, b)
    end)

    T.it("a non-string declarationFile is left alone", function()
      local fp = cache.compute_leaf_fingerprint(ENTRY, { declarationFile = 42 })
      T.eq(#(fp or ""), 64)
    end)

    -- ── input-domain errors ─────────────────────────────────────────────

    T.it("rejects a relative entry_file rather than reading the cwd", function()
      local fp, err = cache.compute_leaf_fingerprint("src/api.ts", { a = 1 })
      T.eq(fp, nil)
      T.ok(err:find("absolute", 1, true) ~= nil, "error names the requirement")
    end)

    T.it("rejects a value outside the JSON-shaped domain", function()
      local fp, err = cache.compute_leaf_fingerprint(ENTRY, { fn = function() return 1 end })
      T.eq(fp, nil)
      T.ok(err:find("function", 1, true) ~= nil, "error names the offending type")
    end)

    T.it("rejects a map carrying a non-string key", function()
      local fp, err = cache.compute_leaf_fingerprint(ENTRY, { [2] = "gap" })
      T.eq(fp, nil)
      T.ok(err ~= nil, "expected an error message")
    end)

  end)

  T.describe("canonicalize_for_fingerprint", function()

    T.it("leaves a scalar unchanged", function()
      T.eq(cache.canonicalize_for_fingerprint("x", "/repo"), "x")
      T.eq(cache.canonicalize_for_fingerprint(7, "/repo"), 7)
    end)

    T.it("rewrites declarationFile and copies rather than mutating", function()
      local input = { declarationFile = "/repo/src/types.ts", kind = "object" }
      local out = cache.canonicalize_for_fingerprint(input, "/repo/src")
      T.eq(out.declarationFile, "types.ts")
      T.eq(out.kind, "object")
      T.eq(input.declarationFile, "/repo/src/types.ts") -- untouched
    end)

    T.it("preserves list order", function()
      local out = cache.canonicalize_for_fingerprint({ "a", "b", "c" }, "/repo")
      T.eq(out[1], "a")
      T.eq(out[3], "c")
    end)

  end)

  T.describe("compute_bundle_fingerprint", function()

    T.it("returns a hex sha256", function()
      local fp = cache.compute_bundle_fingerprint({ ["a.b"] = "h1", ["c.d"] = "h2" })
      T.eq(#fp, 64)
    end)

    T.it("does not depend on leaf-key encounter order", function()
      local a = cache.compute_bundle_fingerprint({ z = "h1", a = "h2", m = "h3" })
      local b = cache.compute_bundle_fingerprint({ a = "h2", m = "h3", z = "h1" })
      T.eq(a, b)
    end)

    T.it("changes when a leaf's fingerprint changes", function()
      local a = cache.compute_bundle_fingerprint({ x = "h1" })
      local b = cache.compute_bundle_fingerprint({ x = "h2" })
      T.ok(a ~= b, "a moved leaf must move the bundle")
    end)

    T.it("changes when a leaf is added", function()
      local a = cache.compute_bundle_fingerprint({ x = "h1" })
      local b = cache.compute_bundle_fingerprint({ x = "h1", y = "h2" })
      T.ok(a ~= b, "an added leaf must move the bundle")
    end)

    T.it("an empty bundle has a stable fingerprint", function()
      T.eq(cache.compute_bundle_fingerprint({}), cache.compute_bundle_fingerprint({}))
    end)

  end)

  T.describe("compute_def_names_fingerprint", function()

    T.it("returns a hex sha256", function()
      T.eq(#cache.compute_def_names_fingerprint({ "Book", "Review" }), 64)
    end)

    T.it("does not depend on the order given", function()
      local a = cache.compute_def_names_fingerprint({ "Review", "Book", "Author" })
      local b = cache.compute_def_names_fingerprint({ "Author", "Book", "Review" })
      T.eq(a, b)
    end)

    T.it("changes when a name is added", function()
      local a = cache.compute_def_names_fingerprint({ "Book" })
      local b = cache.compute_def_names_fingerprint({ "Book", "Review" })
      T.ok(a ~= b, "the set of callable def names must reach the hash")
    end)

    T.it("an empty set has a stable fingerprint", function()
      T.eq(cache.compute_def_names_fingerprint({}), cache.compute_def_names_fingerprint({}))
    end)

  end)

end)
