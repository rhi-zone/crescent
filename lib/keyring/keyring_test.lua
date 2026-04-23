-- lib/keyring/keyring_test.lua
-- Tests for the keyring fallback (encrypted file) tier.
-- OS keychain tiers require a live desktop session; the file tier is always
-- available because it only depends on lib.hash.sha256 (ships with crescent).

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T       = require("lib.test.assert")
local keyring = require("lib.keyring")

-- ── Tier availability ─────────────────────────────────────────────────────────

T.describe("keyring.tier", function()
	T.it("loads at least the file tier", function()
		-- Force backend selection.
		keyring.get("crescent/test/probe")
		T.ok(keyring._tier ~= nil, "expected a tier to load, got nil")
	end)
end)

-- ── Build a test-isolated file tier instance ──────────────────────────────────
-- We re-implement just enough of the file tier internals to redirect the
-- storage path to a temp file, so tests don't touch ~/.crescent/keyring.enc.

local function make_isolated_file_tier()
	-- The file tier shares the encrypt/decrypt logic with init.lua but uses a
	-- separate path and key.  We construct it here to keep tests self-contained.
	local sha256_mod = require("lib.hash.sha256")
	local sha256_hex = sha256_mod.sha256
	local bit    = require("bit")
	local bxor   = bit.bxor
	local band   = bit.band
	local rshift = bit.rshift

	local function hex_to_bin(hex)
		return (hex:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end))
	end
	local function sha256_bin(s) return hex_to_bin(sha256_hex(s)) end

	local function hmac_sha256_bin(key, msg)
		if #key > 64 then key = sha256_bin(key) end
		while #key < 64 do key = key .. "\0" end
		local ipad_k, opad_k = {}, {}
		for i = 1, 64 do
			local b = key:byte(i)
			ipad_k[i] = string.char(bxor(b, 0x36))
			opad_k[i] = string.char(bxor(b, 0x5c))
		end
		return sha256_bin(table.concat(opad_k) .. sha256_bin(table.concat(ipad_k) .. msg))
	end

	local function pack_u16_le(n) return string.char(n%256, math.floor(n/256)%256) end
	local function pack_u32_le(n)
		local b0=band(n,0xff); local b1=band(rshift(n,8),0xff)
		local b2=band(rshift(n,16),0xff); local b3=band(rshift(n,24),0xff)
		return string.char(b0,b1,b2,b3)
	end
	local function unpack_u16_le(s,pos)
		local b0,b1=s:byte(pos,pos+1); return b0+b1*256, pos+2
	end
	local function unpack_u32_le(s,pos)
		local b0,b1,b2,b3=s:byte(pos,pos+3)
		return b0+b1*256+b2*65536+b3*16777216, pos+4
	end

	local MAGIC   = "CKR2"
	local IV_LEN  = 16
	local TAG_LEN = 32
	local ctr     = 0

	local function make_iv()
		ctr = ctr + 1
		-- Deterministic IV for tests: hash of counter (still unique per call).
		return sha256_bin("test-iv-" .. ctr):sub(1, IV_LEN)
	end

	local _tier_counter = (_G._keyring_tier_counter or 0) + 1
	_G._keyring_tier_counter = _tier_counter
	local tmp_path = (os.getenv("TMPDIR") or "/tmp")
		.. "/crescent_keyring_test_" .. tostring(os.time()) .. "_" .. _tier_counter .. ".enc"

	-- Constant test key (32 bytes).
	local TEST_KEY = sha256_bin("crescent-test-key")

	local function encrypt(plaintext, key)
		local enc_k = sha256_bin(key .. "enc")
		local mac_k = sha256_bin(key .. "mac")
		local iv = make_iv()
		local pt_len = #plaintext
		local ct_parts = {}
		local pos, blk = 1, 0
		while pos <= pt_len do
			local ks = sha256_bin(enc_k .. iv .. pack_u32_le(blk))
			local chunk_end = math.min(pos+31, pt_len)
			local chunk = {}
			for i = pos, chunk_end do
				chunk[#chunk+1] = string.char(bxor(plaintext:byte(i), ks:byte(i-pos+1)))
			end
			ct_parts[#ct_parts+1] = table.concat(chunk)
			pos = chunk_end+1; blk = blk+1
		end
		local ct = table.concat(ct_parts)
		return hmac_sha256_bin(mac_k, iv..ct) .. iv .. ct
	end

	local function decrypt(payload, key)
		if #payload < TAG_LEN+IV_LEN then return nil, "too short" end
		local tag_stored = payload:sub(1, TAG_LEN)
		local iv  = payload:sub(TAG_LEN+1, TAG_LEN+IV_LEN)
		local ct  = payload:sub(TAG_LEN+IV_LEN+1)
		local enc_k = sha256_bin(key.."enc")
		local mac_k = sha256_bin(key.."mac")
		local tag_expected = hmac_sha256_bin(mac_k, iv..ct)
		if tag_expected ~= tag_stored then return nil, "auth failed" end
		local ct_len = #ct
		local pt_parts = {}
		local pos, blk = 1, 0
		while pos <= ct_len do
			local ks = sha256_bin(enc_k..iv..pack_u32_le(blk))
			local chunk_end = math.min(pos+31, ct_len)
			local chunk = {}
			for i = pos, chunk_end do
				chunk[#chunk+1] = string.char(bxor(ct:byte(i), ks:byte(i-pos+1)))
			end
			pt_parts[#pt_parts+1] = table.concat(chunk)
			pos = chunk_end+1; blk = blk+1
		end
		return table.concat(pt_parts)
	end

	local function load_entries()
		local f = io.open(tmp_path, "rb")
		if not f then return {} end
		local data = f:read("*a"); f:close()
		if #data < 8 or data:sub(1,4) ~= MAGIC then return {} end
		local nentries, pos = unpack_u32_le(data, 5)
		local entries = {}
		for _ = 1, nentries do
			if pos+2 > #data+1 then break end
			local slen; slen, pos = unpack_u16_le(data, pos)
			local service = data:sub(pos, pos+slen-1); pos = pos+slen
			local plen; plen, pos = unpack_u32_le(data, pos)
			entries[service] = data:sub(pos, pos+plen-1); pos = pos+plen
		end
		return entries
	end

	local function save_entries(entries)
		local parts = { MAGIC }
		local count = 0; for _ in pairs(entries) do count=count+1 end
		parts[#parts+1] = pack_u32_le(count)
		for svc, payload in pairs(entries) do
			parts[#parts+1] = pack_u16_le(#svc)
			parts[#parts+1] = svc
			parts[#parts+1] = pack_u32_le(#payload)
			parts[#parts+1] = payload
		end
		local f = io.open(tmp_path, "wb")
		if not f then return nil, "cannot write" end
		f:write(table.concat(parts)); f:close()
		return true
	end

	local tier = {}

	function tier.set(service, value)
		local payload = encrypt(value, TEST_KEY)
		local entries = load_entries()
		entries[service] = payload
		return save_entries(entries)
	end

	function tier.get(service)
		local entries = load_entries()
		local payload = entries[service]
		if not payload then return nil end
		return decrypt(payload, TEST_KEY)
	end

	function tier.delete(service)
		local entries = load_entries()
		if not entries[service] then return nil, "not found" end
		entries[service] = nil
		return save_entries(entries)
	end

	function tier.list(prefix)
		local entries = load_entries()
		local names = {}
		for service in pairs(entries) do
			if prefix == nil or service:sub(1, #prefix) == prefix then
				names[#names + 1] = service
			end
		end
		table.sort(names)
		return names
	end

	function tier.cleanup() os.remove(tmp_path) end

	return tier
end

-- ── File tier tests ───────────────────────────────────────────────────────────

T.describe("keyring file tier", function()
	local tier = make_isolated_file_tier()

	T.it("set and get round-trip", function()
		local ok, serr = tier.set("crescent/openai", "sk-test-1234")
		T.ok(ok, tostring(serr))
		local value, gerr = tier.get("crescent/openai")
		T.ok(value ~= nil, tostring(gerr))
		T.eq(value, "sk-test-1234")
	end)

	T.it("get returns nil for unknown key", function()
		local value = tier.get("crescent/nonexistent-xyz")
		T.eq(value, nil)
	end)

	T.it("overwrite replaces value", function()
		tier.set("crescent/anthropic", "original-key")
		tier.set("crescent/anthropic", "updated-key")
		T.eq(tier.get("crescent/anthropic"), "updated-key")
	end)

	T.it("delete removes entry", function()
		tier.set("crescent/openrouter", "to-delete")
		local ok, derr = tier.delete("crescent/openrouter")
		T.ok(ok, tostring(derr))
		T.eq(tier.get("crescent/openrouter"), nil)
	end)

	T.it("delete returns error for missing key", function()
		local ok, derr = tier.delete("crescent/does-not-exist")
		T.eq(ok, nil)
		T.ok(derr ~= nil)
	end)

	T.it("multiple keys coexist", function()
		tier.set("crescent/openai",    "key-openai")
		tier.set("crescent/anthropic", "key-anthropic")
		tier.set("crescent/cohere",    "key-cohere")
		T.eq(tier.get("crescent/openai"),    "key-openai")
		T.eq(tier.get("crescent/anthropic"), "key-anthropic")
		T.eq(tier.get("crescent/cohere"),    "key-cohere")
	end)

	T.it("values survive re-load (file persistence)", function()
		tier.set("crescent/persist-test", "persistent-value")
		-- get() always re-reads the file — no in-memory cache.
		T.eq(tier.get("crescent/persist-test"), "persistent-value")
	end)

	T.it("list returns all keys when no prefix", function()
		-- Use a fresh tier so the key set is known.
		local t2 = make_isolated_file_tier()
		t2.set("crescent/a", "va")
		t2.set("crescent/b", "vb")
		t2.set("other/c",    "vc")
		local names = t2.list()
		table.sort(names)
		T.eq(#names, 3)
		T.eq(names[1], "crescent/a")
		T.eq(names[2], "crescent/b")
		T.eq(names[3], "other/c")
		t2.cleanup()
	end)

	T.it("list filters by prefix", function()
		local t2 = make_isolated_file_tier()
		t2.set("crescent/x", "vx")
		t2.set("crescent/y", "vy")
		t2.set("other/z",    "vz")
		local names = t2.list("crescent/")
		table.sort(names)
		T.eq(#names, 2)
		T.eq(names[1], "crescent/x")
		T.eq(names[2], "crescent/y")
		t2.cleanup()
	end)

	T.it("list returns empty table when file does not exist", function()
		local t2 = make_isolated_file_tier()
		local names = t2.list()
		T.eq(#names, 0)
		t2.cleanup()
	end)

	T.it("list returns empty table when prefix matches nothing", function()
		local t2 = make_isolated_file_tier()
		t2.set("crescent/q", "vq")
		local names = t2.list("nomatch/")
		T.eq(#names, 0)
		t2.cleanup()
	end)

	tier.cleanup()
end)

-- ── Integration: module-level API via whichever tier loaded ───────────────────

T.describe("keyring module API", function()
	T.it("set/get/delete round-trip", function()
		if not keyring._tier then T.ok(true); return end
		local svc = "crescent/test/integration-" .. tostring(os.time())
		local ok, serr = keyring.set(svc, "integration-value")
		T.ok(ok, tostring(serr))
		local value, gerr = keyring.get(svc)
		T.ok(value ~= nil, tostring(gerr))
		T.eq(value, "integration-value")
		local dok, derr = keyring.delete(svc)
		T.ok(dok, tostring(derr))
		T.eq(keyring.get(svc), nil)
	end)

	T.it("list returns table or 'not supported'", function()
		if not keyring._tier then T.ok(true); return end
		local result, err = keyring.list("crescent/")
		if result ~= nil then
			-- File / libsecret / keychain tier: must be a table.
			T.ok(type(result) == "table", "expected table from list()")
		else
			-- A tier may legitimately return "not supported" if a dependency
			-- (e.g. glib-2.0 for libsecret) can't be loaded.
			T.ok(err ~= nil, "expected error string when list returns nil")
		end
	end)

	-- Tier-aware list() round-trip.  Uses a unique per-run prefix so the real
	-- keyring isn't polluted if we're running against libsecret or keychain.
	T.it("list round-trip: set, list, filter by prefix, delete", function()
		if not keyring._tier then T.ok(true); return end

		-- Probe: does list() work on this tier?
		local probe, perr = keyring.list()
		if probe == nil then
			-- list is not implemented on this tier (e.g. missing glib).
			T.ok(perr ~= nil)
			return
		end

		local rand_tag = tostring(os.time()) .. "-" .. tostring(math.random(1, 1e9))
		local prefix_a = "crescent-test-" .. rand_tag .. "/a/"
		local prefix_b = "crescent-test-" .. rand_tag .. "/b/"
		local svc_a1   = prefix_a .. "one"
		local svc_a2   = prefix_a .. "two"
		local svc_b1   = prefix_b .. "one"

		-- Always try to clean up, even on failure.
		local function cleanup()
			keyring.delete(svc_a1)
			keyring.delete(svc_a2)
			keyring.delete(svc_b1)
		end

		local function contains(tbl, v)
			for i = 1, #tbl do if tbl[i] == v then return true end end
			return false
		end

		local sok, serr = pcall(function()
			T.ok(keyring.set(svc_a1, "va1"), "set svc_a1")
			T.ok(keyring.set(svc_a2, "va2"), "set svc_a2")
			T.ok(keyring.set(svc_b1, "vb1"), "set svc_b1")

			-- list() with no prefix returns all keys (including ours).
			local all = keyring.list()
			T.ok(type(all) == "table", tostring(serr))
			T.ok(contains(all, svc_a1), "svc_a1 present")
			T.ok(contains(all, svc_a2), "svc_a2 present")
			T.ok(contains(all, svc_b1), "svc_b1 present")

			-- list(prefix_a) returns only a/* keys.
			local only_a = keyring.list(prefix_a)
			T.ok(type(only_a) == "table")
			T.ok(contains(only_a, svc_a1), "a filter includes svc_a1")
			T.ok(contains(only_a, svc_a2), "a filter includes svc_a2")
			T.ok(not contains(only_a, svc_b1), "a filter excludes svc_b1")

			-- list(prefix_b) returns only b/* keys.
			local only_b = keyring.list(prefix_b)
			T.ok(type(only_b) == "table")
			T.ok(contains(only_b, svc_b1), "b filter includes svc_b1")
			T.ok(not contains(only_b, svc_a1), "b filter excludes svc_a1")
		end)

		cleanup()
		T.ok(sok, tostring(serr))
	end)
end)
