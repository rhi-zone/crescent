-- Phase 4g — Content-addressed cache primitives.
--
-- Rewrite design §10 commits the typechecker to a content-addressed interface
-- cache (`.cri` pattern), keyed by SHA-256 of source content. This module
-- supplies the four primitives that pattern needs, operating on V4Type values
-- only — no AST, no constraint graph, no solver state. The unit of caching is
-- the *export interface type* a file declares (or that constraint generation
-- inferred for it); coupling the cache to internal solver state would make
-- every solver change invalidate every cached file.
--
-- Public surface:
--
--   M.serialize(type)             -> bytes
--   M.deserialize(bytes)          -> V4Type | nil, errmsg | nil
--   M.content_hash(bytes)         -> sha256-hex
--   M.serialize_manifest(m)       -> bytes
--   M.deserialize_manifest(bytes) -> Manifest | nil, errmsg | nil
--   M.cache_lookup(caps, dir, source_hash) -> bytes | nil
--   M.cache_store(caps, dir, source_hash, type, deps?)
--
-- The cache_lookup / cache_store primitives accept an `io_caps` capability
-- table — they do NOT reach for `os` / `io` directly. CLAUDE.md "Caps-first,
-- everywhere": injection is not optional, defaulting to globals is also a
-- violation. `caps` must supply `read_file`, `write_file`, `mkdir`, and
-- `file_exists`. Absence is an error, not a fallback.
--
-- ── Serialization format ──────────────────────────────────────────────────
--
-- A custom binary encoding. Considered alternatives:
--
--   * Lua-syntax via `load()` with an empty environment. Compact and
--     human-readable, but determinism is fragile — `string.format("%q", s)`,
--     numeric printing, and table iteration order all need careful
--     normalization to make the hash stable. The discipline required is
--     exactly the same as a binary format, with extra debugging surface
--     when something drifts.
--   * JSON. Verbose, slow to parse, and Lua has no first-class JSON in the
--     standard library; pulling one in just for cache contents is a
--     dependency the rewrite shouldn't take.
--
-- Binary is the principled answer for *cache contents* (a machine-readable
-- artifact, never edited by hand). It avoids parse/escape complexity and
-- makes the hash deterministic by construction: every byte is placed by
-- code, no `%g` rounding, no string escaping decisions.
--
-- ── Determinism ───────────────────────────────────────────────────────────
--
-- Hash determinism requires *byte-identical* serialization for structurally
-- equal types regardless of construction order. This module enforces it:
--
--   * Record fields are emitted with `pairs`-iteration order replaced by
--     lexicographic sort over keys.
--   * Effect sets are emitted with names sorted lexicographically.
--   * Union/intersection members are emitted in their stored order. Member
--     order IS part of the type's identity — `A | B` and `B | A` round-trip
--     identically each, and a caller that wants order-independent equality
--     must canonicalize before serializing. (Imposing canonicalization here
--     would mis-attribute hashes for types the rest of the v4 lattice does
--     distinguish; canonicalization is a coalescing concern, not a cache
--     concern.)
--   * Manifest entries are emitted with sorted source-hash keys, and each
--     entry's deps map is emitted with sorted path keys.
--
-- ── μ types and sharing ───────────────────────────────────────────────────
--
-- `μX. T(X)` is represented as a cyclic Lua table (the `mu` node references
-- itself inside `body`). Serialization assigns each visited μ-node a
-- serialization-local index on first encounter and emits MU_DEF; subsequent
-- visits to the same node emit MU_REF with the same index. Deserialization
-- allocates a placeholder μ-table before recursing into the body, populates
-- the back-reference table, and overwrites the placeholder's `body` after
-- the body is decoded. This preserves table identity for the cycle.
--
-- V4Vars are handled identically: a var may appear in multiple constructor
-- positions (one occurrence per use site, plus self-reference through its
-- own bound lists). The same index/back-reference protocol applies.
--
-- ── What is NOT cached ────────────────────────────────────────────────────
--
-- - Var ids and skolem ids from the producing process. They are local to the
--   solver run that produced the type. The serializer emits them so the
--   reader can reconstruct equality at the *table* level, but the readable-
--   side ids are fresh — they are NOT meaningful to compare against ids
--   from the producer.
-- - Solver caches, constraint graphs, or any other transient state.

local sha256_mod = require("lib.hash.sha256")
local T          = require("lib.type.static-v4.types")

local M = {}

-- ── Byte writers / readers ────────────────────────────────────────────────

-- Append helper. The writer state is a list of byte chunks (strings); we
-- table.concat at the end to avoid quadratic string-append cost. The state
-- is annotated open (`...`) because different call sites carry different
-- companion fields (var_idx/mu_idx/next_idx on the type serializer; nothing
-- extra on the manifest serializer).
--: ({ buf: string[], ... }, string) -> nil
local function w(s, b)
	s.buf[#s.buf + 1] = b
end

-- Encode a 32-bit unsigned integer as little-endian 4 bytes. Used for
-- lengths, counts, and ids.
--: (integer) -> string
local function u32(n)
	local b0 = n % 256
	local b1 = math.floor(n / 256) % 256
	local b2 = math.floor(n / 65536) % 256
	local b3 = math.floor(n / 16777216) % 256
	return string.char(b0, b1, b2, b3)
end

-- In-place insertion sort. We avoid `table.sort` here because this module is
-- checked by the static typechecker (lib/type/static), which has trouble
-- re-instantiating `table.sort`'s generic `V` parameter when multiple calls
-- in one scope use different element types — the V can pin to the first
-- call's binding. Two monomorphic helpers sidestep that. The lists we sort
-- are tiny (record-field keys, effect names, dep paths, var-id sets) so
-- the O(n²) cost is irrelevant — keys per record/manifest are bounded by
-- the file's structure.

--: ({ [integer]: string }) -> nil
local function sort_strs(xs)
	for i = 2, #xs do
		local x = xs[i]
		if x ~= nil then
			local j = i - 1
			while j >= 1 do
				local y = xs[j]
				if y == nil or y <= x then break end
				xs[j + 1] = y
				j = j - 1
			end
			xs[j + 1] = x
		end
	end
end

--: ({ [integer]: integer }) -> nil
local function sort_ints(xs)
	for i = 2, #xs do
		local x = xs[i]
		if x ~= nil then
			local j = i - 1
			while j >= 1 do
				local y = xs[j]
				if y == nil or y <= x then break end
				xs[j + 1] = y
				j = j - 1
			end
			xs[j + 1] = x
		end
	end
end

--: (string, integer) -> (integer, integer)
local function read_u32(bytes, pos)
	if pos + 3 > #bytes then error("read_u32: EOF") end
	local b0 = bytes:byte(pos)
	local b1 = bytes:byte(pos + 1)
	local b2 = bytes:byte(pos + 2)
	local b3 = bytes:byte(pos + 3)
	if b0 == nil or b1 == nil or b2 == nil or b3 == nil then
		error("read_u32: byte EOF")
	end
	-- After the nil-guard the four bytes are integer-valued. Use checked
	-- casts to make this explicit for the typechecker (the stdlib `byte`
	-- signature has a multi-return overload that interferes with narrowing
	-- through the conjunction above).
	local i0 = b0 --[[: integer]]
	local i1 = b1 --[[: integer]]
	local i2 = b2 --[[: integer]]
	local i3 = b3 --[[: integer]]
	local n = i0 + i1 * 256 + i2 * 65536 + i3 * 16777216
	return math.floor(n), pos + 4
end

--: ({ buf: string[], ... }, string) -> nil
local function w_str(s, str)
	w(s, u32(#str))
	w(s, str)
end

--: (string, integer) -> (string, integer)
local function read_str(bytes, pos)
	local len, p = read_u32(bytes, pos)
	if p + len - 1 > #bytes then error("read_str: EOF") end
	return bytes:sub(p, p + len - 1), p + len
end

-- Encode a Lua number as 8 little-endian bytes via a ULEB-ish split. We do
-- NOT use string.pack (Lua 5.1 / LuaJIT lacks it without compat). Instead,
-- represent the value as its decimal/integer text form, length-prefixed.
-- This keeps the encoding deterministic across platforms (no float endian
-- concerns) and exact for integers up to 2^53. Literals beyond that range
-- are rare in practice (the typechecker never sees an exact runtime float
-- as a literal type unless the user wrote one).
--: ({ buf: string[], ... }, number) -> nil
local function w_num(s, n)
	-- "%.17g" round-trips a double exactly per IEEE-754; standard practice.
	w_str(s, string.format("%.17g", n))
end

--: (string, integer) -> (number, integer)
local function read_num(bytes, pos)
	local txt, p = read_str(bytes, pos)
	local n = tonumber(txt)
	if n == nil then error("read_num: not a number: " .. txt) end
	return n, p
end

-- ── Tag bytes ─────────────────────────────────────────────────────────────

local TAG_TOP      = 0x01
local TAG_BOT      = 0x02
local TAG_PRIM     = 0x03
local TAG_LIT_NIL  = 0x04
local TAG_LIT_BOOL = 0x05
local TAG_LIT_NUM  = 0x06
local TAG_LIT_STR  = 0x07
local TAG_FN       = 0x08
local TAG_REC      = 0x09
local TAG_UNION    = 0x0A
local TAG_INTER    = 0x0B
local TAG_NEG      = 0x0C
local TAG_MU_DEF   = 0x0D
local TAG_MU_REF   = 0x0E
local TAG_VAR_DEF  = 0x0F
local TAG_VAR_REF  = 0x10
local TAG_FORALL   = 0x11
local TAG_SKOLEM   = 0x12

-- Magic + version. Bumped if the format ever evolves so a stale cache file
-- is rejected loudly rather than silently misinterpreted.
local MAGIC   = "CRI4"
local VERSION = 1

-- ── Serialization ─────────────────────────────────────────────────────────

local emit -- forward
--: ({ buf: string[], var_idx: { [integer]: integer }, mu_idx: { [integer]: integer }, next_idx: integer }, V4Type) -> nil
emit = function(s, t)
	if t.tag == "top" then
		w(s, string.char(TAG_TOP))
	elseif t.tag == "bot" then
		w(s, string.char(TAG_BOT))
	elseif t.tag == "prim" then
		w(s, string.char(TAG_PRIM))
		w_str(s, t.name)
	elseif t.tag == "literal" then
		if t.base == "nil" then
			w(s, string.char(TAG_LIT_NIL))
		elseif t.base == "boolean" then
			w(s, string.char(TAG_LIT_BOOL))
			local v = t.value
			if v == true then
				w(s, string.char(1))
			else
				w(s, string.char(0))
			end
		elseif t.base == "number" or t.base == "integer" then
			w(s, string.char(TAG_LIT_NUM))
			w_str(s, t.base)
			-- Literal numeric value: typed as `unknown` in V4Type; the cast
			-- below narrows to number for the writer. If the value is not a
			-- number the serializer errors — a literal with a non-numeric
			-- value but a numeric base is malformed.
			local v = t.value
			if type(v) ~= "number" then
				error("literal with base " .. t.base .. " has non-numeric value")
			end
			w_num(s, v)
		elseif t.base == "string" then
			w(s, string.char(TAG_LIT_STR))
			local v = t.value
			if type(v) ~= "string" then
				error("literal with base string has non-string value")
			end
			w_str(s, v)
		else
			error("unknown literal base: " .. tostring(t.base))
		end
	elseif t.tag == "fn" then
		w(s, string.char(TAG_FN))
		w(s, u32(#t.params))
		for _, p in ipairs(t.params) do emit(s, p) end
		emit(s, t.ret)
		-- Effects: sort names so the encoding is deterministic.
		local names = {} --[[: { [integer]: string } ]]
		for name in pairs(t.effects) do names[#names + 1] = name end
		sort_strs(names)
		w(s, u32(#names))
		for _, n in ipairs(names) do w_str(s, n) end
	elseif t.tag == "rec" then
		w(s, string.char(TAG_REC))
		if t.open then w(s, string.char(1)) else w(s, string.char(0)) end
		-- Fields: sort keys for determinism.
		local keys = {} --[[: { [integer]: string } ]]
		for k in pairs(t.fields) do keys[#keys + 1] = k end
		sort_strs(keys)
		w(s, u32(#keys))
		for _, k in ipairs(keys) do
			w_str(s, k)
			local v = t.fields[k]
			if v == nil then error("nil field value for key " .. k) end
			emit(s, v --[[: V4Type]])
		end
		local ix = t.indexer
		if ix == nil then
			w(s, string.char(0))
		else
			w(s, string.char(1))
			emit(s, ix.key)
			emit(s, ix.value)
		end
	elseif t.tag == "union" then
		w(s, string.char(TAG_UNION))
		w(s, u32(#t.members))
		for _, m in ipairs(t.members) do emit(s, m) end
	elseif t.tag == "inter" then
		w(s, string.char(TAG_INTER))
		w(s, u32(#t.members))
		for _, m in ipairs(t.members) do emit(s, m) end
	elseif t.tag == "neg" then
		w(s, string.char(TAG_NEG))
		emit(s, t.body)
	elseif t.tag == "mu" then
		local existing = s.mu_idx[t.id]
		if existing ~= nil then
			w(s, string.char(TAG_MU_REF))
			w(s, u32(existing))
			return
		end
		local idx = s.next_idx
		s.next_idx = idx + 1
		s.mu_idx[t.id] = idx
		w(s, string.char(TAG_MU_DEF))
		w(s, u32(idx))
		emit(s, t.body)
	elseif t.tag == "var" then
		local existing = s.var_idx[t.id]
		if existing ~= nil then
			w(s, string.char(TAG_VAR_REF))
			w(s, u32(existing))
			return
		end
		local idx = s.next_idx
		s.next_idx = idx + 1
		s.var_idx[t.id] = idx
		w(s, string.char(TAG_VAR_DEF))
		w(s, u32(idx))
		w_str(s, t.name)
		w(s, u32(#t.lower))
		for _, b in ipairs(t.lower) do emit(s, b) end
		w(s, u32(#t.upper))
		for _, b in ipairs(t.upper) do emit(s, b) end
		-- lower_vars / upper_vars: emit as sorted-by-id lists so the encoding
		-- is deterministic. The map ids are local to the producer, but the
		-- iteration order would otherwise depend on Lua's hash-part layout.
		local lv_keys = {} --[[: { [integer]: integer } ]]
		for k in pairs(t.lower_vars) do lv_keys[#lv_keys + 1] = k end
		sort_ints(lv_keys)
		w(s, u32(#lv_keys))
		for _, k in ipairs(lv_keys) do
			local vp = t.lower_vars[k]
			if vp == nil then error("nil lower_vars entry") end
			emit(s, vp --[[: V4Type]])
		end
		local uv_keys = {} --[[: { [integer]: integer } ]]
		for k in pairs(t.upper_vars) do uv_keys[#uv_keys + 1] = k end
		sort_ints(uv_keys)
		w(s, u32(#uv_keys))
		for _, k in ipairs(uv_keys) do
			local vp = t.upper_vars[k]
			if vp == nil then error("nil upper_vars entry") end
			emit(s, vp --[[: V4Type]])
		end
	elseif t.tag == "forall" then
		w(s, string.char(TAG_FORALL))
		w(s, u32(#t.vars))
		-- Bound vars: emit each as a VAR_DEF (registering its index) so the
		-- body can back-reference them. This must happen in order before the
		-- body so refs resolve.
		for _, v in ipairs(t.vars) do emit(s, v) end
		emit(s, t.body)
	elseif t.tag == "skolem" then
		w(s, string.char(TAG_SKOLEM))
		-- The skolem id is producer-local. We emit it for deterministic
		-- ordering only; on read, we mint a fresh skolem (preserving name).
		w(s, u32(t.id))
		w_str(s, t.name)
	else
		error("emit: unknown tag " .. tostring(t.tag))
	end
end

--: (V4Type) -> string
function M.serialize(type_)
	local s = {
		buf      = {} --[[: { [integer]: string } ]],
		var_idx  = {} --[[: { [integer]: integer } ]],
		mu_idx   = {} --[[: { [integer]: integer } ]],
		next_idx = 0,
	}
	w(s, MAGIC)
	w(s, u32(VERSION))
	emit(s, type_)
	return table.concat(s.buf)
end

-- ── Deserialization ───────────────────────────────────────────────────────

local read_type -- ({ bytes: string, pos: integer, refs: { [integer]: V4Type } }) -> V4Type
--: ({ bytes: string, pos: integer, refs: { [integer]: V4Type } }) -> V4Type
read_type = function(s)
	if s.pos > #s.bytes then error("read_type: EOF") end
	local tag = s.bytes:byte(s.pos)
	s.pos = s.pos + 1
	if tag == TAG_TOP then
		return T.top()
	elseif tag == TAG_BOT then
		return T.bot()
	elseif tag == TAG_PRIM then
		local name; name, s.pos = read_str(s.bytes, s.pos)
		return T.prim(name)
	elseif tag == TAG_LIT_NIL then
		return T.literal("nil", nil)
	elseif tag == TAG_LIT_BOOL then
		if s.pos > #s.bytes then error("read TAG_LIT_BOOL: EOF") end
		local b = s.bytes:byte(s.pos); s.pos = s.pos + 1
		return T.literal("boolean", b ~= 0)
	elseif tag == TAG_LIT_NUM then
		local base; base, s.pos = read_str(s.bytes, s.pos)
		local v; v, s.pos = read_num(s.bytes, s.pos)
		return T.literal(base, v)
	elseif tag == TAG_LIT_STR then
		local v; v, s.pos = read_str(s.bytes, s.pos)
		return T.literal("string", v)
	elseif tag == TAG_FN then
		local n; n, s.pos = read_u32(s.bytes, s.pos)
		local params = {} --[[: V4Type[] ]]
		for i = 1, n do params[i] = read_type(s) end
		local ret = read_type(s)
		local en; en, s.pos = read_u32(s.bytes, s.pos)
		local effs = {} --[[: { [string]: boolean } ]]
		for _ = 1, en do
			local name; name, s.pos = read_str(s.bytes, s.pos)
			effs[name] = true
		end
		return T.fn(params, ret, effs)
	elseif tag == TAG_REC then
		if s.pos > #s.bytes then error("read TAG_REC: EOF") end
		local open = s.bytes:byte(s.pos) ~= 0; s.pos = s.pos + 1
		local n; n, s.pos = read_u32(s.bytes, s.pos)
		local fields = {} --[[: { [string]: V4Type } ]]
		for _ = 1, n do
			local k; k, s.pos = read_str(s.bytes, s.pos)
			fields[k] = read_type(s)
		end
		if s.pos > #s.bytes then error("read TAG_REC: EOF") end
		local has_ix = s.bytes:byte(s.pos) ~= 0; s.pos = s.pos + 1
		local ix = nil --[[: V4Indexer | nil]]
		if has_ix then
			local k = read_type(s)
			local v = read_type(s)
			ix = T.indexer(k, v)
		end
		return T.rec(fields, open, ix)
	elseif tag == TAG_UNION then
		local n; n, s.pos = read_u32(s.bytes, s.pos)
		local ms = {} --[[: V4Type[] ]]
		for i = 1, n do ms[i] = read_type(s) end
		return T.union(ms)
	elseif tag == TAG_INTER then
		local n; n, s.pos = read_u32(s.bytes, s.pos)
		local ms = {} --[[: V4Type[] ]]
		for i = 1, n do ms[i] = read_type(s) end
		return T.inter(ms)
	elseif tag == TAG_NEG then
		return T.neg(read_type(s))
	elseif tag == TAG_MU_DEF then
		local idx; idx, s.pos = read_u32(s.bytes, s.pos)
		-- Allocate placeholder so back-references can resolve while we
		-- decode the body. The body must be cyclic (refers to this μ via
		-- a TAG_MU_REF); on return we overwrite `body` with the decoded
		-- value, preserving Lua table identity.
		local node = T.mu(T.top() --[[: V4Type]]) --[[: V4Type]]
		s.refs[idx] = node
		local body = read_type(s)
		if node.tag == "mu" then node.body = body end
		return node
	elseif tag == TAG_MU_REF then
		local idx; idx, s.pos = read_u32(s.bytes, s.pos)
		local r = s.refs[idx]
		if r == nil then error("TAG_MU_REF: unknown idx " .. tostring(idx)) end
		return r --[[: V4Type]]
	elseif tag == TAG_VAR_DEF then
		local idx; idx, s.pos = read_u32(s.bytes, s.pos)
		local name; name, s.pos = read_str(s.bytes, s.pos)
		-- Allocate the var first (so bounds can reference it via VAR_REF).
		local v = T.var(name) --[[: V4Type]]
		s.refs[idx] = v
		local nlow; nlow, s.pos = read_u32(s.bytes, s.pos)
		if v.tag == "var" then
			for _ = 1, nlow do v.lower[#v.lower + 1] = read_type(s) end
		end
		local nup; nup, s.pos = read_u32(s.bytes, s.pos)
		if v.tag == "var" then
			for _ = 1, nup do v.upper[#v.upper + 1] = read_type(s) end
		end
		local nlv; nlv, s.pos = read_u32(s.bytes, s.pos)
		for _ = 1, nlv do
			local other = read_type(s)
			if v.tag == "var" and other.tag == "var" then
				v.lower_vars[other.id] = other
			end
		end
		local nuv; nuv, s.pos = read_u32(s.bytes, s.pos)
		for _ = 1, nuv do
			local other = read_type(s)
			if v.tag == "var" and other.tag == "var" then
				v.upper_vars[other.id] = other
			end
		end
		return v
	elseif tag == TAG_VAR_REF then
		local idx; idx, s.pos = read_u32(s.bytes, s.pos)
		local r = s.refs[idx]
		if r == nil then error("TAG_VAR_REF: unknown idx " .. tostring(idx)) end
		return r --[[: V4Type]]
	elseif tag == TAG_FORALL then
		local nv; nv, s.pos = read_u32(s.bytes, s.pos)
		local vars = {} --[[: V4Type[] ]]
		for i = 1, nv do vars[i] = read_type(s) end
		local body = read_type(s)
		return T.forall_raw(vars, body)
	elseif tag == TAG_SKOLEM then
		local _id; _id, s.pos = read_u32(s.bytes, s.pos)
		local name; name, s.pos = read_str(s.bytes, s.pos)
		-- Mint a fresh skolem on read; the producer id is meaningless cross-
		-- process. The name carries the human-readable identity.
		return T.skolem(name)
	else
		error("deserialize: unknown tag byte " .. tostring(tag))
	end
end

--: (string) -> (V4Type | nil, string | nil)
function M.deserialize(bytes)
	if #bytes < #MAGIC + 4 then return nil, "deserialize: input too short" end
	if bytes:sub(1, #MAGIC) ~= MAGIC then
		return nil, "deserialize: bad magic (not a CRI4 stream)"
	end
	local ver, pos = read_u32(bytes, #MAGIC + 1)
	if ver ~= VERSION then
		return nil, "deserialize: unsupported version " .. tostring(ver)
	end
	local s = {
		bytes = bytes,
		pos   = pos,
		refs  = {} --[[: { [integer]: V4Type } ]],
	}
	local ok, result = pcall(read_type, s)
	if not ok then return nil, "deserialize: " .. tostring(result) end
	if s.pos ~= #bytes + 1 then
		return nil, "deserialize: trailing bytes after type (pos=" .. s.pos .. ", len=" .. #bytes .. ")"
	end
	return result, nil
end

-- ── Content hashing ───────────────────────────────────────────────────────

-- SHA-256 hex digest of the serialized bytes. Used as the cache lookup key
-- (input: the source hash) and as the on-disk filename (input: the
-- serialized type bytes). The two domains do not mix — the manifest maps
-- source-hash → cri-hash, and on-disk lookup is by cri-hash filename.
--: (string) -> string
function M.content_hash(bytes)
	return sha256_mod.sha256(bytes)
end

-- ── Manifest schema ───────────────────────────────────────────────────────
--
-- The manifest maps source-content-hash → entry. An entry records the cri
-- content hash (where to find the serialized type on disk) and the per-file
-- dependency hashes (used by callers to invalidate cascading: when a
-- transitively imported source's hash changes, this file's cache entry is
-- stale).
--
--:: V4CacheEntry    = { cri_hash: string, deps: { [string]: string } }
--:: V4CacheManifest = { entries: { [string]: V4CacheEntry } }
--
-- The on-disk encoding is the same binary protocol used for V4Type, with a
-- distinct magic so a manifest file is never confused for a cri file.

local MANIFEST_MAGIC   = "CRM4"
local MANIFEST_VERSION = 1

--: (V4CacheManifest) -> string
function M.serialize_manifest(m)
	local buf = {} --[[: { [integer]: string } ]]
	local s = { buf = buf }
	w(s, MANIFEST_MAGIC)
	w(s, u32(MANIFEST_VERSION))
	local keys = {} --[[: { [integer]: string } ]]
	for k in pairs(m.entries) do keys[#keys + 1] = k end
	sort_strs(keys)
	w(s, u32(#keys))
	for _, k in ipairs(keys) do
		w_str(s, k)
		local e = m.entries[k]
		if e == nil then error("nil manifest entry") end
		local entry = e --[[: V4CacheEntry]]
		w_str(s, entry.cri_hash)
		local dep_keys = {} --[[: { [integer]: string } ]]
		for dk in pairs(entry.deps) do dep_keys[#dep_keys + 1] = dk end
		sort_strs(dep_keys)
		w(s, u32(#dep_keys))
		for _, dk in ipairs(dep_keys) do
			w_str(s, dk)
			local dv = entry.deps[dk]
			if dv == nil then error("nil dep entry") end
			w_str(s, dv --[[: string]])
		end
	end
	return table.concat(buf)
end

--: (string) -> (V4CacheManifest | nil, string | nil)
function M.deserialize_manifest(bytes)
	if #bytes < #MANIFEST_MAGIC + 4 then
		return nil, "deserialize_manifest: too short"
	end
	if bytes:sub(1, #MANIFEST_MAGIC) ~= MANIFEST_MAGIC then
		return nil, "deserialize_manifest: bad magic"
	end
	local ver, pos = read_u32(bytes, #MANIFEST_MAGIC + 1)
	if ver ~= MANIFEST_VERSION then
		return nil, "deserialize_manifest: unsupported version " .. tostring(ver)
	end
	local n; n, pos = read_u32(bytes, pos)
	local entries = {} --[[: { [string]: V4CacheEntry } ]]
	for _ = 1, n do
		local k; k, pos = read_str(bytes, pos)
		local cri_hash; cri_hash, pos = read_str(bytes, pos)
		local dn; dn, pos = read_u32(bytes, pos)
		local deps = {} --[[: { [string]: string } ]]
		for _2 = 1, dn do
			local dk; dk, pos = read_str(bytes, pos)
			local dv; dv, pos = read_str(bytes, pos)
			deps[dk] = dv
		end
		entries[k] = { cri_hash = cri_hash, deps = deps }
	end
	if pos ~= #bytes + 1 then
		return nil, "deserialize_manifest: trailing bytes"
	end
	return { entries = entries }, nil
end

-- ── I/O capability surface ────────────────────────────────────────────────
--
--:: V4IoCaps = {
--::     read_file:   (path: string) -> (string | nil, string | nil),
--::     write_file:  (path: string, bytes: string) -> (boolean, string | nil),
--::     mkdir:       (path: string) -> (boolean, string | nil),
--::     file_exists: (path: string) -> boolean,
--:: }
--
-- All four are required. Defaulting to globals (`opts.foo or io.foo`) is a
-- caps violation per CLAUDE.md ("Caps-first, everywhere"). If any cap is
-- missing the call errors at the entry point.

--: (V4IoCaps) -> nil
local function require_caps(caps)
	if caps == nil then error("cache: io_caps is required") end
	if caps.read_file == nil then error("cache: io_caps.read_file is required") end
	if caps.write_file == nil then error("cache: io_caps.write_file is required") end
	if caps.mkdir == nil then error("cache: io_caps.mkdir is required") end
	if caps.file_exists == nil then error("cache: io_caps.file_exists is required") end
end

-- Path layout under `dir`:
--   <dir>/manifest.crm              ← manifest (binary)
--   <dir>/<sha256hex>.cri           ← serialized V4Type bytes
--: (string) -> string
local function manifest_path(dir) return dir .. "/manifest.crm" end
--: (string, string) -> string
local function cri_path(dir, h) return dir .. "/" .. h .. ".cri" end

--: (V4IoCaps, string) -> V4CacheManifest
local function load_manifest(caps, dir)
	local mp = manifest_path(dir)
	if not caps.file_exists(mp) then
		return { entries = {} --[[: { [string]: V4CacheEntry } ]] }
	end
	local bytes, err = caps.read_file(mp)
	if bytes == nil then error("cache: read manifest failed: " .. tostring(err)) end
	local m, derr = M.deserialize_manifest(bytes)
	if m == nil then error("cache: parse manifest failed: " .. tostring(derr)) end
	return m
end

-- Look up a cached cri-bytes blob by source hash. Returns nil if absent or if
-- the manifest references a cri file that is no longer on disk (a torn
-- write situation — surface as a miss, not an error).
--: (V4IoCaps, string, string) -> string | nil
function M.cache_lookup(caps, dir, source_hash)
	require_caps(caps)
	local m = load_manifest(caps, dir)
	local entry = m.entries[source_hash]
	if entry == nil then return nil end
	local cp = cri_path(dir, entry.cri_hash)
	if not caps.file_exists(cp) then return nil end
	local bytes, err = caps.read_file(cp)
	if bytes == nil then error("cache: read cri failed: " .. tostring(err)) end
	return bytes
end

-- Store a type in the cache under the given source hash. Serializes the
-- type, computes its content hash, writes the cri file (if not already
-- present — content addressing means two source hashes may produce the same
-- cri bytes), and updates the manifest with the (cri-hash, deps) entry.
--
-- `deps` is `{ [source_path] = source_hash }` for transitive cache
-- invalidation. nil treated as empty.
--: (V4IoCaps, string, string, V4Type, { [string]: string } | nil) -> nil
function M.cache_store(caps, dir, source_hash, type_, deps)
	require_caps(caps)
	local ok, err = caps.mkdir(dir)
	if not ok then error("cache: mkdir failed: " .. tostring(err)) end
	local bytes = M.serialize(type_)
	local cri_hash = M.content_hash(bytes)
	local cp = cri_path(dir, cri_hash)
	if not caps.file_exists(cp) then
		local wok, werr = caps.write_file(cp, bytes)
		if not wok then error("cache: write cri failed: " .. tostring(werr)) end
	end
	local m = load_manifest(caps, dir)
	local actual_deps = deps
	if actual_deps == nil then actual_deps = {} --[[: { [string]: string } ]] end
	m.entries[source_hash] = { cri_hash = cri_hash, deps = actual_deps }
	local mbytes = M.serialize_manifest(m)
	local wok, werr = caps.write_file(manifest_path(dir), mbytes)
	if not wok then error("cache: write manifest failed: " .. tostring(werr)) end
end

return M
