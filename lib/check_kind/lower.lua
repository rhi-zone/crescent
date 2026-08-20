-- lib/check_kind/lower.lua
-- Lowers the SMALL SLICE of the annotation type grammar that the value/kind
-- checker understands into our value model (kinds.lua).
--
-- We reuse the real annotation grammar parser (lib.type.static.ann) — we do NOT
-- invent new syntax. The parser produces type-arena nodes; this module reads
-- only the tags we support and maps them to value-model types:
--
--   atoms        : nil, boolean, number, string, integer, cdata, unknown, never
--   nilable      : `T | nil` (a UNION whose members are an atom and nil)
--   arrows       : `(A, B) -> R`  (TAG_FUNCTION)
--   table        : `{ ... }` / `{ [K]: V }` / `T[]` (TAG_TABLE) → the `table` kind
--   literals     : "foo" / 42 / true → their atom (literal refinement DEFERRED)
--
-- Anything outside this slice (generics, intersections, match, named aliases,
-- multi-member unions beyond nilable) lowers to `unknown` — the checker then
-- demands a decision at the use site. This is the "demand the decision, don't
-- infer cleverly" rule: we never guess at a construct we cannot cheaply model.
--
-- STRUCTURE: like the checker itself, the lowering pass is a set of TOP-LEVEL
-- functions over an explicit lowering context `lctx` (the injected deps: the
-- type/list arenas, the type accessors, the tag defs, and our value model). No
-- closure-captured state; `M.new` only builds the `lctx` and exposes `lower`.
-- The functions are left unannotated so the typechecker infers their parameter
-- shapes from use — the reused annotation arena has no type alias to borrow.

local M = {}

-- Map an annotation primitive TAG to a value-model atom, or nil if outside the
-- supported slice.
local function atom_for_tag(lctx, tag)
    local defs, kinds = lctx.defs, lctx.kinds
    if tag == defs.TAG_NIL      then return kinds.NIL end
    if tag == defs.TAG_BOOLEAN  then return kinds.boolean() end
    if tag == defs.TAG_NUMBER   then return kinds.number() end
    if tag == defs.TAG_INTEGER  then return kinds.number() end  -- int/float DEFERRED
    if tag == defs.TAG_STRING   then return kinds.string() end
    if tag == defs.TAG_CDATA    then return kinds.cdata() end
    if tag == defs.TAG_UNKNOWN  then return kinds.UNKNOWN end
    if tag == defs.TAG_ANY      then return kinds.UNKNOWN end   -- `any` not modeled; treat as unknown
    if tag == defs.TAG_NEVER    then return kinds.NEVER end
    if tag == defs.TAG_TABLE    then return kinds.table() end
    return nil
end

-- Forward declaration (mutually recursive with the aggregate lowerings below).
local lower

-- Lower a UNION. We only understand the nilable shape: a union of exactly one
-- non-nil atom plus `nil` (in any order, any arity as long as the non-nil part
-- is a single kind). Otherwise → unknown.
local function lower_union(lctx, tid)
    local types, lists = lctx.types, lctx.lists
    local types_mod, defs, kinds = lctx.types_mod, lctx.defs, lctx.kinds
    local t = types:get(tid)
    local start = types_mod.agg_members_start(t)
    local len = types_mod.agg_members_len(t)
    local saw_nil = false
    local base = nil
    for i = 0, len - 1 do
        local mid = lists:get(start + i)
        local mt = types:get(mid)
        if mt.tag == defs.TAG_NIL then
            saw_nil = true
        else
            local lm = lower(lctx, mid)
            if lm == nil then return kinds.UNKNOWN end
            if base == nil then
                base = lm
            elseif base.k ~= lm.k then
                -- A union of two distinct non-nil kinds is outside the slice.
                return kinds.UNKNOWN
            end
        end
    end
    if base == nil then
        -- Union of only nils → nil.
        return kinds.NIL
    end
    if saw_nil then return kinds.as_nilable(base) end
    return base
end

-- Lower a FUNCTION (arrow). Parameters lower element-wise; the return is the
-- first return slot (multi-return collapse is DEFERRED). A parameter or return
-- outside the slice lowers to unknown (not an error — the arrow is still usable
-- as a function kind).
local function lower_function(lctx, tid)
    local types, lists = lctx.types, lctx.lists
    local types_mod, kinds = lctx.types_mod, lctx.kinds
    local t = types:get(tid)
    local ps = types_mod.fn_params_start(t)
    local pl = types_mod.fn_params_len(t)
    local params = {}
    for i = 0, pl - 1 do
        local pid = lists:get(ps + i)
        params[i + 1] = lower(lctx, pid) or kinds.UNKNOWN
    end
    local rs = types_mod.fn_returns_start(t)
    local rl = types_mod.fn_returns_len(t)
    local ret
    if rl >= 1 then
        ret = lower(lctx, lists:get(rs)) or kinds.UNKNOWN
    else
        ret = kinds.NEVER  -- declared to return nothing
    end
    return kinds.fn(params, ret)
end

-- lower: annotation type_id -> value-model type, or nil if unrepresentable (nil
-- only used internally; the public entry coerces nil to unknown).
lower = function(lctx, tid)
    if tid == nil or tid < 0 then return nil end
    local types, types_mod, defs, kinds = lctx.types, lctx.types_mod, lctx.defs, lctx.kinds
    local t = types:get(tid)
    local tag = t.tag

    local atom = atom_for_tag(lctx, tag)
    if atom ~= nil then return atom end

    if tag == defs.TAG_LITERAL then
        -- Literal refinement DEFERRED: a literal lowers to its atom.
        local lk = types_mod.lit_kind(t)
        if lk == defs.LIT_STRING then return kinds.string() end
        if lk == defs.LIT_BOOLEAN then return kinds.boolean() end
        return kinds.number()  -- LIT_INTEGER / LIT_NUMBER
    end

    if tag == defs.TAG_UNION then
        return lower_union(lctx, tid)
    end

    if tag == defs.TAG_FUNCTION then
        return lower_function(lctx, tid)
    end

    -- Everything else (named aliases, intersections, generics, match, ...) is
    -- outside the supported slice. Demand a decision elsewhere: unknown.
    return nil
end

-- new: build a lowering context bound to a parsed-annotation result.
--   ann_res   : result table from ann_mod.parse_annotations
--   pool      : intern pool
--   types_mod : lib.type.static.types (accessors)
--   defs      : lib.type.static.defs (tags)
--   kinds     : lib.check_kind.kinds (our value model)
function M.new(ann_res, pool, types_mod, defs, kinds)
    -- The lowering context: the injected arenas, accessors, tag defs, and value
    -- model that the top-level lowerings read through.
    local lctx = {
        types     = ann_res.types,
        lists     = ann_res.lists,
        types_mod = types_mod,
        defs      = defs,
        kinds     = kinds,
    }

    return {
        -- Public lowering: always returns a value-model type (unknown fallback).
        lower = function(tid)
            local r = lower(lctx, tid)
            if r == nil then return kinds.UNKNOWN end
            return r
        end,
    }
end

return M
