-- lib/edit/edit_test.lua
-- Tests for the file-edit applier.

if not package.path:find("?/init.lua", 1, true) then
    package.path = "?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local edit = require("lib.edit")

--: (string, string) -> string
local function write_tmp(name, content)
    local path = "/tmp/" .. name
    local f = io.open(path, "wb")
    if not f then error("cannot open " .. path) end
    f:write(content)
    f:close()
    return path
end

--: (string) -> string
local function read_tmp(path)
    local f = io.open(path, "rb")
    if not f then error("cannot open " .. path) end
    local s = f:read("*a")
    f:close()
    return s or ""
end

local M = {}

function M.test_basic_delete()
    local path = write_tmp("edit_test_basic.lua", "hello WORLD!")
    -- delete "WORLD" (bytes 6..11 in 0-indexed half-open)
    local ok, nfiles, nedits, errs = edit.apply({
        [path] = { { byte_start = 6, byte_end = 11, replacement = "" } },
    })
    T.ok(ok, "apply returned ok=true")
    T.eq(nfiles, 1, "one file changed")
    T.eq(nedits, 1, "one edit applied")
    T.eq(#errs, 0, "no errors")
    T.eq(read_tmp(path), "hello !")
    os.remove(path)
end

function M.test_multiple_descending_apply()
    -- Multiple edits in one file. Applier must sort descending so byte
    -- offsets remain valid as later edits don't shift earlier ones.
    local path = write_tmp("edit_test_multi.lua", "AAAA BBBB CCCC")
    local ok, nfiles, nedits = edit.apply({
        [path] = {
            { byte_start = 0,  byte_end = 4,  replacement = "X" },   -- AAAA -> X
            { byte_start = 5,  byte_end = 9,  replacement = "YY" },  -- BBBB -> YY
            { byte_start = 10, byte_end = 14, replacement = "Z" },   -- CCCC -> Z
        },
    })
    T.ok(ok)
    T.eq(nfiles, 1)
    T.eq(nedits, 3)
    T.eq(read_tmp(path), "X YY Z")
    os.remove(path)
end

function M.test_overlap_rejected()
    local path = write_tmp("edit_test_overlap.lua", "ABCDEFGH")
    local ok, _, _, errs = edit.apply({
        [path] = {
            { byte_start = 0, byte_end = 4, replacement = "X" },
            { byte_start = 2, byte_end = 6, replacement = "Y" },
        },
    })
    T.fail(ok, "overlap should fail")
    T.eq(#errs, 1)
    T.eq(read_tmp(path), "ABCDEFGH")  -- unchanged
    os.remove(path)
end

function M.test_out_of_range_rejected()
    local path = write_tmp("edit_test_oob.lua", "short")
    local ok, _, _, errs = edit.apply({
        [path] = { { byte_start = 0, byte_end = 100, replacement = "X" } },
    })
    T.fail(ok)
    T.eq(#errs, 1)
    T.eq(read_tmp(path), "short")
    os.remove(path)
end

return M
