if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local D = require("lib.deepcopy")

T.describe("deepcopy", function()

  -- ─── copy ───────────────────────────────────────────────────────────────

  T.describe("copy", function()
    T.it("copies a simple table", function()
      local orig = { a = 1, b = 2 }
      local c = D.copy(orig)
      T.eq(c.a, 1)
      T.eq(c.b, 2)
    end)

    T.it("nested tables become independent copies", function()
      local orig = { x = { y = 42 } }
      local c = D.copy(orig)
      T.eq(c.x.y, 42)
      c.x.y = 99
      T.eq(orig.x.y, 42)
    end)

    T.it("shared inner refs become independent copies", function()
      local inner = { v = 1 }
      local orig = { a = inner, b = inner }
      local c = D.copy(orig)
      -- Both point to the same copy (cycle/alias preserved)
      T.ok(c.a == c.b, "shared ref preserved as same object in copy")
      c.a.v = 2
      T.eq(c.b.v, 2)        -- still shared in copy
      T.eq(orig.a.v, 1)     -- original unchanged
    end)

    T.it("handles cycles without infinite loop", function()
      local t = { name = "root" }
      t.self = t
      local c = D.copy(t)
      T.eq(c.name, "root")
      T.ok(c.self == c, "cycle points back to copy")
    end)

    T.it("preserves metatables", function()
      local mt = { __index = function(_, k) return k .. "!" end }
      local orig = setmetatable({ explicit = "yes" }, mt)
      local c = D.copy(orig)
      T.eq(c.explicit, "yes")
      T.eq(c.missing, "missing!")  -- __index still works
      T.ok(getmetatable(c) == mt)
    end)

    T.it("copies non-table values as-is", function()
      T.eq(D.copy(42), 42)
      T.eq(D.copy("hello"), "hello")
      T.eq(D.copy(true), true)
      T.eq(D.copy(nil), nil)
    end)

    T.it("transform override", function()
      local orig = { a = 1, b = 2 }
      local c = D.copy(orig, {
        transform = function(v, _depth)
          if type(v) == "number" then return v * 10, true end
          return nil, false
        end
      })
      T.eq(c.a, 10)
      T.eq(c.b, 20)
    end)
  end)

  -- ─── shallow ────────────────────────────────────────────────────────────

  T.describe("shallow", function()
    T.it("copies top-level keys", function()
      local orig = { a = 1, b = 2 }
      local c = D.shallow(orig)
      T.eq(c.a, 1)
      T.eq(c.b, 2)
    end)

    T.it("nested tables are shared (not copied)", function()
      local inner = { v = 1 }
      local orig = { inner = inner }
      local c = D.shallow(orig)
      T.ok(c.inner == inner, "shallow copy shares nested table")
      c.inner.v = 99
      T.eq(orig.inner.v, 99)
    end)

    T.it("original unaffected by top-level mutation", function()
      local orig = { a = 1 }
      local c = D.shallow(orig)
      c.a = 2
      T.eq(orig.a, 1)
    end)

    T.it("non-table passthrough", function()
      T.eq(D.shallow(5), 5)
    end)
  end)

  -- ─── freeze ─────────────────────────────────────────────────────────────

  T.describe("freeze", function()
    T.it("read still works after freeze", function()
      local f = D.freeze({ x = 10 })
      T.eq(f.x, 10)
    end)

    T.it("write to existing key raises error after freeze", function()
      local f = D.freeze({ x = 10 })
      T.throws(function() f.x = 20 end)
    end)

    T.it("new key raises error after freeze", function()
      local f = D.freeze({})
      T.throws(function() f.y = 1 end)
    end)

    T.it("freeze is idempotent (double-freeze returns same proxy)", function()
      local f = D.freeze({ a = 1 })
      local f2 = D.freeze(f)
      T.ok(D.is_frozen(f))
      T.ok(D.is_frozen(f2))
    end)

    T.it("freeze returns a proxy (not original)", function()
      local t = { a = 1 }
      local f = D.freeze(t)
      T.ok(f ~= t)
      T.ok(D.is_frozen(f))
      T.ok(not D.is_frozen(t))
    end)
  end)

  -- ─── is_frozen ──────────────────────────────────────────────────────────

  T.describe("is_frozen", function()
    T.it("returns false for unfrozen table", function()
      T.ok(not D.is_frozen({}))
    end)

    T.it("returns true for frozen proxy", function()
      local f = D.freeze({})
      T.ok(D.is_frozen(f))
    end)

    T.it("returns false for non-table", function()
      T.ok(not D.is_frozen(42))
      T.ok(not D.is_frozen("str"))
      T.ok(not D.is_frozen(nil))
    end)
  end)

  -- ─── freeze_deep ────────────────────────────────────────────────────────

  T.describe("freeze_deep", function()
    T.it("freezes nested tables", function()
      local f = D.freeze_deep({ inner = { v = 1 } })
      T.ok(D.is_frozen(f))
      T.ok(D.is_frozen(f.inner))
    end)

    T.it("nested write raises error", function()
      local f = D.freeze_deep({ inner = { v = 1 } })
      T.throws(function() f.inner.v = 2 end)
    end)

    T.it("deeply nested", function()
      local f = D.freeze_deep({ a = { b = { c = 1 } } })
      T.ok(D.is_frozen(f.a.b))
      T.throws(function() f.a.b.c = 2 end)
    end)
  end)

  -- ─── equal ──────────────────────────────────────────────────────────────

  T.describe("equal", function()
    T.it("identical primitives", function()
      T.ok(D.equal(1, 1))
      T.ok(D.equal("a", "a"))
      T.ok(D.equal(true, true))
      T.ok(D.equal(nil, nil))
    end)

    T.it("different primitives", function()
      T.ok(not D.equal(1, 2))
      T.ok(not D.equal("a", "b"))
    end)

    T.it("equal tables", function()
      T.ok(D.equal({a=1, b=2}, {a=1, b=2}))
    end)

    T.it("different values", function()
      T.ok(not D.equal({a=1}, {a=2}))
    end)

    T.it("different keys", function()
      T.ok(not D.equal({a=1}, {b=1}))
    end)

    T.it("extra keys in b", function()
      T.ok(not D.equal({a=1}, {a=1, b=2}))
    end)

    T.it("nested equal", function()
      T.ok(D.equal({x={y=1}}, {x={y=1}}))
    end)

    T.it("nested different", function()
      T.ok(not D.equal({x={y=1}}, {x={y=2}}))
    end)

    T.it("cycle detection (equal cycles)", function()
      local a = {}; a.self = a
      local b = {}; b.self = b
      T.ok(D.equal(a, b))
    end)

    T.it("strict mode: different metatables not equal", function()
      local mt1 = {}
      local mt2 = {}
      local a = setmetatable({x=1}, mt1)
      local b = setmetatable({x=1}, mt2)
      T.ok(not D.equal(a, b, {strict=true}))
    end)

    T.it("strict mode: same metatables equal", function()
      local mt = {}
      local a = setmetatable({x=1}, mt)
      local b = setmetatable({x=1}, mt)
      T.ok(D.equal(a, b, {strict=true}))
    end)
  end)

  -- ─── diff ───────────────────────────────────────────────────────────────

  T.describe("diff", function()
    T.it("no changes returns empty list", function()
      local d = D.diff({a=1}, {a=1})
      T.eq(#d, 0)
    end)

    T.it("single value change", function()
      local d = D.diff({a=1}, {a=2})
      T.eq(#d, 1)
      T.eq(d[1].path, "a")
      T.eq(d[1].old, 1)
      T.eq(d[1].new, 2)
    end)

    T.it("added key", function()
      local d = D.diff({}, {b=2})
      T.eq(#d, 1)
      T.eq(d[1].path, "b")
      T.eq(d[1].old, nil)
      T.eq(d[1].new, 2)
    end)

    T.it("removed key", function()
      local d = D.diff({a=1}, {})
      T.eq(#d, 1)
      T.eq(d[1].path, "a")
      T.eq(d[1].old, 1)
      T.eq(d[1].new, nil)
    end)

    T.it("nested change", function()
      local d = D.diff({user={name="Alice"}}, {user={name="Bob"}})
      T.eq(#d, 1)
      T.eq(d[1].path, "user.name")
      T.eq(d[1].old, "Alice")
      T.eq(d[1].new, "Bob")
    end)

    T.it("array index in path", function()
      local d = D.diff({items={10,20}}, {items={10,99}})
      T.eq(#d, 1)
      T.eq(d[1].path, "items[2]")
      T.eq(d[1].old, 20)
      T.eq(d[1].new, 99)
    end)
  end)

  -- ─── patch ──────────────────────────────────────────────────────────────

  T.describe("patch", function()
    T.it("patch round-trips diff", function()
      local orig = { a = 1, b = { c = 2 } }
      local modified = { a = 9, b = { c = 2 } }
      local d = D.diff(orig, modified)
      local result = D.patch(orig, d)
      T.ok(D.equal(result, modified))
    end)

    T.it("patch does not mutate original", function()
      local orig = { a = 1 }
      local d = D.diff(orig, { a = 2 })
      local _ = D.patch(orig, d)
      T.eq(orig.a, 1)
    end)

    T.it("patch can add keys", function()
      local orig = { a = 1 }
      local d = D.diff(orig, { a = 1, b = 2 })
      local result = D.patch(orig, d)
      T.eq(result.b, 2)
    end)

    T.it("patch can remove keys", function()
      local orig = { a = 1, b = 2 }
      local d = D.diff(orig, { a = 1 })
      local result = D.patch(orig, d)
      T.eq(result.b, nil)
    end)
  end)

  -- ─── merge ──────────────────────────────────────────────────────────────

  T.describe("merge", function()
    T.it("merges two tables", function()
      local r = D.merge({a=1}, {b=2})
      T.eq(r.a, 1)
      T.eq(r.b, 2)
    end)

    T.it("rightmost wins on conflict", function()
      local r = D.merge({a=1}, {a=2})
      T.eq(r.a, 2)
    end)

    T.it("original unmodified", function()
      local t1 = {a=1}
      local _ = D.merge(t1, {b=2})
      T.eq(t1.b, nil)
    end)

    T.it("multiple tables", function()
      local r = D.merge({a=1}, {b=2}, {c=3, a=9})
      T.eq(r.a, 9)
      T.eq(r.b, 2)
      T.eq(r.c, 3)
    end)
  end)

  -- ─── deep_merge ─────────────────────────────────────────────────────────

  T.describe("deep_merge", function()
    T.it("merges nested tables recursively", function()
      local r = D.deep_merge({user={name="A", age=10}}, {user={age=20}})
      T.eq(r.user.name, "A")
      T.eq(r.user.age, 20)
    end)

    T.it("arrays in override replace arrays in base", function()
      local r = D.deep_merge({items={1,2,3}}, {items={4,5}})
      T.eq(#r.items, 2)
      T.eq(r.items[1], 4)
    end)

    T.it("original unmodified", function()
      local t1 = {user={name="A"}}
      local _ = D.deep_merge(t1, {user={name="B"}})
      T.eq(t1.user.name, "A")
    end)

    T.it("deep nesting", function()
      local r = D.deep_merge({a={b={c=1}}}, {a={b={d=2}}})
      T.eq(r.a.b.c, 1)
      T.eq(r.a.b.d, 2)
    end)
  end)

  -- ─── get ────────────────────────────────────────────────────────────────

  T.describe("get", function()
    T.it("simple key", function()
      T.eq(D.get({a=1}, "a"), 1)
    end)

    T.it("dot path", function()
      T.eq(D.get({user={name="Alice"}}, "user.name"), "Alice")
    end)

    T.it("missing intermediate returns nil", function()
      T.eq(D.get({}, "user.name"), nil)
    end)

    T.it("missing key returns nil", function()
      T.eq(D.get({a=1}, "b"), nil)
    end)

    T.it("array index", function()
      T.eq(D.get({items={10,20,30}}, "items[2]"), 20)
    end)
  end)

  -- ─── set ────────────────────────────────────────────────────────────────

  T.describe("set", function()
    T.it("simple key", function()
      local t = {}
      D.set(t, "a", 1)
      T.eq(t.a, 1)
    end)

    T.it("creates intermediate tables", function()
      local t = {}
      D.set(t, "user.profile.name", "Bob")
      T.eq(t.user.profile.name, "Bob")
    end)

    T.it("modifies in place", function()
      local t = {user={name="Alice"}}
      D.set(t, "user.name", "Bob")
      T.eq(t.user.name, "Bob")
    end)

    T.it("overwrites intermediate if not table", function()
      local t = {user="string"}
      D.set(t, "user.name", "Bob")
      T.eq(t.user.name, "Bob")
    end)
  end)

  -- ─── delete ─────────────────────────────────────────────────────────────

  T.describe("delete", function()
    T.it("removes key and returns old value", function()
      local t = {a=42}
      local old = D.delete(t, "a")
      T.eq(old, 42)
      T.eq(t.a, nil)
    end)

    T.it("nested delete", function()
      local t = {user={name="Alice", age=30}}
      D.delete(t, "user.name")
      T.eq(t.user.name, nil)
      T.eq(t.user.age, 30)
    end)

    T.it("missing key returns nil", function()
      local t = {}
      local old = D.delete(t, "x")
      T.eq(old, nil)
    end)
  end)

  -- ─── flatten / unflatten ────────────────────────────────────────────────

  T.describe("flatten", function()
    T.it("flattens nested table", function()
      local t = {user={name="Alice", age=30}}
      local f = D.flatten(t)
      T.eq(f["user.name"], "Alice")
      T.eq(f["user.age"], 30)
    end)

    T.it("array keys use bracket notation", function()
      local t = {items={10,20}}
      local f = D.flatten(t)
      T.eq(f["items[1]"], 10)
      T.eq(f["items[2]"], 20)
    end)

    T.it("flat table unchanged", function()
      local t = {a=1, b=2}
      local f = D.flatten(t)
      T.eq(f["a"], 1)
      T.eq(f["b"], 2)
    end)
  end)

  T.describe("unflatten", function()
    T.it("restores nested table", function()
      local f = {["user.name"]="Alice", ["user.age"]=30}
      local t = D.unflatten(f)
      T.eq(t.user.name, "Alice")
      T.eq(t.user.age, 30)
    end)

    T.it("flat keys unchanged", function()
      local f = {a=1, b=2}
      local t = D.unflatten(f)
      T.eq(t.a, 1)
      T.eq(t.b, 2)
    end)
  end)

  T.describe("flatten/unflatten round-trip", function()
    T.it("round-trips nested table", function()
      local orig = {user={name="Alice", age=30}, active=true}
      local result = D.unflatten(D.flatten(orig))
      T.ok(D.equal(result, orig))
    end)
  end)

  -- ─── keys / values / entries ────────────────────────────────────────────

  T.describe("keys", function()
    T.it("returns sorted keys", function()
      local ks = D.keys({c=3, a=1, b=2})
      T.eq(ks[1], "a")
      T.eq(ks[2], "b")
      T.eq(ks[3], "c")
    end)

    T.it("empty table", function()
      T.eq(#D.keys({}), 0)
    end)
  end)

  T.describe("values", function()
    T.it("returns values in key-sorted order", function()
      local vs = D.values({c=30, a=10, b=20})
      T.eq(vs[1], 10)
      T.eq(vs[2], 20)
      T.eq(vs[3], 30)
    end)
  end)

  T.describe("entries", function()
    T.it("returns key-value pairs sorted by key", function()
      local es = D.entries({b=2, a=1})
      T.eq(es[1][1], "a")
      T.eq(es[1][2], 1)
      T.eq(es[2][1], "b")
      T.eq(es[2][2], 2)
    end)
  end)

  -- ─── pick / omit ────────────────────────────────────────────────────────

  T.describe("pick", function()
    T.it("returns only specified keys", function()
      local t = {name="Alice", age=30, password="secret"}
      local r = D.pick(t, {"name", "age"})
      T.eq(r.name, "Alice")
      T.eq(r.age, 30)
      T.eq(r.password, nil)
    end)

    T.it("missing keys are omitted", function()
      local t = {a=1}
      local r = D.pick(t, {"a", "b"})
      T.eq(r.a, 1)
      T.eq(r.b, nil)
    end)
  end)

  T.describe("omit", function()
    T.it("excludes specified keys", function()
      local t = {name="Alice", password="secret", token="xyz"}
      local r = D.omit(t, {"password", "token"})
      T.eq(r.name, "Alice")
      T.eq(r.password, nil)
      T.eq(r.token, nil)
    end)

    T.it("keeps all keys if none match", function()
      local t = {a=1, b=2}
      local r = D.omit(t, {"c"})
      T.eq(r.a, 1)
      T.eq(r.b, 2)
    end)
  end)

end)
