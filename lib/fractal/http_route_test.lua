-- lib/fractal/http_route_test.lua
-- Tests for lib/fractal/http_route.lua (the HTTP route tree, its rewriters,
-- and the wire-time source-coverage check).
--
-- Two properties recur throughout and are worth stating once:
--
--   DETERMINISM. LuaJIT's `pairs` yields string keys in hash order, so any
--   behavior that depends on iteration order would vary between runs. The
--   moveTo tests below pin the observable consequences — which conflict is
--   reported, what order coverage problems come out in — because those are
--   exactly the places the module iterates sorted keys to make the answer
--   stable.
--
--   AUTHORED-POSITION BINDING. `sources.authoredPathParams` is stamped at
--   `naive_transform` time and must survive every rewriter untouched: a leaf's
--   field-to-store binding is a function of where it was AUTHORED, never of
--   where moveTo relocates it. Several tests assert the stamped list directly,
--   and the coverage tests assert the errors that follow from it.
--
-- The route-shape types below are declared locally rather than imported: type
-- aliases are per-file throughout this repo, and assignability is structural,
-- so a locally-declared `HttpRoute` accepts what the module produces. The
-- accessor helpers exist so that unwrapping an optional field happens ONCE,
-- with a loud error, instead of every assertion carrying an `x ~= nil and ...`
-- chain that would silently pass on a nil.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T       = require("lib.test.assert")
local fractal = require("lib.fractal")
local route   = require("lib.fractal.http_route")

--:: Meta = { [string]: unknown }
--:: ParamSource = { store: string, key?: string }
--:: SourceMap = { [string]: ParamSource }
--:: Sources = { sourceMap?: SourceMap, paramNames?: { [integer]: string }, authoredPathParams?: { [integer]: string }, transform?: (bag: { [string]: unknown }) -> { [string]: unknown }, validate?: unknown }
--:: MethodEntry = { handler: (input: unknown) -> unknown, meta: Meta, sources?: Sources | nil }
--:: HttpRoute = { methods?: { [string]: MethodEntry } | nil, children?: { [string]: HttpRoute } | nil, fallback?: { name: string, subtree: HttpRoute } | nil, meta: Meta }
--:: ResponseOverride = { body: unknown, init: { status?: integer, reason?: string, headers?: { [string]: { [integer]: string } } } }

--: (input: unknown) -> unknown
local function noop(input)
  return input
end

--: (r: HttpRoute, name: string) -> HttpRoute
local function child_of(r, name)
  local children = r.children
  if children == nil then error("expected children, found none") end
  local child = children[name]
  if child == nil then error("expected a child named '" .. name .. "'") end
  return child
end

-- Walk a chain of `children` keys, erroring loudly rather than indexing nil
-- three levels deep when a rewriter did not put the node where expected.
--: (r: HttpRoute, path: { [integer]: string }) -> HttpRoute
local function at(r, path)
  local node = r
  for i = 1, #path do
    node = child_of(node, path[i])
  end
  return node
end

--: (r: HttpRoute) -> { name: string, subtree: HttpRoute }
local function fallback_of(r)
  local f = r.fallback
  if f == nil then error("expected a fallback, found none") end
  return f
end

--: (r: HttpRoute) -> { [string]: MethodEntry }
local function methods_of(r)
  return r.methods or {}
end

--: (r: HttpRoute, method: string) -> MethodEntry
local function entry_of(r, method)
  local entry = methods_of(r)[method]
  if entry == nil then error("expected a " .. method .. " method entry, found none") end
  return entry
end

--: (e: MethodEntry) -> Sources
local function sources_of(e)
  local s = e.sources
  if s == nil then error("expected sources on this method entry, found none") end
  return s
end

--: (e: MethodEntry) -> { [integer]: string }
local function authored_of(e)
  local a = sources_of(e).authoredPathParams
  if a == nil then error("expected authoredPathParams, found none") end
  return a
end

-- Shape narrowing only. The BRAND check is `route.is_response_override`,
-- asserted separately in `as_override` below — a `v is T` predicate declared in
-- another module does not carry its narrowing across the require boundary, so
-- the local predicate supplies the type and the module call supplies the fact.
-- Same split as http_value_test.lua's `as_record`.
--: (v: unknown) -> v is ResponseOverride
local function is_override_shape(v)
  return type(v) == "table"
end

--: (v: unknown) -> ResponseOverride
local function as_override(v)
  T.eq(route.is_response_override(v), true)
  if not is_override_shape(v) then error("expected a table") end
  return v
end

--: (t: { [string]: unknown }) -> { [integer]: string }
local function keys_sorted(t)
  --: { [integer]: string }
  local out = {}
  local n = 0
  for k in pairs(t) do
    n = n + 1
    out[n] = k
  end
  table.sort(out)
  return out
end

--: (r: HttpRoute) -> { [integer]: string }
local function method_names(r)
  return keys_sorted(methods_of(r))
end

T.describe("lib.fractal.http_route", function()

  -- ── constructor + brand ────────────────────────────────────────────────

  T.describe("http_route / is_http_route", function()

    T.it("defaults meta to an empty bag", function()
      local r = route.http_route({})
      T.eq(type(r.meta), "table")
      T.eq(next(r.meta), nil)
    end)

    T.it("omits absent fields rather than setting them to a placeholder", function()
      local r = route.http_route({ meta = { a = 1 } })
      T.eq(r.methods, nil)
      T.eq(r.children, nil)
      T.eq(r.fallback, nil)
    end)

    T.it("brands what it builds", function()
      T.eq(route.is_http_route(route.http_route({})), true)
    end)

    T.it("does not brand a structurally identical plain table", function()
      -- The whole reason the brand exists: a `Node` and an `HttpRoute` both
      -- carry `children` and `meta`, so shape alone cannot discriminate.
      T.eq(route.is_http_route({ children = {}, meta = {} }), false)
    end)

    T.it("rejects non-tables", function()
      T.eq(route.is_http_route(nil), false)
      T.eq(route.is_http_route("x"), false)
      T.eq(route.is_http_route(7), false)
    end)

    T.it("brands every route the transform pipeline produces", function()
      local naive = route.naive_transform(fractal.api({ a = fractal.op(noop) }))
      T.eq(route.is_http_route(naive), true)
      T.eq(route.is_http_route(child_of(naive, "a")), true)
      T.eq(route.is_http_route(route.apply_methods(naive)), true)
      T.eq(route.is_http_route(route.apply_move_to(naive)), true)
      T.eq(route.is_http_route(route.apply_response(naive)), true)
    end)

  end)

  -- ── flat-key readers ───────────────────────────────────────────────────

  T.describe("flat-key readers", function()

    T.it("read_http_meta returns an empty bag for absent or non-table http", function()
      T.eq(next(route.read_http_meta({})), nil)
      T.eq(next(route.read_http_meta({ http = "nope" })), nil)
    end)

    T.it("source_map_of / validate_of / paginated_directive_of read their key", function()
      --: Meta
      local meta = {
        http = {
          sourceMap = { apiKey = { store = "header", key = "x-api-key" } },
          validate = "schema-sentinel",
          paginated = { style = "cursor", inputCursorParam = "after" },
        },
      }
      local sm = route.source_map_of(meta)
      if sm == nil then error("expected a sourceMap") end
      T.eq(sm.apiKey.store, "header")
      T.eq(sm.apiKey.key, "x-api-key")
      T.eq(route.validate_of(meta), "schema-sentinel")
      local pg = route.paginated_directive_of(meta)
      if pg == nil then error("expected a paginated directive") end
      T.eq(pg.style, "cursor")
      T.eq(pg.inputCursorParam, "after")
    end)

    T.it("returns nil for keys the meta does not carry", function()
      T.eq(route.source_map_of({}), nil)
      T.eq(route.validate_of({}), nil)
      T.eq(route.paginated_directive_of({}), nil)
    end)

  end)

  -- ── naive_transform ────────────────────────────────────────────────────

  T.describe("naive_transform", function()

    T.it("turns a leaf into a single POST entry", function()
      local names = method_names(route.naive_transform(fractal.op(noop)))
      T.eq(#names, 1)
      T.eq(names[1], "POST")
    end)

    T.it("turns each child into a path-segment child", function()
      local tree = fractal.api({ books = fractal.api({ list = fractal.op(noop) }) })
      local leaf = at(route.naive_transform(tree), { "books", "list" })
      T.eq(method_names(leaf)[1], "POST")
    end)

    T.it("copies meta through unchanged, by reference", function()
      --: Meta
      local meta = { http = { method = "get" } }
      local naive = route.naive_transform(fractal.op(noop, meta))
      T.eq(naive.meta, meta)
      T.eq(entry_of(naive, "POST").meta, meta)
    end)

    T.it("carries a leaf's sourceMap and validate onto sources", function()
      local naive = route.naive_transform(fractal.op(noop, {
        http = { sourceMap = { id = { store = "header" } }, validate = "schema-sentinel" },
      }))
      local sources = sources_of(entry_of(naive, "POST"))
      local sm = sources.sourceMap
      if sm == nil then error("expected sourceMap on sources") end
      T.eq(sm.id.store, "header")
      T.eq(sources.validate, "schema-sentinel")
    end)

    T.it("stamps an EMPTY authored set on a leaf under no fallback", function()
      -- Empty, not absent: the leaf DID go through naive_transform and simply
      -- has no authored slugs. Absent would mean "hand-built route", which is
      -- a different branch in the coverage check.
      local naive = route.naive_transform(fractal.op(noop))
      T.eq(#authored_of(entry_of(naive, "POST")), 0)
    end)

    T.it("stamps the ancestor fallback-name chain, outermost first", function()
      local inner = fractal.api({ chapter = fractal.op(noop) }, {
        fallback = { name = "chapterId", subtree = fractal.op(noop) },
      })
      local naive = route.naive_transform(fractal.api({}, {
        fallback = { name = "bookId", subtree = inner },
      }))
      local leaf = fallback_of(fallback_of(naive).subtree).subtree
      local authored = authored_of(entry_of(leaf, "POST"))
      T.eq(#authored, 2)
      T.eq(authored[1], "bookId")
      T.eq(authored[2], "chapterId")
    end)

    T.it("a sibling under the same fallback does not see the deeper chain", function()
      -- The chain is appended into a NEW array per fallback, never mutated in
      -- place; a shared array would leak `chapterId` into this leaf.
      local inner = fractal.api({ chapter = fractal.op(noop) }, {
        fallback = { name = "chapterId", subtree = fractal.op(noop) },
      })
      local naive = route.naive_transform(fractal.api({}, {
        fallback = { name = "bookId", subtree = inner },
      }))
      local sibling = child_of(fallback_of(naive).subtree, "chapter")
      local authored = authored_of(entry_of(sibling, "POST"))
      T.eq(#authored, 1)
      T.eq(authored[1], "bookId")
    end)

  end)

  -- ── map_route ──────────────────────────────────────────────────────────

  T.describe("map_route", function()

    T.it("visits every node, including fallback subtrees", function()
      local tree = fractal.api({ a = fractal.api({ b = fractal.op(noop) }) }, {
        fallback = { name = "id", subtree = fractal.op(noop) },
      })
      local naive = route.naive_transform(tree)
      local seen = 0
      route.map_route(naive, function(node)
        seen = seen + 1
        return node
      end)
      -- root, a, a.b, and the fallback subtree.
      T.eq(seen, 4)
    end)

    T.it("is PRE-order — fn sees a node before its children are walked", function()
      -- Pre-order is what lets `fn` swap in an entirely different node and
      -- have THAT node's children walked instead of the original's.
      local naive = route.naive_transform(fractal.api({ old = fractal.op(noop) }))
      local out = route.map_route(naive, function(node)
        local children = node.children
        if children ~= nil and children.old ~= nil then
          return route.http_route({ children = { new = children.old }, meta = node.meta })
        end
        return node
      end)
      T.eq(method_names(child_of(out, "new"))[1], "POST")
      T.eq(out.children ~= nil and out.children.old, nil)
    end)

    T.it("does not mutate the input tree", function()
      local naive = route.naive_transform(fractal.api({ a = fractal.op(noop) }))
      local before = child_of(naive, "a")
      route.map_route(naive, function(node)
        return route.http_route({ methods = node.methods, meta = { touched = true } })
      end)
      T.eq(child_of(naive, "a"), before)
      T.eq(naive.meta.touched, nil)
    end)

  end)

  -- ── apply_methods ──────────────────────────────────────────────────────

  T.describe("apply_methods", function()

    T.it("renames POST to the declared method, uppercased", function()
      local naive = route.naive_transform(fractal.api({
        list = fractal.op(noop, { http = { method = "get" } }),
      }))
      local names = method_names(child_of(route.apply_methods(naive), "list"))
      T.eq(#names, 1)
      T.eq(names[1], "GET")
    end)

    T.it("leaves an entry alone when no method is declared", function()
      local naive = route.naive_transform(fractal.api({ list = fractal.op(noop) }))
      T.eq(method_names(child_of(route.apply_methods(naive), "list"))[1], "POST")
    end)

    T.it("does NOT strip meta.http.method after renaming", function()
      -- "Resolved shape = authored shape": the key is informational, not a
      -- directive to consume.
      local naive = route.naive_transform(fractal.api({
        list = fractal.op(noop, { http = { method = "get" } }),
      }))
      local entry = entry_of(child_of(route.apply_methods(naive), "list"), "GET")
      T.eq(route.read_http_meta(entry.meta).method, "get")
    end)

    T.it("preserves sources across the rename", function()
      local naive = route.naive_transform(fractal.api({}, {
        fallback = { name = "id", subtree = fractal.op(noop, { http = { method = "get" } }) },
      }))
      local leaf = fallback_of(route.apply_methods(naive)).subtree
      local authored = authored_of(entry_of(leaf, "GET"))
      T.eq(#authored, 1)
      T.eq(authored[1], "id")
    end)

  end)

  -- ── apply_move_to ──────────────────────────────────────────────────────

  T.describe("apply_move_to", function()

    T.it("'.' is identity — the node stays where it is", function()
      local naive = route.naive_transform(fractal.api({
        keep = fractal.op(noop, { http = { moveTo = "." } }),
      }))
      T.eq(method_names(child_of(route.apply_move_to(naive), "keep"))[1], "POST")
    end)

    T.it("'../newname' renames a node in place", function()
      local naive = route.naive_transform(fractal.api({
        getBook = fractal.op(noop, { http = { moveTo = "../books" } }),
      }))
      local moved = route.apply_move_to(naive)
      T.eq(moved.children ~= nil and moved.children.getBook, nil)
      T.eq(method_names(child_of(moved, "books"))[1], "POST")
    end)

    T.it("'*' pushes the node below a new wildcard segment named 'param'", function()
      -- [convention] The wildcard's parameter name is not yet carried by any
      -- metadata key; "param" is the documented default.
      local naive = route.naive_transform(fractal.api({
        books = fractal.api({ get = fractal.op(noop, { http = { moveTo = "*" } }) }),
      }))
      local moved = route.apply_move_to(naive)
      local fb = fallback_of(at(moved, { "books", "get" }))
      T.eq(fb.name, "param")
      T.eq(method_names(fb.subtree)[1], "POST")
    end)

    T.it("prefers an existing fallback name over the 'param' default", function()
      local existing = route.http_route({ meta = {} })
      local root = route.http_route({
        children = {
          books = route.http_route({
            children = { get = route.http_route({ methods = { POST = { handler = noop, meta = {} } }, meta = { http = { moveTo = "../*" } } }) },
            fallback = { name = "bookId", subtree = existing },
            meta = {},
          }),
        },
        meta = {},
      })
      T.eq(fallback_of(child_of(route.apply_move_to(root), "books")).name, "bookId")
    end)

    T.it("mkdir-p: creates every intermediate segment of a deep target", function()
      local naive = route.naive_transform(fractal.api({
        users = fractal.op(noop, { http = { moveTo = "../api/v2/users" } }),
      }))
      T.eq(method_names(at(route.apply_move_to(naive), { "api", "v2", "users" }))[1], "POST")
    end)

    T.it("popping past the root is a no-op, not an error", function()
      local naive = route.naive_transform(fractal.api({
        a = fractal.op(noop, { http = { moveTo = "../../../top" } }),
      }))
      T.eq(method_names(child_of(route.apply_move_to(naive), "top"))[1], "POST")
    end)

    T.it("a '.' path component is a no-op", function()
      local naive = route.naive_transform(fractal.api({
        a = fractal.op(noop, { http = { moveTo = "./deeper" } }),
      }))
      T.eq(method_names(at(route.apply_move_to(naive), { "a", "deeper" }))[1], "POST")
    end)

    T.it("converging subtrees merge into one position", function()
      -- The motivating REST case: get/update/delete all land on the same
      -- wildcard, each contributing its own method. "../*" — up out of the
      -- operation's own name, then down into a wildcard sibling; a bare "*"
      -- would push each below its OWN name and nothing would converge.
      local tree = fractal.api({
        books = fractal.api({
          get    = fractal.op(noop, { http = { method = "get", moveTo = "../*" } }),
          update = fractal.op(noop, { http = { method = "put", moveTo = "../*" } }),
          remove = fractal.op(noop, { http = { method = "delete", moveTo = "../*" } }),
        }),
      })
      local moved = route.apply_move_to(route.apply_methods(route.naive_transform(tree)))
      local names = method_names(fallback_of(child_of(moved, "books")).subtree)
      T.eq(#names, 3)
      T.eq(names[1], "DELETE")
      T.eq(names[2], "GET")
      T.eq(names[3], "PUT")
    end)

    T.it("errors when two nodes converge on the same path AND method", function()
      local tree = fractal.api({
        books = fractal.api({
          getA = fractal.op(noop, { http = { moveTo = "../*" } }),
          getB = fractal.op(noop, { http = { moveTo = "../*" } }),
        }),
      })
      local naive = route.naive_transform(tree)
      local ok, err = pcall(function() return route.apply_move_to(naive) end)
      T.eq(ok, false)
      local msg = tostring(err)
      T.eq(msg:find("conflicting route", 1, true) ~= nil, true)
      T.eq(msg:find("POST /books/*", 1, true) ~= nil, true)
    end)

    T.it("reports the same conflict deterministically across runs", function()
      -- Detach and re-insert both iterate sorted keys, so the message does not
      -- depend on LuaJIT's hash order.
      local tree = fractal.api({
        books = fractal.api({
          alpha = fractal.op(noop, { http = { moveTo = "../*" } }),
          beta  = fractal.op(noop, { http = { moveTo = "../*" } }),
          gamma = fractal.op(noop, { http = { moveTo = "../*" } }),
        }),
      })
      --: () -> string
      local function message()
        local ok, err = pcall(function() return route.apply_move_to(route.naive_transform(tree)) end)
        T.eq(ok, false)
        return tostring(err)
      end
      local first = message()
      for _ = 1, 20 do T.eq(message(), first) end
    end)

    T.it("does NOT strip meta.http.moveTo from the moved leaf's method entry", function()
      local naive = route.naive_transform(fractal.api({
        getBook = fractal.op(noop, { http = { moveTo = "../books" } }),
      }))
      local entry = entry_of(child_of(route.apply_move_to(naive), "books"), "POST")
      T.eq(route.read_http_meta(entry.meta).moveTo, "../books")
    end)

    T.it("the NODE-position meta at a created target is the target's, not the mover's", function()
      -- `merge_routes` keeps `target.meta`, so a subtree landing on a
      -- mkdir-p'd intermediate takes that intermediate's (empty) meta at the
      -- node position. Ported as-is from the TypeScript; the leaf's own
      -- method-entry meta, asserted above, is where the authored bag survives.
      local naive = route.naive_transform(fractal.api({
        getBook = fractal.op(noop, { http = { moveTo = "../books" } }),
      }))
      T.eq(route.read_http_meta(child_of(route.apply_move_to(naive), "books").meta).moveTo, nil)
    end)

    T.it("moves a fallback subtree out and clears the fallback slot", function()
      local tree = fractal.api({}, {
        fallback = { name = "id", subtree = fractal.op(noop, { http = { moveTo = "../../detail" } }) },
      })
      local moved = route.apply_move_to(route.naive_transform(tree))
      T.eq(moved.fallback, nil)
      T.eq(method_names(child_of(moved, "detail"))[1], "POST")
    end)

    T.it("does not alter a leaf's authored path params", function()
      -- The whole point of stamping them at naive_transform time: moveTo is an
      -- ADDRESS transform and must not rebind inputs.
      local tree = fractal.api({}, {
        fallback = {
          name = "bookId",
          subtree = fractal.op(noop, { http = { moveTo = "../../elsewhere" } }),
        },
      })
      local moved = route.apply_move_to(route.naive_transform(tree))
      local authored = authored_of(entry_of(child_of(moved, "elsewhere"), "POST"))
      T.eq(#authored, 1)
      T.eq(authored[1], "bookId")
    end)

  end)

  -- ── apply_response ─────────────────────────────────────────────────────

  T.describe("apply_response", function()

    T.it("leaves a handler untouched when no response directive is present", function()
      local naive = route.naive_transform(fractal.api({ a = fractal.op(noop) }))
      local before = entry_of(child_of(naive, "a"), "POST")
      local after = entry_of(child_of(route.apply_response(naive), "a"), "POST")
      T.eq(after, before)
    end)

    T.it("wraps the handler so it returns a branded override", function()
      local naive = route.naive_transform(fractal.api({
        a = fractal.op(noop, { http = { response = { status = 201 } } }),
      }))
      local entry = entry_of(child_of(route.apply_response(naive), "a"), "POST")
      local ov = as_override(entry.handler("payload"))
      T.eq(ov.body, "payload")
      T.eq(ov.init.status, 201)
    end)

    T.it("converts the directive's flat header map into the multi-valued bag", function()
      local naive = route.naive_transform(fractal.api({
        a = fractal.op(noop, { http = { response = { headers = { ["X-Trace"] = "abc" } } } }),
      }))
      local entry = entry_of(child_of(route.apply_response(naive), "a"), "POST")
      local headers = as_override(entry.handler(nil)).init.headers
      if headers == nil then error("expected headers on the override init") end
      -- Lowercased on the way in, and an ARRAY of values — never a flattened
      -- scalar. See http_value.lua's module doc.
      T.eq(#headers["x-trace"], 1)
      T.eq(headers["x-trace"][1], "abc")
      T.eq(headers["X-Trace"], nil)
    end)

    T.it("omits status/headers from init when the directive omits them", function()
      local naive = route.naive_transform(fractal.api({
        a = fractal.op(noop, { http = { response = {} } }),
      }))
      local entry = entry_of(child_of(route.apply_response(naive), "a"), "POST")
      local init = as_override(entry.handler(nil)).init
      T.eq(init.status, nil)
      T.eq(init.headers, nil)
    end)

    T.it("does NOT strip meta.http.response after wrapping", function()
      local naive = route.naive_transform(fractal.api({
        a = fractal.op(noop, { http = { response = { status = 201 } } }),
      }))
      local entry = entry_of(child_of(route.apply_response(naive), "a"), "POST")
      local directive = route.read_http_meta(entry.meta).response
      if directive == nil then error("expected the response directive to survive") end
      T.eq(directive.status, 201)
    end)

    T.it("preserves sources across wrapping", function()
      local naive = route.naive_transform(fractal.api({
        a = fractal.op(noop, {
          http = { response = { status = 201 }, sourceMap = { id = { store = "header" } } },
        }),
      }))
      local entry = entry_of(child_of(route.apply_response(naive), "a"), "POST")
      local sm = sources_of(entry).sourceMap
      if sm == nil then error("expected sourceMap to survive wrapping") end
      T.eq(sm.id.store, "header")
    end)

  end)

  -- ── response_override / is_response_override ───────────────────────────

  T.describe("is_response_override", function()

    T.it("recognizes what response_override builds", function()
      T.eq(route.is_response_override(route.response_override("body", {})), true)
    end)

    T.it("does not recognize a plain table with the same fields", function()
      -- The reason the brand is a weak table rather than an in-band `kind`
      -- field: the override wraps an ARBITRARY handler return value, so any
      -- structural marker would be forgeable by a handler returning it.
      T.eq(route.is_response_override({ body = "x", init = {} }), false)
    end)

    T.it("rejects non-tables", function()
      T.eq(route.is_response_override(nil), false)
      T.eq(route.is_response_override("x"), false)
    end)

  end)

  -- ── compose_transforms ─────────────────────────────────────────────────

  T.describe("compose_transforms", function()

    T.it("applies transforms left to right", function()
      --: { [integer]: string }
      local order = {}
      --: (tag: string) -> ((r: HttpRoute) -> HttpRoute)
      local function tagger(tag)
        return function(r)
          order[#order + 1] = tag
          return r
        end
      end
      local composed = route.compose_transforms(tagger("first"), tagger("second"), tagger("third"))
      composed(route.http_route({}))
      T.eq(#order, 3)
      T.eq(order[1], "first")
      T.eq(order[2], "second")
      T.eq(order[3], "third")
    end)

    T.it("with no transforms is the identity", function()
      local r = route.http_route({})
      T.eq(route.compose_transforms()(r), r)
    end)

    T.it("threads each transform's output into the next", function()
      local tree = fractal.api({
        list = fractal.op(noop, { http = { method = "get", moveTo = "../items" } }),
      })
      local pipeline = route.compose_transforms(route.apply_methods, route.apply_move_to, route.apply_response)
      T.eq(method_names(child_of(pipeline(route.naive_transform(tree)), "items"))[1], "GET")
    end)

  end)

  -- ── split_path ─────────────────────────────────────────────────────────

  T.describe("split_path", function()

    T.it("drops empty segments from leading, trailing, and doubled slashes", function()
      local segs = route.split_path("//books//42/")
      T.eq(#segs, 2)
      T.eq(segs[1], "books")
      T.eq(segs[2], "42")
    end)

    T.it("the root path has no segments", function()
      T.eq(#route.split_path("/"), 0)
      T.eq(#route.split_path(""), 0)
    end)

    T.it("a path with no slashes is one segment", function()
      local segs = route.split_path("books")
      T.eq(#segs, 1)
      T.eq(segs[1], "books")
    end)

  end)

  -- ── source coverage ────────────────────────────────────────────────────

  T.describe("find_route_source_coverage_problems", function()

    -- A single leaf at `/books` carrying an explicit `sources`, built by hand
    -- the way a route that bypasses naive_transform is.
    --: (method: string, sources: Sources) -> HttpRoute
    local function leaf_at_books(method, sources)
      --: { [string]: MethodEntry }
      local ms = {}
      ms[method] = { handler = noop, meta = {}, sources = sources }
      return route.http_route({
        children = { books = route.http_route({ methods = ms, meta = {} }) },
        meta = {},
      })
    end

    T.it("skips a leaf with no paramNames", function()
      -- Without a codegen-derived param list there is no fixed set to check
      -- coverage against at all.
      local r = leaf_at_books("GET", { sourceMap = { id = { store = "nowhere" } } })
      T.eq(#route.find_route_source_coverage_problems(r), 0)
    end)

    T.it("flags an override naming a store nothing builds", function()
      local r = leaf_at_books("GET", { paramNames = { "id" }, sourceMap = { id = { store = "cookie" } } })
      local problems = route.find_route_source_coverage_problems(r)
      T.eq(#problems, 1)
      T.eq(problems[1].kind, "unknown-store")
      T.eq(problems[1].param, "id")
      T.eq(problems[1].method, "GET")
      T.eq(problems[1].path, "/books")
      T.eq(problems[1].detail:find("cookie", 1, true) ~= nil, true)
    end)

    T.it("accepts an extra store named via known_stores", function()
      local r = leaf_at_books("GET", { paramNames = { "id" }, sourceMap = { id = { store = "cookie" } } })
      T.eq(#route.find_route_source_coverage_problems(r, { known_stores = { "cookie" } }), 0)
    end)

    T.it("accepts every builtin store", function()
      local stores = { "query", "header", "body", "caller" }
      for i = 1, #stores do
        local r = leaf_at_books("POST", { paramNames = { "id" }, sourceMap = { id = { store = stores[i] } } })
        T.eq(#route.find_route_source_coverage_problems(r), 0)
      end
    end)

    T.it("flags a 'path' override at a position with no slug", function()
      -- "path" is the one store whose key must actually exist at the leaf's
      -- projected position; /books has no slug segment.
      local r = leaf_at_books("POST", { paramNames = { "id" }, sourceMap = { id = { store = "path" } } })
      local problems = route.find_route_source_coverage_problems(r)
      T.eq(#problems, 1)
      T.eq(problems[1].kind, "unfillable-path")
    end)

    T.it("flags a path override whose key no segment supplies", function()
      local r = leaf_at_books("GET", { paramNames = { "id" }, sourceMap = { id = { store = "path", key = "bookId" } } })
      local problems = route.find_route_source_coverage_problems(r)
      T.eq(#problems, 1)
      T.eq(problems[1].kind, "unfillable-path")
      T.eq(problems[1].detail:find("bookId", 1, true) ~= nil, true)
    end)

    T.it("flags a sourceMap entry that is not one of the route's params", function()
      local r = leaf_at_books("GET", { paramNames = { "id" }, sourceMap = { stray = { store = "header" } } })
      local problems = route.find_route_source_coverage_problems(r)
      T.eq(#problems, 1)
      T.eq(problems[1].kind, "unused-override")
      T.eq(problems[1].param, "stray")
    end)

    T.it("an ordinary primary-store field is not a problem", function()
      T.eq(#route.find_route_source_coverage_problems(leaf_at_books("GET", { paramNames = { "id" } })), 0)
      T.eq(#route.find_route_source_coverage_problems(leaf_at_books("POST", { paramNames = { "id" } })), 0)
    end)

    T.it("a hand-built route with no authored set binds on live slugs alone", function()
      -- `authoredPathParams` ABSENT means "did not come from naive_transform",
      -- so the check falls back to the plain live-slug behavior.
      local inner = route.http_route({
        methods = { GET = { handler = noop, meta = {}, sources = { paramNames = { "id" } } } },
        meta = {},
      })
      local r = route.http_route({ fallback = { name = "id", subtree = inner }, meta = {} })
      T.eq(#route.find_route_source_coverage_problems(r), 0)
    end)

    T.it("a leaf still under its authored slug is fine", function()
      local naive = route.naive_transform(fractal.api({}, {
        fallback = { name = "id", subtree = fractal.op(noop) },
      }))
      sources_of(entry_of(fallback_of(naive).subtree, "POST")).paramNames = { "id" }
      T.eq(#route.find_route_source_coverage_problems(naive), 0)
    end)

    T.it("flags a leaf moveTo relocated away from its authored slug", function()
      local naive = route.naive_transform(fractal.api({}, {
        fallback = {
          name = "id",
          subtree = fractal.op(noop, { http = { moveTo = "../../detail" } }),
        },
      }))
      sources_of(entry_of(fallback_of(naive).subtree, "POST")).paramNames = { "id" }

      local problems = route.find_route_source_coverage_problems(route.apply_move_to(naive))
      T.eq(#problems, 1)
      T.eq(problems[1].kind, "unfillable-path")
      T.eq(problems[1].param, "id")
      T.eq(problems[1].path, "/detail")
    end)

    T.it("a name that merely COINCIDES with a live slug post-move is not path-bound", function()
      -- The leaf never authored `id` as a slug, so it stays an ordinary
      -- query/body field even though the position it landed in has an `id`
      -- segment. This is the implicit name-collision binding that was removed.
      local inner = route.http_route({
        methods = {
          GET = {
            handler = noop,
            meta = {},
            -- Empty authored set: went through naive_transform, no slugs.
            sources = { paramNames = { "id" }, authoredPathParams = {} },
          },
        },
        meta = {},
      })
      local r = route.http_route({ fallback = { name = "id", subtree = inner }, meta = {} })
      T.eq(#route.find_route_source_coverage_problems(r), 0)
    end)

    T.it("renders the path with slug segments in braces", function()
      local inner = route.http_route({
        methods = {
          GET = {
            handler = noop,
            meta = {},
            sources = { paramNames = { "x" }, sourceMap = { x = { store = "cookie" } } },
          },
        },
        meta = {},
      })
      local r = route.http_route({
        children = { books = route.http_route({ fallback = { name = "id", subtree = inner }, meta = {} }) },
        meta = {},
      })
      T.eq(route.find_route_source_coverage_problems(r)[1].path, "/books/{id}")
    end)

    T.it("reports every problem in one pass, in a stable order", function()
      --: { [string]: MethodEntry }
      local ms = {
        GET = { handler = noop, meta = {}, sources = { paramNames = { "a" }, sourceMap = { a = { store = "zzz" } } } },
        PUT = { handler = noop, meta = {}, sources = { paramNames = { "b" }, sourceMap = { b = { store = "yyy" } } } },
      }
      local r = route.http_route({
        children = {
          zebra = route.http_route({ methods = ms, meta = {} }),
          alpha = route.http_route({ methods = ms, meta = {} }),
        },
        meta = {},
      })
      --: () -> string
      local function shape()
        local problems = route.find_route_source_coverage_problems(r)
        --: { [integer]: string }
        local parts = {}
        for i = 1, #problems do
          parts[i] = problems[i].path .. " " .. problems[i].method .. " " .. problems[i].param
        end
        return table.concat(parts, "|")
      end
      local expected = "/alpha GET a|/alpha PUT b|/zebra GET a|/zebra PUT b"
      for _ = 1, 20 do T.eq(shape(), expected) end
    end)

  end)

  T.describe("check_route_source_coverage", function()

    T.it("passes silently on a clean tree", function()
      local ok = pcall(function()
        route.check_route_source_coverage(route.naive_transform(fractal.api({ a = fractal.op(noop) })))
        return nil
      end)
      T.eq(ok, true)
    end)

    T.it("errors with every problem listed, not just the first", function()
      --: { [string]: MethodEntry }
      local ms = {
        GET = {
          handler = noop,
          meta = {},
          sources = {
            paramNames = { "a" },
            sourceMap = { a = { store = "zzz" }, stray = { store = "header" } },
          },
        },
      }
      local r = route.http_route({
        children = { books = route.http_route({ methods = ms, meta = {} }) },
        meta = {},
      })
      local ok, err = pcall(function()
        route.check_route_source_coverage(r)
        return nil
      end)
      T.eq(ok, false)
      local msg = tostring(err)
      T.eq(msg:find("2 problem(s)", 1, true) ~= nil, true)
      T.eq(msg:find('param "a"', 1, true) ~= nil, true)
      T.eq(msg:find('param "stray"', 1, true) ~= nil, true)
    end)

    T.it("source_coverage_message renders one line per problem plus a header", function()
      --: { [string]: MethodEntry }
      local ms = {
        GET = { handler = noop, meta = {}, sources = { paramNames = { "a" }, sourceMap = { a = { store = "zzz" } } } },
      }
      local problems = route.find_route_source_coverage_problems(route.http_route({ methods = ms, meta = {} }))
      local msg = route.source_coverage_message(problems)
      local lines = 0
      for _ in msg:gmatch("[^\n]+") do lines = lines + 1 end
      T.eq(lines, 2)
    end)

  end)

end)
