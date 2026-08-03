-- lib/fractal/cache.lua — the IR fingerprinting primitives from fractal's
-- packages/api-tree/src/cache.ts.
--
-- SCOPE. cache.ts is a content-addressed incremental-build cache for a
-- TypeScript extract/codegen pipeline. Its two outer entry points —
-- `checkCache`/`writeCacheMetadata` and the `withCache` orchestration around
-- them — are bound to `ts.Program` (they hash the source-file set a TypeScript
-- Program parsed) and to Node's `require.resolve` (they read the installed
-- `typescript` and `fractal-type-ir` package versions as toolchain-identity
-- signals). Neither has a Lua equivalent, and neither is ported. What IS
-- ported is the tier-2 fingerprinting layer, which is pure data:
-- canonicalization plus hashing of an already-extracted IR value.
--
-- `isTsBuiltinLibFile` is likewise not ported — it exists solely to filter a
-- `ts.Program`'s file list, which nothing here produces.
--
-- DETERMINISM. The TS side relies on `JSON.stringify` preserving JS object
-- insertion order, which for a TypeRef is derived from source declaration
-- order and so is stable per source text. Lua tables carry no insertion
-- order at all, and LuaJIT randomizes hash-table iteration order per process,
-- so a `pairs()`-order serialization would not even be stable between two
-- runs of the same program on the same input. `serialize_canonical` below
-- therefore sorts every map's keys explicitly before hashing. That is a
-- correctness requirement for this module's core promise — the same IR must
-- hash the same way every run — not a stylistic preference.
--
-- These fingerprints are consequently NOT comparable with the TypeScript
-- side's: a Lua-side cache is independent, and cache metadata is not shared
-- across the language boundary.

if not package.path:find("?/init.lua", 1, true) then
	package.path = package.path .. ";./?/init.lua"
end

local fractal = require("lib.fractal")
local path    = require("lib.path")
local sha256  = require("lib.hash.sha256")

local M = {}

-- Escape a string into a quoted, unambiguous literal. Every byte outside the
-- printable ASCII range is escaped numerically, so two distinct strings can
-- never serialize identically and the output is byte-stable across platforms.
--: (s: string) -> string
local function quote(s)
	--: (c: string) -> string
	local function escape_byte(c)
		return string.format("\\%03d", c:byte())
	end
	-- Two statements, not a chain: `gsub` returns (string, count), and
	-- calling a method on that tuple loses the string type.
	local backslashed = s:gsub("[\\\"]", "\\%0")
	local escaped = backslashed:gsub("[%z\1-\31\127-\255]", escape_byte)
	return '"' .. escaped .. '"'
end

-- Narrowing wrapper over init.lua's `is_array`, so an array-shaped table can
-- be indexed positionally without a cast.
--: (v: { [unknown]: unknown }) -> v is { [integer]: unknown }
local function is_json_array(v)
	return fractal.is_array(v)
end

-- Serialize a JSON-shaped value to a canonical string: map keys sorted,
-- numbers formatted at full precision, strings escaped.
--
-- Array-vs-map is decided by init.lua's `is_array`, under which an empty
-- table is a map and so serializes as `{}`. Lua has no runtime tag
-- distinguishing an empty list from an empty record, so one of the two has to
-- be chosen; which one does not matter here, only that the choice is applied
-- consistently, since these hashes are compared only against other hashes
-- this same function produced.
--
-- Returns `(nil, errmsg)` for a value outside the JSON-shaped domain: a
-- function or userdata, or a map carrying a non-string key. The TypeScript
-- original cannot encounter either — a JS object's keys are always strings,
-- and its input is by construction a parsed IR value — so rejecting them is
-- reporting an input that was never in the domain, not a behavior of its own.
--: (value: unknown) -> (string | nil, string | nil)
local function serialize_canonical(value)
	if value == nil then return "null" end
	if type(value) == "boolean" then return tostring(value) end
	if type(value) == "number" then return string.format("%.17g", value) end
	if type(value) == "string" then return quote(value) end
	if type(value) ~= "table" then
		return nil, "cannot fingerprint a value of type " .. type(value)
	end

	if is_json_array(value) then
		local parts = {} --[[: { [integer]: string }]]
		for i = 1, #value do
			local encoded, err = serialize_canonical(value[i])
			if encoded == nil then return nil, err end
			parts[i] = encoded
		end
		return "[" .. table.concat(parts, ",") .. "]"
	end

	local keys = {} --[[: { [integer]: string }]]
	local n = 0
	for k in pairs(value) do
		if type(k) ~= "string" then
			return nil, "cannot fingerprint a table with a non-string key of type " .. type(k)
		end
		n = n + 1
		keys[n] = k
	end
	-- The explicit sort — see this module's determinism note.
	table.sort(keys)
	local parts = {} --[[: { [integer]: string }]]
	for i = 1, n do
		local key = keys[i]
		local encoded, err = serialize_canonical(value[key])
		if encoded == nil then return nil, err end
		parts[i] = quote(key) .. ":" .. encoded
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

-- Deep-copy `value` (a JSON-shaped tree), rewriting every string found under
-- a `declarationFile` key to a path relative to `root_dir`. An extracted IR
-- records the absolute path of the file a type was declared in, so without
-- this the same source checked out at two different absolute locations would
-- fingerprint differently.
--
-- General over WHERE `declarationFile` appears — any table's own key, at any
-- depth — rather than narrowed to one IR shape, so a shape that later starts
-- carrying it is covered without changing this function.
--: (value: unknown, root_dir: string) -> unknown
function M.canonicalize_for_fingerprint(value, root_dir)
	if type(value) ~= "table" then return value end
	if is_json_array(value) then
		local out = {}
		for i = 1, #value do
			out[i] = M.canonicalize_for_fingerprint(value[i], root_dir)
		end
		return out
	end
	local out = {}
	for k, v in pairs(value) do
		if k == "declarationFile" and type(v) == "string" then
			out[k] = path.relative(v, root_dir)
		else
			out[k] = M.canonicalize_for_fingerprint(v, root_dir)
		end
	end
	return out
end

-- Fingerprint one leaf's extracted IR: the sha256 of its canonical
-- serialization, with any `declarationFile` path first made relative to
-- `entry_file`'s directory so the result is portable across checkouts.
--
-- `entry_file` must be an ABSOLUTE path. The TypeScript original resolves a
-- relative one against the process working directory; doing that here would
-- mean reading the cwd out of an ambient global, which this repo's caps-first
-- rule forbids, so the caller — which has that context — resolves it.
--
-- `leaf` is whatever the caller's extraction produces per leaf (typically an
-- input/output IR pair); this function does not interpret its shape, only
-- requires that it be JSON-shaped.
--: (entry_file: string, leaf: unknown) -> (string | nil, string | nil)
function M.compute_leaf_fingerprint(entry_file, leaf)
	if not path.is_absolute(entry_file) then
		return nil, "compute_leaf_fingerprint: entry_file must be an absolute path, got " .. entry_file
	end
	local root_dir = path.dirname(entry_file)
	local encoded, err = serialize_canonical(M.canonicalize_for_fingerprint(leaf, root_dir))
	if encoded == nil then return nil, err end
	return sha256.sha256(encoded)
end

-- Rollup over every leaf's fingerprint, sorted by leaf key rather than
-- encounter order, so the rollup does not depend on extraction visiting
-- leaves in any particular order. Lets a caller decide "does this bundle need
-- rewriting at all" in one comparison instead of walking every leaf.
--: (leaf_fingerprints: { [string]: string }) -> string
function M.compute_bundle_fingerprint(leaf_fingerprints)
	local keys = {}
	local n = 0
	for k in pairs(leaf_fingerprints) do
		n = n + 1
		keys[n] = k
	end
	table.sort(keys)
	local parts = {}
	for i = 1, n do
		parts[i] = leaf_fingerprints[keys[i]]
	end
	return sha256.sha256(table.concat(parts, ""))
end

-- Fingerprint of a SET of def names — the shared/recursive names in scope for
-- one entry's compile — sorted. A leaf's own generated code depends on which
-- def NAMES are callable, not on the def bodies, so this is the second half of
-- a leaf's carry-forward safety check alongside its own fingerprint.
--: (def_names: { [integer]: string }) -> string
function M.compute_def_names_fingerprint(def_names)
	local sorted = {}
	for i = 1, #def_names do sorted[i] = def_names[i] end
	table.sort(sorted)
	return sha256.sha256(table.concat(sorted, ","))
end

return M
