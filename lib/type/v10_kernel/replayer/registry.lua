-- lib/type/v10_kernel/replayer/registry.lua
--
-- Registry declarations for the v10 kernel replayer
-- (docs/decisions/typechecker-v10-core-design.md, task brief "Registry
-- declarations"). Cleanroom-built over lib/type/v10_kernel/term_algebra/;
-- does not read or depend on the retired lib/type/v10_kernel/kernel.lua
-- replayer or its registry.lua.
--
-- Two declaration kinds, validated entirely at declaration time (the same
-- validity-by-construction fence term_algebra's declare_signature applies):
--
--   declare_rule(spec)  — a rule schema: premise patterns, a conclusion
--                         pattern, and discharge slots (premise index +
--                         hypothesis pattern). Patterns are term_algebra
--                         terms (built via a chosen tier's build/build_var/
--                         build_meta) containing meta nodes; validated
--                         well-formed against a cited signature (every
--                         var/meta leaf's sort must be declared in the
--                         signature; every op node's decl must belong to
--                         that exact signature name+version).
--
--   declare_axiom(spec) — a named, versioned judgment pattern (schematic;
--                         ground = the zero-metavariable case). Axiom
--                         declarations admit no discharge form: if
--                         spec.discharges is present and non-empty,
--                         declaration is rejected ("axiom nodes admit no
--                         discharge form" is a grammar rule enforced here,
--                         per the ratified design's certificate-grammar
--                         section).
--
-- Patterns themselves are NOT re-validated structurally here beyond the
-- signature-membership walk below — term_algebra's `build`/`build_var`/
-- `build_meta` already make ill-formed terms unrepresentable; this module
-- only checks that a well-formed term was built against the signature the
-- rule/axiom claims to belong to.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

--:: Sort = string
--:: SortSet = { [Sort]: boolean }
--:: OpDeclRef = { name: string, sig_name: string, sig_version: integer }
--:: PatternArg = { term: unknown }
--:: Signature = { name: string, version: integer, sorts: SortSet, ops: unknown }

--:: DischargeSlotSpec = { premise: integer, pattern: unknown }
--:: DischargeSlot = { premise: integer, pattern: unknown }
--:: RuleDeclareSpec = { name: string, version: integer, signature: Signature, premises: unknown[], conclusion: unknown, discharges: DischargeSlotSpec[] | nil }
--:: RuleDecl = { name: string, version: integer, signature: Signature, premises: unknown[], conclusion: unknown, discharges: DischargeSlot[] }

--:: AxiomDeclareSpec = { name: string, version: integer, signature: Signature, pattern: unknown, discharges: unknown | nil }
--:: AxiomDecl = { name: string, version: integer, signature: Signature, pattern: unknown }

-- ── Pattern well-formedness against a cited signature ───────────────────────
--
-- Walks a term_algebra term (var/meta/op, per the ratified three-node
-- grammar) checking: var/meta leaves have a sort declared in the
-- signature's sort set; op nodes carry a decl belonging to exactly this
-- signature (name + version) — operator identity is declared-object
-- identity, so "belongs to" is a name+version match, per
-- docs/decisions/typechecker-v10-core-design.md "Operator signature
-- format".

--: (term: unknown, signature: Signature, path: string) -> string | nil
local function check_pattern(term, signature, path)
	if type(term) ~= "table" then
		return "expected a term_algebra term at " .. path .. ", got " .. type(term)
	end
	local t = term --[[: { [string]: unknown } ]]
	local tag = t.tag
	if tag == "var" or tag == "meta" then
		local sort = t.sort
		if type(sort) ~= "string" or not signature.sorts[sort] then
			return "unknown sort " .. tostring(sort) .. " at " .. path
		end
		return nil
	elseif tag == "op" then
		local decl_raw = t.decl
		if type(decl_raw) ~= "table" then
			return "malformed operator node at " .. path
		end
		local decl = decl_raw --[[: OpDeclRef ]]
		if decl.sig_name ~= signature.name or decl.sig_version ~= signature.version then
			return "operator " .. tostring(decl.name) .. " at " .. path
				.. " does not belong to signature " .. signature.name .. " v" .. signature.version
		end
		local args_raw = t.args
		if type(args_raw) ~= "table" then
			return "malformed operator node at " .. path .. " (missing args)"
		end
		local args = args_raw --[[: PatternArg[] ]]
		for i, a in ipairs(args) do
			local err = check_pattern(a.term, signature, path .. "." .. i)
			if err then return err end
		end
		return nil
	end
	return "unrecognized term tag " .. tostring(tag) .. " at " .. path
end

-- ── Rule schema declaration ──────────────────────────────────────────────────

--: (spec: unknown) -> (RuleDecl | nil, string | nil)
function M.declare_rule(spec)
	if type(spec) ~= "table" then return nil, "declare_rule: spec must be a table" end
	local spec_t = spec --[[: { [string]: unknown } ]]

	local name = spec_t.name
	if type(name) ~= "string" then return nil, "declare_rule: spec.name must be a string" end

	local version_raw = spec_t.version
	if type(version_raw) ~= "number" then return nil, "declare_rule: spec.version must be an integer" end
	if version_raw ~= math.floor(version_raw) then return nil, "declare_rule: spec.version must be an integer" end
	local version = math.floor(version_raw)

	local signature_raw = spec_t.signature
	if type(signature_raw) ~= "table" then return nil, "declare_rule: spec.signature must be a declared signature" end
	local signature = signature_raw --[[: Signature ]]
	if type(signature.name) ~= "string" or type(signature.sorts) ~= "table" then
		return nil, "declare_rule: spec.signature must be a declared signature"
	end

	local premises_spec = spec_t.premises
	if type(premises_spec) ~= "table" then return nil, "declare_rule: spec.premises must be an array of patterns" end

	local premises = {} --[[: unknown[] ]]
	local i = 0
	for _, p in ipairs(premises_spec) do
		i = i + 1
		local err = check_pattern(p, signature, "premises[" .. i .. "]")
		if err then return nil, "declare_rule: " .. name .. ": " .. err end
		premises[i] = p
	end

	local conclusion = spec_t.conclusion
	local cerr = check_pattern(conclusion, signature, "conclusion")
	if cerr then return nil, "declare_rule: " .. name .. ": " .. cerr end

	local discharges_spec = spec_t.discharges or {}
	if type(discharges_spec) ~= "table" then return nil, "declare_rule: " .. name .. ": spec.discharges must be an array" end

	local discharges = {} --[[: DischargeSlot[] ]]
	local j = 0
	for _, d_raw in ipairs(discharges_spec) do
		j = j + 1
		if type(d_raw) ~= "table" then
			return nil, "declare_rule: " .. name .. ": discharge slot " .. j .. " must be a table"
		end
		local d = d_raw --[[: { [string]: unknown } ]]
		local premise_idx_raw = d.premise
		if type(premise_idx_raw) ~= "number" then
			return nil, "declare_rule: " .. name .. ": discharge slot " .. j .. ".premise must be an integer"
		end
		if premise_idx_raw ~= math.floor(premise_idx_raw) then
			return nil, "declare_rule: " .. name .. ": discharge slot " .. j .. ".premise must be an integer"
		end
		local premise_idx = math.floor(premise_idx_raw)
		if premise_idx < 1 or premise_idx > #premises then
			return nil, "declare_rule: " .. name .. ": discharge slot " .. j
				.. ".premise " .. premise_idx .. " out of range (1.." .. #premises .. ")"
		end
		local perr = check_pattern(d.pattern, signature, "discharges[" .. j .. "].pattern")
		if perr then return nil, "declare_rule: " .. name .. ": " .. perr end
		discharges[j] = { premise = premise_idx, pattern = d.pattern }
	end

	return {
		name = name,
		version = version,
		signature = signature,
		premises = premises,
		conclusion = conclusion,
		discharges = discharges,
	}
end

-- ── Axiom declaration ────────────────────────────────────────────────────────

--: (spec: unknown) -> (AxiomDecl | nil, string | nil)
function M.declare_axiom(spec)
	if type(spec) ~= "table" then return nil, "declare_axiom: spec must be a table" end
	local spec_t = spec --[[: { [string]: unknown } ]]

	local name = spec_t.name
	if type(name) ~= "string" then return nil, "declare_axiom: spec.name must be a string" end

	local version_raw = spec_t.version
	if type(version_raw) ~= "number" then return nil, "declare_axiom: spec.version must be an integer" end
	if version_raw ~= math.floor(version_raw) then return nil, "declare_axiom: spec.version must be an integer" end
	local version = math.floor(version_raw)

	local signature_raw = spec_t.signature
	if type(signature_raw) ~= "table" then return nil, "declare_axiom: spec.signature must be a declared signature" end
	local signature = signature_raw --[[: Signature ]]
	if type(signature.name) ~= "string" or type(signature.sorts) ~= "table" then
		return nil, "declare_axiom: spec.signature must be a declared signature"
	end

	local pattern = spec_t.pattern
	local perr = check_pattern(pattern, signature, "pattern")
	if perr then return nil, "declare_axiom: " .. name .. ": " .. perr end

	-- Grammar rule: axiom nodes admit no discharge form. Enforced here at
	-- declaration, not merely by the axiom-decl shape lacking the field —
	-- a caller that supplies a non-empty spec.discharges is rejected
	-- explicitly (docs/decisions/typechecker-v10-core-design.md,
	-- "Certificate/derivation grammar" item 2).
	local discharges_raw = spec_t.discharges
	if discharges_raw ~= nil then
		if type(discharges_raw) ~= "table" then
			return nil, "declare_axiom: " .. name .. ": spec.discharges must be an array if present"
		end
		if #discharges_raw > 0 then
			return nil, "declare_axiom: " .. name .. ": axiom nodes admit no discharge form"
		end
	end

	return { name = name, version = version, signature = signature, pattern = pattern }
end

return M
