-- Canonical projection and serialization for the typechecker framework.
--
-- This module implements the F1 value layer from
-- docs/typechecker-framework-canonicalization.md. It deliberately does not
-- validate theory schemas or replay evidence.
--
-- Byte grammar:
--   bool    ::= "b1" | "b0"
--   string  ::= "s" decimal-byte-length ":" bytes
--   integer ::= "i" canonical-decimal-integer
--   array   ::= "a" decimal-length "[" value* "]"
--   map     ::= "m" decimal-entry-count "{" (string-key value)* "}"
-- Map keys are encoded as bare length-prefixed strings and sorted before
-- encoding. Empty Lua tables encode as empty maps; schema-directed empty array
-- distinction belongs to F0/F2, not this table-native value projection.

local sha256 = require("lib.hash.sha256").sha256

local M = {}

--: (unknown) -> boolean
local function is_integer(n)
	return type(n) == "number" and n % 1 == 0
end

--: (table) -> (string | nil)
local function table_shape(t)
	local has_number = false
	local has_string = false
	local max = 0
	local count = 0
	for k in pairs(t) do
		count = count + 1
		if type(k) == "number" then
			if not is_integer(k) or k < 1 then return nil end
			has_number = true
			if k > max then max = k end
		elseif type(k) == "string" then
			has_string = true
		else
			return nil
		end
	end
	if has_number and has_string then return nil end
	if has_number then
		if max ~= count then return nil end
		for i = 1, max do
			if t[i] == nil then return nil end
		end
		return "array"
	end
	return "map"
end

--: (string) -> string
local function len_prefix(s)
	return tostring(#s) .. ":" .. s
end

--: (number) -> string
local function integer_text(n)
	if n == 0 then return "0" end
	return tostring(n)
end

--: ({ [integer]: string, ... }, string) -> nil
local function push(out, s)
	out[#out + 1] = s
end

--: (unknown, { [table]: boolean, ... } | nil) -> (unknown, string | nil)
local function project_inner(value, seen)
	local tv = type(value)
	if tv == "nil" then
		return nil, "nil is not a canonical framework value"
	elseif tv == "boolean" or tv == "string" then
		return value
	elseif tv == "number" then
		local n = value
		if n ~= n then return nil, "NaN is not a canonical framework number" end
		if n == math.huge or n == -math.huge then return nil, "infinity is not a canonical framework number" end
		if not is_integer(n) then return nil, "non-integer numbers are not admitted in framework F1" end
		return n
	elseif tv == "table" then
		local t = value
		if getmetatable(t) ~= nil then return nil, "metatables are not canonical framework values" end
		seen = seen or {}
		if seen[t] then return nil, "cyclic tables are not canonical framework values" end
		seen[t] = true
		local shape = table_shape(t)
		if not shape then
			seen[t] = nil
			return nil, "table must be a dense array or string-keyed map"
		end
		local out = {}
		if shape == "array" then
			for i = 1, #t do
				local projected, msg = project_inner(t[i], seen)
				if msg then
					seen[t] = nil
					return nil, msg
				end
				out[i] = projected
			end
		else
			for k, v in pairs(t) do
				if k ~= "meta" then
					local projected, msg = project_inner(v, seen)
					if msg then
						seen[t] = nil
						return nil, msg
					end
					out[k] = projected
				end
			end
		end
		seen[t] = nil
		return out
	end
	return nil, "unsupported canonical framework value type " .. tv
end

--: (unknown) -> (unknown, string | nil)
function M.project(value)
	return project_inner(value, nil)
end

--: ({ [integer]: string, ... }, unknown) -> (boolean | nil, string | nil)
local function encode_into(out, value)
	local tv = type(value)
	if tv == "boolean" then
		push(out, value and "b1" or "b0")
		return true
	elseif tv == "string" then
		push(out, "s")
		push(out, len_prefix(value))
		return true
	elseif tv == "number" then
		if not is_integer(value) then return nil, "non-integer number reached encoder" end
		push(out, "i")
		push(out, integer_text(value))
		return true
	elseif tv == "table" then
		local shape = table_shape(value)
		if not shape then return nil, "table must be a dense array or string-keyed map" end
		if shape == "array" then
			push(out, "a")
			push(out, tostring(#value))
			push(out, "[")
			for i = 1, #value do
				local ok, msg = encode_into(out, value[i])
				if not ok then return nil, msg end
			end
			push(out, "]")
			return true
		end
		local keys = {}
		for k in pairs(value) do
			if type(k) ~= "string" then return nil, "canonical map key must be string" end
			keys[#keys + 1] = k
		end
		table.sort(keys)
		push(out, "m")
		push(out, tostring(#keys))
		push(out, "{")
		for _, key in ipairs(keys) do
			push(out, len_prefix(key))
			local ok, msg = encode_into(out, value[key])
			if not ok then return nil, msg end
		end
		push(out, "}")
		return true
	end
	return nil, "unsupported projected framework value type " .. tv
end

--: (unknown) -> (string | nil, string | nil)
function M.serialize(value)
	local projected, msg = M.project(value)
	if msg then return nil, msg end
	local out = {}
	local ok, encode_msg = encode_into(out, projected)
	if not ok then return nil, encode_msg end
	return table.concat(out)
end

--: (unknown) -> (string | nil, string | nil)
function M.digest(value)
	local encoded, msg = M.serialize(value)
	if not encoded then return nil, msg end
	return sha256(encoded)
end

--: (string, unknown) -> (string | nil, string | nil)
function M.prefixed_digest(prefix, value)
	local digest, msg = M.digest(value)
	if not digest then return nil, msg end
	return prefix .. ":" .. digest
end

return M
