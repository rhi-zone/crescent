if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local T = require("lib.test.assert")
local id = require("lib.y_crdt.id")
local content = require("lib.y_crdt.content")
local item = require("lib.y_crdt.item")
local struct_store = require("lib.y_crdt.struct_store")
local integrate = require("lib.y_crdt.integrate")

--: (client: integer, clock: integer, text: string) -> unknown
local function mk(client, clock, text)
  return item.new(id.new(client, clock), nil, nil, nil, nil, content.string(text))
end

-- TYPECHECKER WORKAROUND: builds the SharedType/Transaction records as
-- plain table literals matching item.lua/integrate.lua's own local aliases,
-- instead of calling shared_type.new()/transaction.new(). Those modules'
-- own constructors are typed against their own (deliberately loose, `start:
-- unknown` etc.) local SharedType/Transaction aliases -- correct for their
-- own leaf-module scope, which can't reference item.lua's Item type without
-- a require() cycle -- but that means their return values don't structurally
-- match item.lua/integrate.lua's stricter local aliases (`start: Item |
-- nil` etc.) when passed into `item.new`/`integrate.integrate`. Table
-- literals here get checked directly against the stricter expected
-- parameter type at each call site instead. TODO.md tracks unifying this
-- once cross-module recursive-type references are supported.
local function new_parent(type_name)
  return { kind = "shared_type", type_name = type_name, start = nil, map = {}, length = 0, item = nil }
end

local function new_txn(store)
  return { doc = { store = store }, new_items = {}, deleted_items = {} }
end

T.describe("struct_store.add / get / find", function()
  T.it("adds and retrieves an item by id", function()
    local store = struct_store.new()
    local it = mk(1, 0, "hello")
    T.eq(struct_store.add(store, it), true)
    local found = struct_store.find(store, id.new(1, 0))
    T.eq(found, it)
  end)

  T.it("finds an item covering a clock in the middle of its run", function()
    local store = struct_store.new()
    local it = mk(1, 0, "hello")
    struct_store.add(store, it)
    local found = struct_store.find(store, id.new(1, 3))
    T.eq(found, it)
  end)

  T.it("returns (nil, errmsg) for an unknown client", function()
    local store = struct_store.new()
    local found, err = struct_store.find(store, id.new(99, 0))
    T.eq(found, nil)
    T.ok(err ~= nil)
  end)

  T.it("get returns non-item structs too", function()
    local store = struct_store.new()
    local it = mk(1, 0, "hi")
    struct_store.add(store, it)
    local s = struct_store.get(store, id.new(1, 0))
    T.eq(s.kind, "item")
  end)
end)

T.describe("struct_store.get_state / get_state_vector", function()
  T.it("is 0 for an unknown client", function()
    local store = struct_store.new()
    T.eq(struct_store.get_state(store, 1), 0)
  end)

  T.it("is the next expected clock after adding items", function()
    local store = struct_store.new()
    struct_store.add(store, mk(1, 0, "hello"))
    T.eq(struct_store.get_state(store, 1), 5)
    struct_store.add(store, mk(1, 5, "!!"))
    T.eq(struct_store.get_state(store, 1), 7)
  end)

  T.it("covers all known clients", function()
    local store = struct_store.new()
    struct_store.add(store, mk(1, 0, "aa"))
    struct_store.add(store, mk(2, 0, "bbb"))
    local sv = struct_store.get_state_vector(store)
    T.eq(sv[1], 2)
    T.eq(sv[2], 3)
  end)
end)

T.describe("struct_store.get_item_clean_start / get_item_clean_end", function()
  T.it("splits an item so it starts exactly at the requested clock", function()
    local store = struct_store.new()
    struct_store.add(store, mk(1, 0, "hello"))
    local it = struct_store.get_item_clean_start(store, id.new(1, 2))
    T.eq(it.id.clock, 2)
    T.eq(it.content.str, "llo")
  end)

  T.it("splits an item so it ends exactly at the requested clock", function()
    local store = struct_store.new()
    struct_store.add(store, mk(1, 0, "hello"))
    local it = struct_store.get_item_clean_end(store, id.new(1, 1))
    T.eq(it.id.clock, 0)
    T.eq(it.content.str, "he")
  end)

  T.it("does not split when the id already falls on a boundary", function()
    local store = struct_store.new()
    struct_store.add(store, mk(1, 0, "hello"))
    local it = struct_store.get_item_clean_start(store, id.new(1, 0))
    T.eq(it.length, 5)
  end)
end)

T.describe("YATA integrate: sequential inserts", function()
  T.it("appends items to an empty sequence type", function()
    local store = struct_store.new()
    local parent = new_parent("text")
    local txn = new_txn(store)

    local a = item.new(id.new(1, 0), nil, nil, parent, nil, content.string("a"))
    T.eq(integrate.integrate(txn, a), true)
    T.eq(parent.start, a)
    T.eq(parent.length, 1)

    local b = item.new(id.new(1, 1), id.new(1, 0), nil, parent, nil, content.string("b"))
    T.eq(integrate.integrate(txn, b), true)
    T.eq(parent.start, a)
    T.eq(a.right, b)
    T.eq(b.left, a)
    T.eq(parent.length, 2)
  end)
end)

T.describe("YATA integrate: concurrent inserts at the same position", function()
  -- Client 1 has "ac" (a at clock 0, c at clock 1, inserted after a).
  -- Both client 2 (inserting "b") and client 3 (inserting "x") then insert
  -- concurrently right after "a" (same origin, no origin_right), without
  -- having seen each other's insert. YATA must resolve this identically on
  -- every replica: same-origin conflicts are broken by client id, higher
  -- client id ends up to the left (closer to the shared origin).
  T.it("orders concurrent same-origin inserts by client id, deterministically both ways", function()
    -- Order 1: integrate 2's insert before 3's insert.
    local store1 = struct_store.new()
    local parent1 = new_parent("text")
    local txn1 = new_txn(store1)
    local a1 = item.new(id.new(1, 0), nil, nil, parent1, nil, content.string("a"))
    integrate.integrate(txn1, a1)
    local b1 = item.new(id.new(2, 0), id.new(1, 0), nil, parent1, nil, content.string("b"))
    integrate.integrate(txn1, b1)
    local x1 = item.new(id.new(3, 0), id.new(1, 0), nil, parent1, nil, content.string("x"))
    integrate.integrate(txn1, x1)

    -- Order 2: integrate 3's insert before 2's insert.
    local store2 = struct_store.new()
    local parent2 = new_parent("text")
    local txn2 = new_txn(store2)
    local a2 = item.new(id.new(1, 0), nil, nil, parent2, nil, content.string("a"))
    integrate.integrate(txn2, a2)
    local x2 = item.new(id.new(3, 0), id.new(1, 0), nil, parent2, nil, content.string("x"))
    integrate.integrate(txn2, x2)
    local b2 = item.new(id.new(2, 0), id.new(1, 0), nil, parent2, nil, content.string("b"))
    integrate.integrate(txn2, b2)

    -- Read off the resulting sequence (by client id) for each replica.
    local function sequence(parent)
      local out = {}
      local cur = parent.start
      while cur ~= nil do
        out[#out + 1] = cur.id.client
        cur = cur.right
      end
      return out
    end

    local seq1 = sequence(parent1)
    local seq2 = sequence(parent2)
    T.eq(#seq1, 3)
    T.eq(seq1[1], seq1[1]) -- sanity
    T.eq(seq1[1], seq2[1])
    T.eq(seq1[2], seq2[2])
    T.eq(seq1[3], seq2[3])
    -- Client 2 (lower id) must end up closer to the shared origin "a" than
    -- client 3: in integrate()'s same-origin case, the new item jumps past
    -- (moves its left pointer to) any already-placed same-origin item whose
    -- client id is lower than its own, so lower client ids accumulate
    -- nearer the origin and higher ones land further right.
    T.eq(seq1[1], 1)
    T.eq(seq1[2], 2)
    T.eq(seq1[3], 3)
  end)
end)

T.describe("YATA integrate: concurrent inserts with different origins", function()
  -- Base sequence "ab" (client 1). Client 2 inserts "X" between a and b
  -- (origin=a, origin_right=b); client 3 concurrently inserts "Y" also
  -- between a and b. Integrating in either order must converge to the same
  -- sequence.
  T.it("converges regardless of integration order", function()
    local function build(second_first)
      local store = struct_store.new()
      local parent = new_parent("text")
      local txn = new_txn(store)
      local a = item.new(id.new(1, 0), nil, nil, parent, nil, content.string("a"))
      integrate.integrate(txn, a)
      local b = item.new(id.new(1, 1), id.new(1, 0), nil, parent, nil, content.string("b"))
      integrate.integrate(txn, b)

      local x = item.new(id.new(2, 0), id.new(1, 0), id.new(1, 1), parent, nil, content.string("x"))
      local y = item.new(id.new(3, 0), id.new(1, 0), id.new(1, 1), parent, nil, content.string("y"))
      if second_first then
        integrate.integrate(txn, y)
        integrate.integrate(txn, x)
      else
        integrate.integrate(txn, x)
        integrate.integrate(txn, y)
      end

      local out = {}
      local cur = parent.start
      while cur ~= nil do
        out[#out + 1] = cur.content.str
        cur = cur.right
      end
      return table.concat(out)
    end

    local order1 = build(false)
    local order2 = build(true)
    T.eq(order1, order2)
  end)
end)
