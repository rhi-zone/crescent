-- lib/openapi/openapi_test.lua

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local json = require("lib.format.json")
local openapi = require("lib.openapi")

-- ── Test spec ───────────────────────────────────────────────────────────────

local test_spec_table = {
	openapi = "3.0.3",
	info = { title = "Test API", version = "1.0.0" },
	paths = {
		["/users"] = {
			get = {
				operationId = "listUsers",
				parameters = { { name = "page", ["in"] = "query", schema = { type = "integer" } } },
				responses = {
					["200"] = {
						description = "OK",
						content = {
							["application/json"] = {
								schema = {
									type = "array",
									items = { ["$ref"] = "#/components/schemas/User" },
								},
							},
						},
					},
				},
			},
			post = {
				operationId = "createUser",
				requestBody = {
					required = true,
					content = {
						["application/json"] = {
							schema = { ["$ref"] = "#/components/schemas/NewUser" },
						},
					},
				},
				responses = { ["201"] = { description = "Created" } },
			},
		},
		["/users/{id}"] = {
			get = {
				operationId = "getUser",
				parameters = { { name = "id", ["in"] = "path", required = true, schema = { type = "integer" } } },
				responses = { ["200"] = { description = "OK" } },
			},
		},
	},
	components = {
		schemas = {
			User = {
				type = "object",
				required = { "id", "name" },
				properties = {
					id = { type = "integer" },
					name = { type = "string" },
					email = { type = "string" },
				},
			},
			NewUser = {
				type = "object",
				required = { "name" },
				properties = {
					name = { type = "string", minLength = 1 },
					email = { type = "string" },
				},
			},
		},
	},
}

local test_spec_json = json.encode(test_spec_table)

-- ── Tests ───────────────────────────────────────────────────────────────────

T.describe("openapi", function()

	T.describe("parse", function()
		T.it("parses spec from JSON string", function()
			local spec, err = openapi.parse(test_spec_json)
			T.ok(spec, "spec should not be nil")
			T.eq(err, nil)
		end)

		T.it("parses spec from table", function()
			-- Deep-copy to avoid mutation from ref resolution
			local copy = json.decode(json.encode(test_spec_table))
			local spec, err = openapi.parse_table(copy)
			T.ok(spec, "spec should not be nil")
			T.eq(err, nil)
		end)

		T.it("returns error on invalid spec (missing openapi field)", function()
			local spec, err = openapi.parse_table({ info = { title = "x", version = "1" } })
			T.eq(spec, nil)
			T.ok(err, "should have error")
			T.ok(err:find("openapi"), "error should mention openapi")
		end)

		T.it("returns error on invalid spec (missing info field)", function()
			local spec, err = openapi.parse_table({ openapi = "3.0.0" })
			T.eq(spec, nil)
			T.ok(err:find("info"), "error should mention info")
		end)

		T.it("returns error on non-string input to parse", function()
			local spec, err = openapi.parse(123)
			T.eq(spec, nil)
			T.ok(err)
		end)

		T.it("returns error on invalid JSON", function()
			local spec, err = openapi.parse("{not json}")
			T.eq(spec, nil)
			T.ok(err)
		end)
	end)

	T.describe("spec inspection", function()
		local spec
		T.it("setup", function()
			spec = openapi.parse(test_spec_json)
			T.ok(spec)
		end)

		T.it("paths() returns path list", function()
			local paths = spec:paths()
			T.ok(#paths >= 2, "should have at least 2 paths")
			-- Sort for stable comparison
			table.sort(paths)
			T.eq(paths[1], "/users")
			T.eq(paths[2], "/users/{id}")
		end)

		T.it("operations() returns all operations", function()
			local ops = spec:operations()
			T.ok(#ops >= 3, "should have at least 3 operations")
			local ids = {}
			for _, op in ipairs(ops) do
				ids[op.operationId] = true
			end
			T.ok(ids["listUsers"])
			T.ok(ids["createUser"])
			T.ok(ids["getUser"])
		end)

		T.it("operation() returns operation by id", function()
			local op = spec:operation("listUsers")
			T.ok(op)
			T.eq(op.method, "get")
			T.eq(op.path, "/users")
			T.eq(op.operationId, "listUsers")
		end)

		T.it("operation() returns nil for unknown id", function()
			T.eq(spec:operation("nonExistent"), nil)
		end)

		T.it("$ref resolution: User schema accessible via operation response", function()
			local op = spec:operation("listUsers")
			T.ok(op)
			local content = op.responses["200"].content["application/json"]
			T.ok(content)
			-- items should be resolved from $ref to the actual User schema
			local items = content.schema.items
			T.ok(items)
			T.eq(items.type, "object")
			T.ok(items.properties.id)
			T.ok(items.properties.name)
		end)
	end)

	T.describe("validate_request", function()
		local spec
		T.it("setup", function()
			spec = openapi.parse(test_spec_json)
			T.ok(spec)
		end)

		T.it("valid GET /users succeeds", function()
			local ok, errs = spec:validate_request({
				method = "GET",
				path = "/users",
				headers = {},
				query = {},
			})
			T.ok(ok, "should succeed")
			T.eq(errs, nil)
		end)

		T.it("valid GET /users with page query param", function()
			local ok, errs = spec:validate_request({
				method = "GET",
				path = "/users",
				headers = {},
				query = { page = "1" },
			})
			T.ok(ok, "should succeed")
			T.eq(errs, nil)
		end)

		T.it("POST /users with valid body succeeds", function()
			local ok, errs = spec:validate_request({
				method = "POST",
				path = "/users",
				headers = { ["content-type"] = "application/json" },
				body = json.encode({ name = "Alice" }),
				query = {},
			})
			T.ok(ok, "should succeed")
			T.eq(errs, nil)
		end)

		T.it("POST /users with missing required field fails", function()
			local ok, errs = spec:validate_request({
				method = "POST",
				path = "/users",
				headers = { ["content-type"] = "application/json" },
				body = json.encode({ email = "alice@example.com" }),
				query = {},
			})
			T.eq(ok, nil)
			T.ok(errs)
			T.ok(#errs > 0)
			-- Should mention required field
			local found = false
			for _, e in ipairs(errs) do
				if e.message:find("required") then found = true; break end
			end
			T.ok(found, "should mention 'required'")
		end)

		T.it("POST /users with empty name fails minLength", function()
			local ok, errs = spec:validate_request({
				method = "POST",
				path = "/users",
				headers = { ["content-type"] = "application/json" },
				body = json.encode({ name = "" }),
				query = {},
			})
			T.eq(ok, nil)
			T.ok(errs)
			local found = false
			for _, e in ipairs(errs) do
				if e.message:find("minLength") then found = true; break end
			end
			T.ok(found, "should mention minLength")
		end)

		T.it("unknown path returns error", function()
			local ok, errs = spec:validate_request({
				method = "GET",
				path = "/unknown",
				headers = {},
				query = {},
			})
			T.eq(ok, nil)
			T.ok(errs)
			T.ok(errs[1].message:find("path not found"))
		end)

		T.it("wrong method returns error", function()
			local ok, errs = spec:validate_request({
				method = "DELETE",
				path = "/users",
				headers = {},
				query = {},
			})
			T.eq(ok, nil)
			T.ok(errs)
			T.ok(errs[1].message:find("method not allowed"))
		end)

		T.it("GET /users/{id} with path param", function()
			local ok, errs = spec:validate_request({
				method = "GET",
				path = "/users/42",
				headers = {},
				query = {},
			})
			T.ok(ok, "should succeed")
			T.eq(errs, nil)
		end)

		T.it("POST /users with missing body when required", function()
			local ok, errs = spec:validate_request({
				method = "POST",
				path = "/users",
				headers = { ["content-type"] = "application/json" },
				body = "",
				query = {},
			})
			T.eq(ok, nil)
			T.ok(errs)
			local found = false
			for _, e in ipairs(errs) do
				if e.message:find("required") then found = true; break end
			end
			T.ok(found)
		end)

		T.it("query param type validation (non-numeric for integer)", function()
			local ok, errs = spec:validate_request({
				method = "GET",
				path = "/users",
				headers = {},
				query = { page = "abc" },
			})
			T.eq(ok, nil)
			T.ok(errs)
		end)
	end)

	T.describe("validate_response", function()
		local spec
		T.it("setup", function()
			spec = openapi.parse(test_spec_json)
			T.ok(spec)
		end)

		T.it("valid response passes", function()
			local ok, errs = spec:validate_response("listUsers", 200, {
				headers = { ["content-type"] = "application/json" },
				body = json.encode({ { id = 1, name = "Alice" } }),
			})
			T.ok(ok)
			T.eq(errs, nil)
		end)

		T.it("invalid response body fails", function()
			local ok, errs = spec:validate_response("listUsers", 200, {
				headers = { ["content-type"] = "application/json" },
				body = json.encode({ { name = "Alice" } }), -- missing id
			})
			T.eq(ok, nil)
			T.ok(errs)
		end)

		T.it("unknown operation returns error", function()
			local ok, errs = spec:validate_response("nonExistent", 200, {})
			T.eq(ok, nil)
			T.ok(errs)
		end)
	end)

	T.describe("validate_schema", function()
		T.it("validates string type", function()
			local ok = openapi.validate_schema("hello", { type = "string" })
			T.ok(ok)
			local ok2, errs = openapi.validate_schema(42, { type = "string" })
			T.eq(ok2, nil)
			T.ok(#errs > 0)
		end)

		T.it("validates integer type", function()
			local ok = openapi.validate_schema(42, { type = "integer" })
			T.ok(ok)
			local ok2, errs = openapi.validate_schema(3.14, { type = "integer" })
			T.eq(ok2, nil)
		end)

		T.it("validates number type", function()
			local ok = openapi.validate_schema(3.14, { type = "number" })
			T.ok(ok)
			local ok2 = openapi.validate_schema(42, { type = "number" })
			T.ok(ok2)
		end)

		T.it("validates boolean type", function()
			local ok = openapi.validate_schema(true, { type = "boolean" })
			T.ok(ok)
			local ok2, errs = openapi.validate_schema("true", { type = "boolean" })
			T.eq(ok2, nil)
		end)

		T.it("validates object with required fields", function()
			local schema = {
				type = "object",
				required = { "name", "age" },
				properties = {
					name = { type = "string" },
					age = { type = "integer" },
				},
			}
			local ok = openapi.validate_schema({ name = "Alice", age = 30 }, schema)
			T.ok(ok)
			local ok2, errs = openapi.validate_schema({ name = "Alice" }, schema)
			T.eq(ok2, nil)
			T.ok(#errs > 0)
		end)

		T.it("validates array with items", function()
			local schema = { type = "array", items = { type = "integer" } }
			local ok = openapi.validate_schema({ 1, 2, 3 }, schema)
			T.ok(ok)
			local ok2, errs = openapi.validate_schema({ 1, "two", 3 }, schema)
			T.eq(ok2, nil)
		end)

		T.it("validates enum", function()
			local schema = { type = "string", enum = { "a", "b", "c" } }
			local ok = openapi.validate_schema("a", schema)
			T.ok(ok)
			local ok2, errs = openapi.validate_schema("d", schema)
			T.eq(ok2, nil)
		end)

		T.it("validates minLength/maxLength", function()
			local schema = { type = "string", minLength = 2, maxLength = 5 }
			local ok = openapi.validate_schema("abc", schema)
			T.ok(ok)
			local ok2, errs = openapi.validate_schema("a", schema)
			T.eq(ok2, nil)
			local ok3, errs3 = openapi.validate_schema("abcdef", schema)
			T.eq(ok3, nil)
		end)

		T.it("validates minimum/maximum", function()
			local schema = { type = "number", minimum = 0, maximum = 100 }
			local ok = openapi.validate_schema(50, schema)
			T.ok(ok)
			local ok2, errs = openapi.validate_schema(-1, schema)
			T.eq(ok2, nil)
			local ok3, errs3 = openapi.validate_schema(101, schema)
			T.eq(ok3, nil)
		end)

		T.it("validates pattern", function()
			local schema = { type = "string", pattern = "^%d+$" }
			local ok = openapi.validate_schema("123", schema)
			T.ok(ok)
			local ok2, errs = openapi.validate_schema("abc", schema)
			T.eq(ok2, nil)
		end)

		T.it("validates allOf", function()
			local schema = {
				allOf = {
					{ type = "object", required = { "a" }, properties = { a = { type = "string" } } },
					{ type = "object", required = { "b" }, properties = { b = { type = "integer" } } },
				},
			}
			local ok = openapi.validate_schema({ a = "x", b = 1 }, schema)
			T.ok(ok)
			local ok2, errs = openapi.validate_schema({ a = "x" }, schema)
			T.eq(ok2, nil)
		end)

		T.it("validates anyOf", function()
			local schema = {
				anyOf = {
					{ type = "string" },
					{ type = "integer" },
				},
			}
			local ok = openapi.validate_schema("hello", schema)
			T.ok(ok)
			local ok2 = openapi.validate_schema(42, schema)
			T.ok(ok2)
			local ok3, errs = openapi.validate_schema(true, schema)
			T.eq(ok3, nil)
		end)

		T.it("validates oneOf", function()
			local schema = {
				oneOf = {
					{ type = "string" },
					{ type = "integer" },
				},
			}
			local ok = openapi.validate_schema("hello", schema)
			T.ok(ok)
			-- number that is both number and integer would match one (integer)
			local ok2 = openapi.validate_schema(42, schema)
			T.ok(ok2)
		end)

		T.it("validates additionalProperties false", function()
			local schema = {
				type = "object",
				properties = { a = { type = "string" } },
				additionalProperties = false,
			}
			local ok = openapi.validate_schema({ a = "x" }, schema)
			T.ok(ok)
			local ok2, errs = openapi.validate_schema({ a = "x", b = "y" }, schema)
			T.eq(ok2, nil)
			T.ok(#errs > 0)
		end)

		T.it("validates null type", function()
			local ok = openapi.validate_schema(nil, { type = "null" })
			T.ok(ok)
		end)

		T.it("nested object validation", function()
			local schema = {
				type = "object",
				properties = {
					address = {
						type = "object",
						required = { "city" },
						properties = { city = { type = "string" } },
					},
				},
			}
			local ok = openapi.validate_schema({ address = { city = "NYC" } }, schema)
			T.ok(ok)
			local ok2, errs = openapi.validate_schema({ address = { city = 42 } }, schema)
			T.eq(ok2, nil)
		end)
	end)

	T.describe("router/mount", function()
		T.it("registers routes on web app", function()
			local spec = openapi.parse(test_spec_json)
			T.ok(spec)
			local web = require("lib.web")
			local app = web.app()
			local called = {}
			spec:mount(app, {
				listUsers = function(req, res)
					called.listUsers = true
					res:json({ { id = 1, name = "Alice" } })
				end,
				createUser = function(req, res)
					called.createUser = true
					res:set_status(201):json({ id = 2, name = "Bob" })
				end,
				getUser = function(req, res)
					called.getUser = true
					res:json({ id = req.params.id, name = "Alice" })
				end,
			})
			-- Test listUsers
			local res = app:handle({ method = "GET", path = "/users" })
			T.ok(called.listUsers)
			T.eq(res.status, 200)
		end)

		T.it("router returns a web app", function()
			local spec = openapi.parse(test_spec_json)
			T.ok(spec)
			local app = spec:router({
				listUsers = function(req, res)
					res:json({})
				end,
			})
			T.ok(app)
			local res = app:handle({ method = "GET", path = "/users" })
			T.eq(res.status, 200)
		end)

		T.it("validation failure returns 400", function()
			local spec = openapi.parse(test_spec_json)
			T.ok(spec)
			local web = require("lib.web")
			local app = web.app()
			spec:mount(app, {
				createUser = function(req, res)
					res:set_status(201)
				end,
			})
			-- POST without body (required)
			local res = app:handle({
				method = "POST",
				path = "/users",
				headers = { ["content-type"] = "application/json" },
				body = "",
			})
			T.eq(res.status, 400)
		end)
	end)
end)

local s = T._summary()
print(string.format("\n%d passed, %d failed", s.pass, s.fail))
if s.fail > 0 then
	for _, t in ipairs(s.tests) do
		if not t.ok then
			print("  FAIL: " .. t.name .. (t.err and (" - " .. t.err) or ""))
		end
	end
	os.exit(1)
end
