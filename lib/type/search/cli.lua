-- lib/type/search/cli.lua
-- CLI for Hoogle-style type search.
-- Usage:
--   luajit lib/type/search/cli.lua "(string) -> string" lib/encode/base64/init.lua ...
--   luajit lib/type/search/cli.lua "(string) -> string" --package lib/encode/ lib/hash/
--   luajit lib/type/search/cli.lua --save-index stdlib.json --package lib/
--   luajit lib/type/search/cli.lua --load-index stdlib.json "(string) -> string"

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local search = require("lib.type.search")

local args = {...}

-- Parse flags
local save_index_path = nil
local load_index_path = nil
local query_str = nil
local files = {}
local i = 1
while i <= #args do
    if args[i] == "--save-index" then
        i = i + 1
        save_index_path = args[i]
        i = i + 1
    elseif args[i] == "--load-index" then
        i = i + 1
        load_index_path = args[i]
        i = i + 1
    elseif args[i] == "--package" then
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
    elseif not query_str and args[i]:sub(1, 1) ~= "-" then
        -- First non-flag argument is the query string (unless it looks like a file)
        -- Heuristic: if it contains -> or ( or is not a .lua file, treat as query
        if args[i]:find("->") or args[i]:find("%(") or not args[i]:find("%.lua$") then
            query_str = args[i]
            i = i + 1
        else
            files[#files + 1] = args[i]
            i = i + 1
        end
    else
        files[#files + 1] = args[i]
        i = i + 1
    end
end

-- Validate arguments
if not save_index_path and not load_index_path and not query_str then
    io.stderr:write("Usage: luajit lib/type/search/cli.lua <type-query> [--package <dir>...] <file>...\n")
    io.stderr:write("       luajit lib/type/search/cli.lua --save-index <path> [--package <dir>...] <file>...\n")
    io.stderr:write("       luajit lib/type/search/cli.lua --load-index <path> <type-query>\n")
    io.stderr:write("\nExamples:\n")
    io.stderr:write("  luajit lib/type/search/cli.lua '(string) -> string' lib/encode/base64/init.lua\n")
    io.stderr:write("  luajit lib/type/search/cli.lua '(string) -> string' --package lib/encode/ lib/hash/\n")
    io.stderr:write("  luajit lib/type/search/cli.lua --save-index stdlib.json --package lib/\n")
    io.stderr:write("  luajit lib/type/search/cli.lua --load-index stdlib.json '(string) -> string'\n")
    os.exit(1)
end

-- Build or load index
local index

if load_index_path then
    local err
    index, err = search.load_index(load_index_path)
    if not index then
        io.stderr:write("Error loading index: " .. (err or "unknown error") .. "\n")
        os.exit(1)
    end
    io.stderr:write(string.format("Loaded index: %d exports from %s\n", #index, load_index_path))
else
    if #files == 0 then
        io.stderr:write("Error: no files specified\n")
        os.exit(1)
    end
    io.stderr:write(string.format("Indexing %d file(s)...\n", #files))
    index = search.build_index(files)
    io.stderr:write(string.format("Index: %d exports\n", #index))
end

-- Save index if requested
if save_index_path then
    local ok, err = search.save_index(index, save_index_path)
    if not ok then
        io.stderr:write("Error saving index: " .. (err or "unknown error") .. "\n")
        os.exit(1)
    end
    io.stderr:write(string.format("Saved index to %s\n", save_index_path))
end

-- Query if a query string was provided
if query_str then
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
end
