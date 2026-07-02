-- lib/type/v9/lattice.lua
-- The v0 TYPE LATTICE for checking real Lua: atoms over the Lua base types
-- (nil / boolean / number / string + the distinct table and function TOPS),
-- finite unions (a set with >1 atom IS a union), and `unknown` as the
-- absorbing top. Deliberately BTy-lite: the real set-theoretic lattice
-- (records, arrows, negation, literals) is a later DOMAIN-LOCAL upgrade
-- behind this same interface — the engine never sees any of this vocabulary.
--
-- Everything flow-sensitive derives from TWO lattice operations:
--
--   truthy(T) = the part of T that survives a truthy test  (drop `nil`;
--               `boolean` stays — v0 has no true/false literals to split)
--   falsy(T)  = the part of T that survives a falsy test   (keep only `nil`
--               and `boolean` — the only atoms containing falsy values)
--
-- `if`-narrowing uses them directly, and `and`/`or` are DERIVED, not
-- hardcoded:  a and b : falsy(a) | type(b)     a or b : truthy(a) | type(b)
-- (the historic `foo and bar -> boolean|nil` bug was a hardcoded special
-- case; here the result falls out of the same two operations narrowing uses).
--
-- Soundness: join is set union with `unknown` absorbing (unknown is a real
-- top, not `any` — values of type unknown must be narrowed before dynamic
-- use). truthy/falsy are monotone, so they are legal transfer functions for
-- the monotone-fixpoint engine.

--:: require "lib.type.v9.engine.defs"

local M = {}

-- A type as a set of atom names; >1 atom = a union; {} = bottom (no info /
-- never); { unknown = true } = top.
--:: AtomSet = { [string]: boolean }

M.ATOMS = { "nil", "boolean", "number", "string", "table", "function", "unknown" }

--: (x: unknown) -> x is AtomSet
local function as_atoms(x) return type(x) == "table" end
M.as_atoms = as_atoms

--: (string) -> AtomSet
local function single(atom)
    local a = {} --: AtomSet
    a[atom] = true
    return a
end
M.single = single

--: (AtomSet, string) -> boolean
local function has(v, atom) return v[atom] == true end

--: (AtomSet) -> boolean
local function has_unknown(v) return has(v, "unknown") end

-- ── Lattice (opaque-facing: this is what the engine consumes) ──────────────

--: () -> unknown
local function bottom()
    local e = {} --: AtomSet
    return e
end

--: (unknown, unknown) -> unknown
local function join(a, b)
    if as_atoms(a) and as_atoms(b) then
        if has_unknown(a) or has_unknown(b) then
            return single("unknown")
        end
        local r = {} --: AtomSet
        for k, v in pairs(a) do if v then r[k] = true end end
        for k, v in pairs(b) do if v then r[k] = true end end
        return r
    end
    return bottom()
end

--: (unknown, unknown) -> boolean
local function equal(a, b)
    if as_atoms(a) and as_atoms(b) then
        for k, v in pairs(a) do if v and not b[k] then return false end end
        for k, v in pairs(b) do if v and not a[k] then return false end end
        return true
    end
    return false
end

M.lattice = { bottom = bottom, join = join, equal = equal } --: Lattice

-- ── Constructors ───────────────────────────────────────────────────────────

--: ({ [integer]: string }) -> AtomSet
function M.of(names)
    local a = {} --: AtomSet
    for i = 1, #names do a[names[i]] = true end
    return a
end

-- ── The two flow operations (narrowing AND and/or derive from these) ───────

-- The part of `v` that survives a TRUTHY test: drop `nil`. `boolean` stays
-- (v0 cannot split true from false). `unknown` stays unknown (top is opaque).
--: (unknown) -> unknown
function M.truthy(v)
    if not as_atoms(v) then return bottom() end
    if has_unknown(v) then return single("unknown") end
    local r = {} --: AtomSet
    for k, present in pairs(v) do
        if present and k ~= "nil" then r[k] = true end
    end
    return r
end

-- The part of `v` that survives a FALSY test: only `nil` and `boolean` atoms
-- contain falsy values (numbers/strings/tables/functions are always truthy
-- in Lua — 0 and "" are truthy).
--: (unknown) -> unknown
function M.falsy(v)
    if not as_atoms(v) then return bottom() end
    if has_unknown(v) then return single("unknown") end
    local r = {} --: AtomSet
    for k, present in pairs(v) do
        if present and (k == "nil" or k == "boolean") then r[k] = true end
    end
    return r
end

-- ── Queries (obligation checking reads these) ──────────────────────────────

--: (AtomSet) -> boolean
function M.is_unknown(v) return has_unknown(v) end

--: (AtomSet) -> boolean
function M.is_bottom(v)
    for _, present in pairs(v) do if present then return false end end
    return true
end

-- Atoms of `v` NOT admitted by `allow` — nil when v ⊆ allow, else a rendered
-- list (stable order). `unknown` in `v` is the caller's use-before-narrow
-- case and is reported separately, never here.
--: (v: AtomSet, allow: AtomSet) -> string | nil
function M.excess(v, allow)
    local bad = {} --: { [integer]: string }
    for k, present in pairs(v) do
        if present and k ~= "unknown" and not allow[k] then bad[#bad + 1] = k end
    end
    if #bad == 0 then return nil end
    table.sort(bad)
    return table.concat(bad, " | ")
end

-- Render as a sorted union string, e.g. "nil | number"; {} -> "never".
--: (unknown) -> string
function M.show(v)
    if not as_atoms(v) then return "never" end
    local atoms = {} --: { [integer]: string }
    for k, present in pairs(v) do if present then atoms[#atoms + 1] = k end end
    table.sort(atoms)
    if #atoms == 0 then return "never" end
    return table.concat(atoms, " | ")
end

return M
