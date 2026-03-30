-- lib/type/static/intrinsic.lua
-- Expansion logic for TAG_INTRINSIC type-level operations.
-- Called from constrain.lua's resolve_annotation_type when a TAG_TYPE_CALL
-- has a TAG_INTRINSIC callee.
--
-- Supported intrinsics:
--   $Keys<T>           — string literal union of field names in T
--   $Values<T>         — union of widened field value types in T (pairs complement)
--   $IpairsValues<T>   — union of numeric/positional field value types in T
--   $EachUnion<T, F>   — apply F to each member of union T, re-union results
--   $EachField<T, F>   — apply F to each field descriptor of T, collect into table
--   $Throw<...Msg>     — emit a diagnostic at the use site; returns never
--   $Catch<T, Default?> — suppress $Throw inside T; return Default (or never) if thrown

local defs       = require("lib.type.static.defs")
local types_mod  = require("lib.type.static.types")
local intern_mod = require("lib.type.static.intern")
local errors_mod = require("lib.type.static.errors")
local band       = require("bit").band

local TAG_TABLE        = defs.TAG_TABLE
local TAG_UNION        = defs.TAG_UNION
local TAG_TUPLE        = defs.TAG_TUPLE
local TAG_MATCH_TYPE   = defs.TAG_MATCH_TYPE
local TAG_NAMED        = defs.TAG_NAMED
local TAG_ANY          = defs.TAG_ANY
local TAG_LITERAL      = defs.TAG_LITERAL

local LIT_STRING  = defs.LIT_STRING
local LIT_BOOLEAN = defs.LIT_BOOLEAN

local FLAG_OPTIONAL = defs.FLAG_OPTIONAL
local FLAG_READONLY = defs.FLAG_READONLY

local M = {}

-- ---------------------------------------------------------------------------
-- $Keys<T>
-- ---------------------------------------------------------------------------
-- Produce a string literal union of the named field names of T.
-- If T is not a table, returns T_NEVER.
local function expand_keys(ctx, arg_ids)
    if #arg_ids ~= 1 then
        return ctx.T_NEVER
    end
    local t_tid = types_mod.find(ctx, arg_ids[1])
    local t = ctx.types:get(t_tid)
    if t.tag ~= TAG_TABLE then
        return ctx.T_NEVER
    end
    local members = {}
    for i = t.data[0], t.data[0] + t.data[1] - 1 do
        local fid = ctx.lists:get(i)
        local fe  = ctx.fields:get(fid)
        if fe.name_id >= 0 then  -- skip spread markers (name_id == -1)
            local lit = types_mod.make_literal(ctx, LIT_STRING, fe.name_id)
            members[#members + 1] = lit
        end
    end
    if #members == 0 then return ctx.T_NEVER end
    return types_mod.make_union(ctx, members)
end

-- ---------------------------------------------------------------------------
-- $EachUnion<T, F>
-- ---------------------------------------------------------------------------
-- Apply type-level function F to each member of union T.  Re-union results.
-- F must be a TAG_MATCH_TYPE or a TAG_NAMED alias.
-- For TAG_MATCH_TYPE: wrap each arm as a new match with just that member as param.
-- For TAG_NAMED: apply with one arg (the member).
local function apply_type_fn(ctx, fn_tid, member_tid)
    fn_tid = types_mod.find(ctx, fn_tid)
    local ft = ctx.types:get(fn_tid)

    if ft.tag == TAG_MATCH_TYPE then
        -- Build a new TAG_MATCH_TYPE with param=member_tid, same arms
        local id = types_mod.alloc_type(ctx, TAG_MATCH_TYPE)
        local mtt = ctx.types:get(id)
        mtt.data[0] = member_tid
        mtt.data[1] = ft.data[1]
        mtt.data[2] = ft.data[2]
        local match_mod = require("lib.type.static.match")
        return match_mod.evaluate(ctx, id)
    end

    if ft.tag == TAG_NAMED then
        local env_mod = require("lib.type.static.env")
        local resolved = env_mod.resolve_named_type(ctx, ctx.scope, ft.data[0], { member_tid })
        if resolved then return resolved end
    end

    -- Unknown function form — return T_NEVER for this arm
    return ctx.T_NEVER
end

local function expand_each_union(ctx, arg_ids)
    if #arg_ids ~= 2 then
        return ctx.T_NEVER
    end
    local union_tid = types_mod.find(ctx, arg_ids[1])
    local fn_tid    = arg_ids[2]
    local ut = ctx.types:get(union_tid)

    local results = {}
    if ut.tag == TAG_UNION then
        for i = ut.data[0], ut.data[0] + ut.data[1] - 1 do
            local member = types_mod.find(ctx, ctx.lists:get(i))
            results[#results + 1] = apply_type_fn(ctx, fn_tid, member)
        end
    else
        -- Single type — apply once
        results[1] = apply_type_fn(ctx, fn_tid, union_tid)
    end

    if #results == 0 then return ctx.T_NEVER end
    return types_mod.make_union(ctx, results)
end

-- ---------------------------------------------------------------------------
-- $EachField<T, F>
-- ---------------------------------------------------------------------------
-- Apply F to each field descriptor of table T.
-- F receives a table type: { key: "fieldname", value: V, optional: boolean, readonly: boolean }
-- F must return a table type with the same structure.
-- The output is a new table type assembled from F's results.
--
-- Field descriptor table type (synthesised per field):
--   { key: LIT_STRING(name), value: field_type, optional: LIT_BOOLEAN, readonly: LIT_BOOLEAN }
local function make_field_descriptor(ctx, fe)
    -- key: string literal of field name
    local key_id = types_mod.make_literal(ctx, LIT_STRING, fe.name_id)

    -- value: the field's type
    local val_id = types_mod.find(ctx, fe.type_id)

    -- optional: boolean literal
    local opt_val  = band(fe.flags, FLAG_OPTIONAL) ~= 0 and 1 or 0
    local opt_id   = types_mod.make_literal(ctx, LIT_BOOLEAN, opt_val)

    -- readonly: boolean literal
    local ro_val   = band(fe.flags, FLAG_READONLY) ~= 0 and 1 or 0
    local ro_id    = types_mod.make_literal(ctx, LIT_BOOLEAN, ro_val)

    local key_name_id     = intern_mod.intern(ctx.pool, "key")
    local val_name_id     = intern_mod.intern(ctx.pool, "value")
    local opt_name_id     = intern_mod.intern(ctx.pool, "optional")
    local ro_name_id      = intern_mod.intern(ctx.pool, "readonly")

    local fids = {
        types_mod.make_field(ctx, key_name_id, key_id,  0),
        types_mod.make_field(ctx, val_name_id, val_id,  0),
        types_mod.make_field(ctx, opt_name_id, opt_id,  0),
        types_mod.make_field(ctx, ro_name_id,  ro_id,   0),
    }
    return types_mod.make_table(ctx, fids, {}, -1, {})
end

-- Extract a field from a descriptor table result.
-- Returns the type_id for the named slot, or nil.
local function descriptor_field(ctx, tbl_tid, slot_name)
    tbl_tid = types_mod.find(ctx, tbl_tid)
    local t = ctx.types:get(tbl_tid)
    if t.tag ~= TAG_TABLE then return nil end
    local name_id = intern_mod.intern(ctx.pool, slot_name)
    local fe = types_mod.table_field(ctx, tbl_tid, name_id)
    if fe then return types_mod.find(ctx, fe.type_id) end
    return nil
end

-- Extract a single descriptor table (tag TAG_TABLE) and push the resulting
-- output field onto out_fields.  fe is the original FieldEntry (used for
-- fallback name/type when the descriptor doesn't supply them).
local function push_descriptor_field(ctx, out_fields, desc_tid, fe)
    desc_tid = types_mod.find(ctx, desc_tid)
    local key_tid   = descriptor_field(ctx, desc_tid, "key")
    local val_tid   = descriptor_field(ctx, desc_tid, "value")
    local opt_tid   = descriptor_field(ctx, desc_tid, "optional")
    local ro_tid    = descriptor_field(ctx, desc_tid, "readonly")

    -- Determine output field name from key slot
    -- Expect a LIT_STRING result; fall back to original name
    local out_name_id = fe.name_id
    if key_tid then
        local kt = ctx.types:get(key_tid)
        if kt.tag == defs.TAG_LITERAL and kt.data[0] == LIT_STRING then
            out_name_id = kt.data[1]
        end
    end

    -- Determine output field type
    local out_val_tid = val_tid or types_mod.find(ctx, fe.type_id)

    -- Determine flags
    local out_flags = 0
    if opt_tid then
        local ot = ctx.types:get(opt_tid)
        if ot.tag == defs.TAG_LITERAL and ot.data[0] == LIT_BOOLEAN and ot.data[1] == 1 then
            out_flags = out_flags + FLAG_OPTIONAL
        end
    end
    if ro_tid then
        local rt = ctx.types:get(ro_tid)
        if rt.tag == defs.TAG_LITERAL and rt.data[0] == LIT_BOOLEAN and rt.data[1] == 1 then
            out_flags = out_flags + FLAG_READONLY
        end
    end

    out_fields[#out_fields + 1] = types_mod.make_field(ctx, out_name_id, out_val_tid, out_flags)
end

-- Interpret the result of F(descriptor) as a tuple of descriptors.
-- Returns a list of descriptor type IDs to add to the output (0 = drop).
--
-- Three representations accepted:
--   TAG_TUPLE (paren-tuple):  {  elements via lists  }
--   TAG_TABLE empty closed:   {} from annotation → brace-empty-tuple → drop
--   TAG_TABLE positional:     { D } or { D1, D2 } from annotation → brace-positional-tuple
--   anything else:            backward-compat single descriptor
local function collect_result_descriptors(ctx, result_tid, out)
    result_tid = types_mod.find(ctx, result_tid)
    local rt = ctx.types:get(result_tid)

    if rt.tag == TAG_TUPLE then
        -- Paren-tuple: () = drop, (D1, D2) = expand.
        for j = rt.data[0], rt.data[0] + rt.data[1] - 1 do
            out[#out + 1] = types_mod.find(ctx, ctx.lists:get(j))
        end
        return
    end

    if rt.tag == TAG_TABLE then
        local fl = rt.data[1]   -- named fields count
        local il = rt.data[3]   -- indexer list length (pairs: il/2 entries)
        local rv = rt.data[4]   -- row var (-1 = closed)
        if fl == 0 and rv == -1 then
            if il == 0 then
                -- {} (empty closed table) → brace-empty-tuple: drop the field.
                return
            else
                -- { D } or { D1, D2 } → positional entries → brace-positional-tuple.
                -- Indexer list is stored as pairs (key_type, val_type).
                -- Each positional entry D becomes a descriptor element.
                local is = rt.data[2]
                local j = is + 1  -- +1: skip key type of first pair, take value type
                while j < is + il do
                    out[#out + 1] = types_mod.find(ctx, ctx.lists:get(j))
                    j = j + 2  -- advance past (key, value) pair
                end
                return
            end
        end
    end

    -- Backward compat: non-tuple result treated as single descriptor.
    out[#out + 1] = result_tid
end

local function expand_each_field_table(ctx, tbl_tid, fn_tid)
    local tt = ctx.types:get(tbl_tid)
    if tt.tag ~= TAG_TABLE then
        return ctx.T_NEVER
    end

    local out_fields = {}

    for i = tt.data[0], tt.data[0] + tt.data[1] - 1 do
        local fid = ctx.lists:get(i)
        local fe  = ctx.fields:get(fid)
        if fe.name_id >= 0 then  -- skip spreads
            -- Build descriptor table for this field
            local desc_tid = make_field_descriptor(ctx, fe)

            -- Apply F to the descriptor — collect zero or more output descriptors.
            local result_tid = apply_type_fn(ctx, fn_tid, desc_tid)
            local descs = {}
            collect_result_descriptors(ctx, result_tid, descs)
            for _, d_tid in ipairs(descs) do
                push_descriptor_field(ctx, out_fields, d_tid, fe)
            end
        end
    end

    return types_mod.make_table(ctx, out_fields, {}, -1, {})
end

local function expand_each_field(ctx, arg_ids)
    if #arg_ids ~= 2 then
        return ctx.T_NEVER
    end
    local tbl_tid = types_mod.find(ctx, arg_ids[1])
    local fn_tid  = arg_ids[2]
    local tt = ctx.types:get(tbl_tid)

    -- any input -> any output (no field iteration possible)
    if tt.tag == TAG_ANY then
        return ctx.T_ANY
    end

    -- union input -> distribute over each arm and union results
    if tt.tag == TAG_UNION then
        local arms = {}
        for i = tt.data[0], tt.data[0] + tt.data[1] - 1 do
            local member_tid = types_mod.find(ctx, ctx.lists:get(i))
            arms[#arms + 1] = expand_each_field_table(ctx, member_tid, fn_tid)
        end
        if #arms == 0 then return ctx.T_NEVER end
        return types_mod.make_union(ctx, arms)
    end

    -- single table input
    return expand_each_field_table(ctx, tbl_tid, fn_tid)
end

-- ---------------------------------------------------------------------------
-- $Values<T> and $IpairsValues<T>
-- ---------------------------------------------------------------------------
-- $Values<T>: union of widened field value types in T.
--   - TAG_TABLE with indexer: return indexer value type
--   - TAG_TABLE with only named fields: return union of widen(field.type)
--   - TAG_TABLE empty/open with no fields: return T_UNKNOWN
--   - TAG_UNION: return union of $Values<arm> for each arm
--   - TAG_INTERSECTION: return $Values<first member that is TAG_TABLE>
--   - TAG_ANY/TAG_UNKNOWN/TAG_VAR/other: return T_UNKNOWN
--   - TAG_NEVER: return T_NEVER
--
-- $IpairsValues<T>: restricted to numeric indexers and positional fields.
--   - TAG_TABLE with integer indexer: return indexer value type
--   - TAG_TABLE with positional fields: return union of their value types (widened)
--   - Otherwise: return T_UNKNOWN
local function extract_values(ctx, T_tid, ipairs_mode)
    T_tid = types_mod.find(ctx, T_tid)
    local T_t = ctx.types:get(T_tid)

    -- TAG_NEVER: return never
    if T_t.tag == defs.TAG_NEVER then
        return ctx.T_NEVER
    end

    -- TAG_UNION: distribute over each arm
    if T_t.tag == TAG_UNION then
        local members = {}
        for i = T_t.data[0], T_t.data[0] + T_t.data[1] - 1 do
            local arm_tid = types_mod.find(ctx, ctx.lists:get(i))
            members[#members + 1] = extract_values(ctx, arm_tid, ipairs_mode)
        end
        if #members == 0 then return ctx.T_NEVER end
        return types_mod.make_union(ctx, members)
    end

    -- TAG_INTERSECTION: first TAG_TABLE member
    if T_t.tag == defs.TAG_INTERSECTION then
        for i = T_t.data[0], T_t.data[0] + T_t.data[1] - 1 do
            local arm_tid = types_mod.find(ctx, ctx.lists:get(i))
            local arm_t = ctx.types:get(arm_tid)
            if arm_t.tag == TAG_TABLE then
                return extract_values(ctx, arm_tid, ipairs_mode)
            end
        end
        return ctx.T_UNKNOWN
    end

    -- Non-table: return unknown
    if T_t.tag ~= TAG_TABLE then
        return ctx.T_UNKNOWN
    end

    if ipairs_mode then
        -- ipairs: prefer integer indexer
        if T_t.data[3] >= 2 then
            local j = T_t.data[2]
            while j < T_t.data[2] + T_t.data[3] - 1 do
                local kt = ctx.types:get(types_mod.find(ctx, ctx.lists:get(j)))
                if kt.tag == defs.TAG_NUMBER or kt.tag == defs.TAG_INTEGER then
                    return types_mod.find(ctx, ctx.lists:get(j + 1))
                end
                j = j + 2
            end
        end
        -- Positional fields: widen value types
        if T_t.data[1] > 0 then
            local val_members = {}
            for i = T_t.data[0], T_t.data[0] + T_t.data[1] - 1 do
                local fid = ctx.lists:get(i)
                local fe  = ctx.fields:get(fid)
                if fe.name_id >= 0 then
                    val_members[#val_members + 1] = types_mod.widen(ctx, fe.type_id)
                end
            end
            if #val_members == 1 then return val_members[1] end
            if #val_members > 1 then return types_mod.make_union(ctx, val_members) end
        end
        return ctx.T_UNKNOWN
    else
        -- pairs: prefer indexer value type
        if T_t.data[3] >= 2 then
            return types_mod.find(ctx, ctx.lists:get(T_t.data[2] + 1))
        end
        -- Named fields: widen value types
        if T_t.data[1] > 0 then
            local val_members = {}
            for i = T_t.data[0], T_t.data[0] + T_t.data[1] - 1 do
                local fid = ctx.lists:get(i)
                local fe  = ctx.fields:get(fid)
                if fe.name_id >= 0 then
                    val_members[#val_members + 1] = types_mod.widen(ctx, fe.type_id)
                end
            end
            if #val_members == 0 then return ctx.T_UNKNOWN end
            if #val_members == 1 then return val_members[1] end
            return types_mod.make_union(ctx, val_members)
        end
        return ctx.T_UNKNOWN
    end
end

-- ---------------------------------------------------------------------------
-- $PairsReturn<T> and $IpairsReturn<T>  (intrinsic helpers kept for build_iter_triple)
-- ---------------------------------------------------------------------------
-- K/V extraction rules for pairs:
--   - TAG_TABLE with indexer: K = indexer key type, V = indexer value type
--   - TAG_TABLE with only named fields (no indexer): K = string, V = union of field value types
--   - TAG_TABLE with no indexer and no fields (empty open table): K = string, V = unknown
--   - Anything else (TAG_VAR, TAG_ANY, TAG_UNKNOWN, etc.): K = unknown, V = unknown
--
-- K/V extraction rules for ipairs:
--   - K is always integer
--   - V = numeric indexer value type (integer key), or union of positional field value types
--   - If neither found: V = unknown

-- Extract K and V types from a table type for pairs().
local function extract_pairs_kv(ctx, T_tid)
    T_tid = types_mod.find(ctx, T_tid)
    local T_t = ctx.types:get(T_tid)
    if T_t.tag ~= TAG_TABLE then
        -- Non-table (any, unknown, var, etc.): return unknown, unknown
        return ctx.T_UNKNOWN, ctx.T_UNKNOWN
    end
    -- Check for an indexer
    if T_t.data[3] >= 2 then
        local K_tid = types_mod.find(ctx, ctx.lists:get(T_t.data[2]))
        local V_tid = types_mod.find(ctx, ctx.lists:get(T_t.data[2] + 1))
        return K_tid, V_tid
    end
    -- No indexer: use named fields
    if T_t.data[1] > 0 then
        local val_members = {}
        for i = T_t.data[0], T_t.data[0] + T_t.data[1] - 1 do
            local fid = ctx.lists:get(i)
            local fe  = ctx.fields:get(fid)
            if fe.name_id >= 0 then  -- skip spread markers
                -- Widen literals (e.g. LIT_INTEGER(1) -> integer) so that
                -- `for k, v in pairs({ x = 1, y = "hi" })` gives v: integer | string.
                val_members[#val_members + 1] = types_mod.widen(ctx, fe.type_id)
            end
        end
        local V_tid
        if #val_members == 0 then
            V_tid = ctx.T_UNKNOWN
        elseif #val_members == 1 then
            V_tid = val_members[1]
        else
            V_tid = types_mod.make_union(ctx, val_members)
        end
        return ctx.T_STRING, V_tid
    end
    -- Empty or open table: K=string (Lua's pairs always yields string keys for plain tables)
    return ctx.T_STRING, ctx.T_UNKNOWN
end

-- Extract V type from a table type for ipairs() (K is always integer).
local function extract_ipairs_v(ctx, T_tid)
    T_tid = types_mod.find(ctx, T_tid)
    local T_t = ctx.types:get(T_tid)
    if T_t.tag ~= TAG_TABLE then
        return ctx.T_UNKNOWN
    end
    -- Look for an integer-compatible indexer
    if T_t.data[3] >= 2 then
        local j = T_t.data[2]
        while j < T_t.data[2] + T_t.data[3] - 1 do
            local kt = ctx.types:get(types_mod.find(ctx, ctx.lists:get(j)))
            if kt.tag == defs.TAG_NUMBER or kt.tag == defs.TAG_INTEGER then
                return types_mod.find(ctx, ctx.lists:get(j + 1))
            end
            j = j + 2
        end
    end
    -- No integer indexer: try positional (named "1","2",...) fields
    -- Collect value types from all named fields (positional array entries).
    -- Widen literals so `ipairs({1,2,3})` yields v: integer, not v: 1|2|3.
    if T_t.data[1] > 0 then
        local val_members = {}
        for i = T_t.data[0], T_t.data[0] + T_t.data[1] - 1 do
            local fid = ctx.lists:get(i)
            local fe  = ctx.fields:get(fid)
            if fe.name_id >= 0 then
                val_members[#val_members + 1] = types_mod.widen(ctx, fe.type_id)
            end
        end
        if #val_members == 1 then return val_members[1] end
        if #val_members > 1 then return types_mod.make_union(ctx, val_members) end
    end
    return ctx.T_UNKNOWN
end

-- Build the iterator triple tuple: (iter_fn, T, K?)
-- iter_fn: (T, K?) -> (K, V)
-- The return key is K (not K?) because the for-in body only executes when the
-- iterator returns a non-nil first value.  Using K? in return position causes
-- false-positive arithmetic errors on loop index variables in the body.
-- The initial key in the triple is K? (nil on the very first call).
local function build_iter_triple(ctx, T_tid, K_tid, V_tid)
    -- K? = K | nil  (initial key is nil on the first call)
    local K_opt_tid = types_mod.make_union(ctx, { K_tid, ctx.T_NIL })
    -- iter_fn: (T, K?) -> (K, V)  — K non-optional: body only runs when K is non-nil
    local iter_fn_tid = types_mod.make_func(ctx, { T_tid, K_opt_tid }, { K_tid, V_tid }, -1, nil)
    -- triple: (iter_fn, T, K?)
    return types_mod.make_tuple(ctx, { iter_fn_tid, T_tid, K_opt_tid })
end

local function expand_pairs_return(ctx, arg_ids)
    if #arg_ids ~= 1 then return ctx.T_NEVER end
    local T_tid = types_mod.find(ctx, arg_ids[1])
    local K_tid, V_tid = extract_pairs_kv(ctx, T_tid)
    return build_iter_triple(ctx, T_tid, K_tid, V_tid)
end

local function expand_ipairs_return(ctx, arg_ids)
    if #arg_ids ~= 1 then return ctx.T_NEVER end
    local T_tid = types_mod.find(ctx, arg_ids[1])
    local V_tid = extract_ipairs_v(ctx, T_tid)
    return build_iter_triple(ctx, T_tid, ctx.T_INTEGER, V_tid)
end

-- ---------------------------------------------------------------------------
-- $Require<T>
-- ---------------------------------------------------------------------------
-- Type-level require: given a string literal type T, look up the declared
-- module type for that module name.  Returns the declared type if found,
-- T_UNKNOWN otherwise.
--
-- Used by the generic function declaration:
--   declare require: <T: string>(module: T) -> $Require<T>
-- When T is bound to LIT_STRING("mod.name"), $Require<T> evaluates to the
-- type declared via --:: module "mod.name": { ... }.
local function expand_require(ctx, arg_ids)
    if #arg_ids ~= 1 then return ctx.T_UNKNOWN end
    local T_tid = types_mod.find(ctx, arg_ids[1])
    local T_t = ctx.types:get(T_tid)
    if T_t.tag == TAG_LITERAL and T_t.data[0] == LIT_STRING then
        local module_name = intern_mod.get(ctx.pool, T_t.data[1])
        if module_name then
            -- Side effect: record module name so NODE_LOCAL_STMT can populate
            -- ctx.require_sources (used by LSP go-to-def).
            ctx._last_require_mod = module_name
            -- module_types: declared via --:: module "name": T (prelude or user file).
            -- Checked before cri_loader so explicit declarations always win.
            if ctx.module_types then
                local declared = ctx.module_types[module_name]
                if declared then return declared end
            end
            -- cri_loader: resolve cross-file types from .cri cache.
            if ctx.cri_loader then
                local exports, aliases = ctx.cri_loader(ctx, module_name)
                if exports then
                    ctx._last_require_aliases = aliases
                    return exports
                end
                -- cri_loader present but unresolvable: fall through to T_ANY for
                -- error recovery (same behaviour as the old special case).
                return ctx.T_ANY
            end
            -- No cri_loader and no module declaration: T_UNKNOWN forces narrowing.
        end
    end
    return ctx.T_UNKNOWN
end

-- ---------------------------------------------------------------------------
-- $Opaque<T>
-- ---------------------------------------------------------------------------
-- Produces a TAG_NOMINAL type with a unique identity per (call site, T).
-- The identity is a content hash of (stable_id, T_fingerprint), making it
-- deterministic across check runs for the same source file — unlike a
-- per-run counter which is unstable once multiple nominal types exist.
--
-- stable_id: an int32 content hash of "filename:ann_tid" stored in
--   TAG_TYPE_CALL.data[3] by constrain.lua. This is stable for the same
--   source content (annotation parser is deterministic) and globally unique
--   due to the filename prefix.
--
-- T_fingerprint: a stable integer derived from T's structure. Primitive
--   types use their tag. TAG_NOMINAL uses its own stable identity. Complex
--   structural types fall back to tag*0x1000+T (per-run, but at least unique
--   within a run). This means Schema<{x:integer}> is not cross-run stable,
--   but Schema<integer>, Schema<string>, etc. are.

local fnv31   = defs.fnv31
local TAG_NOMINAL_I = defs.TAG_NOMINAL

local function T_fingerprint(ctx, T)
    local t = ctx.types:get(T)
    local tag = t.tag
    if tag == defs.TAG_INTEGER  then return 1 end
    if tag == defs.TAG_NUMBER   then return 2 end
    if tag == defs.TAG_STRING   then return 3 end
    if tag == defs.TAG_BOOLEAN  then return 4 end
    if tag == defs.TAG_NIL      then return 5 end
    if tag == defs.TAG_ANY      then return 6 end
    if tag == defs.TAG_NEVER    then return 7 end
    if tag == TAG_NOMINAL_I     then return t.data[1] end  -- recursive: its own stable id
    return tag * 0x1000 + T  -- structural types: per-run unique, not cross-run stable
end

local function expand_opaque(ctx, arg_ids, stable_id)
    if #arg_ids < 1 or #arg_ids > 2 then return ctx.T_NEVER end
    local T = types_mod.find(ctx, arg_ids[1])
    -- Derive a deterministic nominal identity from call site + T type.
    -- If stable_id is 0 (legacy / unset), fall back to per-run counter.
    local nominal_id
    if stable_id ~= 0 then
        nominal_id = fnv31(tostring(stable_id) .. ":" .. tostring(T_fingerprint(ctx, T)))
    else
        ctx.nominal_id = ctx.nominal_id + 1
        nominal_id = ctx.nominal_id
    end
    -- Cache to avoid allocating duplicate TAG_NOMINAL nodes per run.
    if not ctx._opaque_cache then ctx._opaque_cache = {} end
    local cached = ctx._opaque_cache[nominal_id]
    if cached then return cached end
    local opaque_name_id = intern_mod.intern(ctx.pool, "Opaque")
    local result = types_mod.make_nominal(ctx, opaque_name_id, nominal_id, T)
    ctx._opaque_cache[nominal_id] = result
    -- Track which nominal_ids were produced by $Opaque (vs --:: newtype).
    -- solve.lua uses this to block field access on opaque types.
    if not ctx._opaque_nominals then ctx._opaque_nominals = {} end
    ctx._opaque_nominals[nominal_id] = true

    -- Two-arg form: $Opaque<T, U> — U is the exposed structural view.
    -- Validate that U is a structural subtype of T (all fields in U exist in T
    -- with compatible types), then store U in the side table.
    if #arg_ids >= 2 then
        local U_tid = types_mod.find(ctx, arg_ids[2])
        local ut = ctx.types:get(U_tid)
        local t  = ctx.types:get(T)
        -- Only validate when U is a table type and T is a table type.
        if ut.tag == TAG_TABLE and t.tag == TAG_TABLE then
            local unify_mod = require("lib.type.static.unify")
            local errors_mod = require("lib.type.static.errors")
            for i = ut.data[0], ut.data[0] + ut.data[1] - 1 do
                local fid = ctx.lists:get(i)
                local ufe = ctx.fields:get(fid)
                if ufe.name_id >= 0 then
                    local tfe = types_mod.table_field(ctx, T, ufe.name_id)
                    local fname = intern_mod.get(ctx.pool, ufe.name_id) or "?"
                    if not tfe then
                        errors_mod.error(ctx.err, ctx.filename, 0, 0,
                            "$Opaque<T, U>: exposed field `" .. fname
                            .. "` does not exist in inner type T")
                    else
                        -- U's field type must be compatible with T's field type.
                        if not unify_mod.try_unify(ctx, types_mod.find(ctx, ufe.type_id),
                                                        types_mod.find(ctx, tfe.type_id), {}) then
                            errors_mod.error(ctx.err, ctx.filename, 0, 0,
                                "$Opaque<T, U>: exposed field `" .. fname
                                .. "` has incompatible type in inner type T")
                        end
                    end
                end
            end
        end
        if not ctx._opaque_view then ctx._opaque_view = {} end
        ctx._opaque_view[nominal_id] = U_tid
    end

    return result
end

-- ---------------------------------------------------------------------------
-- $Throw<...Msg>
-- ---------------------------------------------------------------------------
-- Variadic. Each arg is either a string literal (emitted verbatim) or a type
-- (rendered via types_mod.display). Concatenates args to form the diagnostic
-- message. Emits a diagnostic at the current use-site location and returns
-- T_NEVER. If ctx.catch_mode is true, does not emit — instead sets
-- ctx.catch_threw = true and returns T_NEVER silently.
local function expand_throw(ctx, arg_ids)
    -- Build the message by concatenating each arg.
    local parts = {}
    for _, tid in ipairs(arg_ids) do
        local resolved = types_mod.find(ctx, tid)
        local t = ctx.types:get(resolved)
        -- String literal arg: emit the raw string value without quotes.
        if t.tag == TAG_LITERAL and t.data[0] == LIT_STRING then
            local s = intern_mod.get(ctx.pool, t.data[1])
            parts[#parts + 1] = s or ""
        else
            -- Type arg: render to display form.
            parts[#parts + 1] = types_mod.display(ctx, resolved)
        end
    end
    local msg = table.concat(parts)
    if ctx.catch_mode then
        ctx.catch_threw = true
    else
        local line = ctx._ann_warn_line or 0
        errors_mod.error(ctx.err, ctx.filename, line, 0, msg)
    end
    return ctx.T_NEVER
end

-- ---------------------------------------------------------------------------
-- $Catch<T, Default?>
-- ---------------------------------------------------------------------------
-- The first arg (T) is already resolved under catch_mode = true (set by
-- constrain.lua before arg resolution). If any $Throw fired during T's
-- resolution, ctx.catch_threw is true. Return Default (arg 2) when caught,
-- or T_NEVER if Default is omitted. If no throw occurred, return T as-is.
local function expand_catch(ctx, arg_ids)
    if #arg_ids < 1 then
        return ctx.T_NEVER
    end
    local t_tid = types_mod.find(ctx, arg_ids[1])
    if ctx.catch_threw then
        -- A $Throw was intercepted inside T.
        if #arg_ids >= 2 then
            return types_mod.find(ctx, arg_ids[2])
        end
        return ctx.T_NEVER
    end
    -- No throw: return T unchanged.
    return t_tid
end

-- ---------------------------------------------------------------------------
-- Public entry point
-- ---------------------------------------------------------------------------

-- Exported so that solve.lua can build iterator triples when evaluating
-- PairsReturn<T>/IpairsReturn<T> match aliases that return (K, V) 2-tuples.
-- See resolve_deferred_intrinsic in solve.lua.
M.build_iter_triple = build_iter_triple

-- expand(ctx, name_id, arg_ids, stable_id) -> type_id
-- Called when a TAG_TYPE_CALL has a TAG_INTRINSIC callee.
-- name_id:   intern ID of the intrinsic name (string)
-- arg_ids:   Lua array of resolved type_ids (the type arguments)
-- stable_id: fnv31(filename:ann_tid) stored in TAG_TYPE_CALL.data[3];
--            0 means not set (legacy cri or non-deferred path without filename)
function M.expand(ctx, name_id, arg_ids, stable_id)
    local name = intern_mod.get(ctx.pool, name_id) or ""

    if name == "EachUnion" then
        return expand_each_union(ctx, arg_ids)
    end

    if name == "EachField" then
        return expand_each_field(ctx, arg_ids)
    end

    if name == "Opaque" then
        return expand_opaque(ctx, arg_ids, stable_id)
    end

    if name == "Require" then
        return expand_require(ctx, arg_ids)
    end

    if name == "Throw" then
        return expand_throw(ctx, arg_ids)
    end

    if name == "Catch" then
        return expand_catch(ctx, arg_ids)
    end

    -- Unknown intrinsic: return T_NEVER so downstream errors are informative
    return ctx.T_NEVER
end

return M
