-- lib/declc/ledger_test.lua
-- Tests for the content-addressed claim ledger: record/lookup, transition
-- logging, invalidation, content-address stability, and optional
-- persistence via an injected io_caps double.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T      = require("lib.test.assert")
local claim  = require("lib.declc.claim")
local kernel = require("lib.declc.kernel")
local ledger = require("lib.declc.ledger")

--: (string) -> Claim
local function mkclaim(site)
	local c, err = claim.new({
		site       = site,
		slot       = "entry:x",
		stratum    = "pi1",
		modal      = "box",
		schema     = "number",
		schema_key = "number",
		provenance = "stated",
	})
	if c == nil then error("test setup: " .. tostring(err)) end
	return c
end

T.describe("ledger: record / lookup", function()
	T.it("lookup on an empty ledger is a plain miss", function()
		local l = ledger.new()
		local c = mkclaim("s1")
		T.eq(l:lookup(c, "codeA", {}), nil)
	end)

	T.it("record then lookup returns the same verdict", function()
		local l = ledger.new()
		local c = mkclaim("s1")
		local v = kernel.proved("cert-1")
		local h, err = l:record(c, "codeA", {}, v)
		T.ok(h ~= nil)
		T.eq(err, nil)
		local got = l:lookup(c, "codeA", {})
		T.ok(kernel.is_verdict(got))
		local k = kernel.kind(got)
		T.eq(k, "proved")
	end)

	T.it("record rejects a non-kernel verdict", function()
		local l = ledger.new()
		local c = mkclaim("s1")
		local h, err = l:record(c, "codeA", {}, { kind = "proved", payload = "forged" })
		T.eq(h, nil)
		T.ok(err ~= nil)
	end)

	T.it("different code_hash is a different entry", function()
		local l = ledger.new()
		local c = mkclaim("s1")
		l:record(c, "codeA", {}, kernel.proved("cert-A"))
		l:record(c, "codeB", {}, kernel.refuted("trace-B"))
		local ga = l:lookup(c, "codeA", {})
		local gb = l:lookup(c, "codeB", {})
		T.eq(kernel.kind(ga), "proved")
		T.eq(kernel.kind(gb), "refuted")
	end)

	T.it("different assumption_set is a different entry", function()
		local l = ledger.new()
		local c = mkclaim("s1")
		l:record(c, "codeA", { "gamma1" }, kernel.proved("cert-1"))
		l:record(c, "codeA", { "gamma2" }, kernel.refuted("trace-2"))
		T.eq(kernel.kind(l:lookup(c, "codeA", { "gamma1" })), "proved")
		T.eq(kernel.kind(l:lookup(c, "codeA", { "gamma2" })), "refuted")
	end)

	T.it("assumption_set order does not affect the content address", function()
		local l = ledger.new()
		local c = mkclaim("s1")
		local h1 = l:content_hash(c, "codeA", { "a", "b", "c" })
		local h2 = l:content_hash(c, "codeA", { "c", "a", "b" })
		T.eq(h1, h2)
	end)

	T.it("two structurally-identical claims (different provenance) share an entry", function()
		local l = ledger.new()
		local stated, _ = claim.new({
			site = "s1", slot = "entry:x", stratum = "pi1", modal = "box",
			schema = "number", schema_key = "number", provenance = "stated",
		})
		local mined, _ = claim.new({
			site = "s1", slot = "entry:x", stratum = "pi1", modal = "box",
			schema = "number", schema_key = "number", provenance = "mined",
		})
		l:record(stated, "codeA", {}, kernel.proved("cert-1"))
		local got = l:lookup(mined, "codeA", {})
		T.ok(kernel.is_verdict(got), "same-key claim under a different provenance hits the same entry")
	end)
end)

T.describe("ledger: verdict-transition log", function()
	T.it("first record produces a log entry with from=nil", function()
		local l = ledger.new()
		local c = mkclaim("s1")
		l:record(c, "codeA", {}, kernel.proved("cert-1"))
		local log = l:transitions(c, "codeA", {})
		T.ok(log ~= nil)
		T.eq(#log, 1)
		T.eq(log[1].from, nil)
		T.eq(log[1].to, "proved")
	end)

	T.it("re-recording a different verdict appends a transition, never overwrites silently", function()
		local l = ledger.new()
		local c = mkclaim("s1")
		l:record(c, "codeA", {}, kernel.proved("cert-1"))
		l:record(c, "codeA", {}, kernel.refuted("trace-1"))
		local log = l:transitions(c, "codeA", {})
		T.ok(log ~= nil)
		T.eq(#log, 2)
		T.eq(log[1].to, "proved")
		T.eq(log[2].from, "proved")
		T.eq(log[2].to, "refuted")
	end)

	T.it("re-recording the same verdict kind still logs a transition (no coalescing)", function()
		local l = ledger.new()
		local c = mkclaim("s1")
		l:record(c, "codeA", {}, kernel.proved("cert-1"))
		l:record(c, "codeA", {}, kernel.proved("cert-2"))
		local log = l:transitions(c, "codeA", {})
		T.ok(log ~= nil)
		T.eq(#log, 2)
		local got = l:lookup(c, "codeA", {})
		local cert = kernel.cert(got)
		T.eq(cert, "cert-2")
	end)

	T.it("transitions() on an unknown entry returns nil", function()
		local l = ledger.new()
		local c = mkclaim("s1")
		T.eq(l:transitions(c, "codeA", {}), nil)
	end)
end)

T.describe("ledger: invalidation", function()
	T.it("invalidate() hides the verdict from lookup", function()
		local l = ledger.new()
		local c = mkclaim("s1")
		l:record(c, "codeA", {}, kernel.proved("cert-1"))
		local n = l:invalidate("codeA")
		T.eq(n, 1)
		T.eq(l:lookup(c, "codeA", {}), nil)
	end)

	T.it("invalidate() is logged as a transition, not a silent drop", function()
		local l = ledger.new()
		local c = mkclaim("s1")
		l:record(c, "codeA", {}, kernel.proved("cert-1"))
		l:invalidate("codeA")
		local log = l:transitions(c, "codeA", {})
		T.ok(log ~= nil)
		T.eq(#log, 2)
		T.eq(log[2].to, "invalidated")
	end)

	T.it("invalidate() only affects matching code_hash", function()
		local l = ledger.new()
		local c = mkclaim("s1")
		l:record(c, "codeA", {}, kernel.proved("cert-1"))
		l:record(c, "codeB", {}, kernel.proved("cert-2"))
		local n = l:invalidate("codeA")
		T.eq(n, 1)
		T.eq(l:lookup(c, "codeA", {}), nil)
		T.ok(kernel.is_verdict(l:lookup(c, "codeB", {})))
	end)

	T.it("re-recording after invalidation revives the entry", function()
		local l = ledger.new()
		local c = mkclaim("s1")
		l:record(c, "codeA", {}, kernel.proved("cert-1"))
		l:invalidate("codeA")
		l:record(c, "codeA", {}, kernel.proved("cert-2"))
		local got = l:lookup(c, "codeA", {})
		T.ok(kernel.is_verdict(got))
		T.eq(kernel.cert(got), "cert-2")
	end)

	T.it("invalidating twice does not double-count or double-log", function()
		local l = ledger.new()
		local c = mkclaim("s1")
		l:record(c, "codeA", {}, kernel.proved("cert-1"))
		T.eq(l:invalidate("codeA"), 1)
		T.eq(l:invalidate("codeA"), 0)
		local log = l:transitions(c, "codeA", {})
		T.ok(log ~= nil)
		T.eq(#log, 2)
	end)
end)

T.describe("ledger: persistence requires an injected cap", function()
	T.it("save() without a persist cap errors", function()
		local l = ledger.new()
		local ok, err = l:save("/tmp/whatever.dclg")
		T.eq(ok, nil)
		T.ok(err ~= nil)
	end)

	T.it("load() without a persist cap errors", function()
		local l = ledger.new()
		local ok, err = l:load("/tmp/whatever.dclg")
		T.eq(ok, nil)
		T.ok(err ~= nil)
	end)

	-- Note: M.new's require_caps() runtime guard against an incomplete
	-- persist cap table is not exercisable from a statically-typed call
	-- site -- LedgerOpts already requires the full four-method shape, so
	-- the typechecker rejects a short cap table before require_caps would
	-- ever run (confirmed: `--[[:! LedgerOpts]]` on a one-method cap table
	-- is rejected by bin/cr check as "force cast has no overlap", i.e. the
	-- checker refuses to even let a test fake its way past this). The
	-- runtime guard exists for genuinely untyped/dynamic callers (caps
	-- assembled from config, loaded data, etc.), which this typed test
	-- suite cannot construct without escaping the type system -- covering
	-- it would require an `any` cast, which CLAUDE.md forbids writing.
end)

-- ── In-memory filesystem double for persistence tests ──────────────────────

--: () -> LedgerIoCaps
local function make_memfs()
	local files = {} --[[: { [string]: string } ]]
	--: (string) -> (string | nil, string | nil)
	local function read_file(path)
		local v = files[path]
		if v == nil then return nil, "memfs: no such file: " .. path end
		return v, nil
	end
	--: (string, string) -> (boolean, string | nil)
	local function write_file(path, bytes)
		files[path] = bytes
		return true, nil
	end
	--: (string) -> (boolean, string | nil)
	local function mkdir(_path)
		return true, nil
	end
	--: (string) -> boolean
	local function file_exists(path)
		return files[path] ~= nil
	end
	return {
		read_file = read_file,
		write_file = write_file,
		mkdir = mkdir,
		file_exists = file_exists,
	}
end

T.describe("ledger: persistence round-trips through an injected cap", function()
	T.it("save then load on a fresh ledger reproduces record/lookup/log state", function()
		local caps = make_memfs()
		local l1 = ledger.new({ persist = caps })
		local c = mkclaim("s1")
		l1:record(c, "codeA", { "g1", "g2" }, kernel.proved({ invariant = "x >= 0" }))
		l1:record(c, "codeA", { "g1", "g2" }, kernel.refuted({ "ev1", "ev2" }))
		l1:invalidate("codeA")

		local sok, serr = l1:save("/mem/ledger.dclg")
		T.ok(sok == true, tostring(serr))

		local l2 = ledger.new({ persist = caps })
		local lok, lerr = l2:load("/mem/ledger.dclg")
		T.ok(lok == true, tostring(lerr))

		T.eq(l2:lookup(c, "codeA", { "g1", "g2" }), nil, "invalidation survives the round-trip")
		local log = l2:transitions(c, "codeA", { "g1", "g2" })
		T.ok(log ~= nil)
		T.eq(#log, 3)
		T.eq(log[1].to, "proved")
		T.eq(log[2].to, "refuted")
		T.eq(log[3].to, "invalidated")
	end)

	T.it("plain-data verdict payloads (nested tables) survive the round-trip byte-for-byte", function()
		local caps = make_memfs()
		local l1 = ledger.new({ persist = caps })
		local c = mkclaim("s1")
		l1:record(c, "codeA", {}, kernel.proved({
			invariant = "0 <= i and i < n",
			witnesses = { 1, 2, 3 },
			meta = { confidence = 0.97, name = "loop-inv" },
		}))
		l1:save("/mem/ledger2.dclg")

		local l2 = ledger.new({ persist = caps })
		l2:load("/mem/ledger2.dclg")
		local got = l2:lookup(c, "codeA", {})
		local cert = kernel.cert(got)
		T.eq(cert.invariant, "0 <= i and i < n")
		T.eq(cert.witnesses[1], 1)
		T.eq(cert.witnesses[2], 2)
		T.eq(cert.witnesses[3], 3)
		T.eq(cert.meta.name, "loop-inv")
	end)

	T.it("a non-plain-data payload (a function) fails save() explicitly", function()
		local caps = make_memfs()
		local l = ledger.new({ persist = caps })
		local c = mkclaim("s1")
		l:record(c, "codeA", {}, kernel.proved(function() end))
		local ok, err = l:save("/mem/ledger3.dclg")
		T.eq(ok, nil)
		T.ok(err ~= nil)
	end)

	T.it("load() of a missing file errors", function()
		local caps = make_memfs()
		local l = ledger.new({ persist = caps })
		local ok, err = l:load("/mem/does-not-exist.dclg")
		T.eq(ok, nil)
		T.ok(err ~= nil)
	end)
end)
