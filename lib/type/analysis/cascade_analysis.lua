-- lib/type/analysis/cascade_analysis.lua
--
-- Gap-cascade magnitude analysis for the crescent slice.
--
-- QUESTION: of all the out-of-subset markers produced by the e2e lowering pass,
-- how many are ROOT gaps (a genuinely-unsupported construct or a truly-undeclared
-- global) versus CASCADE victims (an `unbound-name:X` that only exists because a
-- `local X = <oos-expr>` left X unbound upstream)?
--
-- METHOD:
--  1. Run L.lower() on every corpus file (same path as survey_file_e2e), capturing
--     the full per-marker list (not just the first 3).
--  2. For each file, collect every marker (all constructs, not capped).
--  3. Separate `unbound-name:*` markers from other (root-construct) markers.
--  4. For each `unbound-name:NAME` marker, determine whether it is a CASCADE or ROOT:
--     - LOWER_BOUND cascade: any `unbound-name:NAME` where NAME appears as a
--       locally-declared variable in the source (`local NAME` or `local NAME,` or
--       `local NAME =`). This is a superset of cascade — it catches ALL locals,
--       including those that syntactically succeeded but whose binding was dropped
--       for other reasons. In practice `ctx_get` only misses a name when (a) it was
--       never bound or (b) the lowering skipped the binding. For locals WITH an
--       assignment, only (b) applies.
--     - ROOT: the name never appears as a local declaration target in the source.
--       These are globals, stdlib functions, upvalues from outer scopes, or
--       names introduced by non-local means (module-table fields accessed as bare
--       names, etc.).
--  5. Per-file: classify as FULLY-CASCADE (all OOS markers are cascade unbound-name),
--     PARTIALLY-CASCADE, or ROOT-ONLY (no cascade markers / only root OOS markers).
--
-- DISTINCTION VALIDITY:
--  The source-level `local NAME` scan is conservative-inclusive: it finds every
--  lexically-declared local, whether or not the lowering actually abandoned it. A
--  name declared locally can ALSO be genuinely unbound if its scope chain is wrong
--  (a local shadowed by a differently-scoped oos binding, etc.) but this is rare
--  and keeps the cascade count as an UPPER BOUND on true cascade. The ROOT category
--  (names never declared locally) is therefore a LOWER BOUND on true root gaps.
--
-- This gives us: cascade ∈ [lower_cascade, upper_cascade] and root ∈ [lower_root, upper_root]
-- where lower_cascade + upper_root = total and upper_cascade + lower_root = total.
-- In practice the set of "declared local but not actually cascade" is tiny (a local
-- that resolves fine in its own scope but later appears as unbound in a nested
-- closure that does not inherit the outer ctx). We report both bounds.
--
-- Usage:  bin/cr run lib/type/analysis/cascade_analysis.lua

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
-- Matches: `local NAME`, `local NAME,`, `local NAME =`, `local function NAME`.
-- Returns a set { [name]: true }.
--: (string) -> { [string]: boolean }
local function local_decl_names(src)
	local names = {} --[[: { [string]: boolean } ]]
	-- local function NAME
	for nm in src:gmatch("[%s;]local%s+function%s+([%a_][%w_]*)") do
		names[nm] = true
	end
	-- local NAME[,= \n]  (one or more names on the same decl, comma-separated)
	for decl in src:gmatch("[%s;]local%s+([%a_][%w_%s,]+)[=\n]") do
		for nm in decl:gmatch("[%a_][%w_]*") do
			names[nm] = true
		end
	end
	-- also handle `local NAME` at start of file or after newline
	for nm in src:gmatch("^local%s+([%a_][%w_]*)") do
		names[nm] = true
	end
	for nm in src:gmatch("\nlocal%s+([%a_][%w_]*)") do
		names[nm] = true
	end
	return names
end

-- ── per-file analysis ─────────────────────────────────────────────────────────

--:: CascadeResult = {
--::   path: string,
--::   class: string,
--::   total_markers: integer,
--::   root_construct_markers: integer,
--::   unbound_total: integer,
--::   unbound_cascade_upper: integer,
--::   unbound_root_lower: integer,
--::   root_constructs: { [string]: integer },
--::   unbound_cascade_names: { [string]: integer },
--::   unbound_root_names: { [string]: integer },
--:: }

--: (string) -> CascadeResult
local function analyze_file(path)
	local src0, rerr = read_file(path)
	if not src0 then
		local _ = rerr
		return {
			path = path, class = "PARSE-FAIL",
			total_markers = 0, root_construct_markers = 0,
			unbound_total = 0, unbound_cascade_upper = 0, unbound_root_lower = 0,
			root_constructs = {}, unbound_cascade_names = {}, unbound_root_names = {},
		}
	end
	local src = src0 --[[: string ]]
	local local_names = local_decl_names(src)

	local res = L.lower(src, path, { read_file = read_file, stdlib = true })
	if not res then
		return {
			path = path, class = "LOWER-FAIL",
			total_markers = 0, root_construct_markers = 0,
			unbound_total = 0, unbound_cascade_upper = 0, unbound_root_lower = 0,
			root_constructs = {}, unbound_cascade_names = {}, unbound_root_names = {},
		}
	end

	-- also run the substrate check to count rejected/unknown claims (findings).
	local chk = A.check({ state = res.state, requested_claims = res.requested,
		semantics_registry = e2e_reg(), trust_policy = nil }) --[[: { accepted_claims: { [string]: unknown }, rejected_claims: { [string]: unknown }, unknown_claims: { [string]: unknown } } | nil ]]
	local rej, unk = 0, 0
	if chk then
		for _ in pairs(chk.rejected_claims) do rej = rej + 1 end
		for _ in pairs(chk.unknown_claims) do unk = unk + 1 end
	end

	-- classify ALL markers (not capped at 3).
	local root_constructs = {} --[[: { [string]: integer } ]]
	local unbound_cascade_names = {} --[[: { [string]: integer } ]]
	local unbound_root_names = {} --[[: { [string]: integer } ]]
	local total_markers = 0
	local root_construct_markers = 0
	local unbound_total = 0
	local unbound_cascade_upper = 0
	local unbound_root_lower = 0

	for _, mk in ipairs(res.markers) do
		local c = mk.construct or "unknown"
		-- skip "findings" (type-mismatch / *-error / *-fail): these are real checker
		-- findings, not out-of-subset gap markers.
		local is_finding = c:find("error$") ~= nil or c == "type-mismatch" or c:find("%-fail$") ~= nil
		if not is_finding then
			total_markers = total_markers + 1
			local nm = c:match("^unbound%-name:(.+)$")
			if nm then
				unbound_total = unbound_total + 1
				if local_names[nm] then
					unbound_cascade_upper = unbound_cascade_upper + 1
					unbound_cascade_names[nm] = (unbound_cascade_names[nm] or 0) + 1
				else
					unbound_root_lower = unbound_root_lower + 1
					unbound_root_names[nm] = (unbound_root_names[nm] or 0) + 1
				end
			else
				root_construct_markers = root_construct_markers + 1
				root_constructs[c] = (root_constructs[c] or 0) + 1
			end
		end
	end

	-- also count rejected/unknown claims as findings (not OOS markers).
	local _ = rej
	local _ = unk

	-- file class (mirrors survey_file_e2e logic).
	local class = "CHECKED-CLEAN" --: string
	if total_markers > 0 then
		class = "OUT-OF-SUBSET"
	elseif rej > 0 or unk > 0 then
		class = "CHECKED-FINDINGS"
	elseif #res.requested == 0 then
		class = "NO-ANNOTATION"
	end

	return {
		path = path, class = class,
		total_markers = total_markers,
		root_construct_markers = root_construct_markers,
		unbound_total = unbound_total,
		unbound_cascade_upper = unbound_cascade_upper,
		unbound_root_lower = unbound_root_lower,
		root_constructs = root_constructs,
		unbound_cascade_names = unbound_cascade_names,
		unbound_root_names = unbound_root_names,
	}
end

-- timed wrapper (same budget as survey).
--: (string) -> CascadeResult
local function analyze_file_timed(path)
	local start = os.clock()
	local timed_out = false --: boolean
	local captured --[[: CascadeResult | nil ]]
	--: (string, integer | nil) -> nil
	local function hook(_event, _line)
		if os.clock() - start > 10.0 then
			timed_out = true
			error("cascade_analysis: per-file budget exceeded", 2)
		end
	end
	--: () -> nil
	local function run() captured = analyze_file(path) end
	debug.sethook(hook, "", 100000)
	local ok, res = pcall(run)
	debug.sethook()
	if ok and captured ~= nil then return captured end
	local _ = timed_out
	local _ = res
	return {
		path = path, class = "TIMEOUT-OR-CRASH",
		total_markers = 0, root_construct_markers = 0,
		unbound_total = 0, unbound_cascade_upper = 0, unbound_root_lower = 0,
		root_constructs = {}, unbound_cascade_names = {}, unbound_root_names = {},
	}
end

-- ── corpus run ────────────────────────────────────────────────────────────────

local function main()
	local files = list_corpus()
	local results = {} --[[: CascadeResult[] ]]

	-- corpus-wide counters.
	local corpus_total_markers = 0
	local corpus_root_construct = 0
	local corpus_unbound_total = 0
	local corpus_unbound_cascade = 0
	local corpus_unbound_root = 0

	-- global construct histograms.
	local global_root_constructs = {} --[[: { [string]: integer } ]]
	local global_unbound_root_names = {} --[[: { [string]: integer } ]]
	local global_unbound_cascade_names = {} --[[: { [string]: integer } ]]

	-- per-file cascade/root classification (for recovery estimate).
	local by_class = {} --[[: { [string]: integer } ]]

	-- files where ONLY cascade unbound-name markers (⇒ fully recoverable).
	local fully_cascade_files = 0
	-- files with SOME cascade and SOME non-cascade OOS markers.
	local partially_cascade_files = 0
	-- files with non-zero OOS markers but ZERO cascade markers.
	local root_only_files = 0

	local n = #files
	io.write("cascade_analysis: scanning " .. n .. " files...\n")
	io.flush()

	for i, path in ipairs(files) do
		if i % 50 == 0 then
			io.write("  " .. i .. "/" .. n .. "\n")
			io.flush()
		end
		local r = analyze_file_timed(path)
		results[#results + 1] = r
		by_class[r.class] = (by_class[r.class] or 0) + 1

		corpus_total_markers = corpus_total_markers + r.total_markers
		corpus_root_construct = corpus_root_construct + r.root_construct_markers
		corpus_unbound_total = corpus_unbound_total + r.unbound_total
		corpus_unbound_cascade = corpus_unbound_cascade + r.unbound_cascade_upper
		corpus_unbound_root = corpus_unbound_root + r.unbound_root_lower

		for c, cnt in pairs(r.root_constructs) do
			global_root_constructs[c] = (global_root_constructs[c] or 0) + cnt
		end
		for nm, cnt in pairs(r.unbound_root_names) do
			global_unbound_root_names[nm] = (global_unbound_root_names[nm] or 0) + cnt
		end
		for nm, cnt in pairs(r.unbound_cascade_names) do
			global_unbound_cascade_names[nm] = (global_unbound_cascade_names[nm] or 0) + cnt
		end

		if r.total_markers > 0 then
			local has_cascade = r.unbound_cascade_upper > 0
			local has_root_oos = (r.root_construct_markers + r.unbound_root_lower) > 0
			if has_cascade and not has_root_oos then
				fully_cascade_files = fully_cascade_files + 1
			elseif has_cascade and has_root_oos then
				partially_cascade_files = partially_cascade_files + 1
			elseif has_root_oos then
				root_only_files = root_only_files + 1
			end
		end
	end

	-- ── report ────────────────────────────────────────────────────────────────

	-- sort a count table descending.
	--: ({ [string]: integer }) -> { name: string, count: integer }[]
	local function sorted_desc(t)
		local arr = {} --[[: { name: string, count: integer }[] ]]
		for k, v in pairs(t) do arr[#arr + 1] = { name = k, count = v } end
		for i = 2, #arr do
			local cur = arr[i]
			local j = i - 1
			while j >= 1 and (cur.count > arr[j].count or (cur.count == arr[j].count and cur.name < arr[j].name)) do
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

	io.write("\n")
	io.write("=== CASCADE ANALYSIS RESULTS ===\n\n")
	io.write(string.format("corpus files:                  %d\n", n))
	io.write(string.format("total OOS markers (all files): %d\n", corpus_total_markers))
	io.write(string.format("  root-construct markers:      %d  (%s of total)\n",
		corpus_root_construct, pct(corpus_root_construct, corpus_total_markers)))
	io.write(string.format("  unbound-name markers total:  %d  (%s of total)\n",
		corpus_unbound_total, pct(corpus_unbound_total, corpus_total_markers)))
	io.write(string.format("    cascade (upper bound):     %d  (%s of total)\n",
		corpus_unbound_cascade, pct(corpus_unbound_cascade, corpus_total_markers)))
	io.write(string.format("    root   (lower bound):      %d  (%s of total)\n",
		corpus_unbound_root, pct(corpus_unbound_root, corpus_total_markers)))
	io.write("\n")

	io.write("--- FILE-LEVEL CLASSIFICATION (among OOS files) ---\n")
	io.write(string.format("  fully-cascade  (ALL markers are cascade unbound-name): %d files\n", fully_cascade_files))
	io.write(string.format("  partially-cascade (mix of cascade + root OOS):         %d files\n", partially_cascade_files))
	io.write(string.format("  root-only      (no cascade markers):                   %d files\n", root_only_files))
	io.write("\n")

	io.write("--- FILE CLASS SUMMARY ---\n")
	local order = { "CHECKED-CLEAN", "CHECKED-FINDINGS", "OUT-OF-SUBSET", "NO-ANNOTATION", "TIMEOUT-OR-CRASH", "LOWER-FAIL", "PARSE-FAIL" }
	for _, c in ipairs(order) do
		io.write(string.format("  %-22s %4d  %s\n", c, by_class[c] or 0, pct(by_class[c] or 0, n)))
	end
	io.write("\n")

	io.write("--- TOP ROOT-CONSTRUCT MARKERS (by occurrence count) ---\n")
	local sorted_rc = sorted_desc(global_root_constructs)
	for i = 1, math.min(30, #sorted_rc) do
		local e = sorted_rc[i]
		if e then io.write(string.format("  %6d  %s\n", e.count, e.name)) end
	end
	io.write("\n")

	io.write("--- TOP ROOT UNBOUND-NAMES (not locally declared; likely globals/stdlib) ---\n")
	local sorted_rn = sorted_desc(global_unbound_root_names)
	for i = 1, math.min(30, #sorted_rn) do
		local e = sorted_rn[i]
		if e then io.write(string.format("  %6d  %s\n", e.count, e.name)) end
	end
	io.write("\n")

	io.write("--- TOP CASCADE UNBOUND-NAMES (locally declared; cascade victims) ---\n")
	local sorted_cn = sorted_desc(global_unbound_cascade_names)
	for i = 1, math.min(30, #sorted_cn) do
		local e = sorted_cn[i]
		if e then io.write(string.format("  %6d  %s\n", e.count, e.name)) end
	end
	io.write("\n")

	-- recovery estimate: files that would become clean/findings if cascades vanished.
	-- A file is "fully recoverable" iff its ONLY OOS markers are cascade unbound-name
	-- markers (fully_cascade_files count). Partially recoverable = partially_cascade_files.
	io.write("--- RECOVERY ESTIMATE (if cascade markers eliminated) ---\n")
	io.write(string.format("  fully recoverable (cascade-only files):       %d files\n", fully_cascade_files))
	io.write(string.format("  partially recoverable (mixed files):           %d files\n", partially_cascade_files))
	io.write(string.format("  not recoverable (root-only OOS files):         %d files\n", root_only_files))
	local total_oos = fully_cascade_files + partially_cascade_files + root_only_files
	io.write(string.format("  total OOS files analyzed:                      %d files\n", total_oos))
	io.write("\n")

	-- raw data as JSON-ish for the markdown artifact.
	return {
		n = n,
		corpus_total_markers = corpus_total_markers,
		corpus_root_construct = corpus_root_construct,
		corpus_unbound_total = corpus_unbound_total,
		corpus_unbound_cascade = corpus_unbound_cascade,
		corpus_unbound_root = corpus_unbound_root,
		fully_cascade_files = fully_cascade_files,
		partially_cascade_files = partially_cascade_files,
		root_only_files = root_only_files,
		sorted_rc = sorted_rc,
		sorted_rn = sorted_rn,
		sorted_cn = sorted_cn,
		by_class = by_class,
	}
end

if type(arg) == "table" then
	local av = arg --[[: { [integer]: string } ]]
	local a0 = av[0]
	if type(a0) == "string" and a0:find("cascade_analysis", 1, true) then
		main()
	end
end

return { main = main }
