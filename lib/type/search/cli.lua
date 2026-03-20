-- lib/type/search/cli.lua
-- CLI for Hoogle-style type search.
-- Usage:
--   luajit lib/type/search/cli.lua "(string) -> string" lib/encode/base64/init.lua ...
--   luajit lib/type/search/cli.lua "(string) -> string" --package lib/encode/ lib/hash/

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local search = require("lib.type.search")

local args = {...}
if #args < 2 then
    io.stderr:write("Usage: luajit lib/type/search/cli.lua <type-query> [--package <dir>...] <file>...\n")
    io.stderr:write("\nExamples:\n")
    io.stderr:write("  luajit lib/type/search/cli.lua '(string) -> string' lib/encode/base64/init.lua\n")
    io.stderr:write("  luajit lib/type/search/cli.lua '(string) -> string' --package lib/encode/ lib/hash/\n")
    os.exit(1)
end

local query_str = args[1]
local files = {}
local i = 2
while i <= #args do
    if args[i] == "--package" then
        -- Collect directories until next flag or end
        i = i + 1
        while i <= #args and args[i]:sub(1, 1) ~= "-" do
            local dir = args[i]
            if dir:sub(-1) ~= "/" then dir = dir .. "/" end
            -- Find init.lua files in package directories
            local h = io.popen('find "' .. dir .. '" -name init.lua -not -path "*_test*" 2>/dev/null')
            if h then
                for line in h:lines() do
                    files[#files + 1] = line
                end
                h:close()
            end
            i = i + 1
        end
    else
        files[#files + 1] = args[i]
        i = i + 1
    end
end

if #files == 0 then
    io.stderr:write("Error: no files specified\n")
    os.exit(1)
end

io.stderr:write(string.format("Indexing %d file(s)...\n", #files))
local index = search.build_index(files)
io.stderr:write(string.format("Index: %d exports\n", #index))

local matches = search.query(query_str, index)

if #matches == 0 then
    print("No matches found.")
else
    print(string.format("Found %d match(es) for: %s\n", #matches, query_str))
    for _, m in ipairs(matches) do
        local markers = { [3] = "=", [2] = "<", [1] = ">" }
        local marker = markers[m.score] or "?"
        print(string.format("  [%s] %s.%s", marker, m.file, m.name))
        print(string.format("      %s", m.type))
    end
end
