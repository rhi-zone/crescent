-- Canonical serialization for table-native MR0 payloads.
--
-- This is deliberately narrower than JSON: it encodes deterministic tagged data
-- for certificate digests and rejects values whose MR0 representation has not
-- been specified yet.

local crypto = require("lib.cryptography")
local ffi = require("ffi")
local bit = require("bit")

local M = {}

--:: CanonResult = string | nil

ffi.cdef[[
typedef union { double d; uint64_t u; } crescent_type_v7_f64;
]]

--: (unknown) -> boolean
local function is_array(t)
	if type(t) ~= "table" then return false end
	local max = 0 --: number
	for k in pairs(t) do
		if type(k) ~= "number" then return false end
		local n = k
		if n < 1 or n % 1 ~= 0 then return false end
		if n > max then max = n end
	end
	for i = 1, max do
		if t[i] == nil then return false end
	end
	return true
end

--: (string) -> string
local function len_prefix(s)
	return tostring(#s) .. ":" .. s
end

--: ({ [integer]: string, ... }, string) -> nil
local function push(out, s)
	out[#out + 1] = s
end

--: (number) -> string
local function double_bits_hex(n)
	local u = ffi.new("crescent_type_v7_f64")
	u.d = n
	local bits = u.u
	local lo = tonumber(ffi.cast("uint32_t", bits))
	local hi = tonumber(ffi.cast("uint32_t", bit.rshift(bits, 32)))
	return string.format("%08x%08x", hi, lo)
end

--: (number) -> boolean
local function is_negative_zero(n)
	return n == 0 and 1 / n < 0
end

--: ({ [integer]: string, ... }, unknown) -> (boolean | nil, string | nil)
local function encode_into(out, value)
	if type(value) == "nil" then
		push(out, "n")
		return true
	elseif type(value) == "boolean" then
		push(out, value and "b1" or "b0")
		return true
	elseif type(value) == "string" then
		local s = value
		push(out, "s")
		push(out, len_prefix(s))
		return true
	elseif type(value) == "number" then
		local n = value
		if n ~= n then
			return nil, "canonical MR0 numbers do not admit NaN"
		end
		if n % 1 == 0 and not is_negative_zero(n) then
			push(out, "i")
			push(out, tostring(n))
		else
			push(out, "f")
			push(out, double_bits_hex(n))
		end
		return true
	elseif type(value) == "table" then
		local t = value
		if is_array(t) then
			push(out, "a")
			push(out, tostring(#t))
			push(out, "[")
			for _, item in ipairs(t) do
				local ok, msg = encode_into(out, item)
				if not ok then return nil, msg end
			end
			push(out, "]")
			return true
		end

		local keys = {}
		for k in pairs(t) do
			if type(k) ~= "string" then return nil, "canonical MR0 map keys must be strings" end
			keys[#keys + 1] = k
		end
		table.sort(keys)
		push(out, "m")
		push(out, tostring(#keys))
		push(out, "{")
		for _, key in ipairs(keys) do
			push(out, len_prefix(key))
			local ok, msg = encode_into(out, t[key])
			if not ok then return nil, msg end
		end
		push(out, "}")
		return true
	end
	return nil, "unsupported canonical MR0 value type " .. type(value)
end

--: (unknown) -> (string | nil, string | nil)
function M.serialize(value)
	local out = {}
	local ok, msg = encode_into(out, value)
	if not ok then return nil, msg end
	return table.concat(out)
end

--: (unknown) -> (string | nil, string | nil)
function M.digest(value)
	local encoded, msg = M.serialize(value)
	if not encoded then return nil, msg end
	return crypto.sha256(encoded)
end

--: (string, unknown) -> (string | nil, string | nil)
function M.term_id(sort, payload)
	local digest, msg = M.digest({ sort = sort, payload = payload })
	if not digest then return nil, msg end
	return "t:" .. digest
end

--: ({ locals: unknown, identities?: unknown, live_facts?: unknown, dependencies?: unknown, ... }) -> (string | nil, string | nil)
function M.context_id(context)
	local digest, msg = M.digest({
		locals = context.locals,
		identities = context.identities or {},
		live_facts = context.live_facts or {},
		dependencies = context.dependencies or {},
	})
	if not digest then return nil, msg end
	return "c:" .. digest
end

--: ({ family: string, rule: string, inputs?: unknown, premises?: unknown, outputs: unknown, ... }) -> (string | nil, string | nil)
function M.node_id(node)
	local digest, msg = M.digest({
		family = node.family,
		rule = node.rule,
		inputs = node.inputs or {},
		premises = node.premises or {},
		outputs = node.outputs,
	})
	if not digest then return nil, msg end
	return "n:" .. digest
end

--: ({ id: string, table_digest?: unknown, ... }) -> (string | nil, string | nil)
function M.target_digest(target)
	local digest, msg = M.digest({
		id = target.id,
		table_digest = target.table_digest,
	})
	if not digest then return nil, msg end
	return "target:" .. digest
end

--: ({ source_id: string, content?: unknown, ... }) -> (string | nil, string | nil)
function M.source_digest(source)
	local digest, msg = M.digest({
		source_id = source.source_id,
		content = source.content,
	})
	if not digest then return nil, msg end
	return "source:" .. digest
end

--: ({ decl_id: string, entries?: unknown, trust_kind?: unknown, ... }) -> (string | nil, string | nil)
function M.declaration_digest(decl)
	local digest, msg = M.digest({
		decl_id = decl.decl_id,
		entries = decl.entries or {},
		trust_kind = decl.trust_kind,
	})
	if not digest then return nil, msg end
	return "decl:" .. digest
end

--: ({ version: string, target: unknown, sources?: unknown, declarations?: unknown, terms?: unknown, contexts?: unknown, nodes?: unknown, roots: unknown, ... }) -> (string | nil, string | nil)
function M.certificate_digest(cert)
	return M.digest({
		version = cert.version,
		target = cert.target,
		sources = cert.sources or {},
		declarations = cert.declarations or {},
		terms = cert.terms or {},
		contexts = cert.contexts or {},
		nodes = cert.nodes or {},
		roots = cert.roots,
	})
end

return M
