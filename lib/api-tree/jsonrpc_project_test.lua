-- lib/api-tree/jsonrpc_project_test.lua
-- Tests for lib/api-tree/jsonrpc_project.lua (method projection + dispatch table).

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T       = require("lib.test.assert")
local api_tree = require("lib.api-tree")
local project = require("lib.api-tree.jsonrpc_project")

--: (v: unknown) -> v is { [string]: unknown }
local function as_record(v)
  return type(v) == "table"
end

-- A handler that is never called — these tests are about projection, not
-- dispatch.
--: (input: unknown) -> unknown
local function inert(_input)
  return nil
end

-- The descriptor named `name`, or nil. Methods come back in sorted-key order,
-- so tests index by name rather than by position (see the module doc's CHILD
-- ORDER note).
--: (methods: { [integer]: unknown }, name: string) -> { [string]: unknown } | nil
local function method_named(methods, name)
  for i = 1, #methods do
    local m = methods[i]
    if as_record(m) and m.name == name then return m end
  end
  return nil
end

--: (methods: { [integer]: unknown }, name: string) -> { [string]: unknown }
local function require_method(methods, name)
  local m = method_named(methods, name)
  if m == nil then error("no method named " .. name) end
  return m
end

--: (methods: { [integer]: unknown }) -> { [integer]: string }
local function names_of(methods)
  local out = {} --: { [integer]: string }
  for i = 1, #methods do
    local m = methods[i]
    if as_record(m) then out[#out + 1] = tostring(m.name) end
  end
  table.sort(out)
  return out
end

T.describe("lib.api-tree.jsonrpc_project", function()

  T.describe("overrides_from_meta", function()

    T.it("returns the meta.jsonrpc bag", function()
      local bag = project.overrides_from_meta({ jsonrpc = { name = "custom" } })
      T.eq(bag.name, "custom")
    end)

    T.it("returns an empty bag when absent", function()
      T.eq(next(project.overrides_from_meta({})), nil)
    end)

    T.it("returns an empty bag when meta.jsonrpc is not a table", function()
      T.eq(next(project.overrides_from_meta({ jsonrpc = "nope" })), nil)
    end)
  end)

  T.describe("name derivation", function()

    T.it("names a root leaf by its key", function()
      local tree = api_tree.api({ ping = api_tree.op(inert) }, nil)
      T.eq(require_method(project.methods_from_tree(tree, nil), "ping").name, "ping")
    end)

    T.it("dot-joins tree position", function()
      local tree = api_tree.api({
        users = api_tree.api({ list = api_tree.op(inert), get = api_tree.op(inert) }, nil),
      }, nil)
      local names = names_of(project.methods_from_tree(tree, nil))
      T.eq(#names, 2)
      T.eq(names[1], "users.get")
      T.eq(names[2], "users.list")
    end)

    T.it("nests to arbitrary depth", function()
      local tree = api_tree.api({
        a = api_tree.api({ b = api_tree.api({ c = api_tree.op(inert) }, nil) }, nil),
      }, nil)
      T.eq(require_method(project.methods_from_tree(tree, nil), "a.b.c").name, "a.b.c")
    end)

    T.it("a leaf's meta.jsonrpc.name overrides the whole dotted name", function()
      local tree = api_tree.api({
        users = api_tree.api({ list = api_tree.op(inert, { jsonrpc = { name = "listAllUsers" } }) }, nil),
      }, nil)
      local names = names_of(project.methods_from_tree(tree, nil))
      T.eq(names[1], "listAllUsers")
    end)

    T.it("a branch's meta.jsonrpc.segment replaces its own prefix contribution", function()
      local tree = api_tree.api({
        users = api_tree.api({ list = api_tree.op(inert) }, { meta = { jsonrpc = { segment = "u" } } }),
      }, nil)
      T.eq(require_method(project.methods_from_tree(tree, nil), "u.list").name, "u.list")
    end)

    T.it("a fallback contributes its own name as a literal segment", function()
      local tree = api_tree.api({
        books = api_tree.api({}, {
          fallback = { name = "bookId", subtree = api_tree.api({ get = api_tree.op(inert) }, nil) },
        }),
      }, nil)
      T.eq(require_method(project.methods_from_tree(tree, nil), "books.bookId.get").name, "books.bookId.get")
    end)

    T.it("a fallback whose subtree is a bare leaf is not dropped", function()
      -- Walking a bare-leaf subtree as a branch would see no children and omit
      -- the method entirely.
      local tree = api_tree.api({
        books = api_tree.api({}, { fallback = { name = "bookId", subtree = api_tree.op(inert) } }),
      }, nil)
      local methods = project.methods_from_tree(tree, nil)
      T.eq(#methods, 1)
      T.eq(require_method(methods, "books.bookId").name, "books.bookId")
    end)

    T.it("a root-level fallback needs no prefix", function()
      local tree = api_tree.api({}, { fallback = { name = "id", subtree = api_tree.op(inert) } })
      T.eq(require_method(project.methods_from_tree(tree, nil), "id").name, "id")
    end)
  end)

  T.describe("description", function()

    T.it("falls back to the tree key", function()
      local tree = api_tree.api({ ping = api_tree.op(inert) }, nil)
      T.eq(require_method(project.methods_from_tree(tree, nil), "ping").description, "ping")
    end)

    T.it("reads meta.description", function()
      local tree = api_tree.api({ ping = api_tree.op(inert, { description = "liveness" }) }, nil)
      T.eq(require_method(project.methods_from_tree(tree, nil), "ping").description, "liveness")
    end)

    T.it("meta.jsonrpc.description wins over meta.description", function()
      local tree = api_tree.api({
        ping = api_tree.op(inert, { description = "generic", jsonrpc = { description = "rpc-specific" } }),
      }, nil)
      T.eq(require_method(project.methods_from_tree(tree, nil), "ping").description, "rpc-specific")
    end)

    T.it("a derived description loses to both, but beats the key", function()
      local schemas = { ping = { description = "derived" } }
      local tree = api_tree.api({ ping = api_tree.op(inert) }, nil)
      T.eq(require_method(project.methods_from_tree(tree, { schemas = schemas }), "ping").description, "derived")

      local annotated = api_tree.api({ ping = api_tree.op(inert, { description = "authored" }) }, nil)
      T.eq(require_method(project.methods_from_tree(annotated, { schemas = schemas }), "ping").description, "authored")
    end)

    T.it("a fallback leaf falls back to the fallback's own name", function()
      local tree = api_tree.api({}, { fallback = { name = "id", subtree = api_tree.op(inert) } })
      T.eq(require_method(project.methods_from_tree(tree, nil), "id").description, "id")
    end)
  end)

  T.describe("schemas", function()

    T.it("degrades paramsSchema to the any-object minimum", function()
      local tree = api_tree.api({ ping = api_tree.op(inert) }, nil)
      local schema = require_method(project.methods_from_tree(tree, nil), "ping").paramsSchema
      if not as_record(schema) then error("expected a schema") end
      T.eq(schema.type, "object")
    end)

    T.it("omits resultSchema entirely when nothing derived one", function()
      local tree = api_tree.api({ ping = api_tree.op(inert) }, nil)
      T.eq(require_method(project.methods_from_tree(tree, nil), "ping").resultSchema, nil)
    end)

    T.it("takes both from the derived map, keyed by the RESOLVED name", function()
      local schemas = {
        ["users.list"] = {
          paramsSchema = { type = "object", properties = { limit = { type = "integer" } } },
          resultSchema = { type = "array" },
        },
      }
      local tree = api_tree.api({ users = api_tree.api({ list = api_tree.op(inert) }, nil) }, nil)
      local m = require_method(project.methods_from_tree(tree, { schemas = schemas }), "users.list")
      local params = m.paramsSchema
      local res = m.resultSchema
      if not as_record(params) or not as_record(res) then error("expected schemas") end
      T.eq(params.properties ~= nil, true)
      T.eq(res.type, "array")
    end)

    T.it("looks a renamed method up under its override, not its tree position", function()
      local schemas = { renamed = { resultSchema = { type = "string" } } }
      local tree = api_tree.api({ ping = api_tree.op(inert, { jsonrpc = { name = "renamed" } }) }, nil)
      local m = require_method(project.methods_from_tree(tree, { schemas = schemas }), "renamed")
      local res = m.resultSchema
      if not as_record(res) then error("expected a resultSchema") end
      T.eq(res.type, "string")
    end)
  end)

  T.describe("errorSchema (§5.1 envelope)", function()

    T.it("is the fixed envelope, data unconstrained", function()
      local tree = api_tree.api({ ping = api_tree.op(inert) }, nil)
      local schema = require_method(project.methods_from_tree(tree, nil), "ping").errorSchema
      if not as_record(schema) then error("expected a schema") end
      T.eq(schema.type, "object")
      local props = schema.properties
      if not as_record(props) then error("expected properties") end
      local code = props.code
      local message = props.message
      local data = props.data
      if not as_record(code) or not as_record(message) or not as_record(data) then
        error("expected code/message/data sub-schemas")
      end
      T.eq(code.type, "integer")
      T.eq(message.type, "string")
      T.eq(next(data), nil, "an unconstrained data schema is the empty schema")
    end)

    T.it("narrows data from meta.jsonrpc.errorDataSchema", function()
      local tree = api_tree.api({
        ping = api_tree.op(inert, { jsonrpc = { errorDataSchema = { type = "string" } } }),
      }, nil)
      local schema = require_method(project.methods_from_tree(tree, nil), "ping").errorSchema
      if not as_record(schema) then error("expected a schema") end
      local props = schema.properties
      if not as_record(props) then error("expected properties") end
      local data = props.data
      if not as_record(data) then error("expected a data sub-schema") end
      T.eq(data.type, "string")
    end)
  end)

  T.describe("tag fields", function()

    T.it("omits every tag field when nothing is tagged", function()
      local tree = api_tree.api({ ping = api_tree.op(inert) }, nil)
      local m = require_method(project.methods_from_tree(tree, nil), "ping")
      T.eq(m.readOnly, nil)
      T.eq(m.destructive, nil)
      T.eq(m.idempotent, nil)
      T.eq(m.streaming, nil)
      T.eq(m.deprecated, nil)
    end)

    T.it("surfaces authored tags flat on the descriptor", function()
      local tree = api_tree.api({
        list = api_tree.op(inert, { tags = { readOnly = true, streaming = true, deprecated = true } }),
      }, nil)
      local m = require_method(project.methods_from_tree(tree, nil), "list")
      T.eq(m.readOnly, true)
      T.eq(m.streaming, true)
      T.eq(m.deprecated, true)
    end)

    T.it("applies the implication lattice (readOnly implies idempotent)", function()
      local tree = api_tree.api({ list = api_tree.op(inert, { tags = { readOnly = true } }) }, nil)
      T.eq(require_method(project.methods_from_tree(tree, nil), "list").idempotent, true)
    end)

    T.it("keeps an explicit false rather than dropping it", function()
      local tree = api_tree.api({ del = api_tree.op(inert, { tags = { readOnly = false } }) }, nil)
      T.eq(require_method(project.methods_from_tree(tree, nil), "del").readOnly, false)
    end)

    T.it("reads a leaf's OWN tags, never an ancestor's", function()
      local tree = api_tree.api({
        users = api_tree.api({ list = api_tree.op(inert) }, { meta = { tags = { readOnly = true } } }),
      }, nil)
      T.eq(require_method(project.methods_from_tree(tree, nil), "users.list").readOnly, nil)
    end)
  end)

  T.describe("dispatch table", function()

    T.it("registers one entry per leaf, keyed by resolved name", function()
      local tree = api_tree.api({
        ping = api_tree.op(inert),
        users = api_tree.api({ list = api_tree.op(inert, { jsonrpc = { name = "listUsers" } }) }, nil),
      }, nil)
      local projected = project.project_methods(tree, nil)
      T.ok(projected.handlers["ping"] ~= nil, "ping registered")
      T.ok(projected.handlers["listUsers"] ~= nil, "override name registered")
      T.eq(projected.handlers["users.list"], nil, "tree position must not also be registered")
    end)

    T.it("carries the leaf's handler", function()
      --: (input: unknown) -> unknown
      local function handler(_input) return 42 end
      local tree = api_tree.api({ ping = api_tree.op(handler) }, nil)
      local entry = project.project_methods(tree, nil).handlers["ping"]
      if entry == nil then error("no dispatch entry") end
      T.eq(entry.handler(nil), 42)
    end)

    T.it("defaults source_map to empty", function()
      local tree = api_tree.api({ ping = api_tree.op(inert) }, nil)
      local entry = project.project_methods(tree, nil).handlers["ping"]
      if entry == nil then error("no dispatch entry") end
      T.eq(next(entry.source_map), nil)
    end)

    T.it("carries meta.jsonrpc.sourceMap", function()
      local tree = api_tree.api({
        ping = api_tree.op(inert, { jsonrpc = { sourceMap = { token = { store = "caller", key = "auth" } } } }),
      }, nil)
      local entry = project.project_methods(tree, nil).handlers["ping"]
      if entry == nil then error("no dispatch entry") end
      local src = entry.source_map["token"]
      if src == nil then error("no source override") end
      T.eq(src.store, "caller")
      T.eq(src.key, "auth")
    end)

    T.it("carries the leaf's own meta", function()
      local tree = api_tree.api({ ping = api_tree.op(inert, { description = "liveness" }) }, nil)
      local entry = project.project_methods(tree, nil).handlers["ping"]
      if entry == nil then error("no dispatch entry") end
      T.eq(entry.meta.description, "liveness")
    end)
  end)
end)
