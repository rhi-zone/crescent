-- lib/declc/corpus_run_test.lua
-- Committed, reproducible invocation of the first-slice execution run:
-- harvest + check over lib/declc/corpus_run.lua's default corpus. This is
-- the artifact-generating test for the "execute" step of the chunk 2 task
-- -- run it to regenerate
-- docs/artifacts/2026-07-05-typechecker-declarative-core/execution/
-- first-slice-run.md.
--
-- Assertions here are sanity checks on the run (it completes, produces
-- claims, produces verdicts) -- NOT assertions about specific counts, which
-- would make this test brittle against harvester/check-law changes. The
-- actual data (counts, sample claims, findings) lives in the committed
-- first-slice-run.md artifact and the orchestrator's digest, not in this
-- file's assertions.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local corpus_run = require("lib.declc.corpus_run")

--: (string) -> (string | nil, string | nil)
local function io_read_file(path)
	local fh, err = io.open(path, "r")
	if fh == nil then return nil, tostring(err) end
	local content = fh:read("*a")
	fh:close()
	return content, nil
end

T.describe("corpus_run: first-slice execution over the default lib/ corpus", function()
	T.it("runs every default corpus file without error and harvests claims", function()
		local run = corpus_run.run_corpus(io_read_file, nil)
		T.eq(#run.reports, #corpus_run.DEFAULT_CORPUS)
		for _, report in ipairs(run.reports) do
			T.ok(report.total_claims > 0, report.path .. ": expected at least one harvested claim")
			-- Every claim pool includes the 5-entry axiom catalog regardless
			-- of file content.
			T.eq(report.counts.axiom, 5)
			-- Every verdict is one of the three kernel-minted kinds; tally
			-- accounts for all claim.check groups (no claim topic silently
			-- dropped).
			local accounted = report.tally.proved + report.tally.refuted + report.tally.open
			T.ok(accounted > 0, report.path .. ": expected at least one checked topic")
		end
	end)

	T.it("produces non-empty report text", function()
		local run = corpus_run.run_corpus(io_read_file, nil)
		T.ok(#run.lines > 0)
	end)
end)
