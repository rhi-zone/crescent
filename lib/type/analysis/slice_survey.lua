-- lib/type/analysis/slice_survey.lua
--
-- The crescent.slice.v1 SURVEY PASS runner
-- (docs/agnostic-static-analysis-crescent-slice.md §10; docs/slice-survey-v1.md).
--
-- It drives the slice's parser-frontend ADAPTER (crescent_slice_parse.lua) over
-- the real lib/ corpus — every `.lua` file under lib/ excluding *_test.lua and
-- lib/type/analysis/corpus/ — and classifies each file by whether its
-- annotations sit inside the v1 type+annotation subset (§5).
--
-- WHAT IS CHECKED, AND WHY THIS SHAPE. The slice's adapter consumes real source
-- text at exactly one seam: the ANNOTATION type grammar (`--:` signatures and
-- `--::` aliases), parsed by `parse_type_ann` / `declare_alias`. There is no
-- whole-Lua-statement lowering in v1 (the corpus_test hand-builds derivations).
-- So the honest survey the substrate supports is an ANNOTATION-GRAMMAR
-- CONFORMANCE survey: extract every annotation from each file and drive it
-- through the adapter. The out-of-subset CONSTRUCT TAGS the adapter emits ARE the
-- demand ranking for slice v2 — which is precisely what this pass must produce.
--
-- This runner DOES NOT modify any lib/ file outside lib/type/analysis/. It is a
-- reusable measurement tool: re-run after every v2 increment.
--
-- Per-file classification:
--   CHECKED-CLEAN     : file has >=1 annotation; ALL parse within v1 (0 rejections).
--   CHECKED-FINDINGS  : a rejection with NO construct tag — a malformed/unexpected
--                       annotation. Either a real defect in the lib/ annotation,
--                       a slice precision gap, or an annotation gap (NOT classified
--                       here, only recorded; first 3 diagnostics per file).
--   OUT-OF-SUBSET     : a rejection WITH a construct tag (named-param, generic,
--                       cdata, …) — the adapter hit a construct outside v1. The
--                       construct tag is the payload.
--   NO-ANNOTATION     : file carries zero `--:`/`--::` annotations (nothing to
--                       check; recorded distinctly so percentages are honest).
--   PARSE-FAIL/OTHER  : the file could not be read, or a non-classified error.
--   TIMEOUT           : a single file's parse exceeded the budget (~5s). A slice
--                       hang on real code is a high-value finding.
--
-- Usage:  bin/cr run lib/type/analysis/slice_survey.lua [--md > docs/slice-survey-v1.md]

local P = require("lib.type.analysis.crescent_slice_parse")
local G = require("lib.type.analysis.slice_ty")

local M = {}

-- NOTE on aliases: this runner deliberately does NOT redeclare the slice's `Ty`
-- grammar alias, nor the adapter's `AliasEnv`. Both resolve transitively from the
-- required modules; a local redeclaration would shadow that cross-module
-- resolution and break the adapter's own typecheck. The alias map this runner
-- threads through the adapter is left to inference (its shape is fixed by the
-- `declare_alias` / `parse_type_ann` parameter types), and the runner only ever
-- PASSES alias values opaquely — it never introspects a `Ty`.

-- ── corpus file enumeration ──────────────────────────────────────────────────
-- Every .lua under lib/ excluding *_test.lua and lib/type/analysis/corpus/.

--: () -> string[]
local function list_corpus()
	local cmd = "find lib -name '*.lua' ! -name '*_test.lua' | grep -v '/corpus/' | sort"
	local h = assert(io.popen(cmd, "r"))
	local files = {} --[[: string[] ]]
	for line in h:lines() do files[#files + 1] = tostring(line) end
	h:close()
	return files
end

-- ── annotation extraction ────────────────────────────────────────────────────
-- Read a file, pull out its annotation directives in source order. Aliases
-- (`--::`) and signatures (`--:`) are kept ordered so the alias environment is
-- built before signatures that reference it.

--:: Ann = { kind: string, name?: string, body?: string, line: integer, text: string }

--: (string) -> ({ [integer]: Ann } | nil, string | nil)
local function extract_annotations(path)
	local fh = io.open(path, "r")
	if not fh then return nil, "cannot open file" end
	local anns = {} --[[: { [integer]: Ann } ]]
	local ln = 0 --: integer
	for line in fh:lines() do
		ln = ln + 1
		local sline = tostring(line) --: string
		local d = P.scan_annotation(sline)
		if d then
			local trimmed = sline:gsub("^%s+", "") --: string
			anns[#anns + 1] = {
				kind = d.kind, name = d.name, body = d.body,
				line = ln, text = trimmed,
			}
		end
	end
	fh:close()
	return anns
end

-- ── per-file survey ──────────────────────────────────────────────────────────
--
-- (`--::` declarations must each be a single line — multiline continuation is not
-- supported by the annotation parser.)
--
-- Diag       : one captured rejection (capped at 3 per file at the recording site).
-- FileResult : per-file outcome — `class` is one of the survey classes; `diags`
--              are the captured rejections; `constructs` is the set of distinct
--              out-of-subset construct tags hit; `n_ann` is the annotation count.

--:: Diag = { line: integer, text: string, err: string, construct?: string }
--:: FileResult = { path: string, class: string, diags: Diag[], constructs: { [string]: boolean }, n_ann: integer }

-- Survey one file. Returns a FileResult. Aliases are declared first (in order),
-- then signatures parsed against the accumulated alias environment.
--: (string) -> FileResult
local function survey_file(path)
	G.reset()
	local anns, rerr = extract_annotations(path)
	if not anns then
		return { path = path, class = "PARSE-FAIL/OTHER", diags = {
			{ line = 0, text = "", err = rerr or "read failed" } }, constructs = {}, n_ann = 0 }
	end
	if #anns == 0 then
		return { path = path, class = "NO-ANNOTATION", diags = {}, constructs = {}, n_ann = 0 }
	end

	local aliases = {}
	local diags = {} --[[: Diag[] ]]
	local constructs = {} --[[: { [string]: boolean } ]]
	local has_construct = false --: boolean
	local has_plain = false --: boolean

	-- process aliases first, then signatures (each in source order).
	for _, want_alias in ipairs({ true, false }) do
		for _, a in ipairs(anns) do
			local is_alias = a.kind == "alias"
			if is_alias == want_alias then
				local ok = false --: boolean
				local err --: string | nil
				local construct --: string | nil
				local name, body = a.name, a.body
				if is_alias then
					if name ~= nil and body ~= nil then
						local r, e, c = P.declare_alias(aliases, name, body)
						ok, err, construct = (r ~= nil), e, c
					else
						ok, err = false, "malformed alias directive"
					end
				else
					if body ~= nil then
						local r, e, c = P.parse_type_ann(body, aliases)
						ok, err, construct = (r ~= nil), e, c
					else
						ok, err = false, "empty signature directive"
					end
				end
				if not ok then
					local c_tag = construct --: string | nil
					if c_tag ~= nil then
						constructs[c_tag] = true
						has_construct = true
					else
						has_plain = true
					end
					-- record first 3 diagnostics per file (the prompt's cap).
					if #diags < 3 then
						local d_err = tostring(err or "parse failed") --: string
						local d = { line = a.line, text = a.text, err = d_err } --[[: Diag ]]
						if c_tag ~= nil then d.construct = c_tag end
						diags[#diags + 1] = d
					end
				end
			end
		end
	end

	local class = "CHECKED-CLEAN" --: string
	if has_construct then
		class = "OUT-OF-SUBSET"
	elseif has_plain then
		class = "CHECKED-FINDINGS"
	else
		class = "CHECKED-CLEAN"
	end
	return { path = path, class = class, diags = diags, constructs = constructs, n_ann = #anns }
end

M.survey_file = survey_file

-- ── per-file timeout discipline ──────────────────────────────────────────────
-- Run survey_file under a wall-clock budget. LuaJIT has no preemptive kill, so we
-- bound via a debug hook that errors after the budget elapses; a genuine hang in
-- the (pure, total) parser would be a high-value finding and is surfaced as
-- TIMEOUT. The hook checks os.clock() every N instructions.

--: (string, number) -> FileResult
local function survey_file_timed(path, budget_s)
	local start = os.clock()
	local timed_out = false --: boolean
	-- result captured by upvalue (avoids casting pcall's unknown return).
	local captured --: FileResult | nil
	--: (string, integer | nil) -> nil
	local function hook(_event, _line)
		if os.clock() - start > budget_s then
			timed_out = true
			error("slice_survey: per-file budget exceeded", 2)
		end
	end
	--: () -> nil
	local function run() captured = survey_file(path) end
	debug.sethook(hook, "", 100000)
	local ok, res = pcall(run)
	debug.sethook()
	if ok and captured ~= nil then return captured end
	if timed_out then
		return { path = path, class = "TIMEOUT", diags = {
			{ line = 0, text = "", err = "exceeded " .. budget_s .. "s budget" } }, constructs = {}, n_ann = 0 }
	end
	return { path = path, class = "PARSE-FAIL/OTHER", diags = {
		{ line = 0, text = "", err = "crash: " .. tostring(res) } }, constructs = {}, n_ann = 0 }
end

-- ── report aggregation ───────────────────────────────────────────────────────

--:: Report = { results: FileResult[], by_class: { [string]: integer }, histogram: { [string]: integer }, total: integer }

--: () -> Report
function M.run()
	local files = list_corpus()
	local results = {} --[[: { [integer]: FileResult } ]]
	local by_class = {} --[[: { [string]: integer } ]]
	local histogram = {} --[[: { [string]: integer } ]] -- construct -> file count
	for _, path in ipairs(files) do
		local r = survey_file_timed(path, 5.0)
		results[#results + 1] = r
		by_class[r.class] = (by_class[r.class] or 0) + 1
		for c in pairs(r.constructs) do
			histogram[c] = (histogram[c] or 0) + 1
		end
	end
	return { results = results, by_class = by_class, histogram = histogram, total = #files }
end

-- ── markdown / text rendering ────────────────────────────────────────────────

--:: HistEntry = { name: string, count: integer }

--: ({ [string]: integer }) -> HistEntry[]
local function sorted_pairs(t)
	local arr = {} --[[: HistEntry[] ]]
	for k, v in pairs(t) do
		local name = tostring(k) --: string
		local count = (v or 0) + 0 --: integer
		arr[#arr + 1] = { name = name, count = count }
	end
	-- Manual insertion sort (descending by count, then name) — avoids the
	-- table.sort typed-element generic conflict (cf. lib/doc/init.lua §349).
	--: (HistEntry, HistEntry) -> boolean
	local function before(a, b)
		if a.count ~= b.count then return a.count > b.count end
		return a.name < b.name
	end
	for i = 2, #arr do
		local cur = arr[i]
		local j = i - 1
		while j >= 1 and before(cur, arr[j]) do
			arr[j + 1] = arr[j]
			j = j - 1
		end
		arr[j + 1] = cur
	end
	return arr
end
M.sorted_pairs = sorted_pairs

-- The COLLAPSED demand histogram. Every `unknown-type-name:X` tag is the same
-- demand class — a type name the per-file alias environment did not resolve
-- (overwhelmingly a CROSS-MODULE / imported / `declare`d alias, which v1 has no
-- mechanism to resolve). For the v2 demand reading we bucket them into one
-- `unknown-type-name` entry while the full per-name detail stays in the raw
-- histogram. Each distinct file is counted once per collapsed bucket.
--: (FileResult[]) -> { [string]: integer }
local function collapsed_histogram(results)
	local h = {} --[[: { [string]: integer } ]]
	for _, fr in ipairs(results) do
		local seen = {} --[[: { [string]: boolean } ]]
		for c in pairs(fr.constructs) do
			local bucket = c
			if c:find("^unknown%-type%-name:") then bucket = "unknown-type-name" end
			if not seen[bucket] then
				seen[bucket] = true
				h[bucket] = (h[bucket] or 0) + 1
			end
		end
	end
	return h
end
M.collapsed_histogram = collapsed_histogram

--: (integer, integer) -> string
local function pct(n, total)
	if total == 0 then return "0.0%" end
	return string.format("%.1f%%", 100 * n / total)
end

-- Render the full survey report (the body of docs/slice-survey-v1.md).
--: (Report) -> string
function M.render_md(r)
	local out = {} --[[: { [integer]: string } ]]
	--: (string) -> nil
	local function w(s) out[#out + 1] = s end
	local total = r.total

	w("<!-- GENERATED by lib/type/analysis/slice_survey.lua — do not edit by hand.")
	w("     Re-run: bin/cr run lib/type/analysis/slice_survey.lua --md > docs/slice-survey-v1.md -->")
	w("# Slice Survey v1 — `crescent.slice.v1` over the real `lib/` corpus\n")
	w("Headline measurement of the v1 slice's annotation-grammar coverage, driven by")
	w("`slice_survey.lua` over every `.lua` under `lib/` excluding `*_test.lua` and")
	w("`lib/type/analysis/corpus/`. The out-of-subset construct histogram below IS")
	w("the demand ranking for slice v2.\n")
	w("**Scope note.** The slice adapter consumes real source text at one seam: the")
	w("annotation type grammar (`--:` / `--::`). v1 has no whole-Lua-statement")
	w("lowering, so this survey measures ANNOTATION-grammar conformance — every")
	w("`--:`/`--::` annotation parsed through `parse_type_ann`/`declare_alias`. A")
	w("file is CHECKED-CLEAN when all its annotations sit inside v1.\n")

	-- headline split
	local order = { "CHECKED-CLEAN", "CHECKED-FINDINGS", "OUT-OF-SUBSET", "NO-ANNOTATION", "TIMEOUT", "PARSE-FAIL/OTHER" }
	w("## Headline split (" .. total .. " files)\n")
	w("| Class | Files | Share |")
	w("|---|--:|--:|")
	for _, c in ipairs(order) do
		local n = r.by_class[c] or 0
		w("| " .. c .. " | " .. n .. " | " .. pct(n, total) .. " |")
	end
	w("")

	-- timeouts / crashes prominently
	local timeouts = {} --[[: { [integer]: FileResult } ]]
	local crashes = {} --[[: { [integer]: FileResult } ]]
	for _, fr in ipairs(r.results) do
		if fr.class == "TIMEOUT" then timeouts[#timeouts + 1] = fr end
		if fr.class == "PARSE-FAIL/OTHER" then crashes[#crashes + 1] = fr end
	end
	w("## Timeouts and crashes\n")
	if #timeouts == 0 and #crashes == 0 then
		w("None. No file exceeded the 5s per-file budget; no file crashed the adapter.\n")
	else
		for _, fr in ipairs(timeouts) do
			w("- **TIMEOUT** `" .. fr.path .. "` — " .. (fr.diags[1] and fr.diags[1].err or ""))
		end
		for _, fr in ipairs(crashes) do
			w("- **CRASH/OTHER** `" .. fr.path .. "` — " .. (fr.diags[1] and fr.diags[1].err or ""))
		end
		w("")
	end

	-- construct-frequency histogram — COLLAPSED (the demand ranking) then RAW.
	local chist = sorted_pairs(collapsed_histogram(r.results)) --[[: HistEntry[] ]]
	w("## Out-of-subset construct histogram (demand ranking)\n")
	w("Construct -> number of files in which it blocks at least one annotation.")
	w("Sorted by file count. This collapsed view buckets every")
	w("`unknown-type-name:X` into one `unknown-type-name` class (all are the same")
	w("demand: a name the per-file alias env did not resolve — a cross-module /")
	w("imported / `declare`d alias). **This is slice v2's demand ranking.**\n")
	w("| Construct | Files |")
	w("|---|--:|")
	for i = 1, #chist do
		local e = chist[i]
		if e then w("| `" .. e.name .. "` | " .. e.count .. " |") end
	end
	w("")

	local hist = sorted_pairs(r.histogram)
	w("### Raw histogram (per distinct tag, unknown-type-name names expanded)\n")
	w("| Construct | Files |")
	w("|---|--:|")
	for i = 1, #hist do
		local e = hist[i]
		if e then w("| `" .. e.name .. "` | " .. e.count .. " |") end
	end
	w("")

	-- top-20 most-blocking with an example file each (over the collapsed ranking).
	w("## Top-20 most-blocking constructs (one example file each)\n")
	-- index: collapsed-bucket -> first example file path.
	local example = {} --[[: { [string]: string } ]]
	for _, fr in ipairs(r.results) do
		for c in pairs(fr.constructs) do
			local bucket = c
			if c:find("^unknown%-type%-name:") then bucket = "unknown-type-name" end
			if not example[bucket] then example[bucket] = fr.path end
		end
	end
	w("| Rank | Construct | Files | Example file |")
	w("|--:|---|--:|---|")
	for i = 1, math.min(20, #chist) do
		local e = chist[i]
		if e then
			w("| " .. i .. " | `" .. e.name .. "` | " .. e.count .. " | `" .. (example[e.name] or "?") .. "` |")
		end
	end
	w("")

	-- CHECKED-FINDINGS list
	local findings = {} --[[: { [integer]: FileResult } ]]
	for _, fr in ipairs(r.results) do
		if fr.class == "CHECKED-FINDINGS" then findings[#findings + 1] = fr end
	end
	w("## CHECKED-FINDINGS (" .. #findings .. " files)\n")
	w("Files fully within v1 syntax whose annotations the checker REJECTED with no")
	w("out-of-subset construct tag. Each is a real annotation defect, a slice")
	w("precision gap, or an annotation gap (not classified here). First 3")
	w("diagnostics per file.\n")
	if #findings == 0 then
		w("None.\n")
	else
		for _, fr in ipairs(findings) do
			w("### `" .. fr.path .. "`\n")
			for _, d in ipairs(fr.diags) do
				w("- L" .. d.line .. ": `" .. d.text .. "`")
				w("  - " .. d.err)
			end
			w("")
		end
	end

	-- what v2 should build first (pure reading of the collapsed histogram)
	w("## What v2 should build first (a reading of the histogram)\n")
	w("Demand-ordered, no design — design happens against this doc separately.\n")
	for i = 1, math.min(10, #chist) do
		local e = chist[i]
		if e then
			w(i .. ". **`" .. e.name .. "`** — blocks " .. e.count .. " files (" .. pct(e.count, total) .. " of corpus).")
		end
	end
	w("")

	return table.concat(out, "\n") .. "\n"
end

-- ── entry point ──────────────────────────────────────────────────────────────

--: ({ [integer]: string }) -> nil
function M.main(argv)
	local rep = M.run()
	local md = (argv and argv[1] == "--md")
	if md then
		io.write(M.render_md(rep))
		return
	end
	-- terse stdout summary (default).
	local total = rep.total
	io.write("slice survey v1 — " .. total .. " files\n")
	local order = { "CHECKED-CLEAN", "CHECKED-FINDINGS", "OUT-OF-SUBSET", "NO-ANNOTATION", "TIMEOUT", "PARSE-FAIL/OTHER" }
	for _, c in ipairs(order) do
		local n = rep.by_class[c] or 0
		io.write(string.format("  %-18s %4d  %s\n", c, n, pct(n, total)))
	end
	io.write("top constructs (collapsed demand ranking):\n")
	local chist = sorted_pairs(collapsed_histogram(rep.results)) --[[: HistEntry[] ]]
	for i = 1, math.min(20, #chist) do
		local e = chist[i]
		if e then io.write(string.format("  %4d  %s\n", e.count, e.name)) end
	end
end

-- Run when invoked as a script (`bin/cr run`), not when `require`d as a module.
-- Under `bin/cr run`, arg[0] is this file's path; a `require` leaves it pointing
-- elsewhere (or nil), so the module stays side-effect-free for the test suite.
if type(arg) == "table" then
	local av = arg --[[: { [integer]: string } ]]
	local a0 = av[0]
	if type(a0) == "string" and a0:find("slice_survey", 1, true) then
		M.main(av)
	end
end

return M
