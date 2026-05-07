-- lib/type/static/types.lua
-- Type arena operations for the typechecker.
-- Types are flat FFI TypeSlot entries accessed via integer IDs.
-- Union-find is used for type variables: TAG_VAR.data[2] is the parent
-- type_id (-1 = unbound root, >= 0 = bound to that ID).

local ffi = require("ffi")
local defs = require("lib.type.static.defs")
local arena_mod = require("lib.type.static.arena")
local intern_mod = require("lib.type.static.intern")

local TAG_NIL          = defs.TAG_NIL
local TAG_BOOLEAN      = defs.TAG_BOOLEAN
local TAG_NUMBER       = defs.TAG_NUMBER
local TAG_STRING       = defs.TAG_STRING
local TAG_ANY          = defs.TAG_ANY
local TAG_NEVER        = defs.TAG_NEVER
local TAG_INTEGER      = defs.TAG_INTEGER
local TAG_UNKNOWN      = defs.TAG_UNKNOWN
local TAG_LITERAL      = defs.TAG_LITERAL
local TAG_FUNCTION     = defs.TAG_FUNCTION
local TAG_TABLE        = defs.TAG_TABLE
local TAG_UNION        = defs.TAG_UNION
local TAG_INTERSECTION = defs.TAG_INTERSECTION
local TAG_VAR          = defs.TAG_VAR
local TAG_ROWVAR       = defs.TAG_ROWVAR
local TAG_TUPLE        = defs.TAG_TUPLE
local TAG_NOMINAL      = defs.TAG_NOMINAL
local TAG_MATCH_TYPE   = defs.TAG_MATCH_TYPE
local TAG_INTRINSIC    = defs.TAG_INTRINSIC
local TAG_TYPE_CALL    = defs.TAG_TYPE_CALL
local TAG_FORALL       = defs.TAG_FORALL
local TAG_SPREAD       = defs.TAG_SPREAD
local TAG_NAMED        = defs.TAG_NAMED
local TAG_CDATA        = defs.TAG_CDATA
local TAG_ENUM_MEMBER  = defs.TAG_ENUM_MEMBER

local LIT_STRING  = defs.LIT_STRING
local LIT_NUMBER  = defs.LIT_NUMBER
local LIT_BOOLEAN = defs.LIT_BOOLEAN
local LIT_NIL     = defs.LIT_NIL
local LIT_INTEGER = defs.LIT_INTEGER
local double_to_i32x2 = defs.double_to_i32x2
local i32x2_to_double = defs.i32x2_to_double

local FLAG_GENERIC    = defs.FLAG_GENERIC
local FLAG_OPTIONAL   = defs.FLAG_OPTIONAL
local FLAG_READONLY   = defs.FLAG_READONLY
local FLAG_PRIVATE    = defs.FLAG_PRIVATE
local FLAG_OPAQUE_KEY = defs.FLAG_OPAQUE_KEY
local band            = require("bit").band

local M = {}

-- TypeSlot data layouts:
--
-- TAG_VAR / TAG_ROWVAR:
--   data[0] = unique var ID (for occurs check)
--   data[1] = level (for generalization)
--   data[2] = parent type_id (-1 = unbound root, >=0 = bound)
--   flags: FLAG_GENERIC if generalized
--
-- TAG_LITERAL:
--   data[0] = LIT_STRING/LIT_NUMBER/LIT_BOOLEAN/LIT_NIL
--   data[1] = for string: intern_id; for boolean: 1=true, 0=false
--             for number: lo int32 of double (data[2] = hi int32)
--
-- TAG_FUNCTION:
--   data[0] = params_start (list pool)
--   data[1] = params_len (type_ids)
--   data[2] = returns_start (list pool)
--   data[3] = returns_len (type_ids)
--   data[4] = vararg_type_id (-1 = none)
--
-- TAG_TABLE:
--   data[0] = fields_start  (list pool, field_arena IDs)
--   data[1] = fields_len
--   data[2] = indexers_start (list pool, interleaved pairs: key_id, val_id, ...)
--   data[3] = indexers_len   (count of type_ids, so #pairs = len/2)
--   data[4] = row_var_id     (-1 = none)
--   data[5] = meta_start     (list pool, field_arena IDs for meta slots)
--   data[6] = meta_len
--
-- TAG_UNION / TAG_INTERSECTION / TAG_TUPLE:
--   data[0] = members_start
--   data[1] = members_len
--
-- TAG_NOMINAL:
--   data[0] = name_id (intern)
--   data[1] = identity (unique int)
--   data[2] = underlying type_id
--
-- TAG_NAMED:
--   data[0] = name_id (intern)
--   data[1] = args_start (type args in list pool)
--   data[2] = args_len
--
-- TAG_MATCH_TYPE:
--   data[0] = param type_id
--   data[1] = arms_start (pairs: pattern_id, result_id)
--   data[2] = arms_len
--
-- TAG_FORALL:
--   data[0] = type_params_start (name_ids)
--   data[1] = type_params_len
--   data[2] = body type_id
--
-- TAG_SPREAD:
--   data[0] = inner type_id
--
-- TAG_INTRINSIC:
--   data[0] = name_id
--
-- TAG_TYPE_CALL:
--   data[0] = callee_id
--   data[1] = args_start
--   data[2] = args_len
--
-- TAG_ENUM_MEMBER:
--   data[0] = enum_name_id   (intern ID of the enum variable name)
--   data[1] = member_name_id (intern ID of the member field name)
--   data[2] = lit_kind       (LIT_INTEGER or LIT_STRING)
--   data[3] = value          (LIT_INTEGER: int32 value; LIT_STRING: intern ID)

-- Singleton IDs (pre-allocated at fixed positions)
M.T_NIL     = 0
M.T_BOOLEAN = 1
M.T_NUMBER  = 2
M.T_STRING  = 3
M.T_ANY     = 4
M.T_NEVER   = 5
M.T_INTEGER = 6
M.T_UNKNOWN = 7

--: (TypeSlotArena, integer) -> integer
local function alloc_zero(types, tag)
    local i = types:alloc()
    local t = types:get(i)
    t.tag = tag
    t.flags = 0
    t.reserved = 0
    t.data[0] = 0; t.data[1] = 0; t.data[2] = 0
    t.data[3] = 0; t.data[4] = 0; t.data[5] = 0; t.data[6] = 0
    return i
end

-- Create a new checker context.
-- pool: shared intern pool (from parse result)
-- Returns a partially-initialized Ctx; remaining fields populated by constrain.M.generate.
--: (InternPool) -> Ctx
function M.new_ctx(pool)
    local types  = arena_mod.new_type_arena(512)
    local fields = arena_mod.new_field_arena(256)
    local lists  = arena_mod.new_list_pool(1024)

    -- Pre-allocate singletons at fixed IDs 0-6
    alloc_zero(types, TAG_NIL)      -- 0
    alloc_zero(types, TAG_BOOLEAN)  -- 1
    alloc_zero(types, TAG_NUMBER)   -- 2
    alloc_zero(types, TAG_STRING)   -- 3
    alloc_zero(types, TAG_ANY)      -- 4
    alloc_zero(types, TAG_NEVER)    -- 5
    alloc_zero(types, TAG_INTEGER)  -- 6
    alloc_zero(types, TAG_UNKNOWN)  -- 7
    -- data[2] for singletons: -1 means "no parent" (they are concrete types, not vars)
    -- but we never call find() expecting to follow them, so it's fine to leave as 0

    local ctx = {
        types        = types,
        fields       = fields,
        lists        = lists,
        pool         = pool,
        var_counter  = 0,
        nominal_id   = 0,
        level        = 0,
        -- Singleton shortcuts
        T_NIL     = M.T_NIL,
        T_BOOLEAN = M.T_BOOLEAN,
        T_NUMBER  = M.T_NUMBER,
        T_STRING  = M.T_STRING,
        T_ANY     = M.T_ANY,
        T_NEVER   = M.T_NEVER,
        T_INTEGER = M.T_INTEGER,
        T_UNKNOWN = M.T_UNKNOWN,
        -- prim_index: TAG_* → TID of the __index table for that primitive.
        -- Populated by prelude.populate. Used by NODE_METHOD_CALL dispatch.
        prim_index = {},
        -- prim_meta: TAG_* → TID of the operator metamethods table for that primitive.
        -- Populated by prelude.populate. Used by meta_op_ret and unify.
        -- Keys: TAG_NUMBER, TAG_INTEGER, TAG_STRING (and their literal subtypes, normalized by callers).
        prim_meta = {},
        -- _ann_warn_line: 0 = no active annotation warning; set to source line before
        -- resolving a user annotation, reset to 0 after. Used by resolve_annotation_type
        -- to emit E.EXPLICIT_ANY when `any` appears in a user-written annotation.
        _ann_warn_line = 0,
        _ann_consumed  = {},
    }
    return ctx --[[: any]]
end

-- Allocate and zero-initialize a TypeSlot. Returns type_id.
function M.alloc_type(ctx, tag)
    return alloc_zero(ctx.types, tag)
end

-- Union-find with path compression.
-- For TAG_VAR / TAG_ROWVAR: follow data[2] chain until root.
-- For all other tags: return tid directly.
--: (Ctx, integer) -> integer
function M.find(ctx, tid)
    local types = ctx.types
    -- Find root
    local root = tid
    while true do
        local t = types:get(root)
        if t.tag ~= TAG_VAR and t.tag ~= TAG_ROWVAR then break end
        local parent = t.data[2]
        if parent == -1 then break end  -- unbound root
        if parent == root then break end  -- self-loop: treat as unbound root (defensive)
        root = parent
    end
    -- Path compression
    local cur = tid
    while cur ~= root do
        local t = types:get(cur)
        if t.tag ~= TAG_VAR and t.tag ~= TAG_ROWVAR then break end
        local parent = t.data[2]
        if parent == -1 then break end
        if parent == cur then break end  -- self-loop guard
        t.data[2] = root
        cur = parent
    end
    return root
end

-- Make a fresh type variable at the given level.
--: (Ctx, integer | nil) -> integer
function M.make_var(ctx, level)
    ctx.var_counter = ctx.var_counter + 1
    local id = alloc_zero(ctx.types, TAG_VAR)
    local t = ctx.types:get(id)
    t.data[0] = ctx.var_counter    -- unique ID
    t.data[1] = level or ctx.level -- scope level
    t.data[2] = -1                 -- unbound
    return id
end

-- Make a fresh row variable at the given level.
--: (Ctx, integer | nil) -> integer
function M.make_rowvar(ctx, level)
    ctx.var_counter = ctx.var_counter + 1
    local id = alloc_zero(ctx.types, TAG_ROWVAR)
    local t = ctx.types:get(id)
    t.data[0] = ctx.var_counter
    t.data[1] = level or ctx.level
    t.data[2] = -1
    return id
end

-- Make a literal type.
-- kind: LIT_STRING/LIT_NUMBER/LIT_BOOLEAN/LIT_NIL
-- val: intern_id (for string) or 1/0 (for boolean) or double (for number)
--: (Ctx, integer, number | nil) -> integer
function M.make_literal(ctx, kind, val)
    -- Intern literals so the same value always maps to the same type_id.
    -- This prevents union dedup from missing duplicate literal members.
    local cache = ctx.lit_cache
    if cache then
        local key
        if kind == LIT_NUMBER then
            local hi, lo = double_to_i32x2(val or 0)
            key = kind .. ":" .. hi .. ":" .. lo
        else
            key = kind .. ":" .. (val or 0)
        end
        local cached = cache[key]
        if cached then return cached end
        local id = alloc_zero(ctx.types, TAG_LITERAL)
        local t = ctx.types:get(id)
        t.data[0] = kind
        if kind == LIT_NUMBER then
            t.data[1], t.data[2] = double_to_i32x2(val or 0)
        else
            t.data[1] = val or 0
        end
        cache[key] = id
        return id
    end
    local id = alloc_zero(ctx.types, TAG_LITERAL)
    local t = ctx.types:get(id)
    t.data[0] = kind
    if kind == LIT_NUMBER then
        t.data[1], t.data[2] = double_to_i32x2(val or 0)
    else
        t.data[1] = val or 0
    end
    return id
end

-- Make an enum member type.
-- enum_name_id:   intern ID of the enum table's variable name (e.g. "Status")
-- member_name_id: intern ID of the field name (e.g. "OK")
-- lit_kind:       LIT_INTEGER or LIT_STRING
-- value:          int32 integer value (LIT_INTEGER) or intern ID of string (LIT_STRING)
function M.make_enum_member(ctx, enum_name_id, member_name_id, lit_kind, value)
    local id = alloc_zero(ctx.types, TAG_ENUM_MEMBER)
    local t = ctx.types:get(id)
    t.data[0] = enum_name_id
    t.data[1] = member_name_id
    t.data[2] = lit_kind
    t.data[3] = value
    return id
end

-- Make a function type.
-- params, returns: Lua arrays of type_ids
-- vararg_id: type_id or -1 for no vararg
-- param_name_ids: optional Lua array of intern IDs (one per param); stored in data[5]/data[6]
--: (Ctx, { [integer]: integer, ... }, { [integer]: integer, ... }, integer | nil, { [integer]: integer, ... } | nil) -> integer
function M.make_func(ctx, params, returns, vararg_id, param_name_ids)
    local m = ctx.lists:mark()
    for i = 1, #params do ctx.lists:push(params[i]) end
    local ps, pl = ctx.lists:since(m)
    m = ctx.lists:mark()
    for i = 1, #returns do ctx.lists:push(returns[i]) end
    local rs, rl = ctx.lists:since(m)
    local id = alloc_zero(ctx.types, TAG_FUNCTION)
    local t = ctx.types:get(id)
    t.data[0] = ps
    t.data[1] = pl
    t.data[2] = rs
    t.data[3] = rl
    t.data[4] = vararg_id ~= nil and vararg_id or -1
    if param_name_ids then
        local pni = param_name_ids
        if #pni > 0 then
            m = ctx.lists:mark()
            for i = 1, #pni do ctx.lists:push(pni[i]) end
            local pns, pnl = ctx.lists:since(m)
            t.data[5] = pns
            t.data[6] = pnl
        end
    end
    return id
end

-- Make a FieldEntry and return its arena ID.
-- flags: bitmask of FLAG_OPTIONAL, FLAG_READONLY, FLAG_PRIVATE.
-- For backward compat, if flags is a boolean it is treated as FLAG_OPTIONAL.
--: (Ctx, integer, integer, unknown) -> integer
function M.make_field(ctx, name_id, type_id, flags)
    local fid = ctx.fields:alloc()
    local fe = ctx.fields:get(fid)
    fe.name_id = name_id
    fe.type_id = type_id
    if type(flags) == "boolean" then
        fe.flags = flags and FLAG_OPTIONAL or 0
    else
        fe.flags = flags or 0
    end
    return fid
end

-- Return the flags byte of a FieldEntry.
function M.field_flags(fe)
    return fe.flags
end

-- Check if a FieldEntry has a given flag bit set.
function M.field_has(fe, flag)
    return band(fe.flags, flag) ~= 0
end

-- Make a table type.
-- field_ids: Lua array of field_arena IDs
-- indexer_pairs: flat Lua array of type_ids [key0, val0, key1, val1, ...]
-- row_var_id: type_id or -1
-- meta_field_ids: Lua array of field_arena IDs for __meta slots
--: (Ctx, { [integer]: integer, ... } | nil, { [integer]: integer, ... } | nil, integer | nil, { [integer]: integer, ... } | nil) -> integer
function M.make_table(ctx, field_ids, indexer_pairs, row_var_id, meta_field_ids)
    field_ids    = field_ids    or {}
    indexer_pairs = indexer_pairs or {}
    meta_field_ids = meta_field_ids or {}

    local fs, fl = 0, 0
    if #field_ids > 0 then
        local m = ctx.lists:mark()
        for _, fid in ipairs(field_ids) do ctx.lists:push(fid) end
        fs, fl = ctx.lists:since(m)
    end
    local is, il = 0, 0
    if #indexer_pairs > 0 then
        local m = ctx.lists:mark()
        for _, tid in ipairs(indexer_pairs) do ctx.lists:push(tid) end
        is, il = ctx.lists:since(m)
    end
    local ms, ml = 0, 0
    if #meta_field_ids > 0 then
        local m = ctx.lists:mark()
        for _, fid in ipairs(meta_field_ids) do ctx.lists:push(fid) end
        ms, ml = ctx.lists:since(m)
    end

    local id = alloc_zero(ctx.types, TAG_TABLE)
    local t = ctx.types:get(id)
    t.data[0] = fs
    t.data[1] = fl
    t.data[2] = is
    t.data[3] = il
    t.data[4] = row_var_id ~= nil and row_var_id or -1
    t.data[5] = ms
    t.data[6] = ml
    return id
end

local union_has  -- forward declaration; defined after struct_equal below

-- Map from TAG_LITERAL kind to the primitive TAG that subsumes it.
local lit_primitive = {
    [LIT_INTEGER] = TAG_INTEGER,
    [LIT_NUMBER]  = TAG_NUMBER,
    [LIT_STRING]  = TAG_STRING,
    [LIT_BOOLEAN] = TAG_BOOLEAN,
}
-- Map from primitive TAG to the LIT kind it subsumes.
local primitive_lit_kind = {
    [TAG_INTEGER] = LIT_INTEGER,
    [TAG_NUMBER]  = LIT_NUMBER,
    [TAG_STRING]  = LIT_STRING,
    [TAG_BOOLEAN] = LIT_BOOLEAN,
}

-- Return true if tid is subsumed by prim_tag (literal-vs-primitive only).
local function lit_subsumed_by_prim(ctx, tid, prim_tag)
    local t = ctx.types:get(tid)
    if t.tag ~= TAG_LITERAL then return false end
    return lit_primitive[t.data[0]] == prim_tag
end

-- Return true if flat already contains a type that subsumes tid.
-- Handles: TAG_LITERAL(k) subsumed by TAG_INTEGER/NUMBER/STRING/BOOLEAN,
-- and TAG_INTEGER subsumed by TAG_NUMBER.
local function flat_has_supertype(ctx, flat, tid)
    local t = ctx.types:get(tid)
    -- Literal subsumed by its primitive
    if t.tag == TAG_LITERAL then
        local prim = lit_primitive[t.data[0]]
        if prim then
            for i = 1, #flat do
                local ft = ctx.types:get(flat[i])
                if ft.tag == prim then return true end
                -- integer literal also subsumed by number
                if t.data[0] == LIT_INTEGER and ft.tag == TAG_NUMBER then return true end
            end
        end
        return false
    end
    -- integer subsumed by number
    if t.tag == TAG_INTEGER then
        for i = 1, #flat do
            if ctx.types:get(flat[i]).tag == TAG_NUMBER then return true end
        end
    end
    return false
end

-- Remove from flat any types subsumed by the new primitive tag.
-- Handles: literals when adding their primitive; TAG_INTEGER when adding TAG_NUMBER.
local function remove_subsumed(ctx, flat, new_tag)
    local lk = primitive_lit_kind[new_tag]
    local i = 1
    while i <= #flat do
        local ft = ctx.types:get(flat[i])
        local remove = false
        -- Remove literals subsumed by this primitive
        if ft.tag == TAG_LITERAL then
            local fprim = lit_primitive[ft.data[0]]
            if fprim == new_tag then remove = true end
            -- integer literal subsumed by number
            if new_tag == TAG_NUMBER and ft.data[0] == LIT_INTEGER then remove = true end
        end
        -- Remove integer when adding number
        if new_tag == TAG_NUMBER and ft.tag == TAG_INTEGER then remove = true end
        if remove then table.remove(flat, i) else i = i + 1 end
    end
end

--: (Ctx, { [integer]: integer, ... }) -> integer
function M.make_union(ctx, member_ids)
    --: { [integer]: integer, ... }
    local flat = {}
    for i = 1, #member_ids do
        local rtid = M.find(ctx, member_ids[i])
        local t = ctx.types:get(rtid)
        if t.tag == TAG_ANY     then return ctx.T_ANY end
        if t.tag == TAG_UNKNOWN then return ctx.T_UNKNOWN end
        if t.tag == TAG_UNION then
            local s, l = t.data[0], t.data[1]
            for j = s, s + l - 1 do
                local mid = M.find(ctx, ctx.lists:get(j))
                local mt = ctx.types:get(mid)
                if mt.tag == TAG_ANY     then return ctx.T_ANY end
                if mt.tag == TAG_UNKNOWN then return ctx.T_UNKNOWN end
                if mt.tag ~= TAG_NEVER and not union_has(ctx, flat, mid)
                   and not flat_has_supertype(ctx, flat, mid) then
                    remove_subsumed(ctx, flat, mt.tag)
                    flat[#flat + 1] = mid
                end
            end
        elseif t.tag ~= TAG_NEVER then
            if not union_has(ctx, flat, rtid) and not flat_has_supertype(ctx, flat, rtid) then
                remove_subsumed(ctx, flat, t.tag)
                flat[#flat + 1] = rtid
            end
        end
    end
    if #flat == 0 then return ctx.T_NEVER end
    if #flat == 1 then return flat[1] end
    local m = ctx.lists:mark()
    for _, id in ipairs(flat) do ctx.lists:push(id) end
    local ms, ml = ctx.lists:since(m)
    local id = alloc_zero(ctx.types, TAG_UNION)
    local t = ctx.types:get(id)
    t.data[0] = ms
    t.data[1] = ml
    return id
end

-- Make an intersection type.
function M.make_intersection(ctx, member_ids)
    local flat = {}
    local seen = {}
    for i = 1, #member_ids do
        local rtid = M.find(ctx, member_ids[i])
        local t = ctx.types:get(rtid)
        if t.tag == TAG_INTERSECTION then
            local s, l = t.data[0], t.data[1]
            for j = s, s + l - 1 do
                local mid = M.find(ctx, ctx.lists:get(j))
                if not seen[mid] then seen[mid] = true; flat[#flat + 1] = mid end
            end
        elseif t.tag ~= TAG_ANY then
            if not seen[rtid] then seen[rtid] = true; flat[#flat + 1] = rtid end
        end
    end
    if #flat == 0 then return ctx.T_ANY end
    if #flat == 1 then return flat[1] end
    local m = ctx.lists:mark()
    for _, id in ipairs(flat) do ctx.lists:push(id) end
    local ms, ml = ctx.lists:since(m)
    local id = alloc_zero(ctx.types, TAG_INTERSECTION)
    local t = ctx.types:get(id)
    t.data[0] = ms
    t.data[1] = ml
    return id
end

-- Make a tuple type.
--: (Ctx, { [integer]: integer, ... }) -> integer
function M.make_tuple(ctx, elem_ids)
    local m = ctx.lists:mark()
    for i = 1, #elem_ids do ctx.lists:push(elem_ids[i]) end
    local es, el = ctx.lists:since(m)
    local id = alloc_zero(ctx.types, TAG_TUPLE)
    local t = ctx.types:get(id)
    t.data[0] = es
    t.data[1] = el
    return id
end

-- Filter a union-of-tuples to arms where slot[slot_index] satisfies predicate_fn.
-- Returns array of surviving arm type_ids, or nil if source is not TAG_UNION.
--: (Ctx, integer, integer, (integer) -> boolean) -> ({ [integer]: integer, ... } | nil)
function M.filter_tuple_union_arms(ctx, union_tid, slot_index, predicate_fn)
    local root = M.find(ctx, union_tid)
    local u = ctx.types:get(root)
    if u.tag ~= TAG_UNION then return nil end
    local surviving = {}
    for i = u.data[0], u.data[0] + u.data[1] - 1 do
        local arm = M.find(ctx, ctx.lists:get(i))
        local arm_t = ctx.types:get(arm)
        if arm_t.tag == TAG_TUPLE and arm_t.data[1] > slot_index then
            local slot_tid = M.find(ctx, ctx.lists:get(arm_t.data[0] + slot_index))
            if predicate_fn(slot_tid) then
                surviving[#surviving + 1] = arm
            end
        end
    end
    return surviving
end

-- Make a nominal type.
function M.make_nominal(ctx, name_id, identity, underlying_id)
    local id = alloc_zero(ctx.types, TAG_NOMINAL)
    local t = ctx.types:get(id)
    t.data[0] = name_id
    t.data[1] = identity
    t.data[2] = underlying_id
    return id
end

-- T? = T | nil
function M.make_optional(ctx, tid)
    return M.make_union(ctx, { tid, ctx.T_NIL })
end

-- T[] = { [number]: T }
function M.make_array(ctx, elem_tid)
    return M.make_table(ctx, {}, { ctx.T_NUMBER, elem_tid }, -1, {})
end

-- Widen literal type to base type.
--: (Ctx, integer) -> integer
function M.widen(ctx, tid)
    tid = M.find(ctx, tid)
    local t = ctx.types:get(tid)
    if t.tag == TAG_LITERAL then
        local kind = t.data[0]
        if kind == LIT_STRING  then return ctx.T_STRING end
        if kind == LIT_NUMBER  then return ctx.T_NUMBER end
        if kind == LIT_BOOLEAN then return ctx.T_BOOLEAN end
        if kind == LIT_NIL     then return ctx.T_NIL end
        if kind == LIT_INTEGER then return ctx.T_INTEGER end
    end
    if t.tag == TAG_ENUM_MEMBER then
        if t.data[2] == LIT_INTEGER then return ctx.T_INTEGER end
        if t.data[2] == LIT_STRING  then return ctx.T_STRING end
    end
    if t.tag == TAG_UNION then
        local members = {}
        for i = t.data[0], t.data[0] + t.data[1] - 1 do
            members[#members + 1] = M.widen(ctx, ctx.lists:get(i))
        end
        return M.make_union(ctx, members)
    end
    return tid
end

-- Deep structural equality with cycle detection.
-- seen: optional table mapping "a:b" string keys to prevent infinite recursion.
local function struct_equal(ctx, a, b, seen)
    a = M.find(ctx, a)
    b = M.find(ctx, b)
    if a == b then return true end
    local ta = ctx.types:get(a)
    local tb = ctx.types:get(b)
    if ta.tag ~= tb.tag then return false end
    local tag = ta.tag
    -- Primitives: tag equality suffices.
    if tag == TAG_NIL or tag == TAG_BOOLEAN or tag == TAG_NUMBER
      or tag == TAG_INTEGER or tag == TAG_STRING
      or tag == TAG_ANY or tag == TAG_NEVER or tag == TAG_UNKNOWN then
        return true
    end
    if tag == TAG_LITERAL then
        if ta.data[0] ~= tb.data[0] then return false end
        if ta.data[0] == LIT_NUMBER then
            return ta.data[1] == tb.data[1] and ta.data[2] == tb.data[2]
        end
        return ta.data[1] == tb.data[1]
    end
    if tag == TAG_ENUM_MEMBER then
        return ta.data[0] == tb.data[0] and ta.data[1] == tb.data[1]
    end
    if tag == TAG_NOMINAL then
        return ta.data[1] == tb.data[1]
    end
    -- TAG_CDATA and TAG_FFIC are singletons per compilation unit:
    -- any two nodes with the same tag are structurally equal.
    if tag == TAG_CDATA then return true end
    if tag == defs.TAG_FFIC then return true end
    -- Cycle detection for recursive types.
    seen = seen or {}
    local key = a .. ":" .. b
    if seen[key] then return true end  -- assume equal under recursion
    seen[key] = true
    if tag == TAG_UNION or tag == TAG_INTERSECTION then
        if ta.data[1] ~= tb.data[1] then seen[key] = nil; return false end
        for i = 0, ta.data[1] - 1 do
            local ma = M.find(ctx, ctx.lists:get(ta.data[0] + i))
            local mb = M.find(ctx, ctx.lists:get(tb.data[0] + i))
            if not struct_equal(ctx, ma, mb, seen) then seen[key] = nil; return false end
        end
        seen[key] = nil; return true
    end
    if tag == TAG_TABLE then
        -- Compare field counts.
        if ta.data[1] ~= tb.data[1] then seen[key] = nil; return false end
        -- Compare fields pairwise (order-sensitive; both come from same annotation structure).
        for i = 0, ta.data[1] - 1 do
            local fa = ctx.fields:get(ctx.lists:get(ta.data[0] + i))
            local fb = ctx.fields:get(ctx.lists:get(tb.data[0] + i))
            if fa.name_id ~= fb.name_id then seen[key] = nil; return false end
            if fa.flags   ~= fb.flags   then seen[key] = nil; return false end
            if not struct_equal(ctx, fa.type_id, fb.type_id, seen) then
                seen[key] = nil; return false
            end
        end
        -- Compare indexer counts and types.
        if ta.data[3] ~= tb.data[3] then seen[key] = nil; return false end
        for i = 0, ta.data[3] - 1 do
            local ka = M.find(ctx, ctx.lists:get(ta.data[2] + i))
            local kb = M.find(ctx, ctx.lists:get(tb.data[2] + i))
            if not struct_equal(ctx, ka, kb, seen) then seen[key] = nil; return false end
        end
        seen[key] = nil; return true
    end
    if tag == TAG_FUNCTION then
        if ta.data[1] ~= tb.data[1] or ta.data[3] ~= tb.data[3] then
            seen[key] = nil; return false
        end
        for i = 0, ta.data[1] - 1 do
            if not struct_equal(ctx,
                M.find(ctx, ctx.lists:get(ta.data[0] + i)),
                M.find(ctx, ctx.lists:get(tb.data[0] + i)), seen) then
                seen[key] = nil; return false
            end
        end
        for i = 0, ta.data[3] - 1 do
            if not struct_equal(ctx,
                M.find(ctx, ctx.lists:get(ta.data[2] + i)),
                M.find(ctx, ctx.lists:get(tb.data[2] + i)), seen) then
                seen[key] = nil; return false
            end
        end
        seen[key] = nil; return true
    end
    seen[key] = nil
    return false
end

-- Check structural equality of two types (shallow for primitives, deep for composites).
function M.types_equal(ctx, a, b)
    return struct_equal(ctx, a, b, nil)
end

union_has = function(ctx, flat, tid)
    for i = 1, #flat do
        if struct_equal(ctx, flat[i], tid, nil) then return true end
    end
    return false
end

-- Post-solve normalization: rebuild all union nodes so their member lists use
-- resolved (find()ed) type IDs and have duplicates removed.  Called once after
-- solve.solve() finishes, before any diagnostics are emitted.
--
-- Why this is needed: the phi-join during constraint generation calls make_union
-- with fresh unresolved TAG_VAR nodes (e.g. the result vars of C_ARITH
-- constraints that haven't been solved yet).  Two vars that both eventually
-- resolve to the same primitive (e.g. T_INTEGER) are not structurally equal at
-- construction time (different data[0] unique IDs), so both end up in the union
-- list.  After solving they both chain to the same root via union-find, but the
-- list stored in the union node still holds the original var IDs.
--
-- Normalization: for each TAG_UNION node, rebuild its member list by following
-- find() on every slot and deduplicating with struct_equal (which also calls
-- find()).  If two members resolve to the same root ID, only one is kept.
--
-- The rebuilt list is appended to the list pool (append-only), and the union
-- node's data[0]/data[1] pointers are updated in-place.  A union that collapses
-- to one element is left as a 1-slot TAG_UNION rather than being converted to a
-- redirect, because the arena does not support tag changes (other nodes hold the
-- union's ID and expect TAG_UNION).  All downstream code that iterates union
-- members handles 1-element unions correctly.
--: (Ctx) -> ()
function M.normalize_unions(ctx)
    --: integer
    local type_count = ctx.types.len
    -- Iterate all type nodes except singletons 0-7.
    --: integer
    local uid = 8
    while uid < type_count do
        --: TypeSlot
        local ut = ctx.types:get(uid)
        if ut.tag == TAG_UNION then
            --: integer
            local us = ut.data[0]
            --: integer
            local ul = ut.data[1]
            -- Build a deduplicated flat list using resolved member IDs.
            --: { [integer]: integer, ... }
            local flat = {}
            for uj = us, us + ul - 1 do
                --: integer
                local umid = M.find(ctx, ctx.lists:get(uj) --[[:! integer]])
                --: TypeSlot
                local umt = ctx.types:get(umid)
                if umt.tag ~= TAG_NEVER
                   and not union_has(ctx, flat, umid)
                   and not flat_has_supertype(ctx, flat, umid) then
                    remove_subsumed(ctx, flat, umt.tag)
                    flat[#flat + 1] = umid
                end
            end
            -- Only rewrite the list when something actually changed.
            local changed = (#flat ~= ul)
            if not changed then
                for ui = 1, ul do
                    if flat[ui] ~= M.find(ctx, ctx.lists:get(us + ui - 1) --[[:! integer]]) then
                        changed = true; break
                    end
                end
            end
            if changed then
                --: integer
                local um = ctx.lists:mark()
                for _, ufid in ipairs(flat) do ctx.lists:push(ufid) end
                local ums, uml = ctx.lists:since(um)
                -- Re-fetch ut: lists:push may grow the list pool which could
                -- trigger a realloc, but the type arena is separate so ut is
                -- still valid.  Nonetheless, re-fetch for safety.
                ut = ctx.types:get(uid)
                ut.data[0] = ums
                ut.data[1] = uml
            end
        end
        uid = uid + 1
    end
end

-- Look up a named field in a table type. Returns (FieldEntry*, field_arena_id) or nil.
-- Skips opaque-key fields (FLAG_OPAQUE_KEY): those are matched by opaque key lookup, not by name.
--: (Ctx, integer, integer) -> (FieldEntry | nil, integer | nil)
function M.table_field(ctx, tbl_tid, name_id)
    local t = ctx.types:get(tbl_tid)  -- caller must have called find()
    for i = t.data[0], t.data[0] + t.data[1] - 1 do
        local fid = ctx.lists:get(i)
        local fe = ctx.fields:get(fid)
        if fe.name_id == name_id and band(fe.flags, FLAG_OPAQUE_KEY) == 0 then
            return fe, fid
        end
    end
    return nil
end

-- Look up an opaque-key field (FLAG_OPAQUE_KEY) by the variable name that serves as the key.
-- key_name_id: intern ID of the variable name used as the key (e.g. intern("Mappable")).
-- Returns (FieldEntry*, field_arena_id) or nil.
--: (Ctx, integer, integer) -> (FieldEntry | nil, integer | nil)
function M.table_opaque_field(ctx, tbl_tid, key_name_id)
    local t = ctx.types:get(tbl_tid)
    for i = t.data[0], t.data[0] + t.data[1] - 1 do
        local fid = ctx.lists:get(i)
        local fe = ctx.fields:get(fid)
        if band(fe.flags, FLAG_OPAQUE_KEY) ~= 0 and fe.name_id == key_name_id then
            return fe, fid
        end
    end
    return nil
end

-- Look up a named field in the meta slots of a table type.
-- Follows spread placeholders (name_id == -1) by resolving their inner type.
--: (Ctx, integer, integer) -> (FieldEntry | nil, integer | nil)
function M.table_meta_field(ctx, tbl_tid, name_id)
    local t = ctx.types:get(tbl_tid)
    for i = t.data[5], t.data[5] + t.data[6] - 1 do
        local fid = ctx.lists:get(i)
        --: FieldEntry
        local fe = ctx.fields:get(fid) --[[:! FieldEntry]]
        if fe.name_id == name_id then return fe, fid end
        if fe.name_id == -1 then
            -- Spread placeholder: resolve the inner type and search its meta slots.
            --: TypeSlot
            local sp_t  = ctx.types:get(M.find(ctx, fe.type_id)) --[[:! TypeSlot]]
            if sp_t.tag == TAG_SPREAD then
                local inner_tid = M.find(ctx, sp_t.data[0])
                --: TypeSlot
                local inner_t   = ctx.types:get(inner_tid) --[[:! TypeSlot]]
                if inner_t.tag == TAG_TABLE then
                    local found_fe, found_fid = M.table_meta_field(ctx, inner_tid, name_id)
                    if found_fe then return found_fe, found_fid end
                end
            end
        end
    end
    return nil
end

-- Subtract a type from a union (remove members matching exclude).
--: (Ctx, integer, integer) -> integer
function M.subtract(ctx, tid, exclude_tid)
    tid = M.find(ctx, tid)
    exclude_tid = M.find(ctx, exclude_tid)
    local t = ctx.types:get(tid)
    if t.tag ~= TAG_UNION then
        if M.types_equal(ctx, tid, exclude_tid) then return ctx.T_NEVER end
        return tid
    end
    --: { [integer]: integer, ... }
    local remaining = {}
    for i = t.data[0], t.data[0] + t.data[1] - 1 do
        local mid = M.find(ctx, ctx.lists:get(i))
        if not M.types_equal(ctx, mid, exclude_tid) then
            remaining[#remaining + 1] = mid
        end
    end
    if #remaining == 0 then return ctx.T_NEVER end
    if #remaining == 1 then return remaining[1] end
    return M.make_union(ctx, remaining)
end

--- Filter a union to members that also appear in ref_tid (set intersection for unions).
--- For non-union tid: return tid if it equals ref_tid, else T_NEVER.
--- Used when accumulating guard_narrowings with no arm_info (compound conditions).
--: (Ctx, integer, integer) -> integer
function M.filter_union(ctx, tid, ref_tid)
    tid     = M.find(ctx, tid)
    ref_tid = M.find(ctx, ref_tid)
    local t = ctx.types:get(tid)
    if t.tag ~= TAG_UNION then
        -- Non-union: subtract to check membership; if unchanged, tid is not in ref_tid.
        local after = M.find(ctx, M.subtract(ctx, ref_tid, tid))
        if M.types_equal(ctx, after, ref_tid) then return ctx.T_NEVER end
        return tid
    end
    --: { [integer]: integer, ... }
    local kept = {}
    for i = t.data[0], t.data[0] + t.data[1] - 1 do
        local mid = M.find(ctx, ctx.lists:get(i))
        -- mid is in ref_tid iff subtract(ref_tid, mid) != ref_tid
        local after = M.find(ctx, M.subtract(ctx, ref_tid, mid))
        if not M.types_equal(ctx, after, ref_tid) then
            kept[#kept + 1] = mid
        end
    end
    if #kept == 0 then return ctx.T_NEVER end
    if #kept == 1 then return kept[1] end
    return M.make_union(ctx, kept)
end

-- Narrow a union by field discriminant. positive=true: keep members where field COULD be lit_intern_id.
-- lit_kind defaults to LIT_STRING for backwards compat.
-- lit_intern_hi is only used when lit_kind == LIT_NUMBER (the high i32 of the i32x2-encoded double).
-- Applies LIT_NUMBER → LIT_INTEGER promotion: a LIT_NUMBER field matches a LIT_INTEGER discriminant
-- when the float value is integer-valued, mirroring the promotion in narrow.lua field_disc extraction.
--: (Ctx, integer, integer, integer, boolean, integer | nil, integer | nil) -> integer
function M.narrow_by_field(ctx, tid, field_name_id, lit_intern_id, positive, lit_kind, lit_intern_hi)
    lit_kind = lit_kind or LIT_STRING
    tid = M.find(ctx, tid)
    local t = ctx.types:get(tid)
    if t.tag ~= TAG_UNION then
        -- Single type: check if field definitely doesn't/does match
        if t.tag == TAG_TABLE then
            local fe = M.table_field(ctx, tid, field_name_id)
            if fe then
                local frt = M.find(ctx, fe.type_id or 0)
                local ft = ctx.types:get(frt)
                if ft.tag == TAG_LITERAL then
                    local definite = false
                    if ft.data[0] == lit_kind then
                        definite = (ft.data[1] == lit_intern_id)
                    elseif ft.data[0] == LIT_NUMBER and lit_kind == LIT_INTEGER then
                        -- Field is LIT_NUMBER; discriminant was promoted to LIT_INTEGER.
                        local fnum = i32x2_to_double(ft.data[1], ft.data[2])
                        if fnum % 1 == 0 and fnum >= -(2^31) and fnum <= 2^31 - 1 then
                            definite = (math.floor(fnum) == lit_intern_id)
                        end
                    end
                    if positive and not definite then return ctx.T_NEVER end
                    if not positive and definite then return ctx.T_NEVER end
                end
            end
        end
        return tid
    end
    --: { [integer]: integer, ... }
    local result = {}
    for i = t.data[0], t.data[0] + t.data[1] - 1 do
        local mid = M.find(ctx, ctx.lists:get(i))
        local mt = ctx.types:get(mid)
        local definite_match = false
        local possible_match = true
        if mt.tag == TAG_TABLE then
            local fe = M.table_field(ctx, mid, field_name_id)
            if fe then
                local frt = M.find(ctx, fe.type_id or 0)
                local ft = ctx.types:get(frt)
                if ft.tag == TAG_LITERAL then
                    if ft.data[0] == lit_kind then
                        definite_match = (ft.data[1] == lit_intern_id)
                    elseif ft.data[0] == LIT_NUMBER and lit_kind == LIT_INTEGER then
                        -- Field is LIT_NUMBER; discriminant was promoted to LIT_INTEGER.
                        -- Promote the field value for comparison.
                        local fnum = i32x2_to_double(ft.data[1], ft.data[2])
                        if fnum % 1 == 0 and fnum >= -(2^31) and fnum <= 2^31 - 1 then
                            definite_match = (math.floor(fnum) == lit_intern_id)
                        end
                    end
                    possible_match = definite_match
                end
            end
        elseif mt.tag ~= TAG_ANY and mt.tag ~= TAG_VAR then
            possible_match = false
        end
        if positive then
            if possible_match then result[#result + 1] = mid end
        else
            if not definite_match then result[#result + 1] = mid end
        end
    end
    if #result == 0 then return ctx.T_NEVER end
    if #result == 1 then return result[1] end
    return M.make_union(ctx, result)
end

-- Display a type as a human-readable string (cold path).
--: (Ctx, unknown, unknown) -> string
function M.display(ctx, tid, seen)
    if type(tid) ~= "number" then return "?" end
    tid = M.find(ctx, math.floor(tid))
    local t = ctx.types:get(tid)
    local tag = t.tag

    if tag == TAG_NIL      then return "nil" end
    if tag == TAG_BOOLEAN  then return "boolean" end
    if tag == TAG_NUMBER   then return "number" end
    if tag == TAG_STRING   then return "string" end
    if tag == TAG_ANY      then return "any" end
    if tag == TAG_NEVER    then return "never" end
    if tag == TAG_UNKNOWN  then return "unknown" end
    if tag == TAG_INTEGER  then return "integer" end
    if tag == TAG_CDATA    then return "cdata" end
    if tag == TAG_ENUM_MEMBER then
        local en = intern_mod.get(ctx.pool, t.data[0]) or "?"
        local mn = intern_mod.get(ctx.pool, t.data[1]) or "?"
        return en .. "." .. mn
    end

    if tag == TAG_VAR then
        -- After find(), still a TAG_VAR means unbound free variable.
        -- Display as anonymous type parameter '_', never as raw numeric ID.
        return "_"
    end
    if tag == TAG_ROWVAR then
        return "..._"
    end

    if tag == TAG_LITERAL then
        local kind = t.data[0]
        if kind == LIT_NIL     then return "nil" end
        if kind == LIT_BOOLEAN then return t.data[1] == 1 and "true" or "false" end
        if kind == LIT_STRING  then
            local s = intern_mod.get(ctx.pool, t.data[1])
            if type(s) == "string" then return '"' .. s .. '"' end
            return '"?"'
        end
        if kind == LIT_NUMBER  then
            return tostring(i32x2_to_double(t.data[1], t.data[2]))
        end
        if kind == LIT_INTEGER then return tostring(t.data[1]) end
    end

    if tag == TAG_FUNCTION then
        local parts = {}
        for i = t.data[0], t.data[0] + t.data[1] - 1 do
            parts[#parts + 1] = M.display(ctx, ctx.lists:get(i), seen)
        end
        if t.data[4] >= 0 then
            parts[#parts + 1] = "..." .. M.display(ctx, t.data[4], seen)
        end
        local rl = t.data[3]
        local ret
        if rl == 0 then
            ret = "()"
        elseif rl == 1 then
            ret = M.display(ctx, ctx.lists:get(t.data[2]), seen)
        else
            local rs = {}
            for i = t.data[2], t.data[2] + rl - 1 do
                rs[#rs + 1] = M.display(ctx, ctx.lists:get(i), seen)
            end
            ret = "(" .. table.concat(rs, ", ") .. ")"
        end
        return "(" .. table.concat(parts, ", ") .. ") -> " .. ret
    end

    if tag == TAG_TABLE then
        seen = seen or {}
        if seen[tid] then return "{...}" end
        seen[tid] = true
        local parts = {} --: { [integer]: string, ... }
        -- fields
        local field_names = {} --: { [integer]: { name: string, fe: FieldEntry }, ... }
        for i = t.data[0], t.data[0] + t.data[1] - 1 do
            local fid = ctx.lists:get(i)
            local fe = ctx.fields:get(fid)
            local name = intern_mod.get(ctx.pool, fe.name_id) or "?"
            field_names[#field_names + 1] = { name = name, fe = fe }
        end
        table.sort(field_names, function(a, b) return a.name < b.name end)
        for _, nf in ipairs(field_names) do
            local opt = band(nf.fe.flags, FLAG_OPTIONAL)   ~= 0 and "?" or ""
            local ro  = band(nf.fe.flags, FLAG_READONLY)   ~= 0 and "readonly " or ""
            local ok  = band(nf.fe.flags, FLAG_OPAQUE_KEY) ~= 0
            if ok then
                parts[#parts + 1] = "[" .. nf.name .. "]: " .. M.display(ctx, nf.fe.type_id, seen)
            else
                parts[#parts + 1] = ro .. nf.name .. opt .. ": " .. M.display(ctx, nf.fe.type_id, seen)
            end
        end
        -- indexers
        local is, il = t.data[2], t.data[3]
        local i = is
        while i < is + il - 1 do
            local kt = M.display(ctx, ctx.lists:get(i), seen)
            local vt = M.display(ctx, ctx.lists:get(i + 1), seen)
            parts[#parts + 1] = "[" .. kt .. "]: " .. vt
            i = i + 2
        end
        -- meta
        local meta_names = {} --: { [integer]: { name: string, fe: FieldEntry }, ... }
        for j = t.data[5], t.data[5] + t.data[6] - 1 do
            local fid = ctx.lists:get(j)
            local fe = ctx.fields:get(fid)
            local name = intern_mod.get(ctx.pool, fe.name_id) or "?"
            meta_names[#meta_names + 1] = { name = name, fe = fe }
        end
        table.sort(meta_names, function(a, b) return a.name < b.name end)
        for _, nf in ipairs(meta_names) do
            local opt = band(nf.fe.flags, FLAG_OPTIONAL) ~= 0 and "?" or ""
            parts[#parts + 1] = "#" .. nf.name .. opt .. ": " .. M.display(ctx, nf.fe.type_id, seen)
        end
        seen[tid] = nil
        if #parts == 0 then return "{}" end
        return "{ " .. table.concat(parts, ", ") .. " }"
    end

    if tag == TAG_UNION then
        local parts = {}
        --: { [string]: boolean, ... }
        local dedup = {}
        for i = t.data[0], t.data[0] + t.data[1] - 1 do
            local s = M.display(ctx, ctx.lists:get(i), seen)
            if not dedup[s] then dedup[s] = true; parts[#parts + 1] = s end
        end
        return table.concat(parts, " | ")
    end

    if tag == TAG_INTERSECTION then
        local parts = {}
        for i = t.data[0], t.data[0] + t.data[1] - 1 do
            parts[#parts + 1] = M.display(ctx, ctx.lists:get(i), seen)
        end
        return table.concat(parts, " & ")
    end

    if tag == TAG_TUPLE then
        local parts = {}
        for i = t.data[0], t.data[0] + t.data[1] - 1 do
            parts[#parts + 1] = M.display(ctx, ctx.lists:get(i), seen)
        end
        return "(" .. table.concat(parts, ", ") .. ")"
    end

    if tag == TAG_SPREAD then
        return "..." .. M.display(ctx, t.data[0], seen)
    end

    if tag == TAG_NOMINAL then
        return intern_mod.get(ctx.pool, t.data[0]) or "nominal"
    end

    if tag == TAG_NAMED then
        local name = intern_mod.get(ctx.pool, t.data[0]) or "?"
        local al = t.data[2]
        if al > 0 then
            local parts = {}
            for i = t.data[1], t.data[1] + al - 1 do
                parts[#parts + 1] = M.display(ctx, ctx.lists:get(i), seen)
            end
            return name .. "<" .. table.concat(parts, ", ") .. ">"
        end
        return name
    end

    if tag == TAG_MATCH_TYPE then
        return "match ... { ... }"
    end

    if tag == TAG_INTRINSIC then
        return "$" .. (intern_mod.get(ctx.pool, t.data[0]) or "?")
    end

    if tag == TAG_TYPE_CALL then
        local parts = {}
        for i = t.data[1], t.data[1] + t.data[2] - 1 do
            parts[#parts + 1] = M.display(ctx, ctx.lists:get(i), seen)
        end
        return M.display(ctx, t.data[0], seen) .. "(" .. table.concat(parts, ", ") .. ")"
    end

    if tag == TAG_FORALL then
        local parts = {}
        for i = t.data[0], t.data[0] + t.data[1] - 1 do
            parts[#parts + 1] = intern_mod.get(ctx.pool, ctx.lists:get(i)) or "?"
        end
        return "<" .. table.concat(parts, ", ") .. "> " .. M.display(ctx, t.data[2], seen)
    end

    return "?"
end

-- Display a type, truncating to max_len characters with "…" appended.
-- Keeps error messages readable for complex / deeply-nested types.
local TRUNC_LEN = 120
function M.display_short(ctx, tid, max_len)
    max_len = max_len or TRUNC_LEN
    local s = M.display(ctx, tid)
    if #s <= max_len then return s end
    return s:sub(1, max_len - 1) .. "\xe2\x80\xa6"  -- UTF-8 ellipsis (…)
end

-- Map from Lua type() string to type_id singleton
--: (Ctx, string) -> integer
function M.typeof_to_id(ctx, s)
    if s == "nil"      then return ctx.T_NIL end
    if s == "boolean"  then return ctx.T_BOOLEAN end
    if s == "number"   then return ctx.T_NUMBER end
    if s == "string"   then return ctx.T_STRING end
    if s == "table"    then return ctx.T_ANY end   -- unknown table type
    if s == "function" then return ctx.T_ANY end   -- unknown function type
    return ctx.T_ANY
end

-- ---------------------------------------------------------------------------
-- Table mutation helpers (used by constrain, cdef)
-- ---------------------------------------------------------------------------

--: (Ctx, integer) -> ({ [integer]: integer, ... }, { [integer]: integer, ... }, integer, { [integer]: integer, ... })
function M.snapshot_table(ctx, obj_tid)
    local ot = ctx.types:get(obj_tid)
    local fs, fl = ot.data[0], ot.data[1]
    local is2, il2 = ot.data[2], ot.data[3]
    local rv = ot.data[4]
    local ms, ml = ot.data[5], ot.data[6]
    local fields = {}
    for i = fs, fs + fl - 1 do fields[#fields + 1] = ctx.lists:get(i) end
    local indexers = {}
    local ix = is2
    while ix < is2 + il2 - 1 do
        indexers[#indexers + 1] = ctx.lists:get(ix)
        indexers[#indexers + 1] = ctx.lists:get(ix + 1)
        ix = ix + 2
    end
    local meta = {}
    for j = ms, ms + ml - 1 do meta[#meta + 1] = ctx.lists:get(j) end
    return fields, indexers, rv, meta
end

function M.patch_table(ctx, obj_tid, fields, indexers, rv, meta)
    local new_tbl = M.make_table(ctx, fields, indexers, rv, meta)
    local ot = ctx.types:get(obj_tid)
    local new_t = ctx.types:get(new_tbl)
    for k = 0, 6 do ot.data[k] = new_t.data[k] end
end

function M.table_add_field(ctx, obj_tid, field_id, field_type_id, flags)
    local fields, indexers, rv, meta = M.snapshot_table(ctx, obj_tid)
    fields[#fields + 1] = M.make_field(ctx, field_id, field_type_id, flags or 0)
    M.patch_table(ctx, obj_tid, fields, indexers, rv, meta)
end

return M
