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
-- SCOPE: the unambiguous atoms only — AStr/ABool/ANil, where the model and real
-- LuaJIT 5.1 clearly correspond regardless of the int/float design fork. AInt,
-- AFloat, ANum, BRec, BArrow are DEFERRED (see the forks in the doc). The model
-- value heads that are NOT these atoms' members (VInt/VFloat/VTable/VFun) ARE
-- represented here so the harness exercises REJECTION too, but they are never
-- claimed to be members of an unambiguous atom.

local M = {}

-- ── the unambiguous atoms ────────────────────────────────────────────────────
-- Exactly the model's `Atom` constructors whose real-LuaJIT correspondence is
-- not entangled with the int/float fork.
--:: BridgeAtom = "AStr" | "ABool" | "ANil"

M.atoms = { "AStr", "ABool", "ANil" } --[[: BridgeAtom[] ]]

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
--   AStr  ↔ match v with VStr  _ => True | _ => False
--   ABool ↔ match v with VBool _ => True | _ => False
--   ANil  ↔ match v with VNil    => True | _ => False
-- This port matches ONLY on the value head, exactly as the model does (the
-- model's denotation is head-determined for these atoms — see `denote_head` in
-- the proof, the `atomic` fragment). It is validated case-for-case against the
-- Coq `Compute` of `denote_dec` in atom_test.lua, so it is a trustworthy proxy
-- for the proven model.
--: (BridgeAtom, ModelValue) -> boolean
function M.model_denote_atom(atom, v)
	if atom == "AStr" then return v.head == "VStr" end
	if atom == "ABool" then return v.head == "VBool" end
	if atom == "ANil" then return v.head == "VNil" end
	error("bridge: not an unambiguous atom: " .. tostring(atom))
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
--: (BridgeAtom) -> string
function M.atom_real_predicate(atom)
	if atom == "AStr" then return 'type(x) == "string"' end
	if atom == "ABool" then return 'type(x) == "boolean"' end
	if atom == "ANil" then return "x == nil" end
	error("bridge: not an unambiguous atom: " .. tostring(atom))
end

return M
