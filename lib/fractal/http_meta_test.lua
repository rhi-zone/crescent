-- lib/fractal/http_meta_test.lua
-- Tests for lib/fractal/http_meta.lua (the `meta.http` accessor, verb
-- derivation from the tag lattice, and the Allow header helper).
--
-- The three-valued tag semantics are what most of these cases exist to pin:
-- an UNKNOWN tag is not a false one, so `{ destructive = true }` alone must
-- not reach DELETE (idempotent is unknown, not true) and an empty tag bag must
-- reach POST rather than any of the safer verbs.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T    = require("lib.test.assert")
local meta = require("lib.fractal.http_meta")

T.describe("lib.fractal.http_meta", function()

  -- ── get_http_meta ─────────────────────────────────────────────────────

  T.describe("get_http_meta", function()

    T.it("returns an empty bag when meta.http is absent", function()
      local h = meta.get_http_meta({})
      T.eq(h.verb, nil)
      T.eq(h.method, nil)
      T.eq(next(h --[[: { [string]: unknown }]]), nil)
    end)

    T.it("returns an empty bag when meta.http is not a table", function()
      T.eq(next(meta.get_http_meta({ http = "GET" }) --[[: { [string]: unknown }]]), nil)
      T.eq(next(meta.get_http_meta({ http = 42 }) --[[: { [string]: unknown }]]), nil)
    end)

    T.it("passes the bag through unchanged — it is a read, not a resolve", function()
      local bag = { verb = "GET", method = "GET", moveTo = "/v2/things" }
      local h = meta.get_http_meta({ http = bag })
      T.eq(h.verb, "GET")
      T.eq(h.method, "GET")
      T.eq(h.moveTo, "/v2/things")
    end)

    T.it("carries the flat bag's every key: response, paginated, validate, maps, middleware", function()
      local validator = { tag = "opaque validator" }
      --: (inner: (req: unknown) -> unknown) -> (req: unknown) -> unknown
      local function mw(inner) return inner end
      local h = meta.get_http_meta({
        http = {
          response = { status = 201, headers = { location = "/things/1" } },
          paginated = { style = "cursor", inputCursorParam = "after", inputLimitParam = "n" },
          validate = validator,
          sourceMap = { token = { store = "header", key = "authorization" } },
          encodingMap = { blob = "base64" },
          middleware = { mw },
        },
      })
      local response = h.response
      T.ok(response ~= nil, "response override survives the read")
      T.eq((response --[[: { status?: integer, headers?: { [string]: string } }]]).status, 201)
      local paginated = h.paginated
      T.eq((paginated --[[: { style?: string }]]).style, "cursor")
      -- `validate` is carried opaquely — identity, not shape, is what is
      -- promised, so the assertion is identity.
      T.eq(h.validate, validator)
      local source_map = h.sourceMap
      T.eq((source_map --[[: { [string]: { store: string, key?: string } }]]).token.store, "header")
      local middleware = h.middleware
      T.eq(#(middleware --[[: { [integer]: unknown } ]]), 1)
    end)

  end)

  -- ── verb_from_tags ────────────────────────────────────────────────────

  T.describe("verb_from_tags", function()

    T.it("an explicit meta.http.verb wins over the tags", function()
      -- readOnly would derive GET; the override must beat it outright.
      T.eq(meta.verb_from_tags({ http = { verb = "PATCH" }, tags = { readOnly = true } }), "PATCH")
    end)

    T.it("uppercases an explicit verb", function()
      T.eq(meta.verb_from_tags({ http = { verb = "delete" } }), "DELETE")
      T.eq(meta.verb_from_tags({ http = { verb = "Post" } }), "POST")
    end)

    T.it("ignores a non-string verb and falls through to the tags", function()
      T.eq(meta.verb_from_tags({ http = { verb = 7 }, tags = { readOnly = true } }), "GET")
    end)

    T.it("readOnly derives GET", function()
      T.eq(meta.verb_from_tags({ tags = { readOnly = true } }), "GET")
    end)

    T.it("readOnly wins over an explicitly idempotent+destructive pair", function()
      -- resolve_tags reports the readOnly/destructive contradiction as a
      -- conflict; verb derivation still has to produce SOMETHING, and the GET
      -- branch is checked first, so the safest verb is what comes out.
      T.eq(meta.verb_from_tags({ tags = { readOnly = true, idempotent = true, destructive = true } }), "GET")
    end)

    T.it("idempotent + destructive derives DELETE", function()
      T.eq(meta.verb_from_tags({ tags = { idempotent = true, destructive = true } }), "DELETE")
    end)

    T.it("idempotent alone derives PUT — unknown destructive is not true", function()
      T.eq(meta.verb_from_tags({ tags = { idempotent = true } }), "PUT")
    end)

    T.it("idempotent with destructive explicitly false derives PUT", function()
      T.eq(meta.verb_from_tags({ tags = { idempotent = true, destructive = false } }), "PUT")
    end)

    T.it("destructive alone derives POST — unknown idempotent is not true", function()
      T.eq(meta.verb_from_tags({ tags = { destructive = true } }), "POST")
    end)

    T.it("an empty tag bag derives POST, the conservative default", function()
      T.eq(meta.verb_from_tags({ tags = {} }), "POST")
      T.eq(meta.verb_from_tags({}), "POST")
    end)

    T.it("explicitly negated tags derive POST", function()
      T.eq(meta.verb_from_tags({ tags = { readOnly = false, idempotent = false } }), "POST")
    end)

    T.it("orthogonal tags do not affect the verb", function()
      T.eq(meta.verb_from_tags({ tags = { readOnly = true, deprecated = true, openWorld = true, streaming = true } }), "GET")
    end)

    T.it("a non-table tags value is treated as no tags", function()
      T.eq(meta.verb_from_tags({ tags = "readOnly" }), "POST")
    end)

  end)

  -- ── allow_header ──────────────────────────────────────────────────────

  T.describe("allow_header", function()

    T.it("joins with comma-space", function()
      T.eq(meta.allow_header({ "DELETE", "GET" }), "DELETE, GET")
    end)

    T.it("de-duplicates", function()
      T.eq(meta.allow_header({ "GET", "GET", "POST", "GET" }), "GET, POST")
    end)

    T.it("sorts, so the output does not depend on input order", function()
      T.eq(meta.allow_header({ "POST", "GET", "DELETE", "PUT" }), "DELETE, GET, POST, PUT")
      T.eq(meta.allow_header({ "PUT", "DELETE", "GET", "POST" }), "DELETE, GET, POST, PUT")
    end)

    T.it("is deterministic across repeated calls — the anti-hash-order property", function()
      -- De-duplication goes through a table keyed by method token, and LuaJIT
      -- randomizes hash-part iteration; without the sort this loop would be
      -- the test that catches it.
      local first = meta.allow_header({ "PATCH", "OPTIONS", "HEAD", "TRACE", "GET", "PUT", "POST", "DELETE" })
      for _ = 1, 20 do
        T.eq(meta.allow_header({ "TRACE", "GET", "DELETE", "HEAD", "POST", "PATCH", "PUT", "OPTIONS" }), first)
      end
    end)

    T.it("an empty list yields an empty string", function()
      T.eq(meta.allow_header({}), "")
    end)

    T.it("a single verb needs no separator", function()
      T.eq(meta.allow_header({ "GET" }), "GET")
    end)

  end)

end)
