-- lib/declc/ledger.lua
-- Content-addressed claim ledger for the declarative-core composite.
--
-- Per research/ceiling-survey/judgment.md §5, "From ENG": content-addressed
-- claims keyed by (property, code_hash, assumption_set), precise
-- invalidation, verdict-transition visibility, "no verdict is ever silently
-- downgraded."
--
--   property        -- WHAT is being claimed: a lib.declc.claim Claim's
--                       identity key (claim.key(c) -- site+slot+stratum+
--                       modal+schema; provenance excluded, see claim.lua)
--   code_hash        -- WHAT CODE the claim is checked against (caller-
--                        supplied, e.g. a sha256 of the relevant source --
--                        this module does not hash source itself)
--   assumption_set    -- WHAT Γ-hypotheses were in force: a list of claim
--                        identity keys, canonicalized by sorting so the
--                        order the caller assembled them in never affects
--                        the content address
--
-- The three are combined and hashed -- reusing lib/hash/sha256 per
-- docs/inventory.md (no new hashing primitive per CLAUDE.md) -- into one
-- content address: the ledger's primary key. Two (claim, code, Γ) triples
-- that are semantically identical always land on the same entry, so a
-- re-check that reaches the same verdict is a no-op and a re-check that
-- reaches a DIFFERENT verdict is a recorded transition, never a silent
-- overwrite.
--
-- Persistence is optional: an in-memory ledger works standalone with no
-- capability injected at all. If the caller wants durability,
-- `M.new({ persist = io_caps })` takes the same four-method io_caps shape
-- as lib/type/static-v4/cache.lua (`read_file`/`write_file`/`mkdir`/
-- `file_exists`) -- caps-first, no `io` fallback: an incomplete `persist`
-- table is an error at construction, and calling save()/load() without one
-- injected is an error, never a silent no-op.
--
-- Verdict payloads (cert/trace/receipt, per lib/declc/kernel.lua) are
-- `unknown` by design -- their shape is future harvester/check-law work.
-- Persistence therefore requires the payload to be plain serializable Lua
-- data (nil/boolean/number/string/table-of-same, recursively); anything
-- else (function, userdata, cyclic table) fails save() with an explicit
-- error rather than silently dropping the field. That is not a guessed
-- schema for cert/trace/receipt -- it is the weakest assumption that lets
-- persistence exist at all before those schemas are designed, exactly
-- mirroring the pure-data discipline lib/type/static-v4/cache.lua uses for
-- its own opaque leaf values.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local sha256_mod = require("lib.hash.sha256")
local claim       = require("lib.declc.claim")
local kernel      = require("lib.declc.kernel")

local M = {}

--:: LedgerIoCaps = {
--::     read_file:   (path: string) -> (string | nil, string | nil),
--::     write_file:  (path: string, bytes: string) -> (boolean, string | nil),
--::     mkdir:       (path: string) -> (boolean, string | nil),
--::     file_exists: (path: string) -> boolean,
--:: }

--:: LedgerOpts = { persist: LedgerIoCaps | nil }

--:: Transition = { from: string | nil, to: string, seq: integer }

--:: LedgerEntry = {
--::   property: string,
--::   code_hash: string,
--::   assumption_set: { [integer]: string },
--::   verdict: unknown,
--::   verdict_kind: string,
--::   invalidated: boolean,
--::   log: { [integer]: Transition },
--:: }

--:: Ledger = {
--::   entries: { [string]: LedgerEntry },
--::   next_seq: integer,
--::   persist: LedgerIoCaps | nil,
--:: }

-- ── Key construction ──────────────────────────────────────────────────────

local SEP = "\1"

-- In-place insertion sort for the (small, per-check) assumption-set list.
-- Mirrors lib/type/static-v4/cache.lua's sort_strs: avoids table.sort so
-- this file is friendly to the same typechecker quirk noted there, and the
-- lists here (Γ-hypotheses in force for one claim check) are tiny.
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

--: ({ [integer]: string }) -> string
local function assumption_key(assumption_set)
	local copy = {} --[[: { [integer]: string } ]]
	for i, a in ipairs(assumption_set) do copy[i] = a end
	sort_strs(copy)
	return table.concat(copy, SEP)
end

--: (string, string, { [integer]: string }) -> (string, { [integer]: string })
local function content_hash(property, code_hash, assumption_set)
	local sorted = {} --[[: { [integer]: string } ]]
	for i, a in ipairs(assumption_set) do sorted[i] = a end
	sort_strs(sorted)
	local akey = table.concat(sorted, SEP)
	local h = sha256_mod.sha256(table.concat({ property, code_hash, akey }, SEP))
	return h, sorted
end

-- ── Construction ──────────────────────────────────────────────────────────

--: (LedgerIoCaps) -> nil
local function require_caps(caps)
	if caps == nil then error("ledger: persist io_caps is required") end
	if caps.read_file == nil then error("ledger: persist.read_file is required") end
	if caps.write_file == nil then error("ledger: persist.write_file is required") end
	if caps.mkdir == nil then error("ledger: persist.mkdir is required") end
	if caps.file_exists == nil then error("ledger: persist.file_exists is required") end
end

local Ledger = {}
Ledger.__index = Ledger

--: (LedgerOpts | nil) -> Ledger
function M.new(opts)
	local persist = nil --[[: LedgerIoCaps | nil]]
	if opts ~= nil then
		local p = opts.persist
		if p ~= nil then
			require_caps(p)
			persist = p
		end
	end
	local entries = {} --[[: { [string]: LedgerEntry } ]]
	local self = { entries = entries, next_seq = 1, persist = persist }
	return setmetatable(self, Ledger)
end

-- ── Record / lookup ───────────────────────────────────────────────────────

-- Records a verdict for (claim, code_hash, assumption_set). Returns the
-- content-hash key on success. If an entry already exists for this exact
-- (property, code, Γ) triple, this is a transition: the previous verdict
-- kind and the new one are appended to the entry's log, and re-recording
-- clears any prior invalidation (a fresh check supersedes it).
--: (Ledger, Claim, string, { [integer]: string }, unknown) -> (string | nil, string | nil)
function Ledger:record(c, code, assumption_set, verdict)
	local kind, kind_err = kernel.kind(verdict)
	if kind == nil then
		return nil, "ledger.record: " .. tostring(kind_err)
	end
	local property = claim.key(c)
	local h, sorted = content_hash(property, code, assumption_set)
	local seq = self.next_seq
	self.next_seq = seq + 1
	local existing = self.entries[h]
	if existing == nil then
		local log = { { from = nil, to = kind, seq = seq } } --[[: { [integer]: Transition } ]]
		self.entries[h] = {
			property = property,
			code_hash = code,
			assumption_set = sorted,
			verdict = verdict,
			verdict_kind = kind,
			invalidated = false,
			log = log,
		}
	else
		local prev_kind = existing.verdict_kind
		existing.log[#existing.log + 1] = { from = prev_kind, to = kind, seq = seq }
		existing.verdict = verdict
		existing.verdict_kind = kind
		existing.invalidated = false
	end
	return h, nil
end

-- Looks up the current verdict for (claim, code_hash, assumption_set).
-- Returns nil if there is no entry, or if the entry has been invalidated
-- and not since re-recorded. Absence is not an error -- a plain miss.
--: (Ledger, Claim, string, { [integer]: string }) -> unknown
function Ledger:lookup(c, code, assumption_set)
	local property = claim.key(c)
	local h = content_hash(property, code, assumption_set)
	local entry = self.entries[h]
	if entry == nil or entry.invalidated then return nil end
	return entry.verdict
end

-- Exposes the content-hash a (claim, code, Γ) triple maps to, without
-- requiring a recorded entry to exist. Useful for callers that want to key
-- their own side-tables by the same address the ledger uses.
--: (Ledger, Claim, string, { [integer]: string }) -> string
function Ledger:content_hash(c, code, assumption_set)
	local property = claim.key(c)
	local h = content_hash(property, code, assumption_set)
	return h
end

-- Invalidates every entry whose code_hash matches (e.g. the source changed
-- underneath it). Invalidation is logged as a transition to the ledger-
-- level lifecycle event "invalidated" -- distinct from any VerdictKind,
-- since invalidation is a ledger fact about staleness, not a kernel
-- verdict. Returns the count of entries invalidated.
--: (Ledger, string) -> integer
function Ledger:invalidate(code)
	local count = 0
	for _, entry in pairs(self.entries) do
		if entry.code_hash == code and not entry.invalidated then
			local seq = self.next_seq
			self.next_seq = seq + 1
			entry.log[#entry.log + 1] = { from = entry.verdict_kind, to = "invalidated", seq = seq }
			entry.invalidated = true
			count = count + 1
		end
	end
	return count
end

-- Returns a copy of the verdict-transition log for a (claim, code, Γ)
-- triple, or nil if no entry exists.
--: (Ledger, Claim, string, { [integer]: string }) -> { [integer]: Transition } | nil
function Ledger:transitions(c, code, assumption_set)
	local property = claim.key(c)
	local h = content_hash(property, code, assumption_set)
	local entry = self.entries[h]
	if entry == nil then return nil end
	local copy = {} --[[: { [integer]: Transition } ]]
	for i, t in ipairs(entry.log) do copy[i] = t end
	return copy
end

-- ── Persistence ───────────────────────────────────────────────────────────
--
-- Generic deterministic serializer for plain Lua data, used to persist
-- ledger entries (including opaque verdict payloads, under the plain-data
-- assumption documented at the top of this file). Tag-byte format, in the
-- same spirit as lib/type/static-v4/cache.lua's binary encoder, but generic
-- over any nil/boolean/number/string/table-of-same value rather than one
-- fixed algebraic type.

--: ({ buf: { [integer]: string }, ... }, string) -> nil
local function w(s, b)
	s.buf[#s.buf + 1] = b
end

--: (integer) -> string
local function u32(n)
	local b0 = n % 256
	local b1 = math.floor(n / 256) % 256
	local b2 = math.floor(n / 65536) % 256
	local b3 = math.floor(n / 16777216) % 256
	return string.char(b0, b1, b2, b3)
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
	-- After the nil-guard the four bytes are integer-valued. Checked casts
	-- make this explicit for the typechecker, mirroring
	-- lib/type/static-v4/cache.lua's read_u32.
	local i0 = b0 --[[: integer]]
	local i1 = b1 --[[: integer]]
	local i2 = b2 --[[: integer]]
	local i3 = b3 --[[: integer]]
	local n = i0 + i1 * 256 + i2 * 65536 + i3 * 16777216
	return math.floor(n), pos + 4
end

--: ({ buf: { [integer]: string }, ... }, string) -> nil
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

local VTAG_NIL   = 0
local VTAG_FALSE = 1
local VTAG_TRUE  = 2
local VTAG_NUM   = 3
local VTAG_STR   = 4
local VTAG_TABLE = 5

-- Serializes one plain-data value. Tables are always emitted as a sorted
-- list of (key, value) pairs -- keys must be strings or integers (encoded
-- as their decimal string form prefixed by a kind byte so "1" (string) and
-- 1 (integer) never collide). Any other Lua type (function, userdata,
-- thread, table key of another type) is a hard error: this format only
-- promises to round-trip plain data.
local ser_value -- forward
--: ({ buf: { [integer]: string }, ... }, unknown) -> nil
ser_value = function(s, v)
	if v == nil then
		w(s, string.char(VTAG_NIL))
	elseif type(v) == "boolean" then
		if v == true then w(s, string.char(VTAG_TRUE)) else w(s, string.char(VTAG_FALSE)) end
	elseif type(v) == "number" then
		w(s, string.char(VTAG_NUM))
		w_str(s, string.format("%.17g", v))
	elseif type(v) == "string" then
		w(s, string.char(VTAG_STR))
		w_str(s, v)
	elseif type(v) == "table" then
		w(s, string.char(VTAG_TABLE))
		local t = v
		local keys = {} --[[: { [integer]: string } ]]
		for k in pairs(t) do
			if type(k) == "string" then
				keys[#keys + 1] = "s" .. k
			elseif type(k) == "number" then
				keys[#keys + 1] = "n" .. string.format("%.17g", k)
			else
				error("ledger: cannot serialize non-plain table key of type " .. type(k))
			end
		end
		sort_strs(keys)
		w(s, u32(#keys))
		for _, encoded_key in ipairs(keys) do
			local kind = encoded_key:sub(1, 1)
			local rest = encoded_key:sub(2)
			if kind == "s" then
				w(s, string.char(0))
				w_str(s, rest)
				ser_value(s, t[rest])
			else
				w(s, string.char(1))
				w_str(s, rest)
				local n = tonumber(rest)
				if n == nil then error("ledger: malformed numeric key " .. rest) end
				ser_value(s, t[n])
			end
		end
	else
		error("ledger: cannot serialize value of type " .. type(v) .. " (only plain data is supported)")
	end
end

local read_value -- forward
--: (string, integer) -> (unknown, integer)
read_value = function(bytes, pos)
	if pos > #bytes then error("read_value: EOF") end
	local tag = bytes:byte(pos)
	pos = pos + 1
	if tag == VTAG_NIL then
		return nil, pos
	elseif tag == VTAG_FALSE then
		return false, pos
	elseif tag == VTAG_TRUE then
		return true, pos
	elseif tag == VTAG_NUM then
		local txt; txt, pos = read_str(bytes, pos)
		local n = tonumber(txt)
		if n == nil then error("read_value: not a number: " .. txt) end
		return n, pos
	elseif tag == VTAG_STR then
		local str; str, pos = read_str(bytes, pos)
		return str, pos
	elseif tag == VTAG_TABLE then
		local n; n, pos = read_u32(bytes, pos)
		local t = {} --[[: { [unknown]: unknown } ]]
		for _ = 1, n do
			if pos > #bytes then error("read_value: EOF in table") end
			local kkind = bytes:byte(pos); pos = pos + 1
			local kstr; kstr, pos = read_str(bytes, pos)
			local val; val, pos = read_value(bytes, pos)
			if kkind == 0 then
				t[kstr] = val
			else
				local n2 = tonumber(kstr)
				if n2 == nil then error("read_value: malformed numeric key " .. kstr) end
				t[n2] = val
			end
		end
		return t, pos
	else
		error("read_value: unknown tag " .. tostring(tag))
	end
end

-- A Verdict's trust mechanism is reference identity (kernel.lua's SENTINEL
-- table) -- it cannot survive a round-trip through bytes by construction,
-- and must not: an "identical-looking" table read back from disk is
-- exactly the forgery kernel.is_verdict exists to reject. Persistence
-- therefore serializes (verdict_kind, payload) -- extracted through the
-- kernel's own accessors, never by reaching into the opaque table -- and
-- reconstructs the Verdict on load through the matching kernel constructor.
-- This is not per-kind special-casing in the sense CLAUDE.md forbids: it is
-- dispatch over the kernel's own fixed three-constructor vocabulary, the
-- same dispatch kernel.lua itself performs inside cert/trace/receipt.
--: (string, unknown) -> unknown
local function verdict_payload(kind, v)
	if kind == "proved" then
		local p, err = kernel.cert(v)
		if p == nil and err ~= nil then error("ledger: " .. err) end
		return p
	elseif kind == "refuted" then
		local p, err = kernel.trace(v)
		if p == nil and err ~= nil then error("ledger: " .. err) end
		return p
	elseif kind == "open" then
		local p, err = kernel.receipt(v)
		if p == nil and err ~= nil then error("ledger: " .. err) end
		return p
	else
		error("ledger: unknown verdict kind " .. kind)
	end
end

--: (string, unknown) -> unknown
local function verdict_from_kind(kind, payload)
	if kind == "proved" then
		return kernel.proved(payload)
	elseif kind == "refuted" then
		return kernel.refuted(payload)
	elseif kind == "open" then
		return kernel.open(payload)
	else
		error("ledger: unknown verdict kind " .. kind)
	end
end

local MAGIC = "DCLG"
local VERSION = 1

-- Serializes the full ledger state to bytes.
--: (Ledger) -> string
local function serialize_ledger(self)
	local buf = {} --[[: { [integer]: string } ]]
	local s = { buf = buf }
	w(s, MAGIC)
	w(s, u32(VERSION))
	w(s, u32(self.next_seq))
	local hashes = {} --[[: { [integer]: string } ]]
	for h in pairs(self.entries) do hashes[#hashes + 1] = h end
	sort_strs(hashes)
	w(s, u32(#hashes))
	for _, h in ipairs(hashes) do
		local entry = self.entries[h]
		if entry == nil then error("ledger: nil entry for hash " .. h) end
		w_str(s, h)
		w_str(s, entry.property)
		w_str(s, entry.code_hash)
		w(s, u32(#entry.assumption_set))
		for _, a in ipairs(entry.assumption_set) do w_str(s, a) end
		w_str(s, entry.verdict_kind)
		ser_value(s, verdict_payload(entry.verdict_kind, entry.verdict))
		w(s, string.char(entry.invalidated and 1 or 0))
		w(s, u32(#entry.log))
		for _, t in ipairs(entry.log) do
			if t.from == nil then
				w(s, string.char(0))
			else
				w(s, string.char(1))
				w_str(s, t.from)
			end
			w_str(s, t.to)
			w(s, u32(t.seq))
		end
	end
	return table.concat(buf)
end

--: (string) -> (Ledger | nil, string | nil)
local function deserialize_ledger(bytes)
	if #bytes < #MAGIC + 4 then return nil, "ledger: input too short" end
	if bytes:sub(1, #MAGIC) ~= MAGIC then return nil, "ledger: bad magic" end
	local pos
	local ver; ver, pos = read_u32(bytes, #MAGIC + 1)
	if ver ~= VERSION then return nil, "ledger: unsupported version " .. tostring(ver) end
	local next_seq; next_seq, pos = read_u32(bytes, pos)
	local n; n, pos = read_u32(bytes, pos)
	local entries = {} --[[: { [string]: LedgerEntry } ]]
	for _ = 1, n do
		local h; h, pos = read_str(bytes, pos)
		local property; property, pos = read_str(bytes, pos)
		local code_hash_; code_hash_, pos = read_str(bytes, pos)
		local an; an, pos = read_u32(bytes, pos)
		local aset = {} --[[: { [integer]: string } ]]
		for i = 1, an do
			local a; a, pos = read_str(bytes, pos)
			aset[i] = a
		end
		local vkind; vkind, pos = read_str(bytes, pos)
		local payload; payload, pos = read_value(bytes, pos)
		local verdict = verdict_from_kind(vkind, payload)
		if pos > #bytes then error("ledger: EOF reading invalidated flag") end
		local inv = bytes:byte(pos) ~= 0; pos = pos + 1
		local ln; ln, pos = read_u32(bytes, pos)
		local log = {} --[[: { [integer]: Transition } ]]
		for i = 1, ln do
			if pos > #bytes then error("ledger: EOF reading log entry") end
			local has_from = bytes:byte(pos) ~= 0; pos = pos + 1
			local from = nil --[[: string | nil]]
			if has_from then
				local f; f, pos = read_str(bytes, pos)
				from = f
			end
			local to; to, pos = read_str(bytes, pos)
			local seq; seq, pos = read_u32(bytes, pos)
			log[i] = { from = from, to = to, seq = seq }
		end
		entries[h] = {
			property = property,
			code_hash = code_hash_,
			assumption_set = aset,
			verdict = verdict,
			verdict_kind = vkind,
			invalidated = inv,
			log = log,
		}
	end
	if pos ~= #bytes + 1 then return nil, "ledger: trailing bytes" end
	local self = { entries = entries, next_seq = next_seq, persist = nil }
	return setmetatable(self, Ledger), nil
end

-- Persists the full ledger state to `path` via the injected persist cap.
-- Errors (returns nil, errmsg) if no persist cap was injected at
-- construction, or if a stored verdict payload is not plain data.
--: (Ledger, string) -> (boolean | nil, string | nil)
function Ledger:save(path)
	local persist = self.persist
	if persist == nil then
		return nil, "ledger.save: no persist io_caps injected at construction"
	end
	local ok, bytes = pcall(serialize_ledger, self)
	if not ok then return nil, "ledger.save: " .. tostring(bytes) end
	local wok, werr = persist.write_file(path, bytes)
	if not wok then return nil, "ledger.save: write_file failed: " .. tostring(werr) end
	return true, nil
end

-- Loads ledger state from `path`, replacing this ledger's in-memory
-- entries. Errors if no persist cap was injected, or if the file is
-- missing/malformed.
--: (Ledger, string) -> (boolean | nil, string | nil)
function Ledger:load(path)
	local persist = self.persist
	if persist == nil then
		return nil, "ledger.load: no persist io_caps injected at construction"
	end
	if not persist.file_exists(path) then
		return nil, "ledger.load: no such file: " .. path
	end
	local bytes, rerr = persist.read_file(path)
	if bytes == nil then return nil, "ledger.load: read_file failed: " .. tostring(rerr) end
	local loaded, derr = deserialize_ledger(bytes)
	if loaded == nil then return nil, "ledger.load: " .. tostring(derr) end
	self.entries = loaded.entries
	self.next_seq = loaded.next_seq
	return true, nil
end

return M
