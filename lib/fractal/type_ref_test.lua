-- lib/fractal/type_ref_test.lua
-- Tests for lib/fractal/type_ref.lua's parent-kind registry.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T        = require("lib.test.assert")
local type_ref = require("lib.fractal.type_ref")

-- The registry is module-level shared state (mirrors fractal's own
-- module-level `parents` map). Each test group uses its own kind-name
-- prefix so tests don't interfere with each other.

T.describe("lib.fractal.type_ref", function()

  T.describe("ancestors", function()

    T.it("a kind with no registered parent has no ancestors", function()
      local chain = type_ref.ancestors("anc_root_kind")
      T.eq(#chain, 0)
    end)

    T.it("a single-level parent yields a one-element chain", function()
      type_ref.register_parent("anc_method", "anc_function")
      local chain = type_ref.ancestors("anc_method")
      T.eq(#chain, 1)
      T.eq(chain[1], "anc_function")
    end)

    T.it("chain is nearest-first, excludes the kind itself, stops at the root", function()
      type_ref.register_parent("anc_c", "anc_b")
      type_ref.register_parent("anc_b", "anc_a")
      -- anc_a has no registered parent: root.
      local chain = type_ref.ancestors("anc_c")
      T.eq(#chain, 2)
      T.eq(chain[1], "anc_b") -- nearest first
      T.eq(chain[2], "anc_a")
      for i = 1, #chain do
        T.neq(chain[i], "anc_c") -- kind itself never included
      end
    end)

    T.it("register_parent(kind, nil) makes a kind a root with no ancestors", function()
      type_ref.register_parent("anc_was_child", "anc_some_parent")
      T.eq(#type_ref.ancestors("anc_was_child"), 1)
      type_ref.register_parent("anc_was_child", nil)
      T.eq(#type_ref.ancestors("anc_was_child"), 0)
    end)

  end)

  T.describe("resolve", function()

    T.it("exact match wins even when ancestors also have a handler", function()
      type_ref.register_parent("res_method", "res_function")
      local handlers = { res_method = "method-handler", res_function = "function-handler" }
      T.eq(type_ref.resolve("res_method", handlers), "method-handler")
    end)

    T.it("no exact match: walks ancestors nearest-first and takes the first hit", function()
      type_ref.register_parent("res_c2", "res_b2")
      type_ref.register_parent("res_b2", "res_a2")
      local handlers = { res_b2 = "b-handler", res_a2 = "a-handler" }
      T.eq(type_ref.resolve("res_c2", handlers), "b-handler")
    end)

    T.it("no exact match, nearest ancestor has no handler: falls through to a further ancestor", function()
      type_ref.register_parent("res_c3", "res_b3")
      type_ref.register_parent("res_b3", "res_a3")
      local handlers = { res_a3 = "a-handler" }
      T.eq(type_ref.resolve("res_c3", handlers), "a-handler")
    end)

    T.it("no handler anywhere up to the root: resolve returns nil", function()
      type_ref.register_parent("res_c4", "res_b4")
      type_ref.register_parent("res_b4", "res_a4")
      -- res_a4 is a root; no handlers table entry for any of c4/b4/a4.
      local handlers = { unrelated_kind = "x" }
      T.eq(type_ref.resolve("res_c4", handlers), nil)
    end)

    T.it("kind with no registered parent and no exact handler: resolve returns nil", function()
      local handlers = { something_else = "x" }
      T.eq(type_ref.resolve("res_isolated_root", handlers), nil)
    end)

  end)

end)
