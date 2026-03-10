-- lib/type/static/cri_write.lua
-- Serialize a set of named type exports from a checked ctx into a .cri binary blob.
--
-- Usage:
--   local cri_write = require("lib.type.static.cri_write")
--   local bytes = cri_write.serialize(ctx, exports)
--   -- exports: { [name_string] = type_id, ... }
--
-- Returns a Lua string containing the raw binary .cri file contents,
-- with the SHA-256 content hash filled in at header offset 12.
--
-- TypeSlot data layouts (from types.lua):
--   TAG_VAR/ROWVAR:     data[0]=var_id, data[1]=level, data[2]=parent_tid(-1=unbound)
--   TAG_LITERAL:        data[0]=lit_kind, data[1]=value (intern_id or 0/1)
--   TAG_FUNCTION:       data[0..1]=params(list), data[2..3]=returns(list), data[4]=vararg_tid
--   TAG_TABLE:          data[0..1]=fields(field_ids in list), data[2..3]=indexers(tid pairs in list),
--                       data[4]=row_var_tid, data[5..6]=meta(field_ids in list)
--   TAG_UNION/etc:      data[0..1]=members(list)
--   TAG_NOMINAL:        data[0]=name_id, data[1]=identity, data[2]=underlying_tid
--   TAG_NAMED:          data[0]=name_id, data[1..2]=args(list)
--   TAG_MATCH_TYPE:     data[0]=param_tid, data[1..2]=arms(list, tid pairs)
--   TAG_FORALL:         data[0..1]=type_params(name_ids in list), data[2]=body_tid
--   TAG_SPREAD:         data[0]=inner_tid
--   TAG_INTRINSIC:      data[0]=name_id
--   TAG_TYPE_CALL:      data[0]=callee_tid, data[1..2]=args(list)
--
-- In .cri format, TAG_TABLE.data[0..1] and data[5..6] become direct field pool indices
-- (the list-of-field-IDs indirection is eliminated at serialization time).

local ffi    = require("ffi")
local bit    = require("bit")
local sha256 = require("lib.type.static.sha256")
local defs   = require("lib.type.static.defs")
local intern_mod = require("lib.type.static.intern")

local band, rshift, tobit = bit.band, bit.rshift, bit.tobit

local TAG_LITERAL     = defs.TAG_LITERAL
local TAG_FUNCTION    = defs.TAG_FUNCTION
local TAG_TABLE       = defs.TAG_TABLE
local TAG_UNION       = defs.TAG_UNION
local TAG_INTERSECTION= defs.TAG_INTERSECTION
local TAG_TUPLE       = defs.TAG_TUPLE
local TAG_NOMINAL     = defs.TAG_NOMINAL
local TAG_MATCH_TYPE  = defs.TAG_MATCH_TYPE
local TAG_TYPE_CALL   = defs.TAG_TYPE_CALL
local TAG_FORALL      = defs.TAG_FORALL
local TAG_SPREAD      = defs.TAG_SPREAD
local TAG_NAMED       = defs.TAG_NAMED
local TAG_VAR         = defs.TAG_VAR
local TAG_ROWVAR      = defs.TAG_ROWVAR
local TAG_INTRINSIC   = defs.TAG_INTRINSIC

local LIT_STRING      = defs.LIT_STRING

local M = {}

-- ---------------------------------------------------------------------------
-- Union-find resolve (non-mutating, follows data[2] chain)
-- ---------------------------------------------------------------------------
local function resolve(ctx, tid)
    if tid < 0 then return tid end
    for _ = 1, 64 do
        local slot = ctx.types:get(tid)
        if slot.tag ~= TAG_VAR and slot.tag ~= TAG_ROWVAR then return tid end
        if slot.data[2] < 0 then return tid end  -- unbound
        tid = slot.data[2]
    end
    return tid
end

-- ---------------------------------------------------------------------------
-- Reachability walk
-- ---------------------------------------------------------------------------
-- Collects all types, strings, type-list ranges, and field entries reachable
-- from the given root type IDs.
--
-- For TAG_TABLE, the fields/meta are stored in ctx as list-pool ranges of
-- field_arena IDs.  We flatten these into a field array directly.
--
-- Results:
--   seen_types[old_tid]  -> new 0-based type index
--   type_order[i]        -> old_tid
--   seen_strings[old_sid]-> new 0-based string index
--   str_order[i]         -> old_sid
--   field_entries[i]     -> {new_name_id, new_type_id (deferred), optional, old_type_id}
--   type_list_ranges     -> collected (start,len) pairs from ctx.lists (type IDs only)
--   list_range_seen["s,l"]-> index in type_list_ranges (0-based new start, deferred)

local function collect(ctx, root_tids)
    local seen_types   = {}  -- old resolved tid -> new 0-based index
    local type_order   = {}  -- [1..n] = old resolved tid

    local seen_strings = {}  -- old sid -> new 0-based index
    local str_order    = {}  -- [1..n] = old sid

    -- Flat field array (each entry = {old_name_sid, old_type_tid, optional(bool)})
    -- Index is 0-based; new field pool index assigned in order of insertion.
    local field_entries = {}  -- [1..n] = {old_name_sid, old_tid, optional}

    -- Type-list ranges (for function params/returns, union members, etc.)
    -- Maps "start,len" of ctx.lists range to insertion order.
    local list_range_seen  = {}  -- "s,l" -> index into list_ranges (1-based)
    local list_ranges      = {}  -- [i] = {start, len}

    local function intern_str(sid)
        if sid < 0 then return end
        if not seen_strings[sid] then
            local idx = #str_order  -- 0-based new index
            seen_strings[sid] = idx
            str_order[#str_order + 1] = sid
        end
    end

    local function intern_list_range(s, l)
        if l == 0 then return end
        local key = s .. "," .. l
        if not list_range_seen[key] then
            list_range_seen[key] = #list_ranges  -- 0-based new start (filled later)
            list_ranges[#list_ranges + 1] = {s, l}
        end
    end

    local walk  -- forward decl

    local function walk_tid(tid)
        if tid < 0 then return end
        tid = resolve(ctx, tid)
        if seen_types[tid] then return end
        local new_idx = #type_order  -- 0-based
        seen_types[tid] = new_idx
        type_order[#type_order + 1] = tid

        local slot = ctx.types:get(tid)
        local tag  = slot.tag

        if tag == TAG_LITERAL then
            -- data[0]=lit_kind, data[1]=value (intern_id for string/number)
            if slot.data[0] == LIT_STRING then
                intern_str(slot.data[1])
            end

        elseif tag == TAG_FUNCTION then
            -- data[0..1]=params list, data[2..3]=returns list, data[4]=vararg_tid
            intern_list_range(slot.data[0], slot.data[1])
            intern_list_range(slot.data[2], slot.data[3])
            for i = slot.data[0], slot.data[0] + slot.data[1] - 1 do
                walk_tid(ctx.lists:get(i))
            end
            for i = slot.data[2], slot.data[2] + slot.data[3] - 1 do
                walk_tid(ctx.lists:get(i))
            end
            if slot.data[4] >= 0 then walk_tid(slot.data[4]) end

        elseif tag == TAG_TABLE then
            -- data[0..1]=fields (list of field_arena IDs)
            -- data[2..3]=indexers (list of type ID pairs)
            -- data[4]=row_var_id, data[5..6]=meta (list of field_arena IDs)
            local function collect_fields_from_list(ls, ll)
                -- Returns the starting index (0-based) in field_entries for this range.
                if ll == 0 then return 0 end
                local start_idx = #field_entries  -- 0-based
                for i = ls, ls + ll - 1 do
                    local fid = ctx.lists:get(i)
                    local fe  = ctx.fields:get(fid)
                    field_entries[#field_entries + 1] = {fe.name_id, fe.type_id, fe.optional ~= 0}
                    intern_str(fe.name_id)
                    walk_tid(fe.type_id)
                end
                return start_idx
            end

            -- We need to track (start, len) in field_entries per table slot.
            -- We can't use a simple dedup here — just collect in order (tables rarely share field lists).
            -- Store (start_idx, len) in slot-local vars; referenced in serialization by old_tid lookup.
            -- Since we call this at walk time, we store it in a side table keyed by old_tid.
            local fields_start = collect_fields_from_list(slot.data[0], slot.data[1])
            local meta_start   = collect_fields_from_list(slot.data[5], slot.data[6])

            -- Indexers: type ID pairs in list pool
            intern_list_range(slot.data[2], slot.data[3])
            for i = slot.data[2], slot.data[2] + slot.data[3] - 1 do
                walk_tid(ctx.lists:get(i))
            end
            -- Row variable
            if slot.data[4] >= 0 then walk_tid(slot.data[4]) end

            -- Store field pool positions for serialization
            -- We embed them in a side table to look up by tid.
            -- (Returned via the main results table; see below.)
            ctx._cri_table_fields = ctx._cri_table_fields or {}
            ctx._cri_table_fields[tid] = {
                fields_start = fields_start,
                fields_len   = slot.data[1],
                meta_start   = meta_start,
                meta_len     = slot.data[6],
            }

        elseif tag == TAG_UNION or tag == TAG_INTERSECTION or tag == TAG_TUPLE then
            intern_list_range(slot.data[0], slot.data[1])
            for i = slot.data[0], slot.data[0] + slot.data[1] - 1 do
                walk_tid(ctx.lists:get(i))
            end

        elseif tag == TAG_NOMINAL then
            -- data[0]=name_id, data[1]=identity, data[2]=underlying_tid
            intern_str(slot.data[0])
            walk_tid(slot.data[2])

        elseif tag == TAG_NAMED then
            -- data[0]=name_id, data[1..2]=args list
            intern_str(slot.data[0])
            intern_list_range(slot.data[1], slot.data[2])
            for i = slot.data[1], slot.data[1] + slot.data[2] - 1 do
                walk_tid(ctx.lists:get(i))
            end

        elseif tag == TAG_MATCH_TYPE then
            -- data[0]=param_tid, data[1..2]=arms list (tid pairs)
            walk_tid(slot.data[0])
            intern_list_range(slot.data[1], slot.data[2])
            for i = slot.data[1], slot.data[1] + slot.data[2] - 1 do
                walk_tid(ctx.lists:get(i))
            end

        elseif tag == TAG_TYPE_CALL then
            -- data[0]=callee_tid, data[1..2]=args list
            walk_tid(slot.data[0])
            intern_list_range(slot.data[1], slot.data[2])
            for i = slot.data[1], slot.data[1] + slot.data[2] - 1 do
                walk_tid(ctx.lists:get(i))
            end

        elseif tag == TAG_FORALL then
            -- data[0..1]=type_params list (name_ids), data[2]=body_tid
            intern_list_range(slot.data[0], slot.data[1])
            -- type_params are name_ids (strings), not type IDs — intern strings
            for i = slot.data[0], slot.data[0] + slot.data[1] - 1 do
                intern_str(ctx.lists:get(i))
            end
            walk_tid(slot.data[2])

        elseif tag == TAG_SPREAD then
            walk_tid(slot.data[0])

        elseif tag == TAG_INTRINSIC then
            intern_str(slot.data[0])

        elseif tag == TAG_VAR or tag == TAG_ROWVAR then
            -- Unbound generic type variable (data[2] < 0).
            -- data[0]=var_id (unique integer, no remap), data[1]=level, data[2]=-1
            -- No children to walk.
        end
        -- TAG_NIL/BOOLEAN/NUMBER/STRING/ANY/NEVER/INTEGER/CDATA: no children
    end

    walk = walk_tid
    for _, tid in ipairs(root_tids) do walk_tid(tid) end

    return {
        seen_types       = seen_types,
        type_order       = type_order,
        seen_strings     = seen_strings,
        str_order        = str_order,
        field_entries    = field_entries,
        list_ranges      = list_ranges,
        list_range_seen  = list_range_seen,
    }
end

-- ---------------------------------------------------------------------------
-- Binary helpers
-- ---------------------------------------------------------------------------
local function u8(v)
    return string.char(band(v, 0xff))
end

local function u16be(v)
    return string.char(band(rshift(tobit(v), 8), 0xff), band(v, 0xff))
end

local function u32be(v)
    v = tobit(v)
    return string.char(
        band(rshift(v, 24), 0xff), band(rshift(v, 16), 0xff),
        band(rshift(v,  8), 0xff), band(v, 0xff))
end

local function i32be(v)
    v = tobit(v)
    return string.char(
        band(rshift(v, 24), 0xff), band(rshift(v, 16), 0xff),
        band(rshift(v,  8), 0xff), band(v, 0xff))
end

local function pad_to_align(parts, alignment)
    local total = 0
    for _, p in ipairs(parts) do total = total + #p end
    local rem = total % alignment
    if rem ~= 0 then
        parts[#parts + 1] = string.rep("\0", alignment - rem)
    end
end

-- ---------------------------------------------------------------------------
-- Serializer
-- ---------------------------------------------------------------------------

local function remap_tid(seen_types, ctx, tid)
    if tid < 0 then return -1 end
    tid = resolve(ctx, tid)
    local idx = seen_types[tid]
    return idx ~= nil and idx or -1
end

local function remap_sid(seen_strings, sid)
    if sid < 0 then return -1 end
    local idx = seen_strings[sid]
    return idx ~= nil and idx or -1
end

-- Build remapped type-list pool. Returns flat array of remapped type IDs and
-- a lookup table: "old_s,old_l" -> new_start (0-based index in the flat array).
local function build_list_pool(ctx, seen_types, list_ranges)
    local flat       = {}   -- flat array of new type IDs
    local range_map  = {}   -- "old_s,old_l" -> new_start

    for _, range in ipairs(list_ranges) do
        local s, l  = range[1], range[2]
        local key   = s .. "," .. l
        local new_s = #flat  -- 0-based
        range_map[key] = new_s
        for i = s, s + l - 1 do
            flat[#flat + 1] = remap_tid(seen_types, ctx, ctx.lists:get(i))
        end
    end

    -- For TAG_FORALL, the list contains name_ids (strings), not type IDs.
    -- We stored them as-is in flat[] via the walk above; at serialization we
    -- remap them to the new string index instead. Handle this in serialize().
    return flat, range_map
end

-- Build remapped field pool entries. After collect(), field_entries[i] has
-- {old_name_sid, old_type_tid, optional}. We remap here.
local function build_field_pool(ctx, seen_types, seen_strings, field_entries)
    local remapped = {}
    for _, fe in ipairs(field_entries) do
        remapped[#remapped + 1] = {
            remap_sid(seen_strings, fe[1]),
            remap_tid(seen_types, ctx, fe[2]),
            fe[3],
        }
    end
    return remapped
end

-- Serialize a set of named exports from ctx.
-- exports: { [name_string] = type_id }
-- Returns the raw .cri bytes as a Lua string, with SHA-256 filled in.
function M.serialize(ctx, exports)
    -- Clean up any leftover side table from a previous call.
    ctx._cri_table_fields = {}

    -- Sort export names for determinism.
    local export_names = {}
    for name in pairs(exports) do export_names[#export_names + 1] = name end
    table.sort(export_names)

    -- Intern export name strings into pool and collect root type IDs.
    local root_tids    = {}
    local export_sids  = {}  -- [i] = pool string id for export_names[i]
    for i, name in ipairs(export_names) do
        export_sids[i] = intern_mod.intern(ctx.pool, name)
        local tid = exports[name]
        if tid then
            root_tids[#root_tids + 1] = resolve(ctx, tid)
        end
    end

    -- Reachability walk
    local R = collect(ctx, root_tids)
    local seen_types      = R.seen_types
    local type_order      = R.type_order
    local seen_strings    = R.seen_strings
    local str_order       = R.str_order
    local field_entries   = R.field_entries
    local list_ranges     = R.list_ranges
    local list_range_seen = R.list_range_seen

    -- Ensure export name strings are in the string table.
    for _, sid in ipairs(export_sids) do
        if not seen_strings[sid] then
            local idx = #str_order
            seen_strings[sid] = idx
            str_order[#str_order + 1] = sid
        end
    end

    -- Build remapped pools
    local flat_list, list_range_map =
        build_list_pool(ctx, seen_types, list_ranges)

    local flat_fields =
        build_field_pool(ctx, seen_types, seen_strings, field_entries)

    local cri_table_fields = ctx._cri_table_fields

    -- Helper: map a (old_s, old_l) list range to (new_s, l)
    local function map_list(s, l)
        if l == 0 then return 0, 0 end
        local key = s .. "," .. l
        local ns = list_range_map[key]
        return (ns ~= nil and ns or 0), l
    end

    -- -----------------------------------------------------------------------
    -- Section 1: String Table
    -- Layout: count(u32) + offsets(u32[count+1]) + data(raw bytes)
    -- Padded to 32-byte alignment.
    -- -----------------------------------------------------------------------
    local str_count = #str_order
    local str_parts = {}
    local str_offsets = {}  -- byte offset of each string in data section
    local byte_pos = 0
    for i, old_sid in ipairs(str_order) do
        str_offsets[i] = byte_pos
        local s = intern_mod.get(ctx.pool, old_sid) or ""
        str_parts[i] = s
        byte_pos = byte_pos + #s
    end
    str_offsets[str_count + 1] = byte_pos  -- sentinel

    local str_buf = { u32be(str_count) }
    for i = 1, str_count + 1 do
        str_buf[#str_buf + 1] = u32be(str_offsets[i])
    end
    for _, s in ipairs(str_parts) do
        str_buf[#str_buf + 1] = s
    end
    pad_to_align(str_buf, 32)
    local str_bytes = table.concat(str_buf)

    -- -----------------------------------------------------------------------
    -- Section 2: Type Table
    -- Layout: count(u32) + pad(28 bytes) + TypeSlot[count] (32 bytes each)
    -- -----------------------------------------------------------------------
    local type_count = #type_order
    local type_buf = { u32be(type_count), string.rep("\0", 28) }  -- count + pad = 32

    for _, old_tid in ipairs(type_order) do
        local slot = ctx.types:get(old_tid)
        local tag  = slot.tag
        local flags = slot.flags
        local d = {-1, -1, -1, -1, -1, -1, -1}  -- default: all -1

        if tag == TAG_LITERAL then
            d[1] = slot.data[0]  -- lit_kind (unchanged)
            -- data[1] = value; remap string ID if LIT_STRING
            if slot.data[0] == LIT_STRING then
                d[2] = remap_sid(seen_strings, slot.data[1])
            else
                d[2] = slot.data[1]  -- boolean 0/1 or numeric value as-is
            end

        elseif tag == TAG_FUNCTION then
            local ps, pl = map_list(slot.data[0], slot.data[1])
            local rs, rl = map_list(slot.data[2], slot.data[3])
            d[1] = ps; d[2] = pl
            d[3] = rs; d[4] = rl
            d[5] = remap_tid(seen_types, ctx, slot.data[4])

        elseif tag == TAG_TABLE then
            -- data layout: [0]=fs,[1]=fl,[2]=is,[3]=il,[4]=row_var,[5]=ms,[6]=ml
            -- In .cri format, fields/meta are direct field pool offsets (not list-of-field-IDs).
            local tf = cri_table_fields[old_tid]
            local is, il = map_list(slot.data[2], slot.data[3])
            d[1] = tf and tf.fields_start or 0
            d[2] = tf and tf.fields_len   or 0
            d[3] = is; d[4] = il
            d[5] = remap_tid(seen_types, ctx, slot.data[4])  -- row_var
            d[6] = tf and tf.meta_start   or 0
            d[7] = tf and tf.meta_len     or 0

        elseif tag == TAG_UNION or tag == TAG_INTERSECTION or tag == TAG_TUPLE then
            local s, l = map_list(slot.data[0], slot.data[1])
            d[1] = s; d[2] = l

        elseif tag == TAG_NOMINAL then
            -- data[0]=name_id, data[1]=identity, data[2]=underlying_tid
            d[1] = remap_sid(seen_strings, slot.data[0])
            d[2] = slot.data[1]  -- identity integer, unchanged
            d[3] = remap_tid(seen_types, ctx, slot.data[2])

        elseif tag == TAG_NAMED then
            -- data[0]=name_id, data[1..2]=args list
            d[1] = remap_sid(seen_strings, slot.data[0])
            local s, l = map_list(slot.data[1], slot.data[2])
            d[2] = s; d[3] = l

        elseif tag == TAG_MATCH_TYPE then
            -- data[0]=param_tid, data[1..2]=arms list
            d[1] = remap_tid(seen_types, ctx, slot.data[0])
            local s, l = map_list(slot.data[1], slot.data[2])
            d[2] = s; d[3] = l

        elseif tag == TAG_TYPE_CALL then
            -- data[0]=callee_tid, data[1..2]=args list
            d[1] = remap_tid(seen_types, ctx, slot.data[0])
            local s, l = map_list(slot.data[1], slot.data[2])
            d[2] = s; d[3] = l

        elseif tag == TAG_FORALL then
            -- data[0..1]=type_params list (name_ids), data[2]=body_tid
            -- In the serialized list pool, FORALL param ranges contain remapped string IDs.
            -- We need to re-remap them here since build_list_pool treated them as type IDs.
            local s, l = map_list(slot.data[0], slot.data[1])
            d[1] = s; d[2] = l
            d[3] = remap_tid(seen_types, ctx, slot.data[2])
            -- Fix the list entries: overwrite the list pool entries for this range
            -- with remapped string IDs (build_list_pool stored type IDs).
            -- We do this as a post-pass below.

        elseif tag == TAG_SPREAD then
            d[1] = remap_tid(seen_types, ctx, slot.data[0])

        elseif tag == TAG_INTRINSIC then
            d[1] = remap_sid(seen_strings, slot.data[0])

        elseif tag == TAG_VAR or tag == TAG_ROWVAR then
            -- Unbound generic var: data[0]=var_id, data[1]=level, data[2]=-1
            d[1] = slot.data[0]  -- var_id unchanged
            d[2] = slot.data[1]  -- level unchanged
            d[3] = -1            -- unbound

        else
            -- Primitives: no data fields needed (all default -1)
        end

        -- TypeSlot: tag(u8), flags(u8), reserved(u16), data[7](i32) = 32 bytes
        type_buf[#type_buf + 1] = u8(tag)
        type_buf[#type_buf + 1] = u8(flags)
        type_buf[#type_buf + 1] = u16be(0)  -- reserved
        for i = 1, 7 do
            type_buf[#type_buf + 1] = i32be(d[i])
        end
        -- 1+1+2+7*4 = 32 bytes ✓
    end
    local type_bytes = table.concat(type_buf)

    -- Post-pass: fix FORALL list entries (name_ids, not type IDs).
    -- flat_list was built treating all list entries as type IDs, but FORALL
    -- type_params are name_ids (string intern IDs). We overwrite those ranges.
    -- We need to rebuild flat_list for FORALL ranges.
    -- Simplest: re-walk FORALL slots and patch flat_list in place.
    for _, old_tid in ipairs(type_order) do
        local slot = ctx.types:get(old_tid)
        if slot.tag == TAG_FORALL then
            local s, l = slot.data[0], slot.data[1]
            if l > 0 then
                local key = s .. "," .. l
                local new_s = list_range_map[key]
                if new_s then
                    for i = 0, l - 1 do
                        local old_name_id = ctx.lists:get(s + i)
                        flat_list[new_s + i + 1] = remap_sid(seen_strings, old_name_id)
                    end
                end
            end
        end
    end

    -- -----------------------------------------------------------------------
    -- Section 3: Field Pool
    -- Layout: count(u32) + FieldEntry[count] (12 bytes each)
    -- -----------------------------------------------------------------------
    local field_count = #flat_fields
    local field_buf = { u32be(field_count) }
    for _, fe in ipairs(flat_fields) do
        field_buf[#field_buf + 1] = i32be(fe[1])                -- name_id (i32)
        field_buf[#field_buf + 1] = i32be(fe[2])                -- type_id (i32)
        field_buf[#field_buf + 1] = u8(fe[3] and 1 or 0)        -- optional (u8)
        field_buf[#field_buf + 1] = "\0\0\0"                    -- padding (3 bytes)
        -- 4+4+1+3 = 12 bytes ✓
    end
    pad_to_align(field_buf, 4)
    local field_bytes = table.concat(field_buf)

    -- -----------------------------------------------------------------------
    -- Section 4: List Pool
    -- Layout: count(u32) + int32_t[count]
    -- -----------------------------------------------------------------------
    local list_count = #flat_list
    local list_buf = { u32be(list_count) }
    for _, v in ipairs(flat_list) do
        list_buf[#list_buf + 1] = i32be(v)
    end
    pad_to_align(list_buf, 4)
    local list_bytes = table.concat(list_buf)

    -- -----------------------------------------------------------------------
    -- Section 5: Export Table
    -- Layout: count(u32) + {name_id(i32), type_id(i32)}[count]
    -- -----------------------------------------------------------------------
    local export_buf = { u32be(#export_names) }
    for i, name in ipairs(export_names) do
        local new_sid = remap_sid(seen_strings, export_sids[i])
        local old_tid = exports[name]
        local new_tid = old_tid and remap_tid(seen_types, ctx, old_tid) or -1
        export_buf[#export_buf + 1] = i32be(new_sid)
        export_buf[#export_buf + 1] = i32be(new_tid)
    end
    local export_bytes = table.concat(export_buf)

    -- -----------------------------------------------------------------------
    -- Header (64 bytes)
    -- magic(4) + version(4) + flags(4) + hash(32) + 5×offset(4) = 64
    -- -----------------------------------------------------------------------
    local HEADER_SIZE = 64
    local str_offset    = HEADER_SIZE
    local type_offset   = str_offset   + #str_bytes
    local field_offset  = type_offset  + #type_bytes
    local list_offset   = field_offset + #field_bytes
    local export_offset = list_offset  + #list_bytes

    local header = "CRIF"
        .. u32be(1)                    -- version
        .. u32be(0)                    -- flags
        .. string.rep("\0", 32)        -- hash (zeroed)
        .. u32be(str_offset)
        .. u32be(type_offset)
        .. u32be(field_offset)
        .. u32be(list_offset)
        .. u32be(export_offset)
    -- 4+4+4+32+4+4+4+4+4 = 64 ✓
    assert(#header == 64)

    -- Assemble
    local body = header .. str_bytes .. type_bytes .. field_bytes .. list_bytes .. export_bytes

    -- Compute SHA-256 with hash field zeroed (it is), fill into offset 12.
    local hex = sha256.hash(body)
    local raw_hash = {}
    for i = 1, 64, 2 do
        raw_hash[#raw_hash + 1] = string.char(tonumber(hex:sub(i, i+1), 16))
    end
    raw_hash = table.concat(raw_hash)  -- 32 bytes

    -- Patch: bytes 1-12 | 32-byte hash | remaining
    -- Header: "CRIF"(4) + version(4) + flags(4) = 12 bytes before hash
    return body:sub(1, 12) .. raw_hash .. body:sub(45)
end

return M
