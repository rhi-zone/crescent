local mod = {}

-- ── fast boolean check (hot path, no allocation on failure) ──────────────────

mod.checkers = {}

--: <T>(Schema<T>, unknown) -> boolean
mod.check = function(schema, x)
	return mod.checkers[schema.type](schema, x)
end

mod.checkers.integer    = function(_, x) return type(x) == "number" and x % 1 == 0 end
mod.checkers.number     = function(_, x) return type(x) == "number" end
mod.checkers.string     = function(_, x) return type(x) == "string" end
mod.checkers.boolean    = function(_, x) return type(x) == "boolean" end
mod.checkers["nil"]     = function(_, x) return type(x) == "nil" end
mod.checkers.literal    = function(s, x)
	local v = s.value
	if type(v) ~= "table" or type(x) ~= "table" then return v == x end
	if v == x then return true end
	if #v ~= #x then return false end
	for k, val in pairs(v) do if x[k] ~= val then return false end end
	for k in pairs(x) do if v[k] == nil then return false end end
	return true
end
mod.checkers.tuple      = function(s, x)
	--[[checking if x is shorter is unsafe: trailing schemas may be optional]]
	if type(x) ~= "table" then return false end
	for i, s2 in ipairs(s.shape) do
		if not mod.check(s2, x[i]) then return false end
	end
	return true
end
mod.checkers.struct     = function(s, x)
	if type(x) ~= "table" then return false end
	for k, s2 in pairs(s.shape) do
		if not mod.check(s2, x[k]) then return false end
	end
	return true
end
mod.checkers.struct_exact = function(s, x)
	if type(x) ~= "table" then return false end
	for k in pairs(x) do if not s.shape[k] then return false end end
	for k, s2 in pairs(s.shape) do
		if not mod.check(s2, x[k]) then return false end
	end
	return true
end
mod.checkers.array      = function(s, x)
	if type(x) ~= "table" then return false end
	local s_item = s.item
	for _, item in ipairs(x) do if not mod.check(s_item, item) then return false end end
	return true
end
mod.checkers.dictionary = function(s, x)
	if type(x) ~= "table" then return false end
	local s_key, s_value = s.key, s.value
	for k, v in pairs(x) do
		if not mod.check(s_key, k) or not mod.check(s_value, v) then return false end
	end
	return true
end
mod.checkers.optional   = function(s, x) return x == nil or mod.check(s.inner, x) end
mod.checkers.any_of     = function(s, x)
	for i = 1, #s.types do if mod.check(s.types[i], x) then return true end end
	return false
end
mod.checkers.all_of     = function(s, x)
	for i = 1, #s.types do if not mod.check(s.types[i], x) then return false end end
	return true
end

-- ── shared helpers ────────────────────────────────────────────────────────────

-- Build a path-prefixed error string.
local function errat(path, msg)
	if path and path ~= "" then return path .. ": " .. msg end
	return msg
end

-- Extend a path with a field name or index.
local function field_path(path, k)
	if path and path ~= "" then return path .. "." .. k end
	return tostring(k)
end
local function index_path(path, i)
	return (path or "") .. "[" .. i .. "]"
end

-- ── validate: strict check, returns value or error path ──────────────────────
--
-- mod.validate(schema, x) → x, nil  |  nil, string
--
-- Returns x unchanged on success (caller can use x knowing it matches schema).
-- On failure returns nil + a human-readable path such as
--   "address.city: expected string, got nil"
-- No type coercion is performed.

local validators = {}

local function do_validate(schema, x, path)
	return validators[schema.type](schema, x, path)
end

validators.integer    = function(_, x, path)
	if type(x) == "number" and x % 1 == 0 then return x end
	return nil, errat(path, "expected integer, got " .. type(x))
end
validators.number     = function(_, x, path)
	if type(x) == "number" then return x end
	return nil, errat(path, "expected number, got " .. type(x))
end
validators.string     = function(_, x, path)
	if type(x) == "string" then return x end
	return nil, errat(path, "expected string, got " .. type(x))
end
validators.boolean    = function(_, x, path)
	if type(x) == "boolean" then return x end
	return nil, errat(path, "expected boolean, got " .. type(x))
end
validators["nil"]     = function(_, x, path)
	if x == nil then return nil end
	return nil, errat(path, "expected nil, got " .. type(x))
end
validators.literal    = function(s, x, path)
	if mod.checkers.literal(s, x) then return x end
	return nil, errat(path, "expected " .. tostring(s.value) .. ", got " .. tostring(x))
end
validators.optional   = function(s, x, path)
	if x == nil then return nil end
	return do_validate(s.inner, x, path)
end
validators.tuple      = function(s, x, path)
	if type(x) ~= "table" then
		return nil, errat(path, "expected table, got " .. type(x))
	end
	for i, s2 in ipairs(s.shape) do
		local _, err = do_validate(s2, x[i], index_path(path, i))
		if err then return nil, err end
	end
	return x
end
validators.struct     = function(s, x, path)
	if type(x) ~= "table" then
		return nil, errat(path, "expected table, got " .. type(x))
	end
	for k, s2 in pairs(s.shape) do
		local _, err = do_validate(s2, x[k], field_path(path, k))
		if err then return nil, err end
	end
	return x
end
validators.struct_exact = function(s, x, path)
	if type(x) ~= "table" then
		return nil, errat(path, "expected table, got " .. type(x))
	end
	for k in pairs(x) do
		if not s.shape[k] then
			return nil, errat(path, "unexpected field '" .. k .. "'")
		end
	end
	for k, s2 in pairs(s.shape) do
		local _, err = do_validate(s2, x[k], field_path(path, k))
		if err then return nil, err end
	end
	return x
end
validators.array      = function(s, x, path)
	if type(x) ~= "table" then
		return nil, errat(path, "expected table, got " .. type(x))
	end
	local s_item = s.item
	for i, item in ipairs(x) do
		local _, err = do_validate(s_item, item, index_path(path, i))
		if err then return nil, err end
	end
	return x
end
validators.dictionary = function(s, x, path)
	if type(x) ~= "table" then
		return nil, errat(path, "expected table, got " .. type(x))
	end
	local s_key, s_value = s.key, s.value
	for k, v in pairs(x) do
		local _, kerr = do_validate(s_key, k, (path or "") .. "[key " .. tostring(k) .. "]")
		if kerr then return nil, kerr end
		local _, verr = do_validate(s_value, v, index_path(path, tostring(k)))
		if verr then return nil, verr end
	end
	return x
end
validators.any_of     = function(s, x, path)
	for i = 1, #s.types do
		local _, err = do_validate(s.types[i], x, path)
		if not err then return x end
	end
	return nil, errat(path, "value does not match any variant")
end
validators.all_of     = function(s, x, path)
	for i = 1, #s.types do
		local _, err = do_validate(s.types[i], x, path)
		if err then return nil, err end
	end
	return x
end

--: <T>(Schema<T>, unknown) -> (T | nil, string | nil)
mod.validate = function(schema, x)
	return do_validate(schema, x, nil)
end

-- ── coerce: transform compatible types, return typed copy ────────────────────
--
-- mod.coerce(schema, x) → value, nil  |  nil, string
--
-- Like validate but also converts between compatible scalar types:
--   integer  ← number (if x%1==0), string (if tonumber gives integer)
--   number   ← string (tonumber)
--   string   ← number (tostring)
--   boolean  ← (none — booleans are strict)
-- Composite types (struct, array, tuple, dictionary) are recursively coerced
-- and a fresh copy is always returned so callers own the result.

local coercers = {}

local function do_coerce(schema, x, path)
	return coercers[schema.type](schema, x, path)
end

coercers.integer    = function(_, x, path)
	if type(x) == "number" then
		if x % 1 == 0 then return x end
		return nil, errat(path, "expected integer, got non-integer number " .. tostring(x))
	elseif type(x) == "string" then
		local n = tonumber(x)
		if n and n % 1 == 0 then return n end
		return nil, errat(path, "expected integer, cannot coerce string '" .. x .. "'")
	end
	return nil, errat(path, "expected integer, got " .. type(x))
end
coercers.number     = function(_, x, path)
	if type(x) == "number" then return x end
	if type(x) == "string" then
		local n = tonumber(x)
		if n then return n end
		return nil, errat(path, "expected number, cannot coerce string '" .. x .. "'")
	end
	return nil, errat(path, "expected number, got " .. type(x))
end
coercers.string     = function(_, x, path)
	if type(x) == "string" then return x end
	if type(x) == "number" then return tostring(x) end
	return nil, errat(path, "expected string, got " .. type(x))
end
coercers.boolean    = function(_, x, path)
	if type(x) == "boolean" then return x end
	return nil, errat(path, "expected boolean, got " .. type(x))
end
coercers["nil"]     = function(_, x, path)
	if x == nil then return nil end
	return nil, errat(path, "expected nil, got " .. type(x))
end
coercers.literal    = function(s, x, path)
	if mod.checkers.literal(s, x) then return x end
	return nil, errat(path, "expected " .. tostring(s.value) .. ", got " .. tostring(x))
end
coercers.optional   = function(s, x, path)
	if x == nil then return nil end
	return do_coerce(s.inner, x, path)
end
coercers.tuple      = function(s, x, path)
	if type(x) ~= "table" then
		return nil, errat(path, "expected table, got " .. type(x))
	end
	local out = {}
	for i, s2 in ipairs(s.shape) do
		local v, err = do_coerce(s2, x[i], index_path(path, i))
		if err then return nil, err end
		out[i] = v
	end
	return out
end
coercers.struct     = function(s, x, path)
	if type(x) ~= "table" then
		return nil, errat(path, "expected table, got " .. type(x))
	end
	local out = {}
	for k, s2 in pairs(s.shape) do
		local v, err = do_coerce(s2, x[k], field_path(path, k))
		if err then return nil, err end
		out[k] = v
	end
	return out
end
coercers.struct_exact = function(s, x, path)
	if type(x) ~= "table" then
		return nil, errat(path, "expected table, got " .. type(x))
	end
	for k in pairs(x) do
		if not s.shape[k] then
			return nil, errat(path, "unexpected field '" .. k .. "'")
		end
	end
	local out = {}
	for k, s2 in pairs(s.shape) do
		local v, err = do_coerce(s2, x[k], field_path(path, k))
		if err then return nil, err end
		out[k] = v
	end
	return out
end
coercers.array      = function(s, x, path)
	if type(x) ~= "table" then
		return nil, errat(path, "expected table, got " .. type(x))
	end
	local out = {}
	local s_item = s.item
	for i, item in ipairs(x) do
		local v, err = do_coerce(s_item, item, index_path(path, i))
		if err then return nil, err end
		out[i] = v
	end
	return out
end
coercers.dictionary = function(s, x, path)
	if type(x) ~= "table" then
		return nil, errat(path, "expected table, got " .. type(x))
	end
	local out = {}
	local s_key, s_value = s.key, s.value
	for k, v in pairs(x) do
		local ck, kerr = do_coerce(s_key, k, (path or "") .. "[key " .. tostring(k) .. "]")
		if kerr then return nil, kerr end
		local cv, verr = do_coerce(s_value, v, index_path(path, tostring(k)))
		if verr then return nil, verr end
		out[ck] = cv
	end
	return out
end
coercers.any_of     = function(s, x, path)
	for i = 1, #s.types do
		local v, err = do_coerce(s.types[i], x, path)
		if not err then return v end
	end
	return nil, errat(path, "value does not match any variant")
end
coercers.all_of     = function(s, x, path)
	-- each schema is applied in order; output of one feeds into the next
	local cur = x
	for i = 1, #s.types do
		local v, err = do_coerce(s.types[i], cur, path)
		if err then return nil, err end
		cur = v
	end
	return cur
end

--: <T>(Schema<T>, unknown) -> (T | nil, string | nil)
mod.coerce = function(schema, x)
	return do_coerce(schema, x, nil)
end

return mod
