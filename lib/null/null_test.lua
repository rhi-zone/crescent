-- lib/null/null_test.lua
-- Tests for lib/null: the shared null sentinel.
--
-- There is one behavior to pin down — identity — and one reason the module
-- exists: that every consumer sees the SAME table. Both are tested here.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T    = require("lib.test.assert")
local null = require("lib.null")

T.describe("lib.null", function()

  T.it("the sentinel is a table, and is not nil", function()
    T.eq(type(null.null), "table")
    T.neq(null.null, nil)
  end)

  T.it("requiring the module twice yields the same sentinel", function()
    -- Lua caches modules, so this is really a guard against the module ever
    -- being rewritten to build its sentinel per call.
    T.eq(require("lib.null").null, null.null)
  end)

  T.it("a separately-built empty table is NOT the sentinel", function()
    -- The failure mode the module exists to prevent: a library minting its
    -- own `{}` and expecting it to compare equal to everyone else's.
    T.neq({}, null.null)
  end)

  T.it("the sentinel is truthy, so `if v then` is not a null test", function()
    -- Documented in the module header; asserted so the note stays true.
    T.ok(null.null)
  end)

  T.it("the sentinel is empty", function()
    T.eq(next(null.null), nil)
  end)

  T.describe("consumers share it", function()

    T.it("the pure JSON tier's null is this sentinel", function()
      T.eq(require("lib.format.json.pure").null, null.null)
    end)

    T.it("the selected JSON tier's null is this sentinel", function()
      -- Whichever tier won selection: the tiers must agree, which is the
      -- exact property that failed while each kept a private `{}`.
      T.eq(require("lib.format.json").null, null.null)
    end)

    T.it("fractal's type_ref re-exports this sentinel for null literals", function()
      T.eq(require("lib.type-ir").null, null.null)
    end)

    T.it("lib.json's null is this sentinel", function()
      T.eq(require("lib.json").null, null.null)
    end)

    T.it("lib.jsonschema's null is this sentinel", function()
      T.eq(require("lib.jsonschema").null, null.null)
    end)

    T.it("lib.bson's null is this sentinel", function()
      T.eq(require("lib.bson").null, null.null)
    end)

    T.it("lib.y_crdt.encoding's null is this sentinel", function()
      T.eq(require("lib.y_crdt.encoding").null, null.null)
    end)

  end)

end)
