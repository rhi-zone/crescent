-- lib/fractal/http_client_extension_test.lua
-- Tests for lib/fractal/http_client_extension.lua (the client extension
-- protocol).
--
-- The property under test almost everywhere is ORDER. Composition direction is
-- the one thing about this module a caller can get wrong without noticing —
-- retry wrapping interceptors and interceptors wrapping retry both "work" and
-- do different things — so nearly every case below records a call log and
-- asserts on the sequence rather than on the result alone.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T   = require("lib.test.assert")
local ext = require("lib.fractal.http_client_extension")

-- An extension whose `wrap_transport` appends `name` to `log` on the way in
-- and on the way out, so the assertions can see nesting rather than only
-- invocation order.
--: (name: string, log: { [integer]: string }) -> unknown
local function tracing_ext(name, log)
  return {
    name = name,
    --: (inner: (req: unknown) -> unknown) -> ((req: unknown) -> unknown)
    wrap_transport = function(inner)
      return function(req)
        log[#log + 1] = name .. ":in"
        local res = inner(req)
        log[#log + 1] = name .. ":out"
        return res
      end
    end,
  }
end

--: (log: { [integer]: string }) -> string
local function joined(log)
  return table.concat(log, ",")
end

T.describe("lib.fractal.http_client_extension", function()

  T.describe("compose_transport", function()

    T.it("returns the transport unchanged when there are no extensions", function()
      --: (req: unknown) -> unknown
      local function transport(req) return req end
      T.eq(ext.compose_transport(transport, nil), transport)
      T.eq(ext.compose_transport(transport, {}), transport)
    end)

    T.it("applies extensions outermost-first — the first listed wraps the rest", function()
      --: { [integer]: string }
      local log = {}
      local composed = ext.compose_transport(function(req)
        log[#log + 1] = "base"
        return req
      end, { tracing_ext("outer", log), tracing_ext("inner", log) })
      composed("req")
      T.eq(joined(log), "outer:in,inner:in,base,inner:out,outer:out")
    end)

    T.it("skips extensions that contribute no wrap_transport", function()
      --: { [integer]: string }
      local log = {}
      local composed = ext.compose_transport(function(req)
        log[#log + 1] = "base"
        return req
      end, { { name = "decoder-only" }, tracing_ext("wrapper", log) })
      composed("req")
      T.eq(joined(log), "wrapper:in,base,wrapper:out")
    end)

  end)

  T.describe("compose_decode_response", function()

    local ctx = { request = "req", refetch = function(r) return r end, meta = {}, codegen_name = nil }

    T.it("returns nil when no extension claims the response", function()
      T.eq(ext.compose_decode_response("res", ctx, nil), nil)
      T.eq(ext.compose_decode_response("res", ctx, { { name = "none" } }), nil)
    end)

    T.it("returns the first claim in listed order, not the last", function()
      local decoded = ext.compose_decode_response("res", ctx, {
        { name = "first",  decode_response = function(res, c) return { value = "first" } end },
        { name = "second", decode_response = function(res, c) return { value = "second" } end },
      })
      T.neq(decoded, nil)
      if decoded ~= nil then T.eq(decoded.value, "first") end
    end)

    T.it("treats a nil decoded value as a claim, not as declining", function()
      -- The whole reason the result is a record rather than a bare value: an
      -- SSE `event: done` frame with no payload decodes to nil legitimately.
      --: { [integer]: string }
      local reached = {}
      local decoded = ext.compose_decode_response("res", ctx, {
        { name = "claims-nil", decode_response = function(res, c) return { value = nil } end },
        { name = "later", decode_response = function(res, c)
          reached[#reached + 1] = "later"
          return { value = "later" }
        end },
      })
      T.neq(decoded, nil)
      if decoded ~= nil then T.eq(decoded.value, nil) end
      T.eq(#reached, 0)
    end)

    T.it("passes the context through to the decoder", function()
      local seen = { name = "" }
      ext.compose_decode_response("res", {
        request = "req", refetch = function(r) return r end, meta = {}, codegen_name = "books_list",
      }, {
        { name = "reader", decode_response = function(res, c)
          seen.name = c.codegen_name or ""
          return { value = nil }
        end },
      })
      T.eq(seen.name, "books_list")
    end)

  end)

  T.describe("find_streaming_call", function()

    T.it("returns nil when nothing contributes one", function()
      T.eq(ext.find_streaming_call(nil), nil)
      T.eq(ext.find_streaming_call({ { name = "a" }, { name = "b", codegen = {} } }), nil)
    end)

    T.it("returns the first contributor, since codegen needs exactly one", function()
      --: (args: unknown) -> string
      local function first(args) return "FIRST" end
      --: (args: unknown) -> string
      local function second(args) return "SECOND" end
      local found = ext.find_streaming_call({
        { name = "a", codegen = { streaming_call = first } },
        { name = "b", codegen = { streaming_call = second } },
      })
      T.eq(found, first)
    end)

  end)

  T.describe("compose_codegen_transport", function()

    T.it("leaves the expression byte-identical when there are no extensions", function()
      local expr, helpers = ext.compose_codegen_transport("base", nil)
      T.eq(expr, "base")
      T.eq(#helpers, 0)
    end)

    T.it("wraps outermost-first, so the first listed is the outermost call", function()
      local expr = ext.compose_codegen_transport("base", {
        { name = "retry", codegen = { wrap = function(inner) return "retry(" .. inner .. ")" end } },
        { name = "log",   codegen = { wrap = function(inner) return "log(" .. inner .. ")" end } },
      })
      T.eq(expr, "retry(log(base))")
    end)

    T.it("skips extensions with no codegen contribution", function()
      local expr = ext.compose_codegen_transport("base", {
        { name = "runtime-only" },
        { name = "retry", codegen = { wrap = function(inner) return "retry(" .. inner .. ")" end } },
      })
      T.eq(expr, "retry(base)")
    end)

    T.it("deduplicates identical helper blocks and emits them innermost-first", function()
      -- Innermost-first is the TS fold direction, and it is observable in
      -- generated source — see the module doc on why it is preserved rather
      -- than normalized to listed order.
      local _, helpers = ext.compose_codegen_transport("base", {
        { name = "a", codegen = { helpers = "function A() {}" } },
        { name = "b", codegen = { helpers = "function B() {}" } },
        { name = "c", codegen = { helpers = "function A() {}" } },
      })
      T.eq(#helpers, 2)
      T.eq(helpers[1], "function A() {}")
      T.eq(helpers[2], "function B() {}")
    end)

  end)

  T.describe("compose_codegen_result", function()

    T.it("returns the expression unchanged with no extensions", function()
      T.eq(ext.compose_codegen_result("__request()", "books_list", nil), "__request()")
      T.eq(ext.compose_codegen_result("__request()", "books_list", {}), "__request()")
    end)

    T.it("wraps outermost-first and threads the codegen name", function()
      local expr = ext.compose_codegen_result("__request()", "books_list", {
        { name = "outer", codegen = { wrap_result = function(inner, n) return "outer(" .. inner .. "," .. n .. ")" end } },
        { name = "inner", codegen = { wrap_result = function(inner, n) return "inner(" .. inner .. ")" end } },
      })
      T.eq(expr, "outer(inner(__request()),books_list)")
    end)

  end)

  T.describe("collect_result_helpers", function()

    T.it("returns an empty list when nothing contributes", function()
      T.eq(#ext.collect_result_helpers({}, nil), 0)
      T.eq(#ext.collect_result_helpers({}, { { name = "a", codegen = {} } }), 0)
    end)

    T.it("collects in listed order and drops nil contributions", function()
      --: { [integer]: unknown }
      local ops = { { codegen_name = "books_list", response_schema = nil } }
      local helpers = ext.collect_result_helpers(ops, {
        { name = "first",  codegen = { result_helpers = function(o) return "FIRST:" .. tostring(#o) end } },
        { name = "silent", codegen = { result_helpers = function(o) return nil end } },
        { name = "last",   codegen = { result_helpers = function(o) return "LAST" end } },
      })
      T.eq(#helpers, 2)
      T.eq(helpers[1], "FIRST:1")
      T.eq(helpers[2], "LAST")
    end)

  end)

end)
