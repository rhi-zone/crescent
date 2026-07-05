-- lib/declc/corpus_run.lua
-- Driver for the declarative-core composite's first-slice execution run:
-- harvest (stated/axiom/mined) + the hypothesis/obligation check law, over
-- a small real corpus from lib/. This is the "then execute" step of the
-- chunk 2 task.
--
-- Caps-first per CLAUDE.md: M.run_file/M.run_corpus take an injected
-- `read_file` cap rather than reaching for `io` themselves -- consistent
-- with every other lib/declc/*.lua module (see lib/declc/ledger.lua's
-- LedgerIoCaps). Only the bottom-of-file CLI entry point (run as a script,
-- not required as a library) constructs the real `io`-backed cap.
--
-- Usage: bin/cr run lib/declc/corpus_run.lua
-- Prints a per-file report to stdout; see corpus_run_test.lua for the
-- committed, reproducible invocation and
-- docs/artifacts/2026-07-05-typechecker-declarative-core/execution/
-- first-slice-run.md for the captured output this produced.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local harvest = require("lib.declc.harvest")
local claim = require("lib.declc.claim")
--:: require "lib.declc.claim"
local kernel = require("lib.declc.kernel")
local check = require("lib.declc.check")
--:: require "lib.declc.check"

local M = {}

--:: ReadFileCap = (path: string) -> (string | nil, string | nil)

M.DEFAULT_CORPUS = {
	"lib/json/init.lua",
	"lib/csv/init.lua",
	"lib/bigint/init.lua",
	"lib/lru/init.lua",
	"lib/queue/init.lua",
	"lib/uuid/init.lua",
	"lib/trie/init.lua",
	"lib/deque/init.lua",
}

--:: ProvenanceCounts = { stated: number, axiom: number, mined: number }

--: ({ [integer]: Claim, ... }) -> ProvenanceCounts
local function count_by_provenance(claims)
	local counts = { stated = 0, axiom = 0, mined = 0 } --: ProvenanceCounts
	for _, c in ipairs(claims) do
		local p = claim.provenance(c)
		if p == "stated" then counts.stated = counts.stated + 1
		elseif p == "axiom" then counts.axiom = counts.axiom + 1
		elseif p == "mined" then counts.mined = counts.mined + 1
		end
	end
	return counts
end

--: (unknown) -> string
local function verdict_kind(v)
	local k = kernel.kind(v)
	return k or "?"
end

--:: FileReport = {
--::   path: string,
--::   counts: ProvenanceCounts,
--::   total_claims: number,
--::   tally: { proved: number, refuted: number, open: number },
--::   result: CheckResult,
--:: }

-- Runs the full harvest + check over one file. Returns a report (all plain
-- data) or (nil, errmsg) on read/parse failure.
--: (ReadFileCap, string) -> (FileReport | nil, string | nil)
function M.run_file(read_file, path)
	local source, rerr = read_file(path)
	if source == nil then return nil, "corpus_run: " .. tostring(rerr) end

	local stated, serr = harvest.harvest_stated(source, path)
	if stated == nil then return nil, "corpus_run: harvest_stated: " .. tostring(serr) end
	local mined, merr = harvest.harvest_mined(source, path)
	if mined == nil then return nil, "corpus_run: harvest_mined: " .. tostring(merr) end
	local axioms = harvest.harvest_axiom()

	local all = {} --: { [integer]: Claim, ... }
	for _, c in ipairs(stated) do all[#all + 1] = c end
	for _, c in ipairs(axioms) do all[#all + 1] = c end
	for _, c in ipairs(mined) do all[#all + 1] = c end

	local result = check.check(all)
	local tally = check.tally(result)

	return {
		path = path,
		counts = count_by_provenance(all),
		total_claims = #all,
		tally = tally,
		result = result,
	}, nil
end

-- Renders one file's report as lines of text (for stdout / capture into the
-- docs artifact). Includes every Refuted verdict in full (small number
-- expected) and up to `sample_n` Proved/Open verdicts as a representative
-- sample (an Open flood is expected and printing all of them would be
-- enormous for some files).
--: (FileReport, integer) -> { [integer]: string, ... }
local function render_report(rep, sample_n)
	local lines = {} --: { [integer]: string, ... }
	lines[#lines + 1] = "## " .. rep.path
	lines[#lines + 1] = ""
	lines[#lines + 1] = string.format(
		"claims: stated=%d axiom=%d mined=%d total=%d",
		rep.counts.stated, rep.counts.axiom, rep.counts.mined, rep.total_claims)
	lines[#lines + 1] = string.format(
		"verdicts: proved=%d refuted=%d open=%d",
		rep.tally.proved, rep.tally.refuted, rep.tally.open)
	lines[#lines + 1] = ""

	local result = rep.result

	lines[#lines + 1] = "### Refuted (all)"
	local refuted_n = 0
	for _, entry in pairs(result) do
		if verdict_kind(entry.verdict) == "refuted" then
			refuted_n = refuted_n + 1
			lines[#lines + 1] = "- " .. entry.reason
			for _, c in ipairs(entry.claims) do
				lines[#lines + 1] = string.format(
					"    %s | %s | schema=%s | provenance=%s",
					claim.site(c), claim.slot(c), claim.schema_key(c), claim.provenance(c))
			end
		end
	end
	if refuted_n == 0 then lines[#lines + 1] = "(none)" end
	lines[#lines + 1] = ""

	lines[#lines + 1] = "### Proved (sample, up to " .. tostring(sample_n) .. ")"
	local proved_n = 0
	for _, entry in pairs(result) do
		if verdict_kind(entry.verdict) == "proved" and proved_n < sample_n then
			proved_n = proved_n + 1
			local c = entry.claims[1]
			lines[#lines + 1] = string.format(
				"- %s | %s | schema=%s | sources=%d",
				claim.site(c), claim.slot(c), claim.schema_key(c), #entry.claims)
		end
	end
	if proved_n == 0 then lines[#lines + 1] = "(none)" end
	lines[#lines + 1] = ""

	lines[#lines + 1] = "### Open (sample, up to " .. tostring(sample_n) .. ")"
	local open_n = 0
	for _, entry in pairs(result) do
		if verdict_kind(entry.verdict) == "open" and open_n < sample_n then
			open_n = open_n + 1
			local c = entry.claims[1]
			lines[#lines + 1] = string.format(
				"- %s | %s | schema=%s | provenance=%s",
				claim.site(c), claim.slot(c), claim.schema_key(c), claim.provenance(c))
			lines[#lines + 1] = "    receipt: " .. entry.reason
		end
	end
	if open_n == 0 then lines[#lines + 1] = "(none)" end
	lines[#lines + 1] = ""

	return lines
end

M.render_report = render_report

--:: CorpusRunResult = { lines: { [integer]: string, ... }, reports: { [integer]: FileReport, ... } }

-- Runs the full corpus and returns { lines, reports }.
--: (ReadFileCap, { [integer]: string, ... } | nil) -> CorpusRunResult
function M.run_corpus(read_file, files)
	files = files or M.DEFAULT_CORPUS
	local out_lines = {} --: { [integer]: string, ... }
	local reports = {} --: { [integer]: FileReport, ... }

	local total_stated = 0 --: number
	local total_axiom = 0 --: number
	local total_mined = 0 --: number
	local total_proved = 0 --: number
	local total_refuted = 0 --: number
	local total_open = 0 --: number

	for _, path in ipairs(files) do
		local report, err = M.run_file(read_file, path)
		if report == nil then
			out_lines[#out_lines + 1] = "## " .. path
			out_lines[#out_lines + 1] = "ERROR: " .. tostring(err)
			out_lines[#out_lines + 1] = ""
		else
			reports[#reports + 1] = report
			total_stated = total_stated + report.counts.stated
			total_axiom = total_axiom + report.counts.axiom
			total_mined = total_mined + report.counts.mined
			total_proved = total_proved + report.tally.proved
			total_refuted = total_refuted + report.tally.refuted
			total_open = total_open + report.tally.open
			local file_lines = render_report(report, 8)
			for _, l in ipairs(file_lines) do out_lines[#out_lines + 1] = l end
		end
	end

	out_lines[#out_lines + 1] = "## TOTAL"
	out_lines[#out_lines + 1] = string.format(
		"claims: stated=%d axiom=%d mined=%d total=%d",
		total_stated, total_axiom, total_mined, total_stated + total_axiom + total_mined)
	out_lines[#out_lines + 1] = string.format(
		"verdicts: proved=%d refuted=%d open=%d",
		total_proved, total_refuted, total_open)

	return { lines = out_lines, reports = reports }
end

-- CLI entry point (`bin/cr run lib/declc/corpus_run.lua`): constructs the
-- real io-backed read_file cap and prints the report to stdout. This is the
-- one place in this file that touches ambient `io` -- everything above
-- takes it as an injected parameter. corpus_run_test.lua does not exercise
-- this branch; it builds its own read_file cap and calls M.run_corpus
-- directly.
if arg and arg[0] and arg[0]:find("corpus_run%.lua$") then
	--: (string) -> (string | nil, string | nil)
	local function io_read_file(path)
		local fh, err = io.open(path, "r")
		if fh == nil then return nil, tostring(err) end
		local content = fh:read("*a")
		fh:close()
		return content, nil
	end
	local run = M.run_corpus(io_read_file, nil)
	for _, l in ipairs(run.lines) do print(l) end
end

return M
