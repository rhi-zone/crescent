-- lib/edit/init.lua
-- Pure file-edit applier: takes a map of filename -> list of byte-range edits
-- and applies them atomically.
--
-- This is a CLI utility module — it uses io directly because it is invoked from
-- the typechecker CLI's --fix path, not from sandboxed library code.
--
-- Edit representation:
--   { byte_start: integer, byte_end: integer, replacement: string }
-- byte_start and byte_end are 0-indexed half-open offsets into the file's
-- byte content: src[byte_start .. byte_end) is replaced by `replacement`.
--
-- API:
--   edit.apply({ ["path"] = { edit, ... }, ... })
--     -> ok, n_files_changed, n_edits_applied, errs
--   On a per-file error (read failure, overlapping edits, out-of-range offsets,
--   atomic rename failure), that file is skipped and an entry is added to errs.

if not package.path:find("?/init.lua", 1, true) then
    package.path = "?/init.lua;" .. package.path
end

local M = {}

--:: EditRec = { byte_start: integer, byte_end: integer, replacement: string }
--:: FileEdits = { [integer]: EditRec, ... }
--:: FileMap   = { [string]: FileEdits, ... }
--:: EditError = { filename: string, msg: string }

-- Read entire file contents.
--: (string) -> string | nil
local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

-- Write entire file atomically (write to path.tmp, then rename).
--: (string, string) -> (boolean, string | nil)
local function write_file_atomic(path, contents)
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "wb")
    if not f then return false, "cannot open " .. tmp .. " for writing" end
    local ok_w = f:write(contents)
    f:close()
    if not ok_w then
        os.remove(tmp)
        return false, "write failed: " .. tmp
    end
    local ok_r, rename_err = os.rename(tmp, path)
    if not ok_r then
        os.remove(tmp)
        return false, "rename failed: " .. (rename_err or tmp)
    end
    return true, nil
end

-- Apply a sorted list of non-overlapping edits to src.
-- Edits are sorted descending by byte_start, so each edit can be applied
-- directly to the source without shifting subsequent offsets.
--: (string, FileEdits) -> string
local function apply_edits_to_source(src, edits)
    local out = src
    for _, e in ipairs(edits) do
        local bs = e.byte_start
        local be = e.byte_end
        local rep = e.replacement or ""
        -- Lua strings are 1-indexed; src[1..bs] is the prefix BEFORE byte_start,
        -- and src[be+1..#src] is the suffix starting AT byte_end (exclusive end).
        out = out:sub(1, bs) .. rep .. out:sub(be + 1)
    end
    return out
end

-- Apply a map of filename -> edit list. Returns (ok, n_files_changed,
-- n_edits_applied, errs).
--: (FileMap) -> (boolean, integer, integer, { [integer]: EditError, ... })
function M.apply(file_map)
    local errs = {} --: { [integer]: EditError, ... }
    local n_files = 0
    local n_edits = 0
    local any_failed = false

    for filename, edits in pairs(file_map) do
        if #edits == 0 then
            -- nothing to do
        else
            local src = read_file(filename)
            if not src then
                errs[#errs + 1] = { filename = filename, msg = "cannot read file" }
                any_failed = true
            else
                -- Sort descending by byte_start. Insertion sort to avoid pulling
                -- in table.sort generic comparator typing.
                local sorted = {} --: FileEdits
                for i, e in ipairs(edits) do sorted[i] = e end
                for i = 2, #sorted do
                    local key = sorted[i]
                    local j = i - 1
                    while j >= 1 and sorted[j].byte_start < key.byte_start do
                        sorted[j + 1] = sorted[j]
                        j = j - 1
                    end
                    sorted[j + 1] = key
                end

                -- Check non-overlap and bounds. After sort (descending), edit[i]
                -- has the largest byte_start. We require edit[i].byte_end <=
                -- edit[i-1].byte_start (with i-1 being later in original, but
                -- since we sorted desc, the lower-byte_start entry comes after).
                local overlap = false
                local oob = false
                local prev_start = nil
                for _, e in ipairs(sorted) do
                    if e.byte_start < 0 or e.byte_end < e.byte_start
                        or e.byte_end > #src then
                        oob = true
                        break
                    end
                    if prev_start ~= nil and e.byte_end > prev_start then
                        overlap = true
                        break
                    end
                    prev_start = e.byte_start
                end

                if oob then
                    errs[#errs + 1] = { filename = filename, msg = "edit offset out of range" }
                    any_failed = true
                elseif overlap then
                    errs[#errs + 1] = { filename = filename, msg = "overlapping edits" }
                    any_failed = true
                else
                    local new_src = apply_edits_to_source(src, sorted)
                    if new_src ~= src then
                        local ok_w, werr = write_file_atomic(filename, new_src)
                        if not ok_w then
                            errs[#errs + 1] = { filename = filename, msg = werr or "write failed" }
                            any_failed = true
                        else
                            n_files = n_files + 1
                            n_edits = n_edits + #sorted
                        end
                    end
                end
            end
        end
    end

    return not any_failed, n_files, n_edits, errs
end

return M
