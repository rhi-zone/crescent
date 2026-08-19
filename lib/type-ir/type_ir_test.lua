-- lib/type-ir/type_ir_test.lua
-- Tests for lib/type-ir/init.lua: the parent-kind registry and the
-- TypeRef data model (shape constructors, documents, traversal).

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T        = require("lib.test.assert")
local type_ref = require("lib.type-ir")
local null     = require("lib.null")

-- The registry is module-level shared state (mirrors fractal's own
-- module-level `parents` map). Each test group uses its own kind-name
-- prefix so tests don't interfere with each other.

T.describe("lib.type-ir", function()

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

  T.describe("built-in lattice seeding", function()

    T.it("integer's parent is number", function()
      local chain = type_ref.ancestors("integer")
      T.eq(#chain, 1)
      T.eq(chain[1], "number")
    end)

    T.it("a projector with only a function handler serves method through it", function()
      T.eq(type_ref.resolve("method", { ["function"] = "fn-handler" }), "fn-handler")
    end)

    T.it("kinds that deliberately have no parent expose no fallback", function()
      -- instance/interface must NOT fall back to object, and stream/page must
      -- NOT fall back to array: a projector that cannot express them has to
      -- degrade explicitly rather than silently render the wrong thing.
      local handlers = { object = "obj-handler", array = "arr-handler" }
      T.eq(type_ref.resolve("instance", handlers), nil)
      T.eq(type_ref.resolve("interface", handlers), nil)
      T.eq(type_ref.resolve("stream", handlers), nil)
      T.eq(type_ref.resolve("page", handlers), nil)
    end)

  end)

  T.describe("types", function()

    T.it("payload-free kinds are shapes carrying only their kind", function()
      T.eq(type_ref.types.boolean.kind, "boolean")
      T.eq(type_ref.types.number.kind, "number")
      T.eq(type_ref.types.integer.kind, "integer")
      T.eq(type_ref.types.string.kind, "string")
      T.eq(type_ref.types.null.kind, "null")
      T.eq(type_ref.types.void.kind, "void")
      T.eq(type_ref.types.unknown.kind, "unknown")
      T.eq(type_ref.types.never.kind, "never")
    end)

    T.it("a payload-free kind is one shared shape, not a fresh table per use", function()
      T.eq(type_ref.types.string, type_ref.types.string)
    end)

    T.it("payload-carrying kinds carry their payload", function()
      local s = type_ref.type_ref_from_shape(type_ref.types.string)
      local n = type_ref.type_ref_from_shape(type_ref.types.number)

      T.eq(type_ref.types.object({ a = s }).fields.a, s)
      T.eq(type_ref.types.array(s).element, s)
      T.eq(type_ref.types.stream(s).element, s)
      T.eq(type_ref.types.tuple({ s, n }).elements[2], n)
      T.eq(type_ref.types.union({ s, n }).variants[1], s)
      T.eq(type_ref.types.intersection({ s, n }).members[1], s)
      T.eq(type_ref.types.enum({ "a", "b" }).members[2], "b")
      T.eq(type_ref.types.ref("Node").target, "Node")
      T.eq(type_ref.types.interface({ go = s }).methods.go, s)

      local m = type_ref.types.map(s, n)
      T.eq(m.key, s)
      T.eq(m.value, n)

      local p = type_ref.types.page(s, "cursor")
      T.eq(p.element, s)
      T.eq(p.style, "cursor")

      local inst = type_ref.types.instance("User", "/src/user.ts")
      T.eq(inst.className, "User")
      T.eq(inst.declarationFile, "/src/user.ts")
    end)

    T.it("function_ and method omit thisType when it is absent", function()
      local ret = type_ref.type_ref_from_shape(type_ref.types.string)
      local this = type_ref.type_ref_from_shape(type_ref.types.number)

      local free = type_ref.types.function_({}, ret)
      T.eq(free.kind, "function")
      T.eq(free.returnType, ret)
      T.eq(free.thisType, nil)

      local bound = type_ref.types.function_({}, ret, this)
      T.eq(bound.thisType, this)

      local meth = type_ref.types.method({}, ret)
      T.eq(meth.kind, "method")
      T.eq(meth.thisType, nil)
      T.eq(type_ref.types.method({}, ret, this).thisType, this)
    end)

    T.it("a null literal is the shared sentinel, which is not nil", function()
      local shape = type_ref.types.literal(null.null)
      T.eq(shape.kind, "literal")
      T.eq(shape.value, null.null)
      T.neq(shape.value, nil)
      -- The module re-exports the SAME sentinel table; identity is the test.
      T.eq(type_ref.null, null.null)
    end)

    T.it("non-null literals carry their value unchanged", function()
      T.eq(type_ref.types.literal("hi").value, "hi")
      T.eq(type_ref.types.literal(42).value, 42)
      T.eq(type_ref.types.literal(false).value, false)
    end)

  end)

  T.describe("type_ref_from_shape", function()

    T.it("meta defaults to an empty bag", function()
      local ref = type_ref.type_ref_from_shape(type_ref.types.string)
      T.eq(ref.shape, type_ref.types.string)
      T.eq(next(ref.meta), nil)
    end)

    T.it("a supplied meta bag is carried through as-is", function()
      local meta = { optional = true }
      T.eq(type_ref.type_ref_from_shape(type_ref.types.string, meta).meta, meta)
    end)

  end)

  T.describe("child_type_refs", function()

    local s = type_ref.type_ref_from_shape(type_ref.types.string)
    local n = type_ref.type_ref_from_shape(type_ref.types.number)

    T.it("leaf kinds have no children", function()
      T.eq(#type_ref.child_type_refs(type_ref.types.string), 0)
      T.eq(#type_ref.child_type_refs(type_ref.types.enum({ "a" })), 0)
      T.eq(#type_ref.child_type_refs(type_ref.types.literal("x")), 0)
      T.eq(#type_ref.child_type_refs(type_ref.types.instance("U", "/u.ts")), 0)
    end)

    T.it("a ref has no children, which is what stops the walk cycling", function()
      T.eq(#type_ref.child_type_refs(type_ref.types.ref("Node")), 0)
    end)

    T.it("a bare TypeRef field is a child", function()
      local kids = type_ref.child_type_refs(type_ref.types.array(s))
      T.eq(#kids, 1)
      T.eq(kids[1], s)
    end)

    T.it("both of a map's TypeRef fields are children, key before value", function()
      local kids = type_ref.child_type_refs(type_ref.types.map(s, n))
      T.eq(#kids, 2)
      T.eq(kids[1], s)
      T.eq(kids[2], n)
    end)

    T.it("a list of TypeRefs contributes each element in order", function()
      local kids = type_ref.child_type_refs(type_ref.types.tuple({ s, n }))
      T.eq(#kids, 2)
      T.eq(kids[1], s)
      T.eq(kids[2], n)
    end)

    T.it("a record of TypeRefs contributes each value", function()
      local kids = type_ref.child_type_refs(type_ref.types.object({ a = s, b = n }))
      T.eq(#kids, 2)
      -- Byte order of the field names, so `a` before `b`.
      T.eq(kids[1], s)
      T.eq(kids[2], n)
    end)

    T.it("a param list contributes each param's type, not the param entry", function()
      local ret = type_ref.type_ref_from_shape(type_ref.types.void)
      local this = type_ref.type_ref_from_shape(type_ref.types.integer)
      local shape = type_ref.types.function_({ { name = "a", type = s }, { name = "b", type = n } }, ret, this)
      local kids = type_ref.child_type_refs(shape)
      -- params, then returnType, then thisType — the TS field order, which
      -- byte-ordered keys reproduce exactly for this kind.
      T.eq(#kids, 4)
      T.eq(kids[1], s)
      T.eq(kids[2], n)
      T.eq(kids[3], ret)
      T.eq(kids[4], this)
    end)

    T.it("child order is stable across repeated calls", function()
      local shape = type_ref.types.object({ z = s, a = n, m = s })
      local first = type_ref.child_type_refs(shape)
      for _ = 1, 20 do
        local again = type_ref.child_type_refs(shape)
        T.eq(#again, #first)
        for i = 1, #first do T.eq(again[i], first[i]) end
      end
    end)

    T.it("an extension kind's TypeRef fields are found without registering anything", function()
      -- The whole point of the generic walk: this file has never heard of
      -- `timestamped`, and still finds its children.
      local shape = { kind = "timestamped", inner = s, at = "2026-01-01" } --[[: TypeShape]]
      local kids = type_ref.child_type_refs(shape)
      T.eq(#kids, 1)
      T.eq(kids[1], s)
    end)

  end)

  T.describe("node_count", function()

    local s = type_ref.type_ref_from_shape(type_ref.types.string)

    T.it("a leaf counts one", function()
      T.eq(type_ref.node_count(s), 1)
    end)

    T.it("counts the node plus every descendant", function()
      local inner = type_ref.type_ref_from_shape(type_ref.types.array(s))
      local outer = type_ref.type_ref_from_shape(type_ref.types.object({ a = inner, b = s }))
      -- outer + inner + inner's element + outer's b
      T.eq(type_ref.node_count(outer), 4)
    end)

    T.it("does not expand through a ref", function()
      local ref = type_ref.type_ref_from_shape(type_ref.types.ref("Node"))
      T.eq(type_ref.node_count(ref), 1)
    end)

  end)

  T.describe("type_ref_document", function()

    T.it("defs default to empty", function()
      local root = type_ref.type_ref_from_shape(type_ref.types.string)
      local doc = type_ref.type_ref_document(root)
      T.eq(doc.root, root)
      T.eq(next(doc.defs), nil)
    end)

    T.it("supplied defs are carried through", function()
      local root = type_ref.type_ref_from_shape(type_ref.types.ref("Node"))
      local node = type_ref.type_ref_from_shape(type_ref.types.string)
      T.eq(type_ref.type_ref_document(root, { Node = node }).defs.Node, node)
    end)

  end)

  T.describe("resolve_ref", function()

    T.it("a non-ref TypeRef is returned unchanged", function()
      local s = type_ref.type_ref_from_shape(type_ref.types.string)
      local doc = type_ref.type_ref_document(s)
      T.eq(type_ref.resolve_ref(doc, s), s)
    end)

    T.it("a ref resolves to the def it targets", function()
      local node = type_ref.type_ref_from_shape(type_ref.types.string)
      local ref = type_ref.type_ref_from_shape(type_ref.types.ref("Node"))
      local doc = type_ref.type_ref_document(ref, { Node = node })
      T.eq(type_ref.resolve_ref(doc, ref), node)
    end)

    T.it("an unresolved target returns (nil, errmsg) rather than throwing", function()
      local ref = type_ref.type_ref_from_shape(type_ref.types.ref("Missing"))
      local doc = type_ref.type_ref_document(ref)
      local resolved, err = type_ref.resolve_ref(doc, ref)
      T.eq(resolved, nil)
      T.ok(err)
      T.ok(err and err:find("Missing", 1, true))
    end)

  end)

  T.describe("walk_type_ref", function()

    T.it("visits every node in the root tree, pre-order", function()
      local s = type_ref.type_ref_from_shape(type_ref.types.string)
      local inner = type_ref.type_ref_from_shape(type_ref.types.array(s))
      local root = type_ref.type_ref_from_shape(type_ref.types.object({ a = inner }))

      local seen = {}
      type_ref.walk_type_ref(type_ref.type_ref_document(root), function(node)
        seen[#seen + 1] = node
      end)

      T.eq(#seen, 3)
      T.eq(seen[1], root)   -- parent before child
      T.eq(seen[2], inner)
      T.eq(seen[3], s)
    end)

    T.it("ancestors is the path down to but not including the node", function()
      local s = type_ref.type_ref_from_shape(type_ref.types.string)
      local inner = type_ref.type_ref_from_shape(type_ref.types.array(s))
      local root = type_ref.type_ref_from_shape(type_ref.types.object({ a = inner }))

      local depths = {}
      type_ref.walk_type_ref(type_ref.type_ref_document(root), function(node, ctx)
        depths[#depths + 1] = #ctx.ancestors
        if node == s then
          T.eq(ctx.ancestors[1], root)
          T.eq(ctx.ancestors[2], inner)
        end
      end)

      T.eq(depths[1], 0)
      T.eq(depths[2], 1)
      T.eq(depths[3], 2)
    end)

    T.it("each def is walked as its own root, with an empty ancestors chain", function()
      local a = type_ref.type_ref_from_shape(type_ref.types.string)
      local b = type_ref.type_ref_from_shape(type_ref.types.number)
      local root = type_ref.type_ref_from_shape(type_ref.types.ref("A"))
      local doc = type_ref.type_ref_document(root, { A = a, B = b })

      local seen, depths = {}, {}
      type_ref.walk_type_ref(doc, function(node, ctx)
        seen[#seen + 1] = node
        depths[#depths + 1] = #ctx.ancestors
      end)

      -- root (a ref, so no structural children), then each def by name order.
      T.eq(#seen, 3)
      T.eq(seen[1], root)
      T.eq(seen[2], a)
      T.eq(seen[3], b)
      T.eq(depths[2], 0)
      T.eq(depths[3], 0)
    end)

    T.it("ctx.resolve_ref is bound to the walk's document", function()
      local node = type_ref.type_ref_from_shape(type_ref.types.string)
      local ref = type_ref.type_ref_from_shape(type_ref.types.ref("Node"))
      local root = type_ref.type_ref_from_shape(type_ref.types.array(ref))
      local doc = type_ref.type_ref_document(root, { Node = node })

      local resolved = nil
      type_ref.walk_type_ref(doc, function(n, ctx)
        if n == ref then resolved = ctx.resolve_ref(n) end
      end)
      T.eq(resolved, node)
    end)

    T.it("is_recursion_target spots a ref that leads back to an ancestor", function()
      -- A recursive def: Node = { next = ref("Node") }. Walking the def, the
      -- visitor resolves the ref by hand and asks whether it has come full
      -- circle.
      local ref = type_ref.type_ref_from_shape(type_ref.types.ref("Node"))
      local node = type_ref.type_ref_from_shape(type_ref.types.object({ next = ref }))
      local doc = type_ref.type_ref_document(node, { Node = node })

      local circled = false
      local checked = false
      type_ref.walk_type_ref(doc, function(n, ctx)
        if n == ref then
          checked = true
          local target = ctx.resolve_ref(n)
          if target ~= nil and ctx.is_recursion_target(target) then circled = true end
        end
      end)
      T.ok(checked, "the ref was visited")
      T.ok(circled, "resolving it landed back on an ancestor")
    end)

    T.it("a walk terminates on a recursive document", function()
      -- No structural cycle exists because refs have no children; this test
      -- pins that property down rather than trusting it.
      local ref = type_ref.type_ref_from_shape(type_ref.types.ref("Node"))
      local node = type_ref.type_ref_from_shape(type_ref.types.object({ next = ref }))
      local doc = type_ref.type_ref_document(node, { Node = node })

      local count = 0
      type_ref.walk_type_ref(doc, function()
        count = count + 1
      end)
      -- root: node, ref. Then the def (the same node): node, ref.
      T.eq(count, 4)
    end)

  end)

end)
