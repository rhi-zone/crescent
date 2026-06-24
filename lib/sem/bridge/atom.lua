-- lib/sem/bridge/atom.lua
-- REALITY BRIDGE — the model↔real-LuaJIT correspondence for the atoms. See
-- docs/reality-bridge.md.
--
-- The Coq proof (proof/subtype.v) establishes everything ABOUT the model:
-- subtyping is a Boolean algebra, the decider is sound, etc. The one thing a
-- proof cannot establish is FAITHFULNESS — that the model's value domain `V`
-- and its `atom_denote` actually correspond to how real LuaJIT classifies real
-- values. This module is the Lua side of that bridge: a small, faithful port of
-- the model's atom-denotation, plus a mapping from model values to real-Lua
-- source, so a differential harness can check the port against BOTH the proven
-- Coq model (via `Compute`, done in the test) and real LuaJIT (`type(x)`).
--
-- SCOPE: the unambiguous atoms AStr/ABool/ANil, PLUS the number atoms ANum,
-- AInt, AND AFloat — under the LuaJIT 5.1 model (fork A′ RESOLVED, see the doc).
-- On 5.1 every number is ONE double: `3 == 3.0`, an integer-valued number IS a
-- float, `type()` returns "number" for both. The proof now has a SINGLE number
-- value `VNum (NumRep)` with `NRint` (integer-valued double, e.g. 3.0) and
-- `NRfrac` (genuinely non-integer double, e.g. 1.5). So:
--   * ANum   = all numbers (`type=="number"`).
--   * AFloat = all numbers too (float ≡ number on 5.1) — `AInt <: AFloat` is a
--              theorem (proof/subtype.v `AInt_sub_AFloat`); AFloat is no longer
--              scoped out, it is fully bridgeable and equals ANum observably.
--   * AInt   = the integer-valued numbers (`x == floor(x)`, finite) — a genuine
--              refinement SUBSET. `VFloat n` (an `NRfrac` non-integer double) is
--              NOT in AInt, and its real image is a genuine non-integer, so the
--              old `AInt VFloat 3` model-vs-reality disagreement is GONE.
-- BRec, BArrow remain deferred. Model value heads NOT members of a given atom
-- (VTable/VFun, etc.) ARE represented here so the harness exercises REJECTION.

local M = {}

-- ── the bridged atoms ────────────────────────────────────────────────────────
-- AStr/ABool/ANil: unambiguous (head-determined, fork-independent).
-- ANum/AInt/AFloat: number atoms on the 5.1 single-double model — ANum and
-- AFloat are both a clean `type=="number"` test (float ≡ number); AInt is the
-- integral-value refinement predicate.
--:: BridgeAtom = "AStr" | "ABool" | "ANil" | "ANum" | "AInt" | "AFloat"

M.atoms = { "AStr", "ABool", "ANil", "ANum", "AInt", "AFloat" } --[[: BridgeAtom[] ]]

-- No atoms are unobservable on LuaJIT 5.1 any longer: with the value domain
-- collapsed to one double (`VNum`), AFloat denotes the number type (= ANum) and
-- is fully observable. (Was: AFloat scoped out under the two-number-value model.)
M.unobservable_atoms = {} --[[: { [string]: string } ]]

-- ── model values (a faithful port of the proof's `V`) ────────────────────────
-- Each model `V` constructor is rendered as a tagged table. We include the
-- non-unambiguous heads (VInt/VFloat/VTable/VFun) so the harness can assert they
-- are correctly REJECTED by every unambiguous atom — but their membership in
-- AInt/ANum etc. is out of scope here (the int/float fork).
--:: MVStr   = { head: "VStr" }
--:: MVBool  = { head: "VBool", b: boolean }
--:: MVNil   = { head: "VNil" }
--:: MVInt   = { head: "VInt" }
--:: MVFloat = { head: "VFloat" }
--:: MVTable = { head: "VTable" }
--:: MVFun   = { head: "VFun" }
--:: ModelValue = MVStr | MVBool | MVNil | MVInt | MVFloat | MVTable | MVFun

-- The model's VStr/VInt/VFloat are all NULLARY (the inert-value-payload removal:
-- stage 1 dropped VStr's payload, stage 2 dropped the number magnitude). Numbers
-- are type-CLASSES with no magnitude: `VInt` is the `NRint` (integer-valued)
-- class, `VFloat` is the `NRfrac` (non-integer) class. Membership is HEAD-ONLY
-- (it reads only the head/class, never a payload). Each renders to a FIXED
-- representative literal (see value_to_lua_expr).
--: () -> ModelValue
function M.vstr() return { head = "VStr" } end
--: (boolean) -> ModelValue
function M.vbool(b) return { head = "VBool", b = b } end
--: () -> ModelValue
function M.vnil() return { head = "VNil" } end
--: () -> ModelValue
function M.vint() return { head = "VInt" } end
--: () -> ModelValue
function M.vfloat() return { head = "VFloat" } end
--: () -> ModelValue
function M.vtable() return { head = "VTable" } end
--: () -> ModelValue
function M.vfun() return { head = "VFun" } end

-- ── the model atom-denotation port (mirrors proof/subtype.v `atom_denote`) ───
-- `atom_denote` in the proof (LuaJIT 5.1 model, one number value `VNum`):
--   AStr   ↔ match v with VStr  _  => True | _ => False
--   ABool  ↔ match v with VBool _  => True | _ => False
--   ANil   ↔ match v with VNil     => True | _ => False
--   AInt   ↔ match v with VNum NRint => True | _ => False
--   ANum   ↔ match v with VNum _ => True | _ => False
--   AFloat ↔ match v with VNum _ => True | _ => False     (float ≡ number on 5.1)
-- This port matches ONLY on the value HEAD/class, exactly as the model does (the
-- denotation is head-determined — see `denote_head`). The model port's `VInt`
-- head is the `NRint` (integer-valued) class; `VFloat` is the `NRfrac`
-- (non-integer) class. CENTRAL FAITHFULNESS POINT (now CONSISTENT with reality):
-- per the MODEL, `VFloat _` is NOT in `AInt` — and its real image is a genuine
-- NON-integer double, so reality agrees (`false`). `VInt _` IS in `AInt` AND in
-- `AFloat` (`AInt <: AFloat`), matching real 5.1 where `3` is integer-valued and
-- is a float. Validated case-for-case against the Coq `Compute` of `denote_dec`
-- in atom_test.lua, so it is a trustworthy proxy for the proven model.
--: (BridgeAtom, ModelValue) -> boolean
function M.model_denote_atom(atom, v)
	if atom == "AStr" then return v.head == "VStr" end
	if atom == "ABool" then return v.head == "VBool" end
	if atom == "ANil" then return v.head == "VNil" end
	if atom == "AInt" then return v.head == "VInt" end
	if atom == "ANum" then return v.head == "VInt" or v.head == "VFloat" end
	if atom == "AFloat" then return v.head == "VInt" or v.head == "VFloat" end
	error("bridge: not a bridged atom: " .. tostring(atom))
end

-- ── model value → real-Lua source expression ────────────────────────────────
-- Produce a Lua expression that, when evaluated by a REAL interpreter, yields
-- the real value corresponding to this model value. This is the value half of
-- the correspondence. Numbers are type-CLASSES with NO magnitude, so each number
-- class renders to a FIXED representative literal (membership is head-only):
--   VInt   (= NRint, the integer-valued class) ↦ a fixed integer-valued literal "0".
--   VFloat (= NRfrac, the non-integer class)   ↦ a fixed non-integer literal "0.5",
--             so its real image is never integral — the faithful image of the
--             `NRfrac` class. (There is no model value whose real image is `3.0`
--             yet is a non-integer; the old `AInt VFloat 3` disagreement cannot
--             arise. The representatives are immaterial to faithfulness — AInt
--             reads only the head, ANum/AFloat accept every number.)
--: (ModelValue) -> string
function M.value_to_lua_expr(v)
	if v.head == "VStr" then
		-- The single model string value renders to a FIXED representative string
		-- literal. AStr membership is head-only, so the choice of representative is
		-- immaterial to faithfulness — any string literal is in `type=="string"`.
		return '"s"'
	end
	if v.head == "VBool" then return v.b and "true" or "false" end
	if v.head == "VNil" then return "nil" end
	if v.head == "VInt" then return "0" end
	if v.head == "VFloat" then
		-- NRfrac: the genuinely-non-integer number class. A fixed fractional
		-- representative, so the real value is never == math.floor of itself.
		return "0.5"
	end
	if v.head == "VTable" then return "{}" end
	if v.head == "VFun" then return "(function() end)" end
	error("bridge: unknown model value head: " .. tostring(v.head))
end

-- ── real-Lua membership predicate per atom (the REAL side of the bridge) ─────
-- The real-LuaJIT classification test for each unambiguous atom, as a Lua
-- expression over a bound name `x`. The differential harness evaluates this in
-- the REAL interpreter and compares against `model_denote_atom`.
--   AStr  ↔ type(x) == "string"
--   ABool ↔ type(x) == "boolean"
--   ANil  ↔ x == nil   (NB: type(nil) == "nil", but `x == nil` is the canonical
--           test and is robust to x being absent)
--   ANum  ↔ type(x) == "number"   (clean — int/float collapse to one runtime kind)
--   AFloat↔ type(x) == "number"   (float ≡ number on 5.1 — same test as ANum;
--           `AInt <: AFloat` holds because every integral number is a number)
--   AInt  ↔ derived predicate: a number, integer-valued, finite (excludes
--           ±inf and nan). On LuaJIT 5.1 this is NOT a runtime tag.
--: (BridgeAtom) -> string
function M.atom_real_predicate(atom)
	if atom == "AStr" then return 'type(x) == "string"' end
	if atom == "ABool" then return 'type(x) == "boolean"' end
	if atom == "ANil" then return "x == nil" end
	if atom == "ANum" then return 'type(x) == "number"' end
	if atom == "AFloat" then return 'type(x) == "number"' end
	if atom == "AInt" then
		-- integer-valued + finite: number, equal to its own floor, equal to
		-- itself (excludes nan), and not ±inf.
		return 'type(x) == "number" and x == math.floor(x) and x == x'
			.. ' and x ~= 1/0 and x ~= -1/0'
	end
	error("bridge: not a bridged atom: " .. tostring(atom))
end

-- ── REFINE-intended classification of a REAL Lua value ───────────────────────
-- The classification a 5.1-faithful REFINE type system INTENDS for a real value
-- `x`, computed in Lua itself (used by the differential to compare the model's
-- verdict against what reality SHOULD say under REFINE). This is the same
-- predicate as `atom_real_predicate` but evaluated host-side on an already-real
-- value rather than shelled out.
--: ("ANum" | "AInt", number | nil) -> boolean
function M.real_refine_class(atom, x)
	if atom == "ANum" then return type(x) == "number" end
	if atom == "AInt" then
		return type(x) == "number"
			and x == math.floor(x)
			and x == x
			and x ~= 1 / 0
			and x ~= -1 / 0
	end
	error("bridge: real_refine_class: not a number atom: " .. tostring(atom))
end

return M
