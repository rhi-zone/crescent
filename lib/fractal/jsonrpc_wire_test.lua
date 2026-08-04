-- lib/fractal/jsonrpc_wire_test.lua
-- Tests for lib/fractal/jsonrpc_wire.lua (JSON-RPC 2.0 wire shapes).

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T    = require("lib.test.assert")
local json = require("lib.format.json")
local null = require("lib.null")
local wire = require("lib.fractal.jsonrpc_wire")

--: (v: unknown) -> v is { [string]: unknown }
local function as_record(v)
  return type(v) == "table"
end

-- The `error` member of a response, as a record, so its fields can be read.
--: (res: unknown) -> { [string]: unknown }
local function error_of(res)
  if not as_record(res) then error("error_of: not a table") end
  local e = res.error
  if not as_record(e) then error("error_of: response carries no error object") end
  return e
end

T.describe("lib.fractal.jsonrpc_wire", function()

  T.describe("standard error codes (§5.1)", function()

    T.it("carries the spec's own values", function()
      T.eq(wire.PARSE_ERROR, -32700)
      T.eq(wire.INVALID_REQUEST, -32600)
      T.eq(wire.METHOD_NOT_FOUND, -32601)
      T.eq(wire.INVALID_PARAMS, -32602)
      T.eq(wire.INTERNAL_ERROR, -32603)
    end)

    T.it("bounds the implementation-defined server-error range", function()
      T.eq(wire.SERVER_ERROR_MIN, -32099)
      T.eq(wire.SERVER_ERROR_MAX, -32000)
    end)
  end)

  T.describe("NULL", function()

    T.it("is the shared sentinel, not a private one", function()
      T.eq(wire.NULL, null.null)
    end)

    T.it("serializes as JSON null", function()
      T.eq(json.encode({ wire.NULL }), "[null]")
    end)
  end)

  T.describe("error_response", function()

    T.it("frames jsonrpc/error/id (§5.1)", function()
      local res = wire.error_response(1, -32600, "Invalid Request", nil)
      T.eq(res.jsonrpc, "2.0")
      T.eq(res.id, 1)
      T.eq(error_of(res).code, -32600)
      T.eq(error_of(res).message, "Invalid Request")
    end)

    T.it("omits data entirely when none is supplied", function()
      local res = wire.error_response(wire.NULL, -32700, "Parse error", nil)
      T.eq(error_of(res).data, nil)
      -- An absent `data` key and a `data: null` are different messages; only
      -- the former means "no extra information".
      T.eq(json.encode(res):find("data", 1, true), nil)
    end)

    T.it("carries data when supplied", function()
      local res = wire.error_response(2, -32602, "Invalid params", { kind = "notFound" })
      local data = error_of(res).data
      if not as_record(data) then error("expected a data record") end
      T.eq(data.kind, "notFound")
    end)

    T.it("keeps a null id null rather than dropping it", function()
      local res = wire.error_response(wire.NULL, -32600, "Invalid Request", nil)
      T.eq(res.id, wire.NULL)
      T.ok(json.encode(res):find('"id":null', 1, true) ~= nil, "id must serialize as null")
    end)
  end)

  T.describe("success_response", function()

    T.it("frames jsonrpc/result/id (§5)", function()
      local res = wire.success_response(7, 19)
      T.eq(res.jsonrpc, "2.0")
      T.eq(res.result, 19)
      T.eq(res.id, 7)
    end)

    T.it("renders a nil result as null, never an absent key", function()
      local res = wire.success_response(7, nil)
      T.eq(res.result, wire.NULL)
      T.ok(json.encode(res):find('"result":null', 1, true) ~= nil,
        "§5 requires a result member on every successful response")
    end)

    T.it("passes false through untouched", function()
      -- `false` is a legitimate result and is not nil; the nil-to-null rule
      -- must not catch it.
      T.eq(wire.success_response(1, false).result, false)
    end)
  end)

  T.describe("is_error_response", function()

    T.it("is true for an error response", function()
      T.eq(wire.is_error_response(wire.error_response(1, -32603, "Internal error", nil)), true)
    end)

    T.it("is false for a success response", function()
      T.eq(wire.is_error_response(wire.success_response(1, "ok")), false)
    end)

    T.it("is false for a success response whose result is null", function()
      T.eq(wire.is_error_response(wire.success_response(1, nil)), false)
    end)
  end)

  T.describe("is_request_shape", function()

    T.it("accepts a minimal Request object", function()
      T.eq(wire.is_request_shape({ jsonrpc = "2.0", method = "ping" }), true)
    end)

    T.it("accepts a Notification (no id)", function()
      T.eq(wire.is_request_shape({ jsonrpc = "2.0", method = "ping", params = {} }), true)
    end)

    T.it("rejects a wrong protocol version", function()
      T.eq(wire.is_request_shape({ jsonrpc = "1.0", method = "ping" }), false)
    end)

    T.it("rejects a missing version", function()
      T.eq(wire.is_request_shape({ method = "ping" }), false)
    end)

    T.it("rejects a non-string method (§4)", function()
      T.eq(wire.is_request_shape({ jsonrpc = "2.0", method = 1 }), false)
    end)

    T.it("rejects a missing method", function()
      T.eq(wire.is_request_shape({ jsonrpc = "2.0", id = 1 }), false)
    end)

    T.it("rejects an array — a batch element that is not an object", function()
      T.eq(wire.is_request_shape({ 1, 2, 3 }), false)
    end)

    T.it("rejects non-tables", function()
      T.eq(wire.is_request_shape(1), false)
      T.eq(wire.is_request_shape("ping"), false)
      T.eq(wire.is_request_shape(nil), false)
      T.eq(wire.is_request_shape(true), false)
    end)
  end)
end)
