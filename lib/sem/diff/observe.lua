-- lib/sem/diff/observe.lua
-- Canonical observation space for Loop-α: map BOTH our spec's run outcome and the
-- real-LuaJIT outcome into the SAME comparable form, so agreement is a string (or
-- structural) equality and disagreement is a divergence.
--
-- OBSERVATION SPACE (S1):
--   * value-shape — the returned tuple, each value rendered canonically:
--       number → "n:<canonical>", string → "s:<quoted>", boolean → "b:true|false",
--       nil → "nil", table → "table", function/closure → "function".
--     Table identity and contents are NOT observed (an admissible-set treatment:
--     two runtimes may allocate different addresses / iterate in different orders;
--     the spec declines to commit, so kind-only is the canonical projection).
--   * fault-class — a runtime error becomes "fault" (S1 collapses all fault classes
--     to one class for the real side, because LuaJIT's error strings are not a
--     stable cross-version contract; our spec's finer fault class is recorded
--     separately for diagnosis but agreement is on the coarse class).
--   * budget — nontermination / step-budget exhaustion is "budget"; treated as
--     admissible (matches anything, since the real side is also time-bounded).
--
-- Both producers emit an Observation; `agree` compares two observations.

--:: require "lib.sem.value"
--:: require "lib.sem.config"
--:: require "lib.sem.run"

local M = {}

--:: Observation = { tag: string, shape: string }

-- canonical render of one of our Values to a shape token.
--: (ValueAlgebra, Value) -> string
local function render_value(va, v)
	local k = va.kind_of(v)
	if k == "number" then
		local n = va.number_value(v)
		-- canonical number form matching the real side's tostring.
		if n ~= n then return "n:nan" end
		if n == math.huge then return "n:inf" end
		if n == -math.huge then return "n:-inf" end
		if n == math.floor(n) and math.abs(n) < 1e15 then
			return "n:" .. string.format("%d", n)
		end
		return "n:" .. string.format("%.14g", n)
	end
	if k == "string" then return "s:" .. va.string_value(v) end
	if k == "boolean" then return va.bool_value(v) and "b:true" or "b:false" end
	if k == "nil" then return "nil" end
	if k == "table" then return "table" end
	return "function"
end

-- our-spec observation from a RunResult.
--: (ValueAlgebra, RunResult) -> Observation
function M.observe_spec(va, res)
	if res.kind == "ok" then
		local parts = {} --[[: { [integer]: string } ]]
		for i = 1, #res.values do
			local v = res.values[i]
			if v ~= nil then parts[#parts + 1] = render_value(va, v) end
		end
		return { tag = "value", shape = table.concat(parts, ",") }
	end
	if res.kind == "fault" then
		return { tag = "fault", shape = res.fault.class }
	end
	return { tag = "budget", shape = "" }
end

-- The real side emits a single canonical line (built by the alpha test's Lua
-- wrapper, see alpha_test.lua). We parse it here into the SAME Observation space.
-- Line grammar:
--   "OK <shape>"     — value tuple, shape uses the same tokens as render_value
--   "FAULT"          — a runtime error
--   anything else    — treated as a fault (defensive)
--: (string) -> Observation
function M.observe_real(line)
	local rest = line:match("^OK (.*)$")
	if rest ~= nil then return { tag = "value", shape = rest } end
	if line:match("^OK$") then return { tag = "value", shape = "" } end
	if line:match("^FAULT") then return { tag = "fault", shape = "" } end
	return { tag = "fault", shape = "" }
end

-- agreement (admissible-set aware):
--   * budget on EITHER side is admissible — matches anything (the spec/real both
--     decline to commit under a step/time bound).
--   * fault matches fault REGARDLESS of class (the real side has no stable class).
--   * value matches value iff the shape strings are identical.
--: (Observation, Observation) -> boolean
function M.agree(a, b)
	if a.tag == "budget" or b.tag == "budget" then return true end
	if a.tag == "fault" and b.tag == "fault" then return true end
	if a.tag == "value" and b.tag == "value" then return a.shape == b.shape end
	return false
end

-- human-readable observation (for divergence reports).
--: (Observation) -> string
function M.show(o)
	if o.tag == "value" then return "value(" .. o.shape .. ")" end
	if o.tag == "fault" then return "fault(" .. o.shape .. ")" end
	return "budget"
end

return M
