-- lib/tar/init.lua
-- ustar (POSIX.1-1988) tar archive reader/writer.
-- Pure Lua — no dependencies, works on LuaJIT and PUC-Rio Lua 5.2+.
--
-- Entry format: { name=string, mode=number, size=number, mtime=number,
--                 data=string, typeflag=string }
-- Supports regular files (typeflag "0"/"\0") and directories (typeflag "5").
-- Unknown typeflags are skipped on read without error.

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

local byte, sub, rep, format = string.byte, string.sub, string.rep, string.format
local concat, insert = table.concat, table.insert
local floor = math.floor

-- Block size for tar format.
local BLOCK = 512

-- ustar header field offsets (1-based Lua string.sub indices).
local OFF_NAME     = 1
local OFF_MODE     = 101
local OFF_UID      = 109
local OFF_GID      = 117
local OFF_SIZE     = 125
local OFF_MTIME    = 137
local OFF_CHKSUM   = 149
local OFF_TYPE     = 157
local OFF_LINKNAME = 158
local OFF_MAGIC    = 258
local OFF_VERSION  = 264
local OFF_UNAME    = 266
local OFF_GNAME    = 298
local OFF_DEVMAJOR = 330
local OFF_DEVMINOR = 338
local OFF_PREFIX   = 346

local LEN_NAME     = 100
local LEN_MODE     = 8
local LEN_UID      = 8
local LEN_GID      = 8
local LEN_SIZE     = 12
local LEN_MTIME    = 12
local LEN_CHKSUM   = 8
local LEN_LINKNAME = 100
local LEN_MAGIC    = 6
local LEN_VERSION  = 2
local LEN_UNAME    = 32
local LEN_GNAME    = 32
local LEN_DEVMAJOR = 8
local LEN_DEVMINOR = 8
local LEN_PREFIX   = 155
local LEN_PADDING  = 12

-- Parse a null-terminated or space-terminated octal string field into a number.
--: (string) -> number
local function parse_octal(s)
    local raw = s:match("^%s*([0-7]*)")
    if not raw or raw == "" then return 0 end
    local n = 0
    for i = 1, #raw do
        local b = byte(raw, i)
        n = n * 8 + (b - 0x30)
    end
    return n
end

-- Format a number as a zero-padded octal string of exactly `width` bytes.
-- Produces (width-1) octal digits followed by a NUL byte.
--: (number, integer) -> string
local function fmt_octal(n, width)
    local s = format("%o", n)
    local len_s = #s
    local pad = width - 1 - len_s
    if pad < 0 then
        s = sub(s, 1 - width)
        pad = 0
    end
    return rep("0", pad) .. s .. "\0"
end

-- Write a string into a fixed-width NUL-padded field.
--: (string, integer) -> string
local function fmt_field(s, width)
    local n = #s
    if n >= width then
        return sub(s, 1, width)
    end
    return s .. rep("\0", width - n)
end

-- Compute ustar checksum: sum of all 512 header bytes,
-- treating the checksum field bytes as spaces (0x20).
--: (string) -> number
local function compute_checksum(header)
    local sum = 0
    local chk_end = OFF_CHKSUM + LEN_CHKSUM - 1
    for i = 1, BLOCK do
        if i >= OFF_CHKSUM and i <= chk_end then
            sum = sum + 0x20
        else
            local b = byte(header, i)
            sum = sum + b
        end
    end
    return sum
end

-- Return true if a 512-byte block is all zeros (end-of-archive marker).
--: (string) -> boolean
local function is_zero_block(block)
    for i = 1, BLOCK do
        local b = byte(block, i)
        if b ~= 0 then return false end
    end
    return true
end

--:: TarEntry = { name: string, mode: number, size: number, mtime: number, data: string, typeflag: string }
--:: TarWriteEntry = { name: string, data: string, mode: number | nil, mtime: number | nil, typeflag: string | nil }

--- Read a tar archive from a byte string.
--- Returns an array of entry tables, or nil + errmsg on failure.
--: (string) -> (TarEntry[] | nil, string | nil)
function M.read(bytes)
    local entries = {}
    local pos = 1
    local len = #bytes
    local zero_blocks = 0

    while pos + BLOCK - 1 <= len do
        local block = sub(bytes, pos, pos + BLOCK - 1)
        pos = pos + BLOCK

        if is_zero_block(block) then
            zero_blocks = zero_blocks + 1
            if zero_blocks >= 2 then break end
        else
            zero_blocks = 0

            -- Validate checksum
            local chk_field  = sub(block, OFF_CHKSUM, OFF_CHKSUM + LEN_CHKSUM - 1)
            local stored_chk = parse_octal(chk_field)
            local actual_chk = compute_checksum(block)
            if actual_chk ~= stored_chk then
                return nil, "tar: invalid checksum at block offset " .. (pos - BLOCK)
            end

            -- Read typeflag; normalize NUL -> "0" for regular files
            local typeflag = sub(block, OFF_TYPE, OFF_TYPE)
            if typeflag == "\0" then typeflag = "0" end

            -- Skip non-file, non-directory entries; just advance past their data
            if typeflag ~= "0" and typeflag ~= "5" then
                local skip_field  = sub(block, OFF_SIZE, OFF_SIZE + LEN_SIZE - 1)
                local skip_size   = parse_octal(skip_field)
                local skip_blocks = floor((skip_size + BLOCK - 1) / BLOCK)
                pos = pos + skip_blocks * BLOCK
            else
                -- Reconstruct full path from optional prefix + name
                local raw_prefix = sub(block, OFF_PREFIX, OFF_PREFIX + LEN_PREFIX - 1)
                local prefix = raw_prefix:match("^([^%z]*)") or ""
                local raw_name = sub(block, OFF_NAME, OFF_NAME + LEN_NAME - 1)
                local name = raw_name:match("^([^%z]*)") or ""
                if prefix ~= "" then
                    name = prefix .. "/" .. name
                end

                local mode_field  = sub(block, OFF_MODE,  OFF_MODE  + LEN_MODE  - 1)
                local size_field  = sub(block, OFF_SIZE,  OFF_SIZE  + LEN_SIZE  - 1)
                local mtime_field = sub(block, OFF_MTIME, OFF_MTIME + LEN_MTIME - 1)
                local mode  = parse_octal(mode_field)
                local size  = parse_octal(size_field)
                local mtime = parse_octal(mtime_field)

                local data_blocks = floor((size + BLOCK - 1) / BLOCK)
                local data = ""
                if size > 0 then
                    if pos + size - 1 > len then
                        return nil, "tar: truncated archive: entry '" .. name .. "' extends past end"
                    end
                    data = sub(bytes, pos, pos + size - 1)
                    pos = pos + data_blocks * BLOCK
                end

                insert(entries, {
                    name     = name,
                    mode     = mode,
                    size     = size,
                    mtime    = mtime,
                    data     = data,
                    typeflag = typeflag,
                })
            end
        end
    end

    return entries
end

--- Find an entry by path in an entries array.
--- Returns the entry's data string, or nil if not found.
--: (TarEntry[], string) -> string | nil
function M.get(entries, path)
    for i = 1, #entries do
        local e = entries[i]
        if e.name == path then
            return e.data
        end
    end
    return nil
end

--- Write a tar archive from an array of entries.
--- Each entry needs at minimum: name (string) and data (string).
--- mode defaults to 0644, mtime defaults to 0.
--- Returns the archive as a byte string, or nil + errmsg on failure.
--: (TarWriteEntry[]) -> (string | nil, string | nil)
function M.write(entries)
    local blocks = {}

    for i = 1, #entries do
        local e = entries[i]
        if type(e.name) ~= "string" then
            return nil, "tar: entry " .. i .. ": name must be a string"
        end
        local data     = e.data or ""
        local mode     = e.mode or 0x1A4  -- 0644
        local mtime    = e.mtime or 0
        local typeflag = e.typeflag or "0"
        local fullname = e.name

        -- Split long names into ustar prefix + name (prefix <= 155, name <= 100)
        local name   = fullname
        local prefix = ""
        if #fullname > LEN_NAME then
            -- search backward for last '/' within the prefix range
            local max_split = #fullname - 1
            if max_split > LEN_PREFIX + LEN_NAME then max_split = LEN_PREFIX + LEN_NAME end
            local split_pos = nil
            for j = max_split, 1, -1 do
                if sub(fullname, j, j) == "/" then
                    split_pos = j
                    break
                end
            end
            if not split_pos or (#fullname - split_pos) > LEN_NAME then
                return nil, "tar: entry " .. i .. ": name too long: " .. fullname
            end
            prefix = sub(fullname, 1, split_pos - 1)
            name   = sub(fullname, split_pos + 1)
        end

        -- Build 512-byte header with checksum field as 8 spaces (placeholder)
        local header_parts = {
            fmt_field(name,   LEN_NAME),     -- name       (100)
            fmt_octal(mode,   LEN_MODE),     -- mode       (8)
            fmt_octal(0,      LEN_UID),      -- uid        (8)
            fmt_octal(0,      LEN_GID),      -- gid        (8)
            fmt_octal(#data,  LEN_SIZE),     -- size       (12)
            fmt_octal(mtime,  LEN_MTIME),    -- mtime      (12)
            rep(" ", LEN_CHKSUM),            -- checksum   (8) placeholder
            typeflag,                        -- typeflag   (1)
            rep("\0", LEN_LINKNAME),         -- linkname   (100)
            "ustar\0",                       -- magic      (6)
            "00",                            -- version    (2)
            rep("\0", LEN_UNAME),            -- uname      (32)
            rep("\0", LEN_GNAME),            -- gname      (32)
            fmt_octal(0, LEN_DEVMAJOR),      -- devmajor   (8)
            fmt_octal(0, LEN_DEVMINOR),      -- devminor   (8)
            fmt_field(prefix, LEN_PREFIX),   -- prefix     (155)
            rep("\0", LEN_PADDING),          -- padding    (12)
        }
        local header = concat(header_parts)
        if #header ~= BLOCK then
            return nil, "tar: internal error: header size " .. #header .. " != 512"
        end

        -- Compute checksum; encode as 6 octal digits + NUL + space (BSD convention)
        local chk     = compute_checksum(header)
        local chk_str = format("%06o", chk) .. "\0 "
        header = sub(header, 1, OFF_CHKSUM - 1) .. chk_str .. sub(header, OFF_CHKSUM + LEN_CHKSUM)

        insert(blocks, header)

        -- Append data blocks, padded to BLOCK boundary
        if #data > 0 then
            local data_blocks = floor((#data + BLOCK - 1) / BLOCK)
            local padded_size = data_blocks * BLOCK
            if #data < padded_size then
                insert(blocks, data .. rep("\0", padded_size - #data))
            else
                insert(blocks, data)
            end
        end
    end

    -- Two 512-byte zero blocks terminate the archive
    insert(blocks, rep("\0", BLOCK))
    insert(blocks, rep("\0", BLOCK))

    return concat(blocks)
end

-- Codec aliases per conventions
M.string_to_tar = M.read
M.tar_to_string = M.write
M.decode        = M.read
M.encode        = M.write

return M
