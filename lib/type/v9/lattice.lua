-- lib/type/v9/lattice.lua
-- The v0 TYPE LATTICE for checking real Lua: atoms over the Lua base types
-- (nil / true / false / number / string + the distinct table and function
-- TOPS), STRUCTURAL OPEN RECORDS, FUNCTION TYPES, finite unions (a value
-- carries an atom SET plus at most one record component plus at most one
-- function component), and `unknown` as the absorbing top. Deliberately
-- BTy-lite: negation / richer literal types are later DOMAIN-LOCAL upgrades
-- behind this same interface — the engine never sees any of this vocabulary.
--
-- BOOLEAN IS SPLIT into the `true` and `false` literal atoms (boolean = their
-- union; constructors normalize the spelling "boolean" into the pair, and
-- show/excess collapse the pair back for display). The split is what makes
-- the classic `cond and a or b` idiom precise: falsy(boolean) = false, and
-- truthy(false | T) = T — the `or` arm never leaks a phantom `boolean`.
--
-- ── Records (the v0 mutation-soundness choice, stated) ─────────────────────
--
-- A record is OPEN (width-subtyped): `{ x: number }` admits any table that
-- has field x at a number — extra fields are always allowed (the proof-dev's
-- `BRec` reading, proof/subtype.v). Mutation makes naive covariant fields
-- UNSOUND (write "s" through a widened alias, read it as number elsewhere),
-- so each field carries a READ/WRITE SPLIT — the engine-lattice encoding of
-- the proof-dev's records-of-refs:
--
--   Field = { r, w }   r : covariant READ type  — joins UP    (set union)
--                      w : contravariant WRITE bound — joins DOWN (meet)
--
-- At construction r = w = the field's initial type (the ref's fixed content
-- type). A join of two record types (phi at a merge) keeps the COMMON fields
-- with r = join(r1, r2) and w = meet(w1, w2): reads through the merged view
-- may see either branch (union), while writes through it must be safe for
-- BOTH branches (meet). Writing through any view is checked against `w`
-- post-solve; a field's types are never relaxed by a write. This rejects the
-- classic unsound cases:
--
--   local t = { x = 1 }            local a = { x = 1 }
--   local u = t                    local b = { x = "s" }
--   u.x = "s"   -- REJECTED        local t = c and a or b   -- w(x) = meet = never
--   t.x + 1     -- stays sound     t.x = anything           -- REJECTED
--
-- The ONE deliberate concession (a NAMED policy rule, `new-field-on-write`,
-- see check.lua): a write may CREATE a field on an open record — the Lua
-- module idiom (`local M = {}; function M.f() end`) requires it. The new
-- field exists only on the writer's flow-sensitive version; aliases taken
-- earlier do not see it (reads through them report missing-field — imprecise
-- but sound), EXCEPT that two aliases creating the SAME new field at
-- different types can fool a reader. That residual hole is exactly what the
-- policy rule names; dial it to "error" to forbid the idiom and close it.
--
-- ── Index signatures (the dynamic-key discipline) ──────────────────────────
--
-- A record optionally carries an INDEX component `idx = { str, num }` — one
-- Field per key KIND ({ [string]: T } / { [number]: T }; `[string]` here is
-- the structural index-signature form, DISTINCT from the `...` open-record
-- marker, which stays a width no-op). The semantics, stated:
--
--   idx == nil    a PLAIN open record: dynamic (non-literal) keys are
--                 UNTRACKED. Dynamic reads project `unknown` (monotone) and
--                 the read obligation names the boundary
--                 (`index-without-signature`, check.lua).
--   idx present   an INDEX-BOUNDED record: string keys are exactly (named
--                 fields) ∪ str, number keys exactly num. A part with
--                 r = w = never means "no keys of that kind" (that is how
--                 `{ [string]: T }` claims number keys absent, and how an
--                 array constructor claims string keys absent). Named
--                 fields take PRECEDENCE on known keys (standard).
--
-- Index READS are `T | nil`, non-negotiably: an absent key IS nil in Lua —
-- this is the spot where TS's index signatures are unsound by default and
-- v9 is not. A dynamic read joins the consulted parts (+ every named field
-- when the key can be a string) + nil. Index WRITES are checked against the
-- part's invariant `w` bound post-solve, exactly like named-field writes;
-- a write may CREATE a part on a part-less/never record — the same named
-- concession as fields (`new-index-on-write`, dialable). Keys outside
-- string/number (Lua allows any non-nil key) are outside the v0 index
-- discipline: never tracked by idx, reads of them stay the honest
-- `unsupported:dynamic-index` boundary — which keeps idx sound without
-- modeling them.
--
-- JOIN keeps idx only when BOTH sides have it (an unbounded side admits
-- keys at any type), pointwise (r up, w down/meet). A named field only one
-- side has does NOT silently vanish (the plain-record width rule): it FOLDS
-- into the joined str part (r joins in, w meets in) — that fold is what
-- keeps dynamic reads through the widened view sound AND keeps the index
-- projections monotone under the engine's join. Subtyping: `b`'s index
-- parts demand matching parts on `a` (r covariant, w contravariant), and
-- every named field of `a` that `b` does not name must fit `b`'s str part
-- (width-into-index). A plain open record does NOT flow into an
-- index-signature type under `leq` (its unnamed keys are unbounded — the
-- sound call); a syntactically FRESH constructor does, under `leq_init`
-- (the ascription re-types its refs, and a fresh table genuinely has no
-- other keys).
--
-- ITERATION projections (the declaration intrinsics `$Elem<N>` /
-- `$Values<N>` / `$Keys<N>` — see Fn.insts below): elem_iter is the ipairs
-- element type (num part, nil-DROPPED — ipairs stops at the first nil, so a
-- visited element is never nil; Lua semantics, stated); values_iter is the
-- pairs value type (named fields + both parts, nil-dropped — a nil-valued
-- key does not exist in a Lua table); keys_iter is the pairs key type | nil
-- (the protocol's end marker rides in the result; for-in drops it). All
-- three read `unknown` off plain open records (unbounded keys) — precision
-- comes from declaring or constructing the index part.
--
-- ── Function types (the v0 arrow, engine-shaped) ───────────────────────────
--
-- A function component types `(params...) -> (results...)`:
--
--   Fn = { params, results, vararg, rest, open }
--   params[i]  = { cell, pin }   cell : the param's ENGINE CELL id — call
--                                sites propose argument values INTO it
--                                (cells-as-unknowns: param inference);
--                                pin  : the annotated param type, nil when
--                                unannotated. Pins are the CONTRAVARIANT
--                                face: a call site's argument is checked
--                                `arg ⊑ pin`, and fn ⊑ fn demands
--                                `pin_b ⊑ pin_a` (see fn_leq).
--   results[i] = Val             COVARIANT: joins UP as return cells grow.
--   vararg     = boolean         the function declares `...`.
--   rest       = Val | nil       annotated `...T` bound for extra arguments.
--   open       = boolean         some return ends in a call/vararg spread —
--                                result positions beyond #results are
--                                `unknown`, not `nil`.
--
-- WHY params are CELLS and results are VALUES: results are covariant, so a
-- rebuild rule re-proposing them as return cells climb is monotone under the
-- engine's join. Params are contravariant — successive proposals would have
-- to MEET, and a meet against an early bottom sticks at bottom (the polarity
-- trap). Cell ids sidestep it: the param list is a CONSTANT (identity), the
-- flow into params happens through the engine's ordinary join on the param
-- cells themselves, and the contravariant CHECK lives in pins + post-solve
-- obligations. This is the arrow analogue of the record r/w split.
--
-- Join of two DIFFERENT functions (a phi like `cond and f or g`) collapses
-- to the `function` atom top — calling it is unchecked (reported as the
-- use-before-narrow class), which is sound and honest; keeping a precise
-- union of arrows is a later domain-local upgrade. Join of the SAME function
-- (same param cells) joins results pointwise.
--
-- TERMINATION: recursion can route a function's own value into its result
-- cells (`local function f() return f end`) — each rebuild would nest one
-- level deeper, an infinite ascent. `clip(v, depth)` cuts values at a fixed
-- depth (replacing deeper structure with `unknown`, an upper approximation,
-- so monotonicity survives); lowering applies it at exactly the two
-- cycle-closing proposal sites (function rebuild, call-site argument flow).
--
-- ── Flow operations ─────────────────────────────────────────────────────────
--
-- Everything flow-sensitive derives from the same two lattice operations:
--
--   truthy(T) = drop `nil` and `false` (records/tables are always truthy)
--   falsy(T)  = keep only `nil` and `false` (records are never falsy)
--
-- `if`-narrowing uses them directly, and `and`/`or` are DERIVED, not
-- hardcoded:  a and b : falsy(a) | type(b)     a or b : truthy(a) | type(b).
-- The `type(x) == "…"` tag guards add two more of the SAME shape —
-- tag_keep/tag_drop (the part of T whose type() is / is not the tag; from
-- `unknown`, keep narrows to the tag's atom — the guard idiom's whole
-- point — and drop stays unknown, an upper approximation).
-- Field READS are one more monotone unary transfer, `project(v, name)`;
-- field WRITES are the binary `set_field(v, name, fv)`. Both are legal
-- engine transfers (monotone; proofs sketched at their definitions).
--
-- Soundness: join is set union on atoms + pointwise-on-common-fields on
-- records, with `unknown` absorbing (unknown is a real top, not `any`).
-- Termination: atom sets are finite; record width is bounded by program
-- syntax (field names are literals) and depth by `clip` at every
-- cycle-closing proposal site — the two recursion sites (function rebuild,
-- call-argument flow) AND loop back edges (a loop can grow a record/union
-- one level per iteration; the clipped back edge is the depth widening
-- that keeps the ascending chain finite — a lowering choice, not an
-- engine change).

--:: require "lib.type.v9.engine.defs"

local M = {}

-- A type value: a set of atom names + at most one open-record component +
-- at most one function component. {} atoms + nil rec + nil fn = bottom (no
-- info / never); { unknown = true } = top.
--:: Val = { atoms: { [string]: boolean }, rec: Rec | nil, fn: Fn | nil }
--:: Rec = { fields: { [string]: Field }, idx: Idx | nil }
--:: Idx = { str: Field, num: Field }
--:: Field = { r: Val, w: Val }
--:: Param = { cell: string, pin: Val | nil }
--:: Inst = { proj: string, idx: integer }
--:: Fn = { params: { [integer]: Param }, results: { [integer]: Val }, vararg: boolean, rest: Val | nil, open: boolean, insts: { [integer]: Inst } | nil }
--:: KeyKinds = { str: boolean, num: boolean, other: boolean, unknown: boolean }

M.ATOMS = { "nil", "true", "false", "number", "string", "table", "function", "unknown" }

--: (x: unknown) -> x is Val
local function as_val(x) return type(x) == "table" end
M.as_val = as_val
-- Back-compat name used by callers narrowing engine cell values.
M.as_atoms = as_val

-- Constructors NORMALIZE the "boolean" spelling into the true/false literal
-- pair — "boolean" is never an atom key, only a display collapse (show/excess).
-- (Dynamic keys throughout: the legacy checker folds literal-key writes
-- into the value's shape — same idiom as check.lua's DEFAULT_RULES.)
--: ({ [string]: boolean }, string) -> nil
local function add_atom(a, name)
    if name == "boolean" then
        local t = "true" --: string
        local f = "false" --: string
        a[t] = true
        a[f] = true
    else
        a[name] = true
    end
    return nil
end

--: (string) -> Val
local function single(atom)
    local a = {} --: { [string]: boolean }
    add_atom(a, atom)
    return { atoms = a, rec = nil, fn = nil }
end
M.single = single

--: ({ [integer]: string }) -> Val
function M.of(names)
    local a = {} --: { [string]: boolean }
    for i = 1, #names do add_atom(a, names[i]) end
    return { atoms = a, rec = nil, fn = nil }
end

--: (Val) -> boolean
local function has_unknown(v) return v.atoms["unknown"] == true end

--: ({ [string]: boolean }) -> { [string]: boolean }
local function copy_atoms(atoms)
    local r = {} --: { [string]: boolean }
    for k, present in pairs(atoms) do if present then r[k] = true end end
    return r
end

-- Records are IMMUTABLE once built (every operation returns fresh outer
-- tables; Field tables and the Idx wrapper are shared, never mutated), so a
-- "copy" is a fresh fields map sharing the Field entries + the shared idx.
--: (Rec) -> Rec
local function rec_copy(rec)
    local fields = {} --: { [string]: Field }
    for name, f in pairs(rec.fields) do fields[name] = f end
    return { fields = fields, idx = rec.idx }
end

--: (Val) -> boolean
local function val_is_bottom(v)
    for _, present in pairs(v.atoms) do if present then return false end end
    return v.rec == nil and v.fn == nil
end

--: () -> Val
local function never_val()
    local a = {} --: { [string]: boolean }
    return { atoms = a, rec = nil, fn = nil }
end

-- The "no keys of this kind" index part: r = w = never (shared, immutable).
local NEVER_FIELD = { r = never_val(), w = never_val() } --: Field

--: (Field) -> boolean
local function field_is_never(f)
    return val_is_bottom(f.r) and val_is_bottom(f.w)
end

-- ── Lattice (opaque-facing: this is what the engine consumes) ──────────────

--: () -> unknown
local function bottom()
    local a = {} --: { [string]: boolean }
    return { atoms = a, rec = nil, fn = nil }
end

-- Forward declarations: join/meet/equal recurse through record fields.
local join_val, meet_val, equal_val

-- ── Function-component helpers ─────────────────────────────────────────────

-- Same function IDENTITY: the param cell lists coincide. (A function's param
-- cells are minted once at its definition, so cell-list equality identifies
-- the definition; pins ride along and never differ for equal cell lists.)
--: (Fn, Fn) -> boolean
local function same_fn(a, b)
    if a == b then return true end
    if #a.params ~= #b.params then return false end
    for i = 1, #a.params do
        if a.params[i].cell ~= b.params[i].cell then return false end
    end
    return a.vararg == b.vararg
end

--: (Fn, Fn) -> boolean
local function fn_equal(a, b)
    if not same_fn(a, b) then return false end
    if #a.results ~= #b.results then return false end
    if a.open ~= b.open then return false end
    for i = 1, #a.results do
        if not equal_val(a.results[i], b.results[i]) then return false end
    end
    return true
end

-- Join of the SAME function: results join pointwise (covariant), positions
-- one side lacks count as `nil` (Lua pads missing results with nil).
--: (Fn, Fn) -> Fn
local function fn_join(a, b)
    local n = #a.results
    if #b.results > n then n = #b.results end
    local results = {} --: { [integer]: Val }
    for i = 1, n do
        local ra = a.results[i] or single("nil")
        local rb = b.results[i] or single("nil")
        results[i] = join_val(ra, rb)
    end
    return {
        params = a.params, results = results, vararg = a.vararg,
        rest = a.rest, open = a.open or b.open, insts = a.insts,
    }
end

-- Pointwise join on COMMON fields (width: a merged view only guarantees the
-- fields BOTH sides have). r joins UP (either branch may be read), w joins
-- DOWN via meet (a write must be safe for both branches). Index parts join
-- pointwise the same way, and survive only when BOTH sides are
-- index-bounded; a named field only ONE side has FOLDS into the joined
-- string part (its values ride there through the widened view — the fold is
-- what keeps dynamic reads sound and the index projections monotone).
--: (Field, Field) -> Field
local function idx_field_join(fa, fb)
    if fa == fb then return fa end
    return { r = join_val(fa.r, fb.r), w = meet_val(fa.w, fb.w) }
end

--: (Rec, Rec) -> Rec
local function rec_join(a, b)
    local ai = a.idx
    local bi = b.idx
    local both = ai ~= nil and bi ~= nil
    local fields = {} --: { [string]: Field }
    local fold_r = nil --: Val | nil
    local fold_w = nil --: Val | nil
    for name, fa in pairs(a.fields) do
        local fb = b.fields[name]
        if fb ~= nil then
            if fa == fb then
                fields[name] = fa
            else
                fields[name] = { r = join_val(fa.r, fb.r), w = meet_val(fa.w, fb.w) }
            end
        elseif both then
            if fold_r == nil or fold_w == nil then
                fold_r = fa.r
                fold_w = fa.w
            else
                fold_r = join_val(fold_r, fa.r)
                fold_w = meet_val(fold_w, fa.w)
            end
        end
    end
    for name, fb in pairs(b.fields) do
        if a.fields[name] == nil and both then
            if fold_r == nil or fold_w == nil then
                fold_r = fb.r
                fold_w = fb.w
            else
                fold_r = join_val(fold_r, fb.r)
                fold_w = meet_val(fold_w, fb.w)
            end
        end
    end
    local idx = nil --: Idx | nil
    if ai ~= nil and bi ~= nil then
        local s = idx_field_join(ai.str, bi.str)
        if fold_r ~= nil and fold_w ~= nil then
            s = { r = join_val(s.r, fold_r), w = meet_val(s.w, fold_w) }
        end
        idx = { str = s, num = idx_field_join(ai.num, bi.num) }
    end
    return { fields = fields, idx = idx }
end

--: (Field, Field) -> boolean
local function idx_field_equal(fa, fb)
    if fa == fb then return true end
    return equal_val(fa.r, fb.r) and equal_val(fa.w, fb.w)
end

--: (Rec, Rec) -> boolean
local function rec_equal(a, b)
    for name, fa in pairs(a.fields) do
        local fb = b.fields[name]
        if fb == nil then return false end
        if fa ~= fb and (not equal_val(fa.r, fb.r) or not equal_val(fa.w, fb.w)) then
            return false
        end
    end
    for name in pairs(b.fields) do
        if a.fields[name] == nil then return false end
    end
    local ai = a.idx
    local bi = b.idx
    if ai == nil then return bi == nil end
    if bi == nil then return false end
    return idx_field_equal(ai.str, bi.str) and idx_field_equal(ai.num, bi.num)
end

--: (Val, Val) -> Val
join_val = function(a, b)
    if has_unknown(a) or has_unknown(b) then return single("unknown") end
    local atoms = copy_atoms(a.atoms)
    for k, present in pairs(b.atoms) do if present then atoms[k] = true end end
    local rec = nil --: Rec | nil
    local ra = a.rec
    local rb = b.rec
    if ra ~= nil and rb ~= nil then
        rec = rec_join(ra, rb)
    elseif ra ~= nil then
        rec = rec_copy(ra)
    elseif rb ~= nil then
        rec = rec_copy(rb)
    end
    local fn = nil --: Fn | nil
    local fa = a.fn
    local fb = b.fn
    if fa ~= nil and fb ~= nil then
        if same_fn(fa, fb) then
            fn = fn_join(fa, fb)
        else
            -- two DIFFERENT functions merge: collapse to the function TOP
            -- (precise arrow unions are a later domain-local upgrade).
            local k = "function" --: string
            atoms[k] = true
        end
    elseif fa ~= nil then
        fn = fa
    elseif fb ~= nil then
        fn = fb
    end
    -- normalize: the `table`/`function` TOPS subsume their components.
    if atoms["table"] then rec = nil end
    if atoms["function"] then fn = nil end
    return { atoms = atoms, rec = rec, fn = fn }
end

-- Meet (greatest lower bound) — used ONLY for write bounds at record joins.
-- It must UNDER-approximate to stay sound (a too-small write bound rejects
-- writes it could have allowed; a too-large one admits unsound writes).
-- Atom sets intersect; `unknown` is the identity. Record components meet
-- conservatively: kept only when structurally equal or when the other side
-- admits any table (the `table` atom); otherwise dropped (= no table values
-- admitted through the record component — strict, sound).
--: (Val, Val) -> Val
meet_val = function(a, b)
    if has_unknown(a) then
        local rb0 = b.rec
        return { atoms = copy_atoms(b.atoms), rec = rb0 ~= nil and rec_copy(rb0) or nil, fn = b.fn }
    end
    if has_unknown(b) then
        local ra0 = a.rec
        return { atoms = copy_atoms(a.atoms), rec = ra0 ~= nil and rec_copy(ra0) or nil, fn = a.fn }
    end
    local atoms = {} --: { [string]: boolean }
    for k, present in pairs(a.atoms) do
        if present and b.atoms[k] then atoms[k] = true end
    end
    local rec = nil --: Rec | nil
    local ra = a.rec
    local rb = b.rec
    if ra ~= nil and rb ~= nil then
        if rec_equal(ra, rb) then rec = rec_copy(ra) end
    elseif ra ~= nil and b.atoms["table"] then
        rec = rec_copy(ra)
    elseif rb ~= nil and a.atoms["table"] then
        rec = rec_copy(rb)
    end
    -- Function components meet conservatively, mirroring records: kept when
    -- structurally equal or when the other side admits any function.
    local fn = nil --: Fn | nil
    local fa = a.fn
    local fb = b.fn
    if fa ~= nil and fb ~= nil then
        if fn_equal(fa, fb) then fn = fa end
    elseif fa ~= nil and b.atoms["function"] then
        fn = fa
    elseif fb ~= nil and a.atoms["function"] then
        fn = fb
    end
    if atoms["table"] then rec = nil end
    if atoms["function"] then fn = nil end
    return { atoms = atoms, rec = rec, fn = fn }
end
M.meet = meet_val

--: (Val, Val) -> boolean
equal_val = function(a, b)
    -- identity fast path: shared immutable structure (alias-DAG values,
    -- rec_copy-shared Fields) compares in O(1), not by deep walk.
    if a == b then return true end
    for k, present in pairs(a.atoms) do if present and not b.atoms[k] then return false end end
    for k, present in pairs(b.atoms) do if present and not a.atoms[k] then return false end end
    local fa = a.fn
    local fb = b.fn
    if fa ~= nil and fb ~= nil then
        if not fn_equal(fa, fb) then return false end
    elseif fa ~= nil or fb ~= nil then
        return false
    end
    local ra = a.rec
    local rb = b.rec
    if ra == nil then return rb == nil end
    if rb == nil then return false end
    return rec_equal(ra, rb)
end

--: (unknown, unknown) -> unknown
local function join(a, b)
    if as_val(a) and as_val(b) then return join_val(a, b) end
    return bottom()
end

--: (unknown, unknown) -> boolean
local function equal(a, b)
    if as_val(a) and as_val(b) then return equal_val(a, b) end
    return false
end

M.lattice = { bottom = bottom, join = join, equal = equal } --: Lattice

-- ── Constructors ───────────────────────────────────────────────────────────

-- Mutable-ref literal WIDENING: a field ref created from a lone `true` /
-- `false` literal holds the base boolean pair (r = w = boolean) — the
-- TS-style widening at mutable positions. Without it the ubiquitous flag
-- idiom ({ enabled = false } … t.enabled = true) is a false-positive
-- machine: the ref's invariant bound would pin the literal. FLOW values
-- (locals, results, narrowing) keep literal precision, and ANNOTATED refs
-- keep exactly what the author wrote (record_rw is not widened).
--: (Val) -> Val
local function widen_ref(v)
    local ht = v.atoms["true"] == true
    local hf = v.atoms["false"] == true
    if ht == hf then return v end
    local a = copy_atoms(v.atoms)
    add_atom(a, "boolean")
    local rec = v.rec
    return { atoms = a, rec = rec ~= nil and rec_copy(rec) or nil, fn = v.fn }
end

-- A fresh open record from field initializers: each field's read type AND
-- write bound start at its initializer's type (the ref's fixed content
-- type; boolean literals widen — see widen_ref). `elem`, when given, is the
-- constructor's ARRAY-part element type (the join of its positional
-- values): the record is then index-bounded with num = the element ref and
-- str = never (a fresh array constructor genuinely has no other dynamic
-- keys; string writes later go through the new-index concession).
--: (fieldvals: { [string]: Val }, elem: Val | nil) -> Val
function M.record_of(fieldvals, elem)
    local fields = {} --: { [string]: Field }
    for name, v in pairs(fieldvals) do
        local w = widen_ref(v)
        fields[name] = { r = w, w = w }
    end
    local idx = nil --: Idx | nil
    if elem ~= nil then
        local ew = widen_ref(elem)
        idx = { str = NEVER_FIELD, num = { r = ew, w = ew } }
    end
    local a = {} --: { [string]: boolean }
    return { atoms = a, rec = { fields = fields, idx = idx }, fn = nil }
end

-- An Idx from per-kind Fields; nil = "no keys of that kind" (the never
-- part — how `{ [string]: T }` claims number keys absent).
--: (str: Field | nil, num: Field | nil) -> Idx
function M.idx_of(str, num)
    local s = NEVER_FIELD --: Field
    local n = NEVER_FIELD --: Field
    if str ~= nil then s = str end
    if num ~= nil then n = num end
    return { str = s, num = n }
end

-- A record from explicit r/w fields — the annotation constructor (readonly
-- fields carry w = never; optional fields carry T | nil on both faces).
-- `idx` is the annotation's index-signature component, if any.
--: (fields: { [string]: Field }, idx: Idx | nil) -> Val
function M.record_rw(fields, idx)
    local copy = {} --: { [string]: Field }
    for name, f in pairs(fields) do copy[name] = f end
    local a = {} --: { [string]: boolean }
    return { atoms = a, rec = { fields = copy, idx = idx }, fn = nil }
end

-- A function value. `params` is the definition's (or annotation's) param
-- cell/pin list — treated as the function's IDENTITY (see header). `insts`
-- marks result positions whose type is INSTANTIATED per call site from an
-- argument (the declaration intrinsics $Elem/$Values/$Keys/$Arg); the
-- static Val at such a position is `unknown` (the fallback when the
-- argument is missing or the arrow is compared structurally).
--: (params: { [integer]: Param }, results: { [integer]: Val }, vararg: boolean, rest: Val | nil, open: boolean, insts: { [integer]: Inst } | nil) -> Val
function M.fn_val(params, results, vararg, rest, open, insts)
    local a = {} --: { [string]: boolean }
    return {
        atoms = a, rec = nil,
        fn = { params = params, results = results, vararg = vararg, rest = rest, open = open, insts = insts },
    }
end

-- Depth clip: replace structure deeper than `depth` with `unknown` (an UPPER
-- approximation — clip(v) ⊒ v — so proposals through it stay monotone).
-- Bottom stays bottom. Param pins are annotation-bounded and not clipped.
-- Applied by lowering at the two cycle-closing proposal sites (function
-- rebuild, call-argument flow) to bound recursion-created ascending chains.
--: (Val, integer) -> Val
local function clip(v, depth)
    if has_unknown(v) then return single("unknown") end
    local rec = v.rec
    local fn = v.fn
    if rec == nil and fn == nil then
        return { atoms = copy_atoms(v.atoms), rec = nil, fn = nil }
    end
    if depth <= 0 then return single("unknown") end
    local rec2 = nil --: Rec | nil
    if rec ~= nil then
        local fields = {} --: { [string]: Field }
        for name, f in pairs(rec.fields) do
            fields[name] = { r = clip(f.r, depth - 1), w = clip(f.w, depth - 1) }
        end
        local idx = rec.idx
        local idx2 = nil --: Idx | nil
        if idx ~= nil then
            idx2 = {
                str = { r = clip(idx.str.r, depth - 1), w = clip(idx.str.w, depth - 1) },
                num = { r = clip(idx.num.r, depth - 1), w = clip(idx.num.w, depth - 1) },
            }
        end
        rec2 = { fields = fields, idx = idx2 }
    end
    local fn2 = nil --: Fn | nil
    if fn ~= nil then
        local results = {} --: { [integer]: Val }
        for i = 1, #fn.results do results[i] = clip(fn.results[i], depth - 1) end
        fn2 = {
            params = fn.params, results = results, vararg = fn.vararg,
            rest = fn.rest, open = fn.open, insts = fn.insts,
        }
    end
    return { atoms = copy_atoms(v.atoms), rec = rec2, fn = fn2 }
end
M.clip = clip

-- ── Ordering (obligation checking: is `a` allowed where `b` is required?) ──

-- a ⊑ b: every value of `a` inhabits `b`. Atoms by subset (`unknown` only
-- below `unknown`); a record component is admitted by `unknown`, by the
-- `table` top, or by a WIDER record (every field b demands, a has, with
-- r covariant and w contravariant — the r/w split is what makes mutable
-- fields sound, see the header). A function component is admitted by
-- `unknown`, by the `function` top, or by fn_leq (params contravariant,
-- results covariant — the standard sound arrow rule).
local leq, fn_leq

--: (Val, Val) -> boolean
leq = function(a, b)
    -- identity fast path (leq is reflexive); shared immutable structure —
    -- the alias-DAG case — stays O(shared nodes), not O(tree paths).
    if a == b then return true end
    if has_unknown(a) then return has_unknown(b) end
    if has_unknown(b) then return true end
    for k, present in pairs(a.atoms) do
        if present and not b.atoms[k] then return false end
    end
    local ra = a.rec
    if ra ~= nil and not b.atoms["table"] then
        local rb = b.rec
        if rb == nil then return false end
        for name, fb in pairs(rb.fields) do
            local fa = ra.fields[name]
            if fa == nil then return false end
            if not leq(fa.r, fb.r) then return false end
            if not leq(fb.w, fa.w) then return false end
        end
        local bi = rb.idx
        if bi ~= nil then
            -- b is index-bounded: a's dynamic keys must be too (a PLAIN open
            -- record's unnamed keys are unbounded — the sound rejection;
            -- fresh constructors go through leq_init instead), pointwise
            -- r-covariant / w-contravariant per kind...
            local ai = ra.idx
            if ai == nil then return false end
            if not leq(ai.str.r, bi.str.r) then return false end
            if not leq(bi.str.w, ai.str.w) then return false end
            if not leq(ai.num.r, bi.num.r) then return false end
            if not leq(bi.num.w, ai.num.w) then return false end
            -- ...and every named field of a that b does NOT name is reached
            -- through b only via b's string part (width-into-index).
            for name, fa in pairs(ra.fields) do
                if rb.fields[name] == nil then
                    if not leq(fa.r, bi.str.r) then return false end
                    if not leq(bi.str.w, fa.w) then return false end
                end
            end
        end
    end
    local fa = a.fn
    if fa ~= nil and not b.atoms["function"] then
        local fb = b.fn
        if fb == nil then return false end
        if not fn_leq(fa, fb) then return false end
    end
    return true
end
M.leq = leq

-- fa usable where fb is expected.
--
-- RESULTS (covariant): callers through fb read fb's result positions; fa
-- must deliver a subtype at each — a position fa lacks delivers `nil`
-- (unless fa is result-open, in which case it is unverifiable: reject).
--
-- PARAMS (contravariant): callers through fb pass values bounded by fb's
-- pins; every requirement fa states (a pin) must ADMIT what fb lets
-- through: `pin_b ⊑ pin_a`. A position fb never passes (beyond its arity,
-- not vararg) reaches fa as `nil`. An fb position with NO pin makes no
-- promise, so a pinned fa param there is unverifiable: reject. Unpinned fa
-- params state no checkable requirement here; the call-site flow (arguments
-- proposed into fa's param cells, checked by the body's own obligations)
-- is what covers them — a v0 concession for fn-in-record-field comparisons,
-- stated, not hidden.
--: (Fn, Fn) -> boolean
fn_leq = function(fa, fb)
    for i = 1, #fb.results do
        local ra = fa.results[i]
        if ra == nil then
            if fa.open then return false end
            ra = single("nil")
        end
        if not leq(ra, fb.results[i]) then return false end
    end
    for i = 1, #fa.params do
        local pa = fa.params[i].pin
        if pa ~= nil then
            local pb = nil --: Val | nil
            local bp = fb.params[i]
            if bp ~= nil then
                pb = bp.pin
            elseif fb.vararg then
                pb = fb.rest
            else
                pb = single("nil")
            end
            if pb == nil then return false end
            if not leq(pb, pa) then return false end
        end
    end
    -- fa's rest bound must admit whatever fb's rest lets through.
    local resta = fa.rest
    local restb = fb.rest
    if fa.vararg and resta ~= nil and fb.vararg then
        if restb == nil then return false end
        if not leq(restb, resta) then return false end
    end
    return true
end

-- Initialization ordering: like leq, but record FIELDS compare covariantly
-- on the read face only, and a field the constructor does not mention IS
-- nil (a fresh table genuinely has nil there — the optional-field idiom
-- `z?: T` is satisfied by absence). Sound ONLY for a syntactically FRESH
-- constructor ascribed at its construction site — the constructor's field
-- refs have no other alias yet, so the ascription re-types them. RECURSIVE
-- through record positions: a constructor nested in a fresh constructor
-- (`{ headers = {} }` ascribed a type whose headers is `{ [string]: T }`)
-- is fresh too. A nested field VALUE that was a non-fresh local rides the
-- same aliasing-concession class as new-field-on-write (stated).
--: (Val, Val) -> boolean
local function leq_init(a, b)
    if has_unknown(a) then return has_unknown(b) end
    if has_unknown(b) then return true end
    local ra = a.rec
    local rb = b.rec
    if ra ~= nil and rb ~= nil then
        for name, fb in pairs(rb.fields) do
            local fa = ra.fields[name]
            if fa == nil then
                if not leq(single("nil"), fb.r) then return false end
            elseif not leq_init(fa.r, fb.r) then
                return false
            end
        end
        local bi = rb.idx
        if bi ~= nil then
            -- initialization into an index-signature type: the FRESH
            -- constructor's refs are re-typed by the ascription, so only
            -- the read faces must fit — its named fields (width-into-index)
            -- and its own index parts (an array part into `[number]: T`);
            -- keys it does not mention genuinely do not exist.
            local ai = ra.idx
            if ai ~= nil then
                if not leq_init(ai.str.r, bi.str.r) then return false end
                if not leq_init(ai.num.r, bi.num.r) then return false end
            end
            for name, fa in pairs(ra.fields) do
                if rb.fields[name] == nil then
                    if not leq_init(fa.r, bi.str.r) then return false end
                end
            end
        end
        -- atoms + fn still compare as usual, minus the record component.
        local a2 = { atoms = a.atoms, rec = nil, fn = a.fn } --: Val
        local b2 = { atoms = b.atoms, rec = nil, fn = b.fn } --: Val
        return leq(a2, b2)
    end
    return leq(a, b)
end
M.leq_init = leq_init

-- ── The two flow operations (narrowing AND and/or derive from these) ───────

-- The part of `v` that survives a TRUTHY test: drop `nil` and the `false`
-- literal (the boolean split makes this exact); records/tables are always
-- truthy and stay. `unknown` stays unknown (top is opaque).
--: (unknown) -> unknown
function M.truthy(v)
    if not as_val(v) then return bottom() end
    if has_unknown(v) then return single("unknown") end
    local r = {} --: { [string]: boolean }
    for k, present in pairs(v.atoms) do
        if present and k ~= "nil" and k ~= "false" then r[k] = true end
    end
    local rec = v.rec
    return { atoms = r, rec = rec ~= nil and rec_copy(rec) or nil, fn = v.fn }
end

-- The part of `v` that survives a FALSY test: only `nil` and the `false`
-- literal are falsy in Lua (numbers/strings/tables/functions — and `true` —
-- are always truthy; 0 and "" are truthy; every table is truthy, so records
-- drop, and so does a function component).
--: (unknown) -> unknown
function M.falsy(v)
    if not as_val(v) then return bottom() end
    if has_unknown(v) then return single("unknown") end
    local r = {} --: { [string]: boolean }
    for k, present in pairs(v.atoms) do
        if present and (k == "nil" or k == "false") then r[k] = true end
    end
    return { atoms = r, rec = nil, fn = nil }
end

-- ── type()-tag flow operations (the `type(x) == "…"` guard filters) ────────

-- Lua's type() tags mapped to v9 atom SETS (the boolean tag covers the
-- true/false literal pair; every other tag covers one atom). Tags with no
-- v0 atoms (userdata / thread / cdata) are still VALID guards: their values
-- only ever appear inside `unknown` in v0, so keep-from-known is bottom
-- (dead branch) and drop-from-known is the identity — both sound.
local TAG_ATOMS = {
    ["nil"] = { "nil" }, boolean = { "true", "false" }, number = { "number" },
    string = { "string" }, table = { "table" }, ["function"] = { "function" },
} --: { [string]: { [integer]: string } }

--: (string) -> boolean
function M.is_type_tag(name)
    return TAG_ATOMS[name] ~= nil or name == "userdata" or name == "thread"
        or name == "cdata"
end

--: ({ [integer]: string }) -> { [string]: boolean }
local function atom_set(list)
    local s = {} --: { [string]: boolean }
    for i = 1, #list do s[list[i]] = true end
    return s
end

-- The part of `v` whose type() IS `tag`. Monotone: as v climbs (atoms grow,
-- up to unknown) the kept part climbs (bounded by the tag's atoms; from
-- `unknown` it is exactly those atoms — the narrowing that makes the guard
-- useful — or unknown for atom-less tags).
--: (unknown, string) -> unknown
function M.tag_keep(v, tag)
    if not as_val(v) then return bottom() end
    local list = TAG_ATOMS[tag] --: { [integer]: string } | nil
    if has_unknown(v) then
        if list ~= nil then return M.of(list) end
        return single("unknown")
    end
    if list == nil then return bottom() end
    local keep = atom_set(list)
    local r = {} --: { [string]: boolean }
    for k, present in pairs(v.atoms) do
        if present and keep[k] then r[k] = true end
    end
    local rec = nil --: Rec | nil
    local fn = nil --: Fn | nil
    if keep["table"] then
        local vr = v.rec
        if vr ~= nil then rec = rec_copy(vr) end
    end
    if keep["function"] then fn = v.fn end
    return { atoms = r, rec = rec, fn = fn }
end

-- The part of `v` whose type() is NOT `tag`. Monotone (atoms grow up to
-- unknown; `unknown` stays unknown — v0 cannot subtract from the top, an
-- upper approximation, stated).
--: (unknown, string) -> unknown
function M.tag_drop(v, tag)
    if not as_val(v) then return bottom() end
    if has_unknown(v) then return single("unknown") end
    local list = TAG_ATOMS[tag] --: { [integer]: string } | nil
    local drop = {} --: { [string]: boolean }
    if list ~= nil then drop = atom_set(list) end
    local r = {} --: { [string]: boolean }
    for k, present in pairs(v.atoms) do
        if present and not drop[k] then r[k] = true end
    end
    local rec = nil --: Rec | nil
    if not drop["table"] then
        local vr = v.rec
        if vr ~= nil then rec = rec_copy(vr) end
    end
    local fn = nil --: Fn | nil
    if not drop["function"] then fn = v.fn end
    return { atoms = r, rec = rec, fn = fn }
end

-- ── Record transfers (field read / field write) ────────────────────────────

-- Field READ: the type of `v.name`. Monotone: as `v` climbs (atoms grow;
-- record fields drop at joins; the record collapses into the `table` top),
-- the projection climbs toward unknown — absent-on-open-record and
-- fields-unknown both project to `unknown` (the field may exist at any
-- type), never below a previously returned value. Non-table atoms
-- contribute nothing here; the field-read OBLIGATION reports them.
--: (unknown, string) -> unknown
function M.project(v, name)
    if not as_val(v) then return bottom() end
    if has_unknown(v) then return single("unknown") end
    if v.atoms["table"] then return single("unknown") end
    local rec = v.rec
    if rec ~= nil then
        local f = rec.fields[name]
        if f ~= nil then
            return f.r
        end
        local idx = rec.idx
        if idx ~= nil then
            -- index-bounded: an unnamed string key reads the str part | nil
            -- (nil when the part is never — the key is claimed absent).
            return join_val(idx.str.r, single("nil"))
        end
        return single("unknown")
    end
    return bottom()
end

-- Field WRITE: the record value AFTER `v.name = fv`. Field types are
-- INVARIANT refs: writing an EXISTING field never changes its type (the
-- write itself is checked against the field's `w` bound by a post-solve
-- obligation); writing a NEW field extends the open record with
-- r = w = fv (the named `new-field-on-write` concession — see header;
-- boolean literals widen at the fresh ref, see widen_ref).
-- Monotone: existing-field writes are the identity on the record; the new
-- field's r grows with fv, and its w descends through the target cell's
-- join (Field w-parts meet), which under-approximates soundly.
--: (unknown, string, unknown) -> unknown
function M.set_field(v, name, fv)
    if not as_val(v) or not as_val(fv) then return bottom() end
    if has_unknown(v) then return single("unknown") end
    local rec = v.rec
    if rec == nil then
        -- atoms-only target (number, table-top, …): the write cannot be
        -- tracked; the field-write obligation reports it.
        return { atoms = copy_atoms(v.atoms), rec = nil, fn = v.fn }
    end
    local out = rec_copy(rec)
    if out.fields[name] == nil then
        local w = widen_ref(fv)
        out.fields[name] = { r = w, w = w }
    end
    return { atoms = copy_atoms(v.atoms), rec = out, fn = v.fn }
end

-- ── Index transfers (dynamic-key read / write) ─────────────────────────────

-- The index KINDS a key value can take: which index parts a dynamic
-- read/write with this key consults. `other` = key kinds outside the v0
-- index discipline (booleans, tables, functions — Lua admits any non-nil
-- key; idx never tracks them, which is what keeps it sound without
-- modeling them). A `nil` atom in the key contributes no kind (reading
-- t[nil] is nil in Lua).
--: (unknown) -> KeyKinds
function M.key_kinds(kv)
    if not as_val(kv) then
        return { str = false, num = false, other = false, unknown = false }
    end
    if has_unknown(kv) then
        return { str = false, num = false, other = false, unknown = true }
    end
    local str = kv.atoms["string"] == true
    local num = kv.atoms["number"] == true
    local other = kv.rec ~= nil or kv.fn ~= nil
    for k, present in pairs(kv.atoms) do
        if present and k ~= "string" and k ~= "number" and k ~= "nil" then
            other = true
        end
    end
    return { str = str, num = num, other = other, unknown = false }
end

-- Dynamic-key READ: the type of `t[k]`. The result is `T | nil`
-- NON-NEGOTIABLY (an absent key IS nil in Lua — the spot where TS's index
-- signatures are unsound by default and v9 is not): the consulted parts
-- (str/num per the key's kinds; every NAMED field joins in when the key
-- can be a string — named fields are string keys) join with nil. Untracked
-- cases project `unknown` (plain open record, table top, unknown/other
-- keys) — monotone: a record only ever LOSES its idx as its cell climbs
-- (join with an unbounded side), and unknown absorbs; the read obligation
-- reports the boundary (check.lua).
--: (unknown, unknown) -> unknown
function M.project_index(v, kv)
    if not as_val(v) or not as_val(kv) then return bottom() end
    if has_unknown(v) then return single("unknown") end
    if v.atoms["table"] then return single("unknown") end
    local rec = v.rec
    if rec == nil then return bottom() end
    if val_is_bottom(kv) then return bottom() end
    local kk = M.key_kinds(kv)
    if kk.unknown or kk.other then return single("unknown") end
    local idx = rec.idx
    if idx == nil then return single("unknown") end
    local out = single("nil") --: Val
    if kk.str then
        out = join_val(out, idx.str.r)
        for _, f in pairs(rec.fields) do out = join_val(out, f.r) end
    end
    if kk.num then out = join_val(out, idx.num.r) end
    return out
end

-- Dynamic-key WRITE: the record value AFTER `t[k] = v`. Index parts are
-- INVARIANT refs like named fields: writing through an EXISTING part never
-- changes it (the write is checked against the part's `w` bound by the
-- index-write obligation); a part-less record — or a never part — GROWS the
-- touched kind(s) with r = w = widen(fv): the `local t = {}; t[k] = v`
-- build idiom, admitted under the same named concession as fields
-- (`new-index-on-write`, resolved post-solve). Writing nil DELETES the key
-- in Lua — the nil part of the written value never enters the ref (a pure
-- nil write grows nothing; reads already carry the `| nil` of absence).
-- An unknown key touches both kinds (it may be either; other key kinds it
-- may also be stay untracked — sound, reads of them never consult idx).
-- Proposals ride the engine's join, as set_field's do.
--: (unknown, unknown, unknown) -> unknown
function M.set_index(v, kv, fv)
    if not as_val(v) or not as_val(kv) or not as_val(fv) then return bottom() end
    if has_unknown(v) then return single("unknown") end
    local rec = v.rec
    if rec == nil then
        -- atoms-only target: untrackable; the index-write obligation reports.
        return { atoms = copy_atoms(v.atoms), rec = nil, fn = v.fn }
    end
    local kk = M.key_kinds(kv)
    local str = kk.str or kk.unknown
    local num = kk.num or kk.unknown
    if not str and not num then
        return { atoms = copy_atoms(v.atoms), rec = rec_copy(rec), fn = v.fn }
    end
    local dropped = M.tag_drop(fv, "nil")
    local fv2 = fv --: Val
    if as_val(dropped) then fv2 = dropped end
    if val_is_bottom(fv2) then
        -- a pure deletion: the record's key claims are unchanged.
        return { atoms = copy_atoms(v.atoms), rec = rec_copy(rec), fn = v.fn }
    end
    local w = widen_ref(fv2)
    local grown = { r = w, w = w } --: Field
    local out = rec_copy(rec)
    local idx = out.idx
    if idx == nil then
        local s = NEVER_FIELD --: Field
        local n = NEVER_FIELD --: Field
        if str then s = grown end
        if num then n = grown end
        out.idx = { str = s, num = n }
    else
        local s = idx.str
        local n = idx.num
        if str and field_is_never(s) then s = grown end
        if num and field_is_never(n) then n = grown end
        out.idx = { str = s, num = n }
    end
    return { atoms = copy_atoms(v.atoms), rec = out, fn = v.fn }
end

-- ── Iteration projections ($Elem / $Values / $Keys — see the header) ───────

-- $Elem<N>: the ipairs ELEMENT type — the num part's read type, nil-DROPPED
-- (ipairs visits t[1..k] up to the FIRST nil, so a visited element is never
-- nil; Lua semantics — this is what makes the loop var `T`, not `T | nil`).
--: (unknown) -> unknown
function M.elem_iter(v)
    if not as_val(v) then return bottom() end
    if has_unknown(v) then return single("unknown") end
    if v.atoms["table"] then return single("unknown") end
    local rec = v.rec
    if rec == nil then return bottom() end
    local idx = rec.idx
    if idx == nil then return single("unknown") end
    return M.tag_drop(idx.num.r, "nil")
end

-- $Values<N>: the pairs VALUE type — every named field + both index parts,
-- nil-dropped (a nil-valued key does not exist in a Lua table: writing nil
-- deletes, so pairs never yields a nil value). Plain open records read as
-- unknown — their unnamed keys are unbounded.
--: (unknown) -> unknown
function M.values_iter(v)
    if not as_val(v) then return bottom() end
    if has_unknown(v) then return single("unknown") end
    if v.atoms["table"] then return single("unknown") end
    local rec = v.rec
    if rec == nil then return bottom() end
    local idx = rec.idx
    if idx == nil then return single("unknown") end
    local out = join_val(idx.str.r, idx.num.r)
    for _, f in pairs(rec.fields) do out = join_val(out, f.r) end
    return M.tag_drop(out, "nil")
end

-- $Keys<N>: the pairs KEY type | nil (the iterator protocol's end marker
-- rides in the result position; for-in nil-drops it for the loop var).
--: (unknown) -> unknown
function M.keys_iter(v)
    if not as_val(v) then return bottom() end
    if has_unknown(v) then return single("unknown") end
    if v.atoms["table"] then return single("unknown") end
    local rec = v.rec
    if rec == nil then return bottom() end
    local idx = rec.idx
    if idx == nil then return single("unknown") end
    local out = single("nil") --: Val
    local named = false
    for _ in pairs(rec.fields) do
        named = true
        break
    end
    if named or not val_is_bottom(idx.str.r) then
        out = join_val(out, single("string"))
    end
    if not val_is_bottom(idx.num.r) then
        out = join_val(out, single("number"))
    end
    return out
end

-- ── Queries (obligation checking reads these) ──────────────────────────────

--: (Val) -> boolean
function M.is_unknown(v) return has_unknown(v) end

--: (Val) -> boolean
function M.is_bottom(v) return val_is_bottom(v) end

--: (Val) -> boolean
function M.has_rec(v) return v.rec ~= nil end

-- Is the value's record INDEX-BOUNDED (carries an idx component)?
--: (Val) -> boolean
function M.has_index(v)
    local rec = v.rec
    return rec ~= nil and rec.idx ~= nil
end

-- Does the record admit UNNAMED string keys (a non-never str part)? Used to
-- suppress missing-field on named reads an index signature covers.
--: (Val) -> boolean
function M.has_str_index(v)
    local rec = v.rec
    if rec == nil then return false end
    local idx = rec.idx
    if idx == nil then return false end
    return not val_is_bottom(idx.str.r)
end

-- The write bound of an index part ("str" | "num"); nil when the value has
-- no record or no idx component. A bottom bound = a never part (no keys of
-- that kind yet — the grow-on-write case).
--: (Val, string) -> Val | nil
function M.index_write_bound(v, kind)
    local rec = v.rec
    if rec == nil then return nil end
    local idx = rec.idx
    if idx == nil then return nil end
    if kind == "num" then return idx.num.w end
    return idx.str.w
end

--: (Val) -> Fn | nil
function M.fn_of(v) return v.fn end

--: (Val) -> boolean
function M.has_table_top(v) return v.atoms["table"] == true end

--: (Val, string) -> boolean
function M.has_field(v, name)
    local rec = v.rec
    return rec ~= nil and rec.fields[name] ~= nil
end

-- The write bound of a field (nil when the value has no record component or
-- the record lacks the field).
--: (Val, string) -> Val | nil
function M.field_write_bound(v, name)
    local rec = v.rec
    if rec == nil then return nil end
    local f = rec.fields[name]
    if f == nil then return nil end
    return f.w
end

-- Does the value admit the `string` atom? String-typed values resolve
-- member access through the DECLARED `string` library table (LuaJIT sets
-- the string metatable's `__index` to the string library) — lowering joins
-- that projection in, and the field-read obligation consults the declared
-- table. Declaration-driven: the method types come from the `string`
-- declaration (globals seam / per-file `--:: declare`), never a hardcoded
-- list here.
--: (Val) -> boolean
function M.has_string(v) return v.atoms["string"] == true end

-- True when `v`'s only content is the `string` atom — the pure
-- string-metatable receiver case (s:sub(...)).
--: (Val) -> boolean
function M.is_string_only(v)
    if v.rec ~= nil or v.fn ~= nil then return false end
    local seen = false
    for k, present in pairs(v.atoms) do
        if present then
            if k ~= "string" then return false end
            seen = true
        end
    end
    return seen
end

local show_val

--: (Fn) -> string
local function fn_show(fn)
    local ps = {} --: { [integer]: string }
    for i = 1, #fn.params do
        local pin = fn.params[i].pin
        if pin ~= nil then ps[#ps + 1] = show_val(pin) else ps[#ps + 1] = "?" end
    end
    if fn.vararg then
        local rest = fn.rest
        if rest ~= nil then
            ps[#ps + 1] = "..." .. show_val(rest)
        else
            ps[#ps + 1] = "..."
        end
    end
    local rs = {} --: { [integer]: string }
    for i = 1, #fn.results do rs[#rs + 1] = show_val(fn.results[i]) end
    if fn.open then rs[#rs + 1] = "..." end
    local r = "()" --: string
    if #rs == 1 then
        r = rs[1]
    elseif #rs > 1 then
        r = "(" .. table.concat(rs, ", ") .. ")"
    end
    return "(" .. table.concat(ps, ", ") .. ") -> " .. r
end

--: (Rec) -> string
local function rec_show(rec)
    local names = {} --: { [integer]: string }
    for name in pairs(rec.fields) do names[#names + 1] = name end
    table.sort(names)
    local parts = {} --: { [integer]: string }
    for i = 1, #names do
        local f = rec.fields[names[i]]
        parts[#parts + 1] = names[i] .. ": " .. show_val(f.r)
    end
    local idx = rec.idx
    if idx ~= nil then
        -- never parts render nothing ("no keys of that kind" is the
        -- record's silence); an all-never idx still renders one marker so
        -- an index-bounded empty record is distinguishable from {}.
        local shown = false
        if not field_is_never(idx.num) then
            parts[#parts + 1] = "[number]: " .. show_val(idx.num.r)
            shown = true
        end
        if not field_is_never(idx.str) then
            parts[#parts + 1] = "[string]: " .. show_val(idx.str.r)
            shown = true
        end
        if not shown then parts[#parts + 1] = "[]: never" end
    end
    if #parts == 0 then return "{}" end
    return "{ " .. table.concat(parts, ", ") .. " }"
end

-- Display collapse: the true/false literal pair renders as "boolean".
--: ({ [integer]: string }) -> { [integer]: string }
local function collapse_boolean(names)
    local has_t = false
    local has_f = false
    for i = 1, #names do
        if names[i] == "true" then has_t = true end
        if names[i] == "false" then has_f = true end
    end
    if not (has_t and has_f) then return names end
    local out = {} --: { [integer]: string }
    for i = 1, #names do
        local n = names[i]
        if n ~= "true" and n ~= "false" then out[#out + 1] = n end
    end
    out[#out + 1] = "boolean"
    return out
end

--: (Val) -> string
show_val = function(v)
    local atoms = {} --: { [integer]: string }
    for k, present in pairs(v.atoms) do if present then atoms[#atoms + 1] = k end end
    atoms = collapse_boolean(atoms)
    table.sort(atoms)
    local rec = v.rec
    if rec ~= nil then atoms[#atoms + 1] = rec_show(rec) end
    local fn = v.fn
    if fn ~= nil then atoms[#atoms + 1] = fn_show(fn) end
    if #atoms == 0 then return "never" end
    return table.concat(atoms, " | ")
end

-- Atoms/components of `v` NOT admitted by `allow` — nil when v ⊑ allow on
-- the atom level, else a rendered list (stable order). A record component is
-- admitted when `allow` has the `table` atom (records are tables) or its own
-- record component; a function component when `allow` has the `function`
-- atom or its own function component. `unknown` in `v` is the caller's
-- use-before-narrow case and is reported separately, never here.
--: (v: Val, allow: Val) -> string | nil
function M.excess(v, allow)
    local bad = {} --: { [integer]: string }
    for k, present in pairs(v.atoms) do
        if present and k ~= "unknown" and not allow.atoms[k] then bad[#bad + 1] = k end
    end
    bad = collapse_boolean(bad)
    table.sort(bad)
    local rec = v.rec
    if rec ~= nil and not allow.atoms["table"] and allow.rec == nil then
        bad[#bad + 1] = rec_show(rec)
    end
    local fn = v.fn
    if fn ~= nil and not allow.atoms["function"] and allow.fn == nil then
        bad[#bad + 1] = fn_show(fn)
    end
    if #bad == 0 then return nil end
    return table.concat(bad, " | ")
end

-- Render as a sorted union string, e.g. "nil | number" or
-- "nil | { x: number }"; bottom -> "never".
--: (unknown) -> string
function M.show(v)
    if not as_val(v) then return "never" end
    return show_val(v)
end

return M
