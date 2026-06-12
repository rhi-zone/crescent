-- lib/type/analysis/check_bench.lua
--
-- Benchmark harness for the substrate check loop (A.check) — measures the
-- fixpoint/worklist cost on (a) the real failing case (lib/type/v7_mr0/init.lua
-- lowered via crescent_slice_lower) and (b) a synthetic linear-chain scaling
-- curve at 100/1k/5k claims. Not a test; run via `bin/cr run`.

local A = require("lib.type.analysis")
local L = require("lib.type.analysis.crescent_slice_lower")
local S = require("lib.type.analysis.crescent_slice")

--: () -> SemanticsRegistry
local function reg()
	local r = A.new_registry()
	S.register(r)
	return r
end

-- ── Real case: lower v7_mr0 and check ────────────────────────────────────────
--: () -> nil
local function bench_real()
	local path = "lib/type/v7_mr0/init.lua"
	local fh = io.open(path, "r")
	if not fh then io.write("real: cannot open " .. path .. "\n"); return end
	local src = fh:read("*a"); fh:close()
	if type(src) ~= "string" then io.write("real: empty read\n"); return end
	local res = L.lower(src, path)
		--[[: { requested: Id[], state: AnalysisState } | nil ]]
	if not res then io.write("real: lower failed\n"); return end
	local n_claims = 0 --: integer
	for _ in pairs(res.state.claims) do n_claims = n_claims + 1 end
	local n_ev = 0 --: integer
	for _ in pairs(res.state.evidence) do n_ev = n_ev + 1 end
	local t0 = os.clock()
	local chk = A.check({ state = res.state, requested_claims = res.requested,
		semantics_registry = reg(), trust_policy = nil })
	local dt = os.clock() - t0
	io.write(string.format("real %s: claims=%d evidence=%d requested=%d check=%.3fs %s\n",
		path, n_claims, n_ev, #res.requested, dt, chk and "ok" or "nil"))
end

-- ── Synthetic chain: N claims, each accepted by evidence depending on the prior
-- claim. A linear dependency chain is the adversarial case for a re-sweeping
-- fixpoint (worst-case O(N) sweeps × O(N) evidence = O(N^2)); a worklist is O(N).
-- We use the prop semantics: claim prop(p_i), evidence `assumption` for p_0 and
-- `modus_ponens` style chaining is overkill — instead each p_{i+1} is proven by
-- an `and_elim_left` of an accepted `and(p_{i+1}, p_{i+1})`... simpler: use a
-- chain where evidence for claim i has claim i-1 as an input via the substrate's
-- input mechanism, and the hosted checker accepts iff inputs are accepted.
-- The prop `and_intro` method needs both conjuncts accepted; we build a chain of
-- and-claims so each depends on the previous. To keep it semantics-faithful and
-- avoid combinatorics, we use a dedicated minimal chain semantics registered
-- here whose only rule is "accept iff all declared inputs are accepted" — this is
-- the pure substrate dependency mechanism, no hosted vocabulary.

--: (integer, boolean) -> SemanticsRegistry
local function chain_reg()
	local r = A.new_registry()
	-- chain semantics: predicate `node`; method `link` accepts iff every input
	-- claim is already accepted (base case: zero inputs accepts immediately).
	A.register(r, {
		id = "chain", version = "1",
		claim_predicates = { "node" },
		evidence_methods = { "link" },
		--: (CheckContext, Claim, Evidence) -> (string, string | nil, Dependency[] | nil, unknown[] | nil)
		checker = function(ctx, _claim, ev)
			for _, inp in ipairs(ev.inputs) do
				if not ctx.is_accepted(inp) then return ctx.UNKNOWN end
			end
			return ctx.ACCEPTED
		end,
	})
	return r
end

-- Build a linear chain of N claims. claim_i depends on claim_{i-1}.
-- We deliberately add claims/evidence in REVERSE order so a naive submission
-- order needs many sweeps (the order-independence guarantee must still hold).
--: (integer) -> (AnalysisState, Id[])
local function build_chain(n)
	local st = A.new_state()
	local requested = {} --[[: Id[] ]]
	for i = n, 1, -1 do
		local cid = A.id("claim", "c" .. i)
		A.add_claim(st, A.claim({ id = cid, semantics = "chain",
			predicate = "node", args = { i } }))
		requested[#requested + 1] = cid
		local inputs = {} --[[: Id[] ]]
		if i > 1 then inputs[1] = A.id("claim", "c" .. (i - 1)) end
		A.add_evidence(st, A.evidence({ id = A.id("evidence", "e" .. i),
			claim = cid, method = "link", inputs = inputs }))
	end
	return st, requested
end

--: (integer) -> nil
local function bench_chain(n)
	local st, requested = build_chain(n)
	local r = chain_reg()
	local t0 = os.clock()
	local chk = A.check({ state = st, requested_claims = requested,
		semantics_registry = r, trust_policy = nil })
	local dt = os.clock() - t0
	local acc = 0 --: integer
	if chk then for _ in pairs(chk.accepted_claims) do acc = acc + 1 end end
	io.write(string.format("chain n=%d: accepted=%d check=%.4fs\n", n, acc, dt))
end

io.write("=== substrate check_bench ===\n")
bench_chain(100)
bench_chain(1000)
bench_chain(5000)
bench_real()
