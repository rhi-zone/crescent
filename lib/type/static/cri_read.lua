-- lib/type/static/cri_read.lua
-- Parse a .cri binary blob and inject the exported types into a ctx.
--
-- Usage:
--   local cri_read = require("lib.type.static.cri_read")
--   local ok, exports = cri_read.load(bytes, ctx)
--   -- exports: { [name_string] = type_id }  (IDs in ctx's arena)
--
-- String ID remapping: .cri string IDs are file-local. On load, each string is
-- re-interned into ctx.pool to get a session-local ID.
--
-- Type ID remapping: .cri type IDs are file-local (0-based). Each type is
-- allocated into ctx.types and its data remapped through the session type table.
--
-- In .cri TAG_TABLE layout (differs from live ctx):
--   data[0..1] = fields_start, fields_len  → direct field pool indices
--   data[5..6] = meta_start,   meta_len    → direct field pool indices
-- On load, we reconstruct the list-of-field-IDs representation expected by ctx.
--
-- Note: ctx.lists:since(mark) returns (start, len) — always capture both values.

local ffi    = require("ffi")
local bit    = require("bit")
local sha256 = require("lib.type.static.sha256")
local defs   = require("lib.type.static.defs")
local intern_mod = require("lib.type.static.intern")

local lshift, rshift, tobit = bit.lshift, bit.rshift, bit.tobit
local band = bit.band

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
local LIT_NUMBER      = defs.LIT_NUMBER

local M = {}

-- ---------------------------------------------------------------------------
-- Binary reading helpers
-- ---------------------------------------------------------------------------
--: (s: string, pos: integer) -> integer
local function r_u8(s, pos)   -- pos is 0-based byte offset
    return s:byte(pos + 1) or 0
end

--: (s: string, pos: integer) -> integer
local function r_u32be(s, pos)
    local a, b, c, d = s:byte(pos+1, pos+4)
    return lshift(a or 0, 24) + lshift(b or 0, 16) + lshift(c or 0, 8) + (d or 0)
end

--: (s: string, pos: integer) -> integer
local function r_i32be(s, pos)
    local v = r_u32be(s, pos)
    if v >= 0x80000000 then return tobit(v) end
    return v
end

-- ---------------------------------------------------------------------------
-- SHA-256 verification
-- ---------------------------------------------------------------------------
--: (bytes: string) -> boolean
local function verify_hash(bytes)
    -- v2: hash is at bytes 17-48 (after magic + version + alias_off + diag_off).
    local zeroed = bytes:sub(1, 16) .. string.rep("\0", 32) .. bytes:sub(49)
    local computed = sha256.hash(zeroed)
    local stored = {}
    for i = 17, 48 do
        stored[#stored + 1] = string.format("%02x", bytes:byte(i))
    end
    return computed == table.concat(stored)
end

-- ---------------------------------------------------------------------------
-- Diagnostics deserialization (Section 7, v2+)
-- ---------------------------------------------------------------------------
-- Returns errors[], warnings[], end_pos.
--: (bytes: string, pos: integer) -> ({ [integer]: any }, { [integer]: any }, integer)
local function read_diagnostics(bytes, pos)
    local errors, warnings = {}, {}
    local total = r_u32be(bytes, pos)
    pos = pos + 4
    for _ = 1, total do
        local kind = r_u8(bytes, pos)
        pos = pos + 4  -- kind(1) + pad(3)
        local line = r_i32be(bytes, pos);     pos = pos + 4
        local col  = r_i32be(bytes, pos);     pos = pos + 4
        local fn_len = r_u32be(bytes, pos);   pos = pos + 4
        local filename = bytes:sub(pos + 1, pos + fn_len)
        pos = pos + fn_len
        local m_len = r_u32be(bytes, pos);    pos = pos + 4
        local msg = bytes:sub(pos + 1, pos + m_len)
        pos = pos + m_len
        local note_count = r_u32be(bytes, pos); pos = pos + 4
        local notes = {}
        for _ = 1, note_count do
            local nl = r_i32be(bytes, pos); pos = pos + 4
            local nc = r_i32be(bytes, pos); pos = pos + 4
            local nfl = r_u32be(bytes, pos); pos = pos + 4
            local nf = bytes:sub(pos + 1, pos + nfl)
            pos = pos + nfl
            local nml = r_u32be(bytes, pos); pos = pos + 4
            local nm = bytes:sub(pos + 1, pos + nml)
            pos = pos + nml
            notes[#notes + 1] = {
                filename = nf, line = nl, col = nc, msg = nm,
            }
        end
        local entry = {
            kind = kind == 1 and "warning" or "error",
            filename = filename, line = line, col = col, msg = msg,
            notes = notes,
        }
        if kind == 1 then
            warnings[#warnings + 1] = entry
        else
            errors[#errors + 1] = entry
        end
    end
    return errors, warnings, pos
end

-- ---------------------------------------------------------------------------
-- load(bytes, ctx) → ok, exports_or_error
-- ---------------------------------------------------------------------------
--: (bytes: string, ctx: any) -> (boolean, any)
function M.load(bytes, ctx)
    if #bytes < 68 then
        return false, "truncated .cri file"
    end
    if bytes:sub(1, 4) ~= "CRIF" then
        return false, "invalid .cri magic"
    end
    local version = r_u32be(bytes, 4)
    if version ~= 2 then
        return false, "unsupported .cri version " .. version
    end
    if not verify_hash(bytes) then
        return false, "SHA-256 mismatch: .cri file is corrupted"
    end

    -- v2 header layout:
    --   magic(0..3) version(4..7) alias_off(8..11) diag_off(12..15)
    --   hash(16..47) str_off(48..51) type_off(52..55) field_off(56..59)
    --   list_off(60..63) export_off(64..67)
    local str_offset    = r_u32be(bytes, 48)
    local type_offset   = r_u32be(bytes, 52)
    local field_offset  = r_u32be(bytes, 56)
    local list_offset   = r_u32be(bytes, 60)
    local export_offset = r_u32be(bytes, 64)

    -- -----------------------------------------------------------------------
    -- String table → session name_id remap
    -- -----------------------------------------------------------------------
    local str_count = r_u32be(bytes, str_offset)
    local offs_base = str_offset + 4
    local data_base = offs_base + (str_count + 1) * 4

    local str_remap = {}  -- [i 0-based] = session name_id
    for i = 0, str_count - 1 do
        local o0 = r_u32be(bytes, offs_base + i * 4)
        local o1 = r_u32be(bytes, offs_base + (i + 1) * 4)
        local s  = bytes:sub(data_base + o0 + 1, data_base + o1)
        str_remap[i] = intern_mod.intern(ctx.pool, s)
    end

    -- -----------------------------------------------------------------------
    -- List pool → flat array of raw int32 values
    -- -----------------------------------------------------------------------
    local list_count = r_u32be(bytes, list_offset)
    local list_data  = {}  -- [i 0-based] = raw cri int32
    for i = 0, list_count - 1 do
        list_data[i] = r_i32be(bytes, list_offset + 4 + i * 4)
    end

    -- -----------------------------------------------------------------------
    -- Field pool → flat array of {cri_name_id, cri_type_id, optional}
    -- -----------------------------------------------------------------------
    local field_count = r_u32be(bytes, field_offset)
    local field_data  = {}  -- [i 0-based]
    for i = 0, field_count - 1 do
        local base    = field_offset + 4 + i * 12
        field_data[i] = {
            r_i32be(bytes, base),      -- name_id
            r_i32be(bytes, base + 4),  -- type_id
            r_u8(bytes, base + 8)      -- flags byte (FLAG_OPTIONAL=0x01, FLAG_READONLY=0x02, FLAG_PRIVATE=0x04)
        }
    end

    -- -----------------------------------------------------------------------
    -- Type table: first pass — allocate all slots, record raw data
    -- -----------------------------------------------------------------------
    local type_count      = r_u32be(bytes, type_offset)
    local type_table_base = type_offset + 32  -- count(4) + pad(28)

    local type_remap = {} --: { [integer]: integer }
    local raw_types  = {} --: { [integer]: { tag: integer, flg: integer, d: { [integer]: integer } } }

    for i = 0, type_count - 1 do
        local base = type_table_base + i * 32
        local tag  = r_u8(bytes, base)
        local flg  = r_u8(bytes, base + 1)
        local d    = {} --: { [integer]: integer }
        for j = 1, 7 do
            d[j] = r_i32be(bytes, base + 4 + (j-1)*4)
        end
        raw_types[i]  = { tag = tag, flg = flg, d = d }
        type_remap[i] = ctx.types:alloc()
    end

    -- Primitive singletons: map cri type IDs to existing ctx singletons.
    local singleton = {
        [defs.TAG_NIL]     = ctx.T_NIL,
        [defs.TAG_BOOLEAN] = ctx.T_BOOLEAN,
        [defs.TAG_NUMBER]  = ctx.T_NUMBER,
        [defs.TAG_STRING]  = ctx.T_STRING,
        [defs.TAG_ANY]     = ctx.T_ANY,
        [defs.TAG_NEVER]   = ctx.T_NEVER,
        [defs.TAG_INTEGER] = ctx.T_INTEGER,
        [defs.TAG_UNKNOWN] = ctx.T_UNKNOWN,
    }
    for i = 0, type_count - 1 do
        local s = singleton[raw_types[i].tag]
        if s ~= nil then type_remap[i] = s end
        -- (The allocated slot is wasted but harmless.)
    end

    -- Helpers
    local function rt(cri_tid)
        if cri_tid < 0 then return -1 end
        local v = type_remap[cri_tid]
        return v ~= nil and v or -1
    end
    local function rs(cri_sid)
        if cri_sid < 0 then return -1 end
        local v = str_remap[cri_sid]
        return v ~= nil and v or -1
    end

    -- Build a ctx list range from a slice of the cri list pool, remapping values with fn.
    -- fn defaults to rt (type ID remap); use rs for FORALL name_id lists.
    --: (cri_s: integer, cri_l: integer, fn: ((unknown) -> integer) | nil) -> (integer, integer)
    local function push_list(cri_s, cri_l, fn)
        fn = fn or rt
        if cri_l == 0 then return 0, 0 end
        local lm = ctx.lists:mark()
        for j = 0, cri_l - 1 do
            ctx.lists:push(fn(list_data[cri_s + j]))
        end
        return ctx.lists:since(lm)  -- returns (start, len)
    end

    -- Reconstruct a field list from field pool entries, returning (ctx.lists start, len).
    local function make_field_list(fp_start, fp_len)
        if fp_len == 0 then return 0, 0 end
        local lm = ctx.lists:mark()
        for j = 0, fp_len - 1 do
            local fe  = field_data[fp_start + j]
            if fe then
                local fid   = ctx.fields:alloc()
                local fslot = ctx.fields:get(fid)
                fslot.name_id = rs(fe[1])
                fslot.type_id = rt(fe[2])
                fslot.flags   = fe[3] or 0
                ctx.lists:push(fid)
            end
        end
        return ctx.lists:since(lm)  -- returns (start, len)
    end

    -- -----------------------------------------------------------------------
    -- Second pass: fill in TypeSlot data
    -- -----------------------------------------------------------------------
    for i = 0, type_count - 1 do
        local tag  = raw_types[i].tag
        local flg  = raw_types[i].flg
        local d    = raw_types[i].d

        -- Skip primitives (already remapped to singletons)
        if singleton[tag] ~= nil then
            -- nothing to do

        else
            local sid = type_remap[i]
            local slot = ctx.types:get(sid)
            slot.tag   = tag
            slot.flags = flg

            if tag == TAG_LITERAL then
                slot.data[0] = d[1]  -- lit_kind unchanged
                if d[1] == LIT_STRING then
                    slot.data[1] = rs(d[2])
                elseif d[1] == LIT_NUMBER then
                    slot.data[1] = d[2]  -- lo int32 of double
                    slot.data[2] = d[3]  -- hi int32 of double
                else
                    slot.data[1] = d[2]  -- boolean 0/1
                end

            elseif tag == TAG_FUNCTION then
                -- d[1..2]=params list, d[3..4]=returns list, d[5]=vararg_tid
                local ps, pl = push_list(d[1], d[2])
                local rs2, rl = push_list(d[3], d[4])
                slot.data[0] = ps; slot.data[1] = pl
                slot.data[2] = rs2; slot.data[3] = rl
                slot.data[4] = rt(d[5])

            elseif tag == TAG_TABLE then
                -- d[1..2]=field pool range, d[3..4]=indexer list, d[5]=row_var, d[6..7]=meta range
                local fs, fl = make_field_list(d[1], d[2])
                local is, il = push_list(d[3], d[4])
                local ms, ml = make_field_list(d[6], d[7])
                slot.data[0] = fs; slot.data[1] = fl
                slot.data[2] = is; slot.data[3] = il
                slot.data[4] = rt(d[5])  -- row_var
                slot.data[5] = ms; slot.data[6] = ml

            elseif tag == TAG_UNION or tag == TAG_INTERSECTION or tag == TAG_TUPLE then
                local s, l = push_list(d[1], d[2])
                slot.data[0] = s; slot.data[1] = l

            elseif tag == TAG_NOMINAL then
                -- d[1]=name_id, d[2]=identity, d[3]=underlying_tid
                slot.data[0] = rs(d[1])
                slot.data[1] = d[2]  -- identity integer unchanged
                slot.data[2] = rt(d[3])

            elseif tag == TAG_NAMED then
                -- d[1]=name_id, d[2..3]=args list
                local s, l = push_list(d[2], d[3])
                slot.data[0] = rs(d[1])
                slot.data[1] = s; slot.data[2] = l

            elseif tag == TAG_MATCH_TYPE then
                -- d[1]=param_tid, d[2..3]=arms list (type pairs)
                local s, l = push_list(d[2], d[3])
                slot.data[0] = rt(d[1])
                slot.data[1] = s; slot.data[2] = l

            elseif tag == TAG_TYPE_CALL then
                -- d[1]=callee_tid, d[2..3]=args list, d[4]=stable call-site hash
                local s, l = push_list(d[2], d[3])
                slot.data[0] = rt(d[1])
                slot.data[1] = s; slot.data[2] = l
                slot.data[3] = d[4]  -- stable hash; 0 if old cri without this field

            elseif tag == TAG_FORALL then
                -- d[1..2]=type_params list (cri string IDs stored by writer), d[3]=body_tid
                local s, l = push_list(d[1], d[2], rs)  -- remap as string IDs
                slot.data[0] = s; slot.data[1] = l
                slot.data[2] = rt(d[3])

            elseif tag == TAG_SPREAD then
                slot.data[0] = rt(d[1])

            elseif tag == TAG_INTRINSIC then
                slot.data[0] = rs(d[1])

            elseif tag == TAG_VAR or tag == TAG_ROWVAR then
                -- Unbound generic variable: data[0]=var_id, data[1]=level, data[2]=-1
                slot.data[0] = d[1]  -- var_id (opaque)
                slot.data[1] = d[2]  -- level
                slot.data[2] = -1
            end
        end
    end

    -- -----------------------------------------------------------------------
    -- Export table → { [name_string] = session_type_id }
    -- -----------------------------------------------------------------------
    local export_count = r_u32be(bytes, export_offset)
    local exports = {}
    for i = 0, export_count - 1 do
        local base        = export_offset + 4 + i * 8
        local cri_name_id = r_i32be(bytes, base)
        local cri_type_id = r_i32be(bytes, base + 4)
        if cri_name_id >= 0 then
            local sess_sid = rs(cri_name_id)
            local name     = intern_mod.get(ctx.pool, sess_sid)
            if name then
                exports[name] = rt(cri_type_id)
            end
        end
    end

    -- -----------------------------------------------------------------------
    -- Type Alias Table (Section 6, optional)
    -- Present when header flags field is non-zero (byte offset of section).
    -- -----------------------------------------------------------------------
    local aliases = {}
    local alias_offset = r_u32be(bytes, 8)  -- v2 alias_offset field
    if alias_offset > 0 and alias_offset < #bytes then
        local alias_count = r_u32be(bytes, alias_offset)
        local pos = alias_offset + 4
        for _ = 1, alias_count do
            local cri_name_id = r_i32be(bytes, pos)
            local cri_body_id = r_i32be(bytes, pos + 4)
            local aflags      = r_u8(bytes, pos + 8)
            local param_count = r_u8(bytes, pos + 9)
            pos = pos + 12  -- name(4) + body(4) + flags(1) + count(1) + pad(2)

            local name_sid = rs(cri_name_id)
            local name     = intern_mod.get(ctx.pool, name_sid)
            local body_tid = cri_body_id >= 0 and rt(cri_body_id) or nil
            local nominal  = (aflags % 2) == 1

            local params = nil
            if param_count > 0 then
                params = {}
                for j = 1, param_count do
                    params[j] = rs(r_i32be(bytes, pos))
                    pos = pos + 4
                end
            else
                -- skip param_name_ids (0 entries) — pos unchanged
            end

            local resolved_bounds = nil
            if param_count > 0 then
                resolved_bounds = {}
                for j = 1, param_count do
                    local bid = r_i32be(bytes, pos)
                    resolved_bounds[j] = bid >= 0 and rt(bid) or nil
                    pos = pos + 4
                end
            end

            if name then
                aliases[name] = {
                    body = body_tid,
                    params = params,          -- session name_ids (or nil)
                    nominal = nominal,
                    resolved_bounds = resolved_bounds,
                }
            end
        end
    end

    -- -----------------------------------------------------------------------
    -- Diagnostics (Section 7, v2+, optional). Present iff diag_off > 0.
    -- -----------------------------------------------------------------------
    local diag_errors, diag_warnings = nil, nil
    local diag_offset = r_u32be(bytes, 12)
    if diag_offset > 0 and diag_offset < #bytes then
        diag_errors, diag_warnings = read_diagnostics(bytes, diag_offset)
    end

    return true, exports, aliases, diag_errors, diag_warnings
end

return M
