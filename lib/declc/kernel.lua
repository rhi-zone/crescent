-- lib/declc/kernel.lua
-- Certificate kernel -- the tiny trusted checker for the declarative-core
-- composite. Per research/ceiling-survey/judgment.md §5 (FP spine): "small
-- trusted certificate-checking kernel; provers are untrusted heuristic
-- engines" -- this module IS the entire trust boundary. Everything a prover
-- produces must pass through here to become a verdict; nothing outside this
-- file can mint one.
--
-- Three verdicts, one constructor each:
--   Proved(cert)    -- a claim holds; cert is the proof object a (future)
--                       checker validates against the operational semantics
--   Refuted(trace)  -- a claim fails; trace is the witness (or witness
--                       family, for diamond-claims per draft.md Hole H3)
--   Open(receipt)   -- neither derivable yet; receipt records why (budget
--                       exhausted, hardness certificate, ...)
--
-- What this module deliberately does NOT do -- out of scope for this
-- substrate chunk, flagged so it is not mistaken for an oversight:
--   - It does not validate cert/trace/receipt CONTENT against the
--     semantics. draft.md Hole H1 names this missing derivation-system
--     layer; building it is harvester/check-law work, scheduled after this
--     substrate chunk. "Minimally-checkable" here means exactly one thing:
--     M.is_verdict distinguishes a genuine kernel-minted Verdict from an
--     arbitrary table, so nothing downstream can forge a Proved/Refuted/
--     Open by hand-assembling a table that merely looks like one.
--
-- Resist extending this file. Speculative fields belong in the payload
-- (cert/trace/receipt), which is `unknown` by design -- this kernel's job
-- is to stay small enough to trust by inspection, not to grow features.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

--:: VerdictKind = "proved" | "refuted" | "open"

-- Private sentinel: only code holding a reference to this local can produce
-- a table `t` such that `t._kernel_tag == SENTINEL`. This is the entire
-- trust mechanism -- the sentinel is never exported, so no code outside
-- this file can construct a value M.is_verdict accepts.
--: unknown
local SENTINEL = {}

--:: Verdict = { kind: VerdictKind, payload: unknown, _kernel_tag: unknown }

--: (VerdictKind, unknown) -> Verdict
local function mint(kind, payload)
	return { kind = kind, payload = payload, _kernel_tag = SENTINEL }
end

--: (unknown) -> Verdict
function M.proved(cert)
	return mint("proved", cert)
end

--: (unknown) -> Verdict
function M.refuted(trace)
	return mint("refuted", trace)
end

--: (unknown) -> Verdict
function M.open(receipt)
	return mint("open", receipt)
end

-- The minimal check: was this object minted by this kernel's own
-- constructors? This is the only "checking" the kernel does at this
-- substrate layer -- it is a provenance check on the Verdict object itself,
-- never a validation of the proof/trace/receipt content.
--
-- Takes `unknown` rather than `Verdict`: Verdict is opaque outside this
-- file by construction (nothing else can produce the sentinel tag), so
-- every public function here accepts `unknown` and validates internally.
-- `is_verdict` is declared as a type predicate (docs/typechecker-reference.md
-- "Type predicates and assertion functions") so `if not M.is_verdict(v) then
-- return ... end` narrows `v` to `Verdict` for the rest of the function --
-- no force cast past unnarrowed `unknown` required anywhere below.
--: (x: unknown) -> x is Verdict
local function is_verdict(v)
	if type(v) ~= "table" then return false end
	local t = v --[[: { _kernel_tag: unknown }]]
	return t._kernel_tag == SENTINEL
end

-- Public alias. Guard-check narrowing (docs/typechecker-reference.md "Type
-- predicates") is only exercised through the bare local `is_verdict` below
-- -- narrowing through a `M.`-prefixed field-access call is not one of the
-- recognized forms, so every function in this file narrows via the local,
-- not via `M.is_verdict`.
M.is_verdict = is_verdict

--: (unknown) -> (VerdictKind | nil, string | nil)
function M.kind(v)
	if not is_verdict(v) then
		return nil, "kernel.kind: value was not minted by lib.declc.kernel"
	end
	return v.kind, nil
end

--: (unknown) -> (unknown | nil, string | nil)
function M.cert(v)
	if not is_verdict(v) then
		return nil, "kernel.cert: value was not minted by lib.declc.kernel"
	end
	if v.kind ~= "proved" then
		return nil, "kernel.cert: verdict is not Proved (kind=" .. tostring(v.kind) .. ")"
	end
	return v.payload, nil
end

--: (unknown) -> (unknown | nil, string | nil)
function M.trace(v)
	if not is_verdict(v) then
		return nil, "kernel.trace: value was not minted by lib.declc.kernel"
	end
	if v.kind ~= "refuted" then
		return nil, "kernel.trace: verdict is not Refuted (kind=" .. tostring(v.kind) .. ")"
	end
	return v.payload, nil
end

--: (unknown) -> (unknown | nil, string | nil)
function M.receipt(v)
	if not is_verdict(v) then
		return nil, "kernel.receipt: value was not minted by lib.declc.kernel"
	end
	if v.kind ~= "open" then
		return nil, "kernel.receipt: verdict is not Open (kind=" .. tostring(v.kind) .. ")"
	end
	return v.payload, nil
end

return M
