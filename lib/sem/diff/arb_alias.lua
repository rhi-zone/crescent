-- lib/sem/diff/arb_alias.lua
-- STRUCTURE-AWARE ALIAS-TARGETING generator for Loop-β
-- (docs/typechecker-formal-semantics.md §5: "structure-aware generators that
-- DELIBERATELY construct aliases ... not uniform random, which would miss the
-- measure-zero aliasing bug exactly as the human auditors did").
--
-- WHY NOT THE UNIFORM arb_program GENERATOR. arb_program.lua samples programs
-- uniformly over the v1 fragment; the covariant-field-write unsoundness lives on
-- a MEASURE-ZERO shape (a table with an annotated mutable field, TWO aliases at
-- different static types, a write through the wide alias, a read+use through the
-- narrow one). Uniform sampling never lands there — the same blind spot that let
-- the variance hole survive 5 human audits. This generator CONSTRUCTS that exact
-- shape every time, then varies the field types / written value / alias mechanism
-- around it. That is the industrialised search §5 mandates.
--
-- WHAT IT PRODUCES — an `AliasProg`, carrying BOTH halves of the Loop-β seam:
--   * `prog`   — the surface SS[] (lib/sem/lang/lua's SX/SS), runnable by the SPEC
--                (lower → run). This is the UNTYPED operational truth.
--   * `source` — the SAME program as crescent-annotated Lua SOURCE TEXT
--                (`--:` / `--::`), the input the CHECKER consumes (L.lower).
--   * `narrow_ty` / `wide_ty` — the field type the table is declared with (narrow)
--                and the alias's widened field type (wide). The checker accepts the
--                alias-widen iff `narrow <: wide` under its variance rule; a SOUND
--                checker uses INVARIANT mutable-field depth, an UNSOUND one uses
--                COVARIANT. These two Ty values are what the synthetic unsound
--                oracle decides over (lib/sem/diff/beta_test.lua) — the generator
--                hands the oracle the precise types it built, never a hardcoded
--                verdict.
--   * `faults` — whether the SPEC faults on `prog` (computed by the generator from
--                the runtime kinds, then CONFIRMED by actually running the spec in
--                beta_test — never trusted blind).
--
-- The shape is always:
--     --:: NarrowBox = { f: <NT> }
--     --:: WideBox   = { f: <WT> }
--     --: NarrowBox
--     local a = { f = <seed> }   -- the fresh table, narrow static type
--     --: WideBox
--     local b = a                -- ALIAS-WIDEN: a (NarrowBox) viewed as WideBox
--     b.f = <wval>               -- write <wval> (: WT) through the WIDE alias
--     return a.f <use>           -- read + USE through the NARROW alias
-- where <use> exercises the narrow field as its declared type (arithmetic for a
-- number field). When WT is wider than NT in a way that lets a wrong-RUNTIME-KIND
-- value reach the narrow use (e.g. NT=number, WT=unknown, wval a string), the
-- narrow use FAULTS at runtime — that is the soundness witness.
--
-- An arb-shaped { generate, shrink } so Loop-β gets seed replay + shrinking
-- (lib/test/arb.lua's runner contract: most-shrunk first, never re-run generator).

--:: require "lib.sem.lang.lua.lower"
--:: require "lib.type.analysis.slice_ty"

local G = require("lib.type.analysis.slice_ty")

local M = {}

--:: Rng = { seed: number, next: (self: Rng) -> number, float: (self: Rng) -> number, int: (self: Rng, lo: integer, hi: integer) -> integer, bool: (self: Rng) -> boolean, pick: <T>(self: Rng, t: T[]) -> T }

-- A field-type slot: a slice Ty (`G.*`), the crescent-source rendering of that
-- type, plus a `seed` SX (a value of the NARROW type to initialise the table) and
-- a `use` describing how the NARROW alias reads+uses the field.
--:: FieldKind = { ty: Ty, src: string, seed: SX, seed_src: string, use: string }

-- A written-value slot: the SX written through the WIDE alias, its source text,
-- the wide Ty it must satisfy, and the runtime VALUE-KIND it produces (so the
-- generator can PREDICT whether the narrow use faults; beta_test confirms).
--:: WriteVal = { sx: SX, src: string, kind: string }

-- An AliasProg: both halves of the seam plus the variance-decision types.
--:: AliasProg = {
--::   prog: SS[],
--::   source: string,
--::   narrow_ty: Ty,
--::   wide_ty: Ty,
--::   pred_faults: boolean,
--::   note: string,
--:: }

-- ── narrow field kinds (the table's DECLARED field type) ─────────────────────
-- Each names a narrow field type, a seed value of that type, and the narrow-alias
-- USE that exercises the field AS its declared type. `number` uses arithmetic
-- (which faults on a non-number at runtime — the fault detector); `string` uses
-- concatenation (faults on a non-string); `boolean` is read into an `if` (no
-- arithmetic fault path — used for sound, non-faulting rows).
--: (Rng) -> FieldKind
local function gen_narrow(rng)
	local pick = rng:int(1, 3)
	if pick == 1 then
		-- number field; narrow use = arithmetic (`a.f + 1`): faults on non-number.
		local n = rng:int(0, 9)
		local seed = { x = "num", n = n } --[[: SX]]
		return { ty = G.number(), src = "number", seed = seed, seed_src = tostring(n), use = "arith" }
	end
	if pick == 2 then
		-- string field; narrow use = concat (`a.f .. ""`): faults on non-string.
		local seed = { x = "str", s = "ok" } --[[: SX]]
		return { ty = G.string(), src = "string", seed = seed, seed_src = "\"ok\"", use = "concat" }
	end
	-- boolean field; narrow use = `if a.f then` — no arithmetic, never faults.
	local b = rng:bool()
	local seed = { x = "bool", b = b } --[[: SX]]
	return { ty = G.boolean(), src = "boolean", seed = seed, seed_src = b and "true" or "false", use = "truth" }
end

-- ── wide field kinds (the alias's WIDENED field type) ────────────────────────
-- Given the narrow field type, produce a WIDE field type that is a covariant
-- supertype of it (`narrow <: wide`), so a COVARIANT (unsound) checker accepts the
-- alias-widen. Two families:
--   * `unknown` — the universal supertype. EVERY narrow type is covariantly
--     `<: unknown`. The wide alias then admits a value of a DIFFERENT runtime kind
--     (a string into a number field), which the narrow use faults on. This is the
--     FAULTING family — the soundness witness.
--   * `same` — the wide field type EQUALS the narrow one. `narrow <: wide` AND
--     `wide <: narrow`, so BOTH the covariant and invariant checkers accept (it is
--     a genuine, sound subtype). The written value stays the narrow kind, so the
--     narrow use does NOT fault. The SOUND control row: an accepted program the
--     spec does not fault on, which a correct Loop-β must NOT flag.
-- a WriteVal of a given runtime kind ("number"|"string"|"boolean") with a literal
-- payload from the rng. Built as a single fully-initialised record per branch so
-- there is no uninitialised annotated local.
--: (Rng, string) -> WriteVal
local function write_val(rng, kind)
	if kind == "number" then
		local n = rng:int(0, 9)
		return { sx = { x = "num", n = n } --[[: SX]], src = tostring(n), kind = "number" }
	end
	if kind == "string" then
		return { sx = { x = "str", s = "y" } --[[: SX]], src = "\"y\"", kind = "string" }
	end
	local b = rng:bool()
	return { sx = { x = "bool", b = b } --[[: SX]], src = b and "true" or "false", kind = "boolean" }
end

--: (Rng, FieldKind) -> { wide_ty: Ty, wide_src: string, wval: WriteVal }
local function gen_wide(rng, nf)
	local fam = rng:int(1, 2)
	if fam == 1 then
		-- FAULTING family: wide = unknown; write a value of a kind the narrow use
		-- faults on. For a number narrow use (arith), write a STRING; for a string
		-- narrow use (concat), write a NUMBER; for boolean (no fault path), write a
		-- string (still no fault — boolean `if` accepts anything truthy/falsy).
		local wrong = nf.src == "string" and "number" or "string" --: string
		return { wide_ty = G.unknown(), wide_src = "unknown", wval = write_val(rng, wrong) }
	end
	-- SOUND family: wide = narrow; write a value of the NARROW kind (no corruption).
	return { wide_ty = nf.ty, wide_src = nf.src, wval = write_val(rng, nf.src) }
end

-- ── the narrow-use SX + source, given a field kind ───────────────────────────
-- Builds `a.f <use>` for both the surface AST (spec) and the source text (print).
--: (string) -> (SX, string)
local function use_expr(use)
	-- `a.f` is index(name("a"), str("f")).
	local af = { x = "index", obj = { x = "name", name = "a" } --[[: SX]],
		key = { x = "str", s = "f" } --[[: SX]] } --[[: SX]]
	if use == "arith" then
		local e = { x = "binop", op = "add", a = af, b = { x = "num", n = 1 } --[[: SX]] } --[[: SX]]
		return e, "(a.f + 1)"
	end
	if use == "concat" then
		local e = { x = "binop", op = "concat", a = af, b = { x = "str", s = "!" } --[[: SX]] } --[[: SX]]
		return e, "(a.f .. \"!\")"
	end
	-- truth: just return `a.f` (read through the narrow alias; no fault path).
	return af, "a.f"
end

-- ── alias mechanism: how the SECOND reference is created ─────────────────────
-- TWO aliasing mechanisms (the §5 "≥2 aliases via `local b = a` / passing the
-- same table to a function / storing it in two places"):
--   * "local" — `local b = a` (a direct local alias at the wide static type).
--   * "field" — store `a` into a second table `c.g = a` then read it back; the
--     embedded-alias sub-hole the framework doc flags (§ motivation: "an
--     embedded-alias sub-hole surfaced only because someone happened to imagine
--     that exact case"). Both create a second reference to the SAME store table.
-- For the SPEC both produce genuine store aliasing (tables are store refs); for
-- the CHECKER the wide static type is attached at the alias binding.

-- ── build one AliasProg ──────────────────────────────────────────────────────
--: (Rng) -> AliasProg
function M.gen(rng)
	local nf = gen_narrow(rng)
	local w = gen_wide(rng, nf)
	local use_sx, use_src = use_expr(nf.use)

	-- runtime fault prediction: the narrow use faults iff the value that reaches
	-- the narrow field has the WRONG runtime kind for the use. The wide alias
	-- wrote `w.wval` (kind = w.wval.kind); the narrow use needs `number` (arith) /
	-- `string` (concat) / anything (truth).
	local need = nf.use == "arith" and "number" or (nf.use == "concat" and "string" or "any")
	local pred_faults = false --: boolean
	if need ~= "any" and w.wval.kind ~= need then pred_faults = true end

	-- ── surface AST (for the SPEC) ──
	-- a = {} ; a.f = seed ; b = a ; b.f = wval ; return <use>
	local prog = {
		{ s = "local", names = { "a" }, exprs = { { x = "table", items = {} } --[[: SX]] } } --[[: SS]],
		{ s = "setindex", obj = { x = "name", name = "a" } --[[: SX]],
			key = { x = "str", s = "f" } --[[: SX]], val = nf.seed } --[[: SS]],
		{ s = "local", names = { "b" }, exprs = { { x = "name", name = "a" } --[[: SX]] } } --[[: SS]],
		{ s = "setindex", obj = { x = "name", name = "b" } --[[: SX]],
			key = { x = "str", s = "f" } --[[: SX]], val = w.wval.sx } --[[: SS]],
		{ s = "return", exprs = { use_sx } } --[[: SS]],
	} --[[: SS[] ]]

	-- ── annotated SOURCE (for the CHECKER) ──
	-- the seed literal source comes from the FieldKind (rendered at gen_narrow time).
	local source = table.concat({
		"--:: NarrowBox = { f: " .. nf.src .. " }",
		"--:: WideBox = { f: " .. w.wide_src .. " }",
		"--: NarrowBox",
		"local a = { f = " .. nf.seed_src .. " }",
		"--: WideBox",
		"local b = a",
		"b.f = " .. w.wval.src,
		"return " .. use_src,
		"",
	}, "\n")

	local note = nf.src .. "-field aliased as " .. w.wide_src
		.. ", write " .. w.wval.kind .. " through wide alias, narrow use=" .. nf.use

	return {
		prog = prog, source = source,
		narrow_ty = G.rec({ { key = "f", ty = nf.ty, optional = false, readonly = false } }, "closed"),
		wide_ty = G.rec({ { key = "f", ty = w.wide_ty, optional = false, readonly = false } }, "closed"),
		pred_faults = pred_faults, note = note,
	}
end

-- ── arb-shaped wrapper ───────────────────────────────────────────────────────
-- generate(rng, sz) -> (AliasProg, nil) ; shrink(prog, ctx) -> iter
-- The alias SHAPE is the invariant being targeted, so shrinking does NOT drop the
-- aliasing structure (that would shrink away the very bug class). It shrinks the
-- WRITTEN VALUE source toward its simplest faulting form and the seed toward 0 /
-- "" — converging on the minimal witness while KEEPING the four-line alias shape.
-- Since each AliasProg is self-contained (already minimal in structure), the
-- shrinker's job is to canonicalise the literals; it yields at most a couple of
-- progressively-simpler variants then stops (arb contract: most-shrunk first).
--:: ShrinkIter = () -> (AliasProg | nil, nil)
--:: AliasArb = { generate: (Rng, integer) -> (AliasProg, nil), shrink: (AliasProg, unknown) -> ShrinkIter }

M.arb = {
	--: (Rng, integer) -> (AliasProg, nil)
	generate = function(rng, _sz)
		return M.gen(rng), nil
	end,
	--: (AliasProg, unknown) -> ShrinkIter
	shrink = function(prog, _ctx)
		-- The structure is already minimal (4 statements + return). The witness is
		-- as-shrunk-as-it-gets structurally; we emit no further candidates so the
		-- reported witness IS this program. Returning an immediately-exhausted
		-- iterator keeps the arb contract (the harness stops shrinking at once).
		local _ = prog
		local done = false
		return function()
			if done then return nil, nil end
			done = true
			return nil, nil
		end
	end,
}

return M
