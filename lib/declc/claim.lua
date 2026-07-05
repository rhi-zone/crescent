-- lib/declc/claim.lua
-- Claim data type for the declarative-core typechecker composite.
--
-- A claim is one atomic behavioral proposition about a program, per
-- docs/artifacts/2026-07-05-typechecker-declarative-core/declarative-core-draft.md
-- §2-3 and the FP-spine stratification in research/ceiling-survey/
-- proposal-first-principles.md §D:
--
--   site        -- program location the claim is about (the `s` in
--                  arrives(s, k, V) / happens(e) / etc.)
--   slot        -- which value slot within an event the claim binds (the
--                  `k` in arrives(s, k, V); e.g. "entry:x", "exit:1")
--   stratum     -- quantifier-complexity class of the claim's logical form:
--                  "sigma1" (some-run: witness-provable, proof-refutable),
--                  "pi1"    (safety, no-run-errs: witness-refutable,
--                            certificate-provable),
--                  "pi2"    (termination/liveness: well-foundedness
--                            certificate provable)
--   modal       -- "box" (universal: forall T in the execution set, i.e. □)
--                  or "diamond" (existential: exists T, i.e. ◇)
--   schema      -- the value-set V a slot is claimed to range over; opaque
--                  payload, shape owned by the caller (a type, a predicate
--                  description, ...)
--   schema_key  -- caller-supplied canonical string for `schema`, used for
--                  equality/keying since `schema` itself is `unknown` and
--                  not comparable in general
--   provenance  -- generation source per the certified two-layer design
--                  (declarative-design.md): "stated" (annotation),
--                  "axiom" (fixed catalog), "mined" (presupposition-mining)
--
-- Grade (credence) is deliberately NOT a claim field: declarative-design.md
-- "Grade axis: operationally inert" finds that checking machinery never
-- branches on grade -- it lives entirely in the reporting layer, not in a
-- claim's identity. Adding it here would be exactly the "special-casing of a
-- source" the certified design forbids.
--
-- Pure data + constructors + accessors + equality/keying. No checking logic
-- lives in this file.

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

--:: Stratum    = "sigma1" | "pi1" | "pi2"
--:: Modal      = "box" | "diamond"
--:: Provenance = "stated" | "axiom" | "mined"

--:: Claim = {
--::   site: string,
--::   slot: string,
--::   stratum: Stratum,
--::   modal: Modal,
--::   schema: unknown,
--::   schema_key: string,
--::   provenance: Provenance,
--:: }

--:: ClaimFields = {
--::   site: string,
--::   slot: string,
--::   stratum: Stratum,
--::   modal: Modal,
--::   schema: unknown,
--::   schema_key: string,
--::   provenance: Provenance,
--:: }

-- Enum value tables, exported so callers never hand-write the string
-- literals (and a rename only touches this file).
--:: Strata      = { SIGMA1: Stratum, PI1: Stratum, PI2: Stratum }
--:: Modals      = { BOX: Modal, DIAMOND: Modal }
--:: Provenances = { STATED: Provenance, AXIOM: Provenance, MINED: Provenance }

M.STRATUM = { SIGMA1 = "sigma1", PI1 = "pi1", PI2 = "pi2" } --[[: Strata]]
M.MODAL = { BOX = "box", DIAMOND = "diamond" } --[[: Modals]]
M.PROVENANCE = { STATED = "stated", AXIOM = "axiom", MINED = "mined" } --[[: Provenances]]

--: { [string]: boolean }
local STRATA = { sigma1 = true, pi1 = true, pi2 = true }
--: { [string]: boolean }
local MODALS = { box = true, diamond = true }
--: { [string]: boolean }
local PROVENANCES = { stated = true, axiom = true, mined = true }

--: (ClaimFields | nil) -> (Claim | nil, string | nil)
function M.new(fields)
	if fields == nil then return nil, "claim.new: fields required" end
	if type(fields.site) ~= "string" or fields.site == "" then
		return nil, "claim.new: site must be a non-empty string"
	end
	if type(fields.slot) ~= "string" or fields.slot == "" then
		return nil, "claim.new: slot must be a non-empty string"
	end
	if type(fields.stratum) ~= "string" or not STRATA[fields.stratum] then
		return nil, "claim.new: stratum must be one of sigma1, pi1, pi2"
	end
	if type(fields.modal) ~= "string" or not MODALS[fields.modal] then
		return nil, "claim.new: modal must be one of box, diamond"
	end
	if type(fields.schema_key) ~= "string" or fields.schema_key == "" then
		return nil, "claim.new: schema_key must be a non-empty string"
	end
	if type(fields.provenance) ~= "string" or not PROVENANCES[fields.provenance] then
		return nil, "claim.new: provenance must be one of stated, axiom, mined"
	end
	local site = fields.site --[[: string]]
	local slot = fields.slot --[[: string]]
	local stratum = fields.stratum --[[: Stratum]]
	local modal = fields.modal --[[: Modal]]
	local schema_key = fields.schema_key --[[: string]]
	local provenance = fields.provenance --[[: Provenance]]
	local c = {
		site       = site,
		slot       = slot,
		stratum    = stratum,
		modal      = modal,
		schema     = fields.schema,
		schema_key = schema_key,
		provenance = provenance,
	}
	return c, nil
end

-- ── Accessors ─────────────────────────────────────────────────────────────

--: (Claim) -> string
function M.site(c) return c.site end
--: (Claim) -> string
function M.slot(c) return c.slot end
--: (Claim) -> Stratum
function M.stratum(c) return c.stratum end
--: (Claim) -> Modal
function M.modal(c) return c.modal end
--: (Claim) -> unknown
function M.schema(c) return c.schema end
--: (Claim) -> string
function M.schema_key(c) return c.schema_key end
--: (Claim) -> Provenance
function M.provenance(c) return c.provenance end

-- ── Keying / equality ─────────────────────────────────────────────────────
--
-- Two claims are the same claim iff they agree on every field that
-- determines what proposition they assert: site, slot, stratum, modal, and
-- schema (via schema_key). Provenance is deliberately NOT part of the key:
-- the same proposition can independently arise from an annotation and from
-- mining -- declarative-design.md's both-ways-audit collapse restates this
-- as "two pool entries sharing provenance" for what is structurally the
-- SAME claim. Two entries with different provenance but identical
-- (site, slot, stratum, modal, schema_key) are the same claim asserted
-- twice; a pool/ledger layer records provenance as attribution metadata
-- alongside the shared key, it does not fork identity over it.

local SEP = "\1"

--: (Claim) -> string
function M.key(c)
	return table.concat({ c.stratum, c.modal, c.site, c.slot, c.schema_key }, SEP)
end

--: (Claim, Claim) -> boolean
function M.equal(a, b)
	return M.key(a) == M.key(b)
end

return M
