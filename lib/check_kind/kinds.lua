-- lib/check_kind/kinds.lua
-- The value model for the value/kind checker (checker #1).
--
-- Derived from first principles (see docs/checkers/value-kind.md):
--   * Six opaque atoms: boolean, number, string, thread, userdata, cdata.
--     (number is a single atom; the integer/float split is DEFERRED.)
--   * A nilable flag (NOT an atom): `nil` is absence, modeled as a `nilable`
--     boolean on every type. The literal `nil` is the absence type.
--   * Arrows: functions AND operators have type (args...) -> ret.
--   * Tables: a single structured kind `table`. Field SHAPES are DEFERRED.
--   * Top/bottom: `unknown` (any value) and `never` (no value).
--
-- A type is a plain Lua table { k = <K_*>, nilable = <bool>, ... }. Keeping the
-- representation as immutable-by-convention plain tables (no FFI arena) keeps
-- this checker standalone and trivially terminating — there are no cycles.

local M = {}

-- A value-model type: a kind tag plus a nilable flag, with optional arrow data
-- (params / ret) when the kind is a function. `params` absent means "arrow
-- unknown — do not check arguments"; `ret` absent means "result unknown".
--:: KindType = { k: integer, nilable: boolean, params?: { [integer]: KindType, ... }, ret?: KindType, ... }

-- Kind tags.
M.K_BOOLEAN  = 1
M.K_NUMBER   = 2
M.K_STRING   = 3
M.K_THREAD   = 4
M.K_USERDATA = 5
M.K_CDATA    = 6
M.K_TABLE    = 7
M.K_FUNCTION = 8
M.K_UNKNOWN  = 9   -- top: any value
M.K_NEVER    = 10  -- bottom: no value
M.K_NIL      = 11  -- absence (the literal `nil`)

local ATOM_NAME = {
    [M.K_BOOLEAN]  = "boolean",
    [M.K_NUMBER]   = "number",
    [M.K_STRING]   = "string",
    [M.K_THREAD]   = "thread",
    [M.K_USERDATA] = "userdata",
    [M.K_CDATA]    = "cdata",
    [M.K_TABLE]    = "table",
    [M.K_FUNCTION] = "function",
    [M.K_UNKNOWN]  = "unknown",
    [M.K_NEVER]    = "never",
    [M.K_NIL]      = "nil",
}

---------------------------------------------------------------------------
-- Singletons (shared, treated as immutable).
---------------------------------------------------------------------------
M.NIL     = { k = M.K_NIL,     nilable = true }
M.UNKNOWN = { k = M.K_UNKNOWN, nilable = true }   -- top includes nil
M.NEVER   = { k = M.K_NEVER,   nilable = false }

---------------------------------------------------------------------------
-- Atom constructors. Each returns a fresh non-nilable atom type.
---------------------------------------------------------------------------
--: () -> KindType
function M.boolean()  return { k = M.K_BOOLEAN,  nilable = false } end
--: () -> KindType
function M.number()   return { k = M.K_NUMBER,   nilable = false } end
--: () -> KindType
function M.string()   return { k = M.K_STRING,   nilable = false } end
--: () -> KindType
function M.thread()   return { k = M.K_THREAD,   nilable = false } end
--: () -> KindType
function M.userdata() return { k = M.K_USERDATA, nilable = false } end
--: () -> KindType
function M.cdata()    return { k = M.K_CDATA,    nilable = false } end
--: () -> KindType
function M.table()    return { k = M.K_TABLE,    nilable = false } end

-- atom_by_tag: build a fresh atom for a kind tag (used by lowering).
--: (integer) -> KindType
function M.atom_by_tag(k)
    return { k = k, nilable = false }
end

---------------------------------------------------------------------------
-- Arrow constructors. params is an array of value-model types; ret is a single
-- value-model type (multi-return is collapsed to the first return for v1 —
-- DEFERRED). fn_unknown is a callable whose arrow is not statically known.
---------------------------------------------------------------------------
--: ({ [integer]: KindType, ... }, KindType) -> KindType
function M.fn(params, ret)
    return { k = M.K_FUNCTION, nilable = false, params = params, ret = ret }
end

--: () -> KindType
function M.fn_unknown()
    -- Callable, but the parameter/return kinds are not known. Absent `params`
    -- signals "do not check arguments"; absent `ret` signals unknown result.
    return { k = M.K_FUNCTION, nilable = false }
end

---------------------------------------------------------------------------
-- Nilability helpers.
---------------------------------------------------------------------------

--: (KindType) -> boolean
function M.is_nilable(ty)
    return ty.nilable == true
end

-- as_nilable: return a copy of ty marked nilable (reading an absent field).
--: (KindType, boolean) -> KindType
local function reflag(ty, nilable)
    --: KindType
    local c = { k = ty.k, nilable = nilable }
    if ty.params then c.params = ty.params end
    if ty.ret then c.ret = ty.ret end
    return c
end

--: (KindType) -> KindType
function M.as_nilable(ty)
    if ty.nilable then return ty end
    return reflag(ty, true)
end

-- strip_nil: return a copy of ty marked non-nilable (after `if x then`).
--: (KindType) -> KindType
function M.strip_nil(ty)
    if ty.k == M.K_NIL then return M.NEVER end
    if not ty.nilable then return ty end
    return reflag(ty, false)
end

---------------------------------------------------------------------------
-- Subtyping: producer <: consumer. Sound and total (no recursion cycles).
--   * never <: anything.
--   * unknown is the top: T <: unknown always; but unknown </: concrete (the
--     caller must narrow — enforced at use sites, and here so assignment to a
--     concrete annotation from unknown is rejected).
--   * nil <: T only if T is nilable.
--   * atom <: same atom (modulo nilability: producer must not be nilable when
--     the consumer is not).
--   * function <: function and table <: table at the kind level (shapes/arrows
--     are not compared in v1 — DEFERRED; we only check the kind matches).
---------------------------------------------------------------------------

--: (KindType, KindType) -> boolean
function M.is_subtype(sub, sup)
    -- bottom is a subtype of everything.
    if sub.k == M.K_NEVER then return true end
    -- top consumer accepts everything.
    if sup.k == M.K_UNKNOWN then return true end
    -- A producer that may be nil is only assignable to a nilable consumer.
    if sub.nilable and not sup.nilable then return false end
    -- The literal nil: assignable exactly to nilable consumers.
    if sub.k == M.K_NIL then
        return sup.nilable == true
    end
    -- An `unknown` producer is NOT a subtype of any concrete kind (must narrow).
    if sub.k == M.K_UNKNOWN then
        return sup.k == M.K_UNKNOWN
    end
    -- Same kind tag matches (atoms, table, function — shape/arrow ignored in v1).
    return sub.k == sup.k
end

---------------------------------------------------------------------------
-- join: the least upper bound used for branch/operator joins. v1 keeps the
-- lattice flat: identical kinds join to that kind (carrying nilability);
-- differing kinds join to `unknown`. nil joins by adding nilability.
---------------------------------------------------------------------------

--: (KindType, KindType) -> KindType
function M.join(a, b)
    if a.k == M.K_NEVER then return b end
    if b.k == M.K_NEVER then return a end
    if a.k == M.K_NIL then return M.as_nilable(b) end
    if b.k == M.K_NIL then return M.as_nilable(a) end
    if a.k == b.k then
        if a.nilable == b.nilable then return a end
        return M.as_nilable(a)
    end
    -- Differing kinds: widen to top.
    return M.UNKNOWN
end

---------------------------------------------------------------------------
-- Pretty-printing for diagnostics.
---------------------------------------------------------------------------

--: (KindType) -> string
function M.tostr(ty)
    local base = ATOM_NAME[ty.k] or "?"
    if ty.k == M.K_NIL or ty.k == M.K_UNKNOWN or ty.k == M.K_NEVER then
        return base
    end
    if ty.nilable then return base .. " | nil" end
    return base
end

return M
