-- lib/type/v10_kernel/registry.lua
-- Theory registry: untrusted rule-schemas register once, by SHAPE only.
--
-- `register` checks a schema's own structure (right fields, right types).
-- It never checks the schema's soundness — that responsibility stays with
-- whoever registers it (the "theory," e.g. w.lua's Algorithm W rules). The
-- kernel (kernel.lua) trusts a registry's contents when replaying a
-- certificate that cites them; this module is what makes a citation
-- resolvable in the first place.

local M = {}

--:: RuleSchema = { name: string, judgment: string, arity: integer, assumes?: boolean, discharges?: boolean }
--:: Registry = { theory: string, schemas: { [string]: RuleSchema } }

--: (string) -> Registry
function M.new(theory)
	return { theory = theory, schemas = {} }
end

--: (unknown) -> (boolean | nil, string | nil)
local function validate_shape(schema)
	if type(schema) ~= "table" then return nil, "schema must be a table" end
	if type(schema.name) ~= "string" or schema.name == "" then
		return nil, "schema.name must be a nonempty string"
	end
	if type(schema.judgment) ~= "string" or schema.judgment == "" then
		return nil, "schema.judgment must be a nonempty string"
	end
	local arity = schema.arity
	if type(arity) ~= "number" then
		return nil, "schema.arity must be a nonnegative integer"
	end
	if arity < 0 or arity ~= math.floor(arity) then
		return nil, "schema.arity must be a nonnegative integer"
	end
	if schema.assumes ~= nil and type(schema.assumes) ~= "boolean" then
		return nil, "schema.assumes must be a boolean when present"
	end
	if schema.discharges ~= nil and type(schema.discharges) ~= "boolean" then
		return nil, "schema.discharges must be a boolean when present"
	end
	return true
end

-- Register `schema` into `registry`, checking only its own shape (never its
-- soundness). Rejects a second registration under the same name — a theory
-- registers each rule once.
--: (Registry, RuleSchema) -> (boolean | nil, string | nil)
function M.register(registry, schema)
	local ok, msg = validate_shape(schema)
	if not ok then return nil, msg end
	if registry.schemas[schema.name] then
		return nil, "rule schema already registered: " .. schema.name
	end
	registry.schemas[schema.name] = schema
	return true
end

--: (Registry, string) -> RuleSchema | nil
function M.lookup(registry, name)
	return registry.schemas[name]
end

return M
