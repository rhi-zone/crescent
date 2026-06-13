-- lib/type/analysis/per_property_metric.lua
--
-- Per-property metric measurement for the leverage critique of the design thesis.
-- (docs/artifacts/typechecker-run-2026-06-12/critique-leverage.md)
--
-- METRIC: "sound-verdict sites" — expression/statement sites in the corpus that
-- receive a sound typed verdict from the checker (accepted, rejected, or unknown
-- claims from A.check). Sites abandoned as OOS markers are NOT sound-verdict sites
-- (they produce no claim at all). The metric is:
--
--   SV = sum over all files of |accepted_claims| + |rejected_claims| + |unknown_claims|
--
-- And its complement:
--   Abandoned_sites ≈ total OOS markers (each marker = one site that produced no claim)
--
-- We measure:
--  1. Current SV (the baseline).
--  2. How many abandoned sites become sound-verdict sites after:
--     (a) the totality fix (unbound→unknown): cascade unbound-name markers turn into
--         unknown-typed bindings, and downstream expression sites produce real claims.
--         The gain is bounded by the number of cascade markers (upper bound) since each
--         cascade marker is a currently-abandoned site.
--     (b) fixing dynamic-index (top root construct at 5,061 occurrences): each
--         dynamic-index marker is a currently-abandoned site that would instead become
--         a checkable claim (against the synthesized index-result type).
--     (c) fixing multi-assign (second root construct, 2,419 occurrences).
--     (d) fixing multi-return (third root construct, 1,774 occurrences).
--
-- STATIC ESTIMATION (no behavior change): We use the marker counts from cascade_analysis
-- as a static proxy. Each root-construct marker = one currently-abandoned site that
-- would become a sound-verdict site once the construct is handled. Cascade markers
-- are a separate category: each is an abandoned site that would be recovered by the
-- totality fix — BUT only if the cascade terminates (i.e., the ROOT of the cascade
-- chain is itself handled). For cross-construct cascade (require→bit→band), the
-- unbound→unknown fix does NOT help: `require` is a root unbound-name gap, not a
-- cascade. The cascade unbound-name count (20,148) is the UPPER BOUND on totality-fix
-- gain, but for chains rooted in a root-unbound-name (like `require` or `ffi`), the
-- totality fix only helps if the root is also fixed. We account for this by separating:
--   - Pure cascade (rooted in a root-CONSTRUCT OOS, not a root-unbound-name): gain
--     is the full cascade chain.
--   - Cross-boundary cascade (rooted in a root-unbound-name like `require`): gain
--     requires BOTH the totality fix AND the root-unbound-name to be handled.
--
-- Usage:  bin/cr run lib/type/analysis/per_property_metric.lua

local L = require("lib.type.analysis.crescent_slice_lower")
local A = require("lib.type.analysis")
local S = require("lib.type.analysis.crescent_slice")

-- ── helpers ──────────────────────────────────────────────────────────────────

--: (path: string) -> (string | nil, string | nil)
local function read_file(path)
	local fh = io.open(path, "r")
	if not fh then return nil, "cannot open " .. path end
	local s = fh:read("*a")
	fh:close()
	if type(s) ~= "string" then return nil, "read failed" end
	return s, nil
end

--: () -> string[]
local function list_corpus()
	local cmd = "find lib -name '*.lua' ! -name '*_test.lua' | grep -v '/corpus/' | sort"
	local h = assert(io.popen(cmd, "r"))
	local files = {} --[[: string[] ]]
	for line in h:lines() do files[#files + 1] = tostring(line) end
	h:close()
	return files
end

--: () -> SemanticsRegistry
local function e2e_reg()
	local r = A.new_registry()
	S.register(r)
	return r
end

-- Extract the set of names that appear as LOCAL declaration targets in source.
--: (string) -> { [string]: boolean }
local function local_decl_names(src)
	local names = {} --[[: { [string]: boolean } ]]
	for nm in src:gmatch("[%s;]local%s+function%s+([%a_][%w_]*)") do
		names[nm] = true
	end
	for decl in src:gmatch("[%s;]local%s+([%a_][%w_%s,]+)[=\n]") do
		for nm in decl:gmatch("[%a_][%w_]*") do
			names[nm] = true
		end
	end
	for nm in src:gmatch("^local%s+([%a_][%w_]*)") do
		names[nm] = true
	end
	for nm in src:gmatch("\nlocal%s+([%a_][%w_]*)") do
		names[nm] = true
	end
	return names
end

-- ── per-file measurement ─────────────────────────────────────────────────────

--:: FileMetric = {
--::   path: string,
--::   class: string,
--::   sv_accepted: integer,
--::   sv_rejected: integer,
--::   sv_unknown: integer,
--::   sv_total: integer,
--::   oos_markers: integer,
--::   oos_root_construct: integer,
--::   oos_cascade_upper: integer,
--::   oos_root_unbound: integer,
--::   top_root_constructs: { [string]: integer },
--:: }

--: (string) -> FileMetric
local function measure_file(path)
	local src0, rerr = read_file(path)
	if not src0 then
		local _ = rerr
		return {
			path = path, class = "PARSE-FAIL",
			sv_accepted = 0, sv_rejected = 0, sv_unknown = 0, sv_total = 0,
			oos_markers = 0, oos_root_construct = 0, oos_cascade_upper = 0, oos_root_unbound = 0,
			top_root_constructs = {},
		}
	end
	local src = src0 --[[: string ]]
	local local_names = local_decl_names(src)

	local res = L.lower(src, path, { read_file = read_file, stdlib = true })
	if not res then
		return {
			path = path, class = "LOWER-FAIL",
			sv_accepted = 0, sv_rejected = 0, sv_unknown = 0, sv_total = 0,
			oos_markers = 0, oos_root_construct = 0, oos_cascade_upper = 0, oos_root_unbound = 0,
			top_root_constructs = {},
		}
	end

	-- run the substrate check; count accepted/rejected/unknown claims.
	local chk = A.check({ state = res.state, requested_claims = res.requested,
		semantics_registry = e2e_reg(), trust_policy = nil }) --[[: { accepted_claims: { [string]: unknown }, rejected_claims: { [string]: unknown }, unknown_claims: { [string]: unknown } } | nil ]]
	local sv_accepted, sv_rejected, sv_unknown = 0, 0, 0
	if chk then
		for _ in pairs(chk.accepted_claims) do sv_accepted = sv_accepted + 1 end
		for _ in pairs(chk.rejected_claims) do sv_rejected = sv_rejected + 1 end
		for _ in pairs(chk.unknown_claims) do sv_unknown = sv_unknown + 1 end
	end
	local sv_total = sv_accepted + sv_rejected + sv_unknown

	-- classify OOS markers (ALL markers, not capped at 3).
	local root_constructs = {} --[[: { [string]: integer } ]]
	local oos_markers = 0
	local oos_root_construct = 0
	local oos_cascade_upper = 0
	local oos_root_unbound = 0

	for _, mk in ipairs(res.markers) do
		local c = mk.construct or "unknown"
		local is_finding = c:find("error$") ~= nil or c == "type-mismatch" or c:find("%-fail$") ~= nil
		if not is_finding then
			oos_markers = oos_markers + 1
			local nm = c:match("^unbound%-name:(.+)$")
			if nm then
				if local_names[nm] then
					oos_cascade_upper = oos_cascade_upper + 1
				else
					oos_root_unbound = oos_root_unbound + 1
				end
			else
				oos_root_construct = oos_root_construct + 1
				root_constructs[c] = (root_constructs[c] or 0) + 1
			end
		end
	end

	-- file class
	local class = "CHECKED-CLEAN" --: string
	if oos_markers > 0 then
		class = "OUT-OF-SUBSET"
	elseif sv_rejected > 0 or sv_unknown > 0 then
		class = "CHECKED-FINDINGS"
	elseif #res.requested == 0 then
		class = "NO-ANNOTATION"
	end

	return {
		path = path, class = class,
		sv_accepted = sv_accepted, sv_rejected = sv_rejected,
		sv_unknown = sv_unknown, sv_total = sv_total,
		oos_markers = oos_markers,
		oos_root_construct = oos_root_construct,
		oos_cascade_upper = oos_cascade_upper,
		oos_root_unbound = oos_root_unbound,
		top_root_constructs = root_constructs,
	}
end

-- timed wrapper (10s budget, same as cascade_analysis).
--: (string) -> FileMetric
local function measure_file_timed(path)
	local start = os.clock()
	local timed_out = false --: boolean
	local captured --[[: FileMetric | nil ]]
	--: (string, integer | nil) -> nil
	local function hook(_event, _line)
		if os.clock() - start > 10.0 then
			timed_out = true
			error("per_property_metric: per-file budget exceeded", 2)
		end
	end
	--: () -> nil
	local function run() captured = measure_file(path) end
	debug.sethook(hook, "", 100000)
	local ok, res = pcall(run)
	debug.sethook()
	if ok and captured ~= nil then return captured end
	local _ = timed_out
	local _ = res
	return {
		path = path, class = "TIMEOUT",
		sv_accepted = 0, sv_rejected = 0, sv_unknown = 0, sv_total = 0,
		oos_markers = 0, oos_root_construct = 0, oos_cascade_upper = 0, oos_root_unbound = 0,
		top_root_constructs = {},
	}
end

-- ── corpus run ────────────────────────────────────────────────────────────────

local function main()
	local files = list_corpus()
	local n = #files

	-- corpus-wide SV totals.
	local total_sv_accepted = 0
	local total_sv_rejected = 0
	local total_sv_unknown  = 0
	local total_sv          = 0

	-- corpus-wide OOS marker totals.
	local total_oos         = 0
	local total_oos_rc      = 0   -- root-construct (the direct OOS gap)
	local total_oos_cascade = 0   -- cascade unbound-name (upper bound)
	local total_oos_runbound = 0  -- root unbound-name (global/stdlib gaps)

	-- per-construct root-construct histograms (marker count across corpus).
	local rc_hist = {} --[[: { [string]: integer } ]]

	-- class histogram.
	local by_class = {} --[[: { [string]: integer } ]]

	-- for cascade-scope analysis: count cascade markers that are rooted in a
	-- root-CONSTRUCT (not a root-unbound-name) so they'd be recovered by totality fix.
	-- We track per-file whether the file has any root-unbound markers: cascade markers
	-- in files with zero root-unbound are "pure cascade" (rooted only in root constructs).
	-- Cascade markers in files WITH root-unbound are ambiguous (may be rooted in either).
	local pure_cascade_files_cascade_sum = 0   -- cascade markers in pure-cascade files
	local mixed_cascade_files_cascade_sum = 0  -- cascade markers in mixed files

	io.write("per_property_metric: scanning " .. n .. " files...\n")
	io.flush()

	for i, path in ipairs(files) do
		if i % 50 == 0 then
			io.write("  " .. i .. "/" .. n .. "\n")
			io.flush()
		end
		local r = measure_file_timed(path)

		-- accumulate.
		total_sv_accepted = total_sv_accepted + r.sv_accepted
		total_sv_rejected = total_sv_rejected + r.sv_rejected
		total_sv_unknown  = total_sv_unknown  + r.sv_unknown
		total_sv          = total_sv          + r.sv_total
		total_oos         = total_oos         + r.oos_markers
		total_oos_rc      = total_oos_rc      + r.oos_root_construct
		total_oos_cascade = total_oos_cascade + r.oos_cascade_upper
		total_oos_runbound = total_oos_runbound + r.oos_root_unbound
		by_class[r.class] = (by_class[r.class] or 0) + 1

		for c, cnt in pairs(r.top_root_constructs) do
			rc_hist[c] = (rc_hist[c] or 0) + cnt
		end

		-- pure vs mixed cascade classification.
		if r.oos_cascade_upper > 0 then
			if r.oos_root_unbound == 0 then
				pure_cascade_files_cascade_sum = pure_cascade_files_cascade_sum + r.oos_cascade_upper
			else
				mixed_cascade_files_cascade_sum = mixed_cascade_files_cascade_sum + r.oos_cascade_upper
			end
		end
	end

	-- sort construct histogram descending.
	--: ({ [string]: integer }) -> { name: string, count: integer }[]
	local function sorted_desc(t)
		local arr = {} --[[: { name: string, count: integer }[] ]]
		for k, v in pairs(t) do arr[#arr + 1] = { name = k, count = v } end
		for i2 = 2, #arr do
			local cur = arr[i2]
			local j = i2 - 1
			while j >= 1 and (cur.count > arr[j].count or
					(cur.count == arr[j].count and cur.name < arr[j].name)) do
				arr[j + 1] = arr[j]; j = j - 1
			end
			arr[j + 1] = cur
		end
		return arr
	end

	--: (integer, integer) -> string
	local function pct(a, b)
		if b == 0 then return "0.0%" end
		return string.format("%.1f%%", 100.0 * a / b)
	end

	local sorted_rc = sorted_desc(rc_hist)
	local total_potential = total_sv + total_oos  -- every site: checked + abandoned

	-- ── COUNTERFACTUAL ESTIMATES (static, no behavior change) ─────────────────
	--
	-- Totality fix (unbound→unknown):
	--   Each cascade-unbound marker is a currently-abandoned site. After the fix,
	--   the abandoned-but-locally-declared name gets type `unknown`, and every
	--   downstream use of it becomes a real claim (accepted/rejected/unknown against
	--   unknown). The gain in SV is at most the cascade count.
	--
	--   BUT: cascade chains rooted in root-unbound-names (like `require`, `ffi`)
	--   are NOT recovered by the totality fix alone — the root unbound-name still
	--   propagates unbound, and the totality fix only helps for the downstream cascade
	--   FROM a successfully-handled (but currently-OOS) root CONSTRUCT. To get a
	--   conservative (honest) gain estimate, we use:
	--     - Upper bound: all cascade markers recovered (20,148).
	--     - Conservative bound: only pure-cascade markers (those in files with zero
	--       root-unbound-name markers — these chains are certainly rooted in a root
	--       construct that is OOS, not in a root unbound-name). These WOULD be
	--       recovered by totality fix alone.
	--     - The mixed-cascade markers require BOTH totality fix AND root-unbound fix
	--       (e.g. modeling `require`), so totality alone doesn't recover them.
	--
	-- Dynamic-index fix:
	--   Each dynamic-index marker is a currently-abandoned site (a table[key] expr
	--   the checker can't type). After the fix, the expr produces a real type and
	--   downstream sites check normally. The DIRECT gain is rc_hist["dynamic-index"].
	--   The INDIRECT gain (downstream cascade unblocked by the fix) requires estimating
	--   how many local names are downstream of a dynamic-index expression — we don't
	--   have that chain data, but the cascade chain analysis tells us that 690 partially-
	--   recoverable files have mixed root+cascade, and dynamic-index is the dominant
	--   root construct. We estimate the cascade multiplier from the cascade/root ratio.
	--
	-- Cascade multiplier estimate: across all files, cascade_upper / root_construct = 20148/30773 ≈ 0.65.
	-- But this includes cascade from root-unbound-names too. For construct-rooted chains:
	-- pure_cascade / root_constructs_in_pure_files. We use the simpler corpus-wide multiplier
	-- as a conservative estimate (it understates the dynamic-index indirect gain since
	-- many cascades are from require/ffi, not dynamic-index).

	local di_count = rc_hist["dynamic-index"] or 0
	local ma_count = rc_hist["multi-assign"] or 0
	local mr_count = rc_hist["multi-return"] or 0
	local expr_count = rc_hist["expr"] or 0

	-- Indirect SV gain per root-construct fix: we use the corpus-wide OOS cascade
	-- fraction applied to the root-construct fraction that dynamic-index represents,
	-- but restricted to the construct-rooted cascade (pure_cascade). Each
	-- dynamic-index occurrence is 5061 of 30773 root-construct markers = 16.4% of all
	-- root constructs. Assuming cascades distribute proportionally to their root, the
	-- dynamic-index-rooted fraction of pure_cascade ≈ pure_cascade * (di_count/total_oos_rc).
	-- Note: this is a structural estimate; the true cascade-per-construct is not measured.

	local di_share_of_rc = (total_oos_rc > 0) and (di_count / total_oos_rc) or 0.0
	local di_indirect_est = math.floor(pure_cascade_files_cascade_sum * di_share_of_rc + 0.5)
	local di_total_est = di_count + di_indirect_est

	local ma_share_of_rc = (total_oos_rc > 0) and (ma_count / total_oos_rc) or 0.0
	local ma_indirect_est = math.floor(pure_cascade_files_cascade_sum * ma_share_of_rc + 0.5)
	local ma_total_est = ma_count + ma_indirect_est

	-- Totality fix: gains the UPPER BOUND of cascade (all cascade markers turn into
	-- real SV sites), but only for cascade chains not rooted in root-unbound-names.
	-- We present both bounds.
	local totality_conservative = pure_cascade_files_cascade_sum
	local totality_upper = total_oos_cascade

	-- ── OUTPUT ────────────────────────────────────────────────────────────────

	io.write("\n")
	io.write("=== PER-PROPERTY METRIC RESULTS ===\n\n")
	io.write(string.format("corpus:                        %d files\n", n))
	io.write("\n")

	io.write("--- CURRENT SOUND-VERDICT SITES (SV) ---\n")
	io.write(string.format("  accepted_claims:             %d\n", total_sv_accepted))
	io.write(string.format("  rejected_claims:             %d\n", total_sv_rejected))
	io.write(string.format("  unknown_claims:              %d\n", total_sv_unknown))
	io.write(string.format("  TOTAL SV (accepted+rej+unk): %d\n", total_sv))
	io.write("\n")

	io.write("--- CURRENTLY ABANDONED SITES (OOS MARKERS) ---\n")
	io.write(string.format("  total OOS markers:           %d\n", total_oos))
	io.write(string.format("    root-construct:            %d  (%s of OOS)\n",
		total_oos_rc, pct(total_oos_rc, total_oos)))
	io.write(string.format("    cascade unbound (upper):   %d  (%s of OOS)\n",
		total_oos_cascade, pct(total_oos_cascade, total_oos)))
	io.write(string.format("    root unbound (lower):      %d  (%s of OOS)\n",
		total_oos_runbound, pct(total_oos_runbound, total_oos)))
	io.write("\n")

	io.write(string.format("  total potential sites (SV + OOS): %d\n", total_potential))
	io.write(string.format("  current SV coverage:         %s of all potential sites\n",
		pct(total_sv, total_potential)))
	io.write("\n")

	io.write("--- PURE vs MIXED CASCADE (for totality-fix scope) ---\n")
	io.write(string.format("  pure-cascade (files with zero root-unbound):  %d cascade markers\n",
		pure_cascade_files_cascade_sum))
	io.write(string.format("  mixed-cascade (files WITH root-unbound):      %d cascade markers\n",
		mixed_cascade_files_cascade_sum))
	io.write("  (mixed cascade requires BOTH totality fix AND root-unbound fix to recover)\n")
	io.write("\n")

	io.write("--- COUNTERFACTUAL SV GAIN ESTIMATES ---\n")
	io.write(string.format("  [TOTALITY FIX: unbound→unknown]\n"))
	io.write(string.format("    conservative gain (pure-cascade sites recovered): +%d SV\n",
		totality_conservative))
	io.write(string.format("    upper bound (all cascade sites recovered):        +%d SV\n",
		totality_upper))
	io.write(string.format("    post-fix SV range:  [%d, %d]\n",
		total_sv + totality_conservative, total_sv + totality_upper))
	io.write(string.format("    pct gain (conservative / current):  %s\n",
		pct(totality_conservative, total_sv)))
	io.write(string.format("    pct gain (upper / current):         %s\n\n",
		pct(totality_upper, total_sv)))

	io.write(string.format("  [DYNAMIC-INDEX FIX]\n"))
	io.write(string.format("    direct gain (dynamic-index markers become SV): +%d SV\n", di_count))
	io.write(string.format("    estimated indirect cascade gain:               +%d SV\n", di_indirect_est))
	io.write(string.format("    total estimated gain:                          +%d SV\n", di_total_est))
	io.write(string.format("    pct gain vs current SV:  %s\n\n",
		pct(di_total_est, total_sv)))

	io.write(string.format("  [MULTI-ASSIGN FIX]\n"))
	io.write(string.format("    direct gain:                                   +%d SV\n", ma_count))
	io.write(string.format("    estimated indirect cascade gain:               +%d SV\n", ma_indirect_est))
	io.write(string.format("    total estimated gain:                          +%d SV\n", ma_total_est))
	io.write(string.format("    pct gain vs current SV:  %s\n\n",
		pct(ma_total_est, total_sv)))

	io.write(string.format("  [MULTI-RETURN FIX]\n"))
	io.write(string.format("    direct gain:                                   +%d SV\n", mr_count))
	io.write(string.format("    pct gain vs current SV:  %s\n\n",
		pct(mr_count, total_sv)))

	io.write(string.format("  [TOP-4 ROOT CONSTRUCTS COMBINED (di+ma+mr+expr)]\n"))
	local top4 = di_count + ma_count + mr_count + expr_count
	local top4_indirect = di_indirect_est + ma_indirect_est
	local top4_total = top4 + top4_indirect
	io.write(string.format("    direct gain (di+ma+mr+expr markers):          +%d SV\n", top4))
	io.write(string.format("    estimated indirect cascade gain (di+ma only): +%d SV\n", top4_indirect))
	io.write(string.format("    total estimated gain:                         +%d SV\n", top4_total))
	io.write(string.format("    pct gain vs current SV:  %s\n\n",
		pct(top4_total, total_sv)))

	io.write("--- TOP ROOT-CONSTRUCT MARKERS (marker count, all occurrences) ---\n")
	for i2 = 1, math.min(20, #sorted_rc) do
		local e = sorted_rc[i2]
		if e then io.write(string.format("  %6d  %s\n", e.count, e.name)) end
	end
	io.write("\n")

	io.write("--- FILE CLASS SUMMARY ---\n")
	local order = { "CHECKED-CLEAN", "CHECKED-FINDINGS", "OUT-OF-SUBSET", "NO-ANNOTATION", "TIMEOUT", "LOWER-FAIL", "PARSE-FAIL" }
	for _, c in ipairs(order) do
		io.write(string.format("  %-22s %4d  %s\n", c, by_class[c] or 0, pct(by_class[c] or 0, n)))
	end
	io.write("\n")

	-- Print structured summary for the markdown artifact.
	io.write("=== STRUCTURED SUMMARY (for artifact) ===\n")
	io.write(string.format("current_sv=%d\n", total_sv))
	io.write(string.format("current_sv_accepted=%d\n", total_sv_accepted))
	io.write(string.format("current_sv_rejected=%d\n", total_sv_rejected))
	io.write(string.format("current_sv_unknown=%d\n", total_sv_unknown))
	io.write(string.format("total_oos=%d\n", total_oos))
	io.write(string.format("total_oos_rc=%d\n", total_oos_rc))
	io.write(string.format("total_oos_cascade=%d\n", total_oos_cascade))
	io.write(string.format("total_oos_runbound=%d\n", total_oos_runbound))
	io.write(string.format("total_potential=%d\n", total_potential))
	io.write(string.format("pure_cascade=%d\n", pure_cascade_files_cascade_sum))
	io.write(string.format("mixed_cascade=%d\n", mixed_cascade_files_cascade_sum))
	io.write(string.format("totality_conservative=%d\n", totality_conservative))
	io.write(string.format("totality_upper=%d\n", totality_upper))
	io.write(string.format("di_count=%d\n", di_count))
	io.write(string.format("di_indirect=%d\n", di_indirect_est))
	io.write(string.format("di_total=%d\n", di_total_est))
	io.write(string.format("ma_count=%d\n", ma_count))
	io.write(string.format("mr_count=%d\n", mr_count))
	io.write(string.format("top4_total=%d\n", top4_total))
end

if type(arg) == "table" then
	local av = arg --[[: { [integer]: string } ]]
	local a0 = av[0]
	if type(a0) == "string" and a0:find("per_property_metric", 1, true) then
		main()
	end
end

return { main = main }
