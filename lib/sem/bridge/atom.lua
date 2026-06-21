-- lib/sem/bridge/atom.lua
-- REALITY BRIDGE — the model↔real-LuaJIT correspondence for the UNAMBIGUOUS
-- atoms (AStr, ABool, ANil). See docs/reality-bridge.md.
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
-- SCOPE: the unambiguous atoms AStr/ABool/ANil, PLUS the number atoms ANum and
-- AInt under the decided REFINE policy (see docs/reality-bridge.md fork (A),
-- RESOLVED). The model tracks `AInt <: ANum` as a REFINED type distinction even
-- though LuaJIT 5.1's `type()` returns "number" for both — so on 5.1 `AInt`
-- membership is a DERIVED value-shape predicate (integer-valued + finite), not a
-- runtime tag. AFloat is SCOPED OUT: the model's `VFloat` is a distinct *value*,
-- but on LuaJIT 5.1 `3.0` and `3` are the SAME double — `VFloat 3` is
-- unobservable as a non-integer, so `AFloat` membership cannot be faithfully
-- tested on 5.1 (see the value-domain sub-fork in the doc). BRec, BArrow remain
-- deferred. The model value heads NOT members of a given atom (VTable/VFun, etc.)
-- ARE represented here so the harness exercises REJECTION too.

local M = {}

-- ── the bridged atoms ────────────────────────────────────────────────────────
-- AStr/ABool/ANil: unambiguous (head-determined, fork-independent).
-- ANum/AInt: number atoms under REFINE — ANum is a clean `type=="number"` test;
-- AInt is the integral-value refinement predicate. AFloat is NOT here (scoped
-- out — unobservable on 5.1; see `unobservable_atoms`).
--:: BridgeAtom = "AStr" | "ABool" | "ANil" | "ANum" | "AInt"

M.atoms = { "AStr", "ABool", "ANil", "ANum", "AInt" } --[[: BridgeAtom[] ]]

-- Atoms the model defines but whose membership is NOT faithfully observable on
-- LuaJIT 5.1, with the reason. AFloat ↔ `VFloat _` in the model, but a model
-- `VFloat 3` maps to the real double `3.0`, indistinguishable from `VInt 3`'s
-- `3` — so "is a non-integer number" is the only testable reading, and it
-- DISAGREES with the model for integer-valued floats. Bridged only if/when the
-- value-domain sub-fork is decided toward a single-double number value.
M.unobservable_atoms = { AFloat = "VFloat is a distinct value in the model; on LuaJIT 5.1 it shares the double representation with the integer-valued VInt, so VFloat-membership is unobservable." }

-- ── model values (a faithful port of the proof's `V`) ────────────────────────
-- Each model `V` constructor is rendered as a tagged table. We include the
-- non-unambiguous heads (VInt/VFloat/VTable/VFun) so the harness can assert they
-- are correctly REJECTED by every unambiguous atom — but their membership in
-- AInt/ANum etc. is out of scope here (the int/float fork).
--:: MVStr   = { head: "VStr", s: string }
--:: MVBool  = { head: "VBool", b: boolean }
--:: MVNil   = { head: "VNil" }
--:: MVInt   = { head: "VInt", n: integer }
--:: MVFloat = { head: "VFloat", n: number }
--:: MVTable = { head: "VTable" }
--:: MVFun   = { head: "VFun" }
--:: ModelValue = MVStr | MVBool | MVNil | MVInt | MVFloat | MVTable | MVFun

--: (string) -> ModelValue
function M.vstr(s) return { head = "VStr", s = s } end
--: (boolean) -> ModelValue
function M.vbool(b) return { head = "VBool", b = b } end
--: () -> ModelValue
function M.vnil() return { head = "VNil" } end
--: (integer) -> ModelValue
function M.vint(n) return { head = "VInt", n = n } end
--: (number) -> ModelValue
function M.vfloat(n) return { head = "VFloat", n = n } end
--: () -> ModelValue
function M.vtable() return { head = "VTable" } end
--: () -> ModelValue
function M.vfun() return { head = "VFun" } end

-- ── the model atom-denotation port (mirrors proof/subtype.v `atom_denote`) ───
-- `atom_denote` in the proof:
--   AStr  ↔ match v with VStr  _  => True | _ => False
--   ABool ↔ match v with VBool _  => True | _ => False
--   ANil  ↔ match v with VNil     => True | _ => False
--   AInt  ↔ match v with VInt  _  => True | _ => False
--   ANum  ↔ match v with VInt _ | VFloat _ => True | _ => False
-- This port matches ONLY on the value HEAD, exactly as the model does (the
-- model's denotation is head-determined — see `denote_head` in the proof). Note
-- the CENTRAL FAITHFULNESS POINT: per the MODEL, `VFloat _` is NOT in `AInt`
-- (only `VInt _` is) — so `model_denote_atom("AInt", vfloat(3.0))` is `false`,
-- even though the real double `3.0` satisfies the integral-value predicate. The
-- port faithfully reports the MODEL's verdict; the disagreement with reality is
-- surfaced by `real_int_predicate_holds` and the differential test, not hidden
-- here. Validated case-for-case against the Coq `Compute` of `denote_dec` in
-- atom_test.lua, so it is a trustworthy proxy for the proven model.
--: (BridgeAtom, ModelValue) -> boolean
function M.model_denote_atom(atom, v)
	if atom == "AStr" then return v.head == "VStr" end
	if atom == "ABool" then return v.head == "VBool" end
	if atom == "ANil" then return v.head == "VNil" end
	if atom == "AInt" then return v.head == "VInt" end
	if atom == "ANum" then return v.head == "VInt" or v.head == "VFloat" end
	error("bridge: not a bridged atom: " .. tostring(atom))
end

-- ── model value → real-Lua source expression ────────────────────────────────
-- Produce a Lua expression that, when evaluated by a REAL interpreter, yields
-- the real value corresponding to this model value. This is the value half of
-- the correspondence: VStr s ↦ a Lua string literal, VBool b ↦ true/false,
-- VNil ↦ nil, VInt/VFloat ↦ a number literal, VTable ↦ {}, VFun ↦ a function.
--: (ModelValue) -> string
function M.value_to_lua_expr(v)
	if v.head == "VStr" then
		-- %q gives a Lua-safe quoted string literal.
		return ("%q"):format(v.s)
	end
	if v.head == "VBool" then return v.b and "true" or "false" end
	if v.head == "VNil" then return "nil" end
	if v.head == "VInt" then return ("%d"):format(v.n) end
	if v.head == "VFloat" then
		-- a non-integer-valued number literal (the model's VFloat is the
		-- non-integer numeric kind; render with a fractional part so real Lua
		-- sees a number that is not == math.floor of itself).
		return ("%.4f"):format(v.n)
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
--   AInt  ↔ REFINE derived predicate: a number, integer-valued, finite (excludes
--           ±inf and nan). On LuaJIT 5.1 this is NOT a runtime tag.
--: (BridgeAtom) -> string
function M.atom_real_predicate(atom)
	if atom == "AStr" then return 'type(x) == "string"' end
	if atom == "ABool" then return 'type(x) == "boolean"' end
	if atom == "ANil" then return "x == nil" end
	if atom == "ANum" then return 'type(x) == "number"' end
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
