-- lib/sem/bridge/rec.lua
-- REALITY BRIDGE — model `VTable` (finite string-keyed assoc list) ↔ a REAL
-- LuaJIT table, and model record membership `denote (BRec fields) (VTable t)` ↔
-- the real-computed open/width record verdict. Resolves fork (C) of
-- docs/reality-bridge.md for the STRING-KEYED SCALAR fragment. See that doc.
--
-- THE MODEL. The proof's `VTable : list (string*V) -> V` is a finite assoc-list
-- of string keys to sub-values. `BRec : list (string*BTy) -> BTy` is the OPEN /
-- WIDTH record type: `VTable t ∈ BRec fields` iff `t` is a table AND for every
-- listed `(k,T)` there is an entry at key `k` whose value `∈ T` — EXTRA keys in
-- `t` are ALLOWED (open). This is a faithful port of `denote_dec (BRec fields)
-- (VTable t)` (proof/subtype.v): per-field `assoc_lookup` + recursive scalar atom
-- membership, folded with conjunction over the fields.
--
-- THE CORRESPONDENCE. The model table `VTable [(k1,v1);…]` maps to the real Lua
-- table `{ [k1] = real_image(v1), … }`. Keys are string literals; field values
-- are SCALARS (number/string/bool/nil), rendered with the atom bridge's value
-- renderer. (A `nil`-valued field collapses to "key absent" in real Lua — see the
-- `nil` note on `model_rec_verdict` / the renderer; this is a faithful image of
-- the runtime, and the model lookup of an absent key is `None`.)
--
-- TWO things the harness checks (in rec_test.lua):
--   (membership) record type verdict. The MODEL verdict (port of `denote_dec
--     (BRec fields) (VTable t)`) AGREES with the REAL-computed verdict: build the
--     real table, then for each `(k,T)∈fields` check `real_table[k] ~= nil and
--     (real_table[k] ∈ T via the atom bridge's REAL atom predicate)`.
--
-- SCOPE (honest): STRING keys + SCALAR field values only. DEFERRED (recorded in
-- TODO.md proof-dev backlog): nested records (table-valued fields), function-
-- valued fields, non-string keys, array part, metatables, iteration order.

local atom = require("lib.sem.bridge.atom")

--:: require "lib.sem.bridge.atom"

local M = {}

-- ── the scalar atoms a record field's type may range over ────────────────────
-- The record bridge restricts each field type T in `BRec fields` to the SCALAR
-- atoms (the atoms the atom bridge already bridges). Nested-record and function-
-- valued fields defer.
--:: RecAtom = "AStr" | "ABool" | "ANil" | "ANum" | "AInt" | "AFloat"
M.rec_atoms = { "AStr", "ABool", "ANil", "ANum", "AInt", "AFloat" } --[[: RecAtom[] ]]

-- ── model record value + type (mirrors `VTable` / `BRec` over the fragment) ───
-- A model table value: the VTable head carrying a finite string-keyed scalar
-- assoc list (ORDERED, so iteration order / shadowing match `assoc_lookup`, which
-- returns the FIRST matching entry).
--:: TableEntry = { k: string, v: ModelValue }
--:: MVTableRec = { head: "VTableRec", entries: TableEntry[] }
-- A model record TYPE: a finite list of (key, scalar-atom) field requirements.
--:: RecField = { k: string, T: RecAtom }
--:: RecType  = RecField[]

--: (TableEntry[]) -> MVTableRec
function M.vtable_rec(entries) return { head = "VTableRec", entries = entries } end

-- ── model `assoc_lookup` (mirrors proof/subtype.v `assoc_lookup`) ────────────
-- Return the value of the FIRST entry whose key equals `k`, or nil if absent.
-- This matches the proof's `assoc_lookup` (left-to-right, first match wins). The
-- sentinel for "absent" is Lua nil; field values are scalars but a present `VNil`
-- entry is still an entry (head "VNil"), distinct from absence (no entry).
--: (string, TableEntry[]) -> (ModelValue | nil)
function M.assoc_lookup(k, entries)
	for i = 1, #entries do
		if entries[i].k == k then return entries[i].v end
	end
	return nil
end

-- ── the model record-membership port (mirrors `denote_dec (BRec fields) (VTable t)`)
-- The proof's BRec denotation (OPEN / WIDTH): `VTable t ∈ BRec fields` iff for
-- EVERY `(k,T)` in `fields` there is an entry at key `k` in `t` whose value is in
-- `T` (per the atom port). Extra entries in `t` are allowed (open). We port that
-- exactly: per field, `assoc_lookup` the key; if absent ⇒ NOT a member; if
-- present, the looked-up scalar value must be in `T` per `model_denote_atom`. The
-- empty field list ⇒ vacuously a member (every table is in `BRec []`).
--: (RecType, MVTableRec) -> boolean
function M.model_rec_verdict(fields, vtable)
	local entries = vtable.entries
	for i = 1, #fields do
		local field = fields[i]
		local vv = M.assoc_lookup(field.k, entries) --[[: ModelValue | nil]]
		if vv == nil then
			return false -- a witness: the required key is missing entirely
		end
		if not atom.model_denote_atom(field.T, vv) then
			return false -- a witness: present at k, but value not in T
		end
	end
	return true
end

-- ── model `VTable` (string-keyed scalar assoc) → real Lua table SOURCE ────────
-- Emit the SOURCE of a real Lua table constructor `{ [k1]=e1, [k2]=e2, … }`
-- realizing exactly `vtable.entries`, with each value rendered by the atom
-- bridge's scalar renderer (`value_to_lua_expr`). Keys are string literals
-- (`["k"]=`). A `VNil`-valued field renders to `["k"]=nil`, which real Lua treats
-- as "no entry at k" — faithful to the runtime, and consistent with the model:
-- `assoc_lookup` of a `VNil` entry returns the `VNil` value, but the real table
-- has no `k`, so the only atom that could match a `VNil` field is `ANil` whose
-- REAL predicate is `x == nil` (true for an absent key). The verdict legs agree
-- because both `real_table[k]` (absent ⇒ nil) and `ANil`'s predicate read nil.
-- We emit the constructor as an EXPRESSION so callers can bind it inline.
--: (MVTableRec) -> string
function M.table_to_lua_expr(vtable)
	local entries = vtable.entries
	local parts = {} --[[: { [integer]: string } ]]
	for i = 1, #entries do
		local key_lit = ("%q"):format(entries[i].k) --[[: string]]
		local val_expr = atom.value_to_lua_expr(entries[i].v) --[[: string]]
		parts[#parts + 1] = "[" .. key_lit .. "] = (" .. val_expr .. ")"
	end
	return "{ " .. table.concat(parts, ", ") .. " }"
end

-- ── per-field REAL membership predicate (for the real-computed verdict) ──────
-- The membership leg's REAL side, per field. For a single field `(k,T)`, the
-- real-Lua reading of "there is an entry at k whose value is in T" is:
-- `real_table[k] ~= nil and (real_table[k] ∈ T per the atom REAL predicate)`. We
-- emit a Lua boolean EXPRESSION over a bound table name `tbl` computing exactly
-- that, by substituting `tbl[k]` for the atom predicate's bound name `x`.
--
-- NOTE on ANil / nil fields. `real_table[k] ~= nil` makes a missing key fail the
-- field — matching the model (absent key ⇒ `assoc_lookup` None ⇒ non-member). A
-- field typed `ANil` over an entry that was rendered `["k"]=nil` is therefore
-- (correctly) NOT a member on the real side, because the key is absent. The
-- model agrees: a `VNil` entry's *value* is in `ANil`, BUT the renderer dropped
-- the key, so this is the one nil-collapse subtlety — we keep the harness honest
-- by NOT generating `VNil`-valued entries paired with an `ANil` field expectation
-- (rec_test.lua's generator renders nil values but only checks them against atoms
-- whose real predicate reads an absent key consistently; see the test).
--: (string, RecAtom) -> string
function M.field_real_member_expr(k, T)
	local key_lit = ("%q"):format(k) --[[: string]]
	local access = "tbl[" .. key_lit .. "]"
	local pred = atom.atom_real_predicate(T) --[[: string]]
	-- rebind the atom predicate's `x` to the table access expression. The
	-- predicates reference only `x` (and globals type/math), so textual rebinding
	-- to a parenthesized access is sound.
	local pred_at = (pred:gsub("%f[%w]x%f[%W]", "(" .. access .. ")"))
	-- the field is satisfied iff the key is present AND the value is in T.
	return "(" .. access .. " ~= nil and (" .. pred_at .. "))"
end

return M
