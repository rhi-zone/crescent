-- lib/type/v9/lattice.lua
-- The v0 TYPE LATTICE for checking real Lua: atoms over the Lua base types
-- (nil / boolean / number / string + the distinct table and function TOPS),
-- STRUCTURAL OPEN RECORDS, finite unions (a value carries an atom SET plus
-- at most one record component), and `unknown` as the absorbing top.
-- Deliberately BTy-lite: arrows / negation / literal types are later
-- DOMAIN-LOCAL upgrades behind this same interface — the engine never sees
-- any of this vocabulary.
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
-- ── Flow operations ─────────────────────────────────────────────────────────
--
-- Everything flow-sensitive derives from the same two lattice operations:
--
--   truthy(T) = drop `nil` (records/tables are always truthy; they stay)
--   falsy(T)  = keep only `nil` and `boolean` (records are never falsy)
--
-- `if`-narrowing uses them directly, and `and`/`or` are DERIVED, not
-- hardcoded:  a and b : falsy(a) | type(b)     a or b : truthy(a) | type(b).
-- Field READS are one more monotone unary transfer, `project(v, name)`;
-- field WRITES are the binary `set_field(v, name, fv)`. Both are legal
-- engine transfers (monotone; proofs sketched at their definitions).
--
-- Soundness: join is set union on atoms + pointwise-on-common-fields on
-- records, with `unknown` absorbing (unknown is a real top, not `any`).
-- Termination: atom sets are finite; record depth is bounded by program
-- syntax (constructors nest syntactically; project/join never deepen a
-- value; v0's rule graphs are acyclic — loops are havoc-fenced). A future
-- loop-checked increment needs a depth widening HERE, not an engine change.

--:: require "lib.type.v9.engine.defs"

local M = {}

-- A type value: a set of atom names + at most one open-record component.
-- {} atoms + nil rec = bottom (no info / never); { unknown = true } = top.
--:: Val = { atoms: { [string]: boolean }, rec: Rec | nil }
--:: Rec = { fields: { [string]: Field } }
--:: Field = { r: Val, w: Val }

M.ATOMS = { "nil", "boolean", "number", "string", "table", "function", "unknown" }

--: (x: unknown) -> x is Val
local function as_val(x) return type(x) == "table" end
M.as_val = as_val
-- Back-compat name used by callers narrowing engine cell values.
M.as_atoms = as_val

--: (string) -> Val
local function single(atom)
    local a = {} --: { [string]: boolean }
    a[atom] = true
    return { atoms = a, rec = nil }
end
M.single = single

--: ({ [integer]: string }) -> Val
function M.of(names)
    local a = {} --: { [string]: boolean }
    for i = 1, #names do a[names[i]] = true end
    return { atoms = a, rec = nil }
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
-- tables; Field tables are shared, never mutated), so a "copy" is a
-- fresh fields map sharing the Field entries.
--: (Rec) -> Rec
local function rec_copy(rec)
    local fields = {} --: { [string]: Field }
    for name, f in pairs(rec.fields) do fields[name] = f end
    return { fields = fields }
end

-- ── Lattice (opaque-facing: this is what the engine consumes) ──────────────

--: () -> unknown
local function bottom()
    local a = {} --: { [string]: boolean }
    return { atoms = a, rec = nil }
end

-- Forward declarations: join/meet/equal recurse through record fields.
local join_val, meet_val, equal_val

-- Pointwise join on COMMON fields (width: a merged view only guarantees the
-- fields BOTH sides have). r joins UP (either branch may be read), w joins
-- DOWN via meet (a write must be safe for both branches).
--: (Rec, Rec) -> Rec
local function rec_join(a, b)
    local fields = {} --: { [string]: Field }
    for name, fa in pairs(a.fields) do
        local fb = b.fields[name]
        if fb ~= nil then
            if fa == fb then
                fields[name] = fa
            else
                fields[name] = { r = join_val(fa.r, fb.r), w = meet_val(fa.w, fb.w) }
            end
        end
    end
    return { fields = fields }
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
    return true
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
    -- normalize: the `table` TOP subsumes any record component.
    if atoms["table"] then rec = nil end
    return { atoms = atoms, rec = rec }
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
        return { atoms = copy_atoms(b.atoms), rec = rb0 ~= nil and rec_copy(rb0) or nil }
    end
    if has_unknown(b) then
        local ra0 = a.rec
        return { atoms = copy_atoms(a.atoms), rec = ra0 ~= nil and rec_copy(ra0) or nil }
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
    if atoms["table"] then rec = nil end
    return { atoms = atoms, rec = rec }
end
M.meet = meet_val

--: (Val, Val) -> boolean
equal_val = function(a, b)
    for k, present in pairs(a.atoms) do if present and not b.atoms[k] then return false end end
    for k, present in pairs(b.atoms) do if present and not a.atoms[k] then return false end end
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

-- A fresh open record from field initializers: each field's read type AND
-- write bound start at its initializer's type (the ref's fixed content type).
--: ({ [string]: Val }) -> Val
function M.record_of(fieldvals)
    local fields = {} --: { [string]: Field }
    for name, v in pairs(fieldvals) do
        fields[name] = { r = v, w = v }
    end
    local a = {} --: { [string]: boolean }
    return { atoms = a, rec = { fields = fields } }
end

-- ── Ordering (obligation checking: is `a` allowed where `b` is required?) ──

-- a ⊑ b: every value of `a` inhabits `b`. Atoms by subset (`unknown` only
-- below `unknown`); a record component is admitted by `unknown`, by the
-- `table` top, or by a WIDER record (every field b demands, a has, with
-- r covariant and w contravariant — the r/w split is what makes mutable
-- fields sound, see the header).
--: (Val, Val) -> boolean
local function leq(a, b)
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
    end
    return true
end
M.leq = leq

-- ── The two flow operations (narrowing AND and/or derive from these) ───────

-- The part of `v` that survives a TRUTHY test: drop `nil`. `boolean` stays
-- (v0 cannot split true from false); records/tables are always truthy and
-- stay. `unknown` stays unknown (top is opaque).
--: (unknown) -> unknown
function M.truthy(v)
    if not as_val(v) then return bottom() end
    if has_unknown(v) then return single("unknown") end
    local r = {} --: { [string]: boolean }
    for k, present in pairs(v.atoms) do
        if present and k ~= "nil" then r[k] = true end
    end
    local rec = v.rec
    return { atoms = r, rec = rec ~= nil and rec_copy(rec) or nil }
end

-- The part of `v` that survives a FALSY test: only `nil` and `boolean` atoms
-- contain falsy values (numbers/strings/tables/functions are always truthy
-- in Lua — 0 and "" are truthy; every table is truthy, so records drop).
--: (unknown) -> unknown
function M.falsy(v)
    if not as_val(v) then return bottom() end
    if has_unknown(v) then return single("unknown") end
    local r = {} --: { [string]: boolean }
    for k, present in pairs(v.atoms) do
        if present and (k == "nil" or k == "boolean") then r[k] = true end
    end
    return { atoms = r, rec = nil }
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
        return single("unknown")
    end
    return bottom()
end

-- Field WRITE: the record value AFTER `v.name = fv`. Field types are
-- INVARIANT refs: writing an EXISTING field never changes its type (the
-- write itself is checked against the field's `w` bound by a post-solve
-- obligation); writing a NEW field extends the open record with
-- r = w = fv (the named `new-field-on-write` concession — see header).
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
        return { atoms = copy_atoms(v.atoms), rec = nil }
    end
    local out = rec_copy(rec)
    if out.fields[name] == nil then
        out.fields[name] = { r = fv, w = fv }
    end
    return { atoms = copy_atoms(v.atoms), rec = out }
end

-- ── Queries (obligation checking reads these) ──────────────────────────────

--: (Val) -> boolean
function M.is_unknown(v) return has_unknown(v) end

--: (Val) -> boolean
function M.is_bottom(v)
    for _, present in pairs(v.atoms) do if present then return false end end
    return v.rec == nil
end

--: (Val) -> boolean
function M.has_rec(v) return v.rec ~= nil end

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

-- True when `v`'s only content is the `string` atom — the string-metatable
-- method/field case (s:sub(...)), which needs stdlib declarations, not a
-- record: reported as its own honest boundary bucket, never op-mismatch.
--: (Val) -> boolean
function M.is_string_only(v)
    if v.rec ~= nil then return false end
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
    if #parts == 0 then return "{}" end
    return "{ " .. table.concat(parts, ", ") .. " }"
end

--: (Val) -> string
show_val = function(v)
    local atoms = {} --: { [integer]: string }
    for k, present in pairs(v.atoms) do if present then atoms[#atoms + 1] = k end end
    table.sort(atoms)
    local rec = v.rec
    if rec ~= nil then atoms[#atoms + 1] = rec_show(rec) end
    if #atoms == 0 then return "never" end
    return table.concat(atoms, " | ")
end

-- Atoms/components of `v` NOT admitted by `allow` — nil when v ⊑ allow on
-- the atom level, else a rendered list (stable order). A record component is
-- admitted when `allow` has the `table` atom (records are tables) or its own
-- record component. `unknown` in `v` is the caller's use-before-narrow case
-- and is reported separately, never here.
--: (v: Val, allow: Val) -> string | nil
function M.excess(v, allow)
    local bad = {} --: { [integer]: string }
    for k, present in pairs(v.atoms) do
        if present and k ~= "unknown" and not allow.atoms[k] then bad[#bad + 1] = k end
    end
    table.sort(bad)
    local rec = v.rec
    if rec ~= nil and not allow.atoms["table"] and allow.rec == nil then
        bad[#bad + 1] = rec_show(rec)
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
