-- lib/fractal/type_ref_json_rpc_test.lua
-- Tests for lib/fractal/type_ref_json_rpc.lua (JSON-RPC 2.0 codes + envelope).

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T       = require("lib.test.assert")
local json_rpc = require("lib.fractal.type_ref_json_rpc")

--: (v: unknown) -> v is { [string]: unknown }
local function as_record(v)
  return type(v) == "table"
end

--: (v: unknown) -> { [string]: unknown }
local function record(v)
  if not as_record(v) then error("expected a record, got " .. type(v)) end
  return v
end

T.describe("lib.fractal.type_ref_json_rpc", function()

  T.describe("standard error codes (§5.1)", function()

    T.it("are the values the specification fixes", function()
      T.eq(json_rpc.PARSE_ERROR, -32700)
      T.eq(json_rpc.INVALID_REQUEST, -32600)
      T.eq(json_rpc.METHOD_NOT_FOUND, -32601)
      T.eq(json_rpc.INVALID_PARAMS, -32602)
      T.eq(json_rpc.INTERNAL_ERROR, -32603)
      T.eq(json_rpc.SERVER_ERROR_MIN, -32099)
      T.eq(json_rpc.SERVER_ERROR_MAX, -32000)
    end)

    T.it("all sit inside the reserved -32768..-32000 range", function()
      local reserved = {
        json_rpc.PARSE_ERROR, json_rpc.INVALID_REQUEST, json_rpc.METHOD_NOT_FOUND,
        json_rpc.INVALID_PARAMS, json_rpc.INTERNAL_ERROR,
        json_rpc.SERVER_ERROR_MIN, json_rpc.SERVER_ERROR_MAX,
      }
      for i = 1, #reserved do
        T.ok(reserved[i] >= -32768 and reserved[i] <= -32000, "code " .. i .. " is in the reserved range")
      end
    end)
  end)

  T.describe("error_schema_from_data_schema", function()

    T.it("describes the fixed { code, message, data? } envelope", function()
      local schema = json_rpc.error_schema_from_data_schema(nil)
      T.eq(schema.type, "object")
      local props = record(schema.properties)
      T.eq(record(props.code).type, "integer")
      T.eq(record(props.message).type, "string")
    end)

    T.it("requires code and message, but never data", function()
      local required = record(json_rpc.error_schema_from_data_schema(nil)).required
      if type(required) ~= "table" then error("expected a required list") end
      local names = required --[[: { [integer]: unknown }]]
      T.eq(#names, 2)
      T.eq(names[1], "code")
      T.eq(names[2], "message")
    end)

    T.it("leaves data unconstrained when no schema is supplied", function()
      local props = record(record(json_rpc.error_schema_from_data_schema(nil)).properties)
      T.eq(next(record(props.data)), nil, "the empty schema constrains nothing")
    end)

    T.it("constrains data when a schema is supplied", function()
      local schema = json_rpc.error_schema_from_data_schema({ type = "string", minLength = 1 })
      local props = record(record(schema).properties)
      local data = record(props.data)
      T.eq(data.type, "string")
      T.eq(data.minLength, 1)
    end)

    T.it("builds a fresh envelope per call", function()
      -- Callers mutate schemas they are handed (a projector merges keys into
      -- one); sharing a table between methods would leak those edits.
      local a = json_rpc.error_schema_from_data_schema(nil)
      local b = json_rpc.error_schema_from_data_schema(nil)
      T.neq(a, b)
    end)
  end)
end)
