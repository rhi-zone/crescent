-- lib/doc/cli.lua
-- CLI entry point for the docgen tool.
-- Usage: luajit lib/doc/cli.lua [--format json|text] <file>...

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local doc    = require("lib.doc")
local json   = require("lib.lunajson")

local format = "json"
local files  = {}

local i = 1
while i <= #arg do
    local a = arg[i]
    if a == "--format" then
        i = i + 1
        format = arg[i] or "json"
    elseif a:sub(1, 9) == "--format=" then
        format = a:sub(10)
    else
        files[#files + 1] = a
    end
    i = i + 1
end

if #files == 0 then
    io.stderr:write("usage: luajit lib/doc/cli.lua [--format json|text] <file>...\n")
    os.exit(1)
end

local results = {}
local had_error = false

for _, filename in ipairs(files) do
    local result, err = doc.generate(filename)
    if err then
        io.stderr:write("error: " .. filename .. ": " .. err .. "\n")
        had_error = true
    else
        results[#results + 1] = result
    end
end

if format == "text" then
    for _, result in ipairs(results) do
        io.write("# " .. result.file .. "\n\n")
        if #result.exports == 0 then
            io.write("(no exports)\n\n")
        else
            for _, exp in ipairs(result.exports) do
                io.write(exp.name .. ": " .. exp.type .. "\n")
                if exp.doc then
                    io.write("  " .. exp.doc .. "\n")
                end
                if exp.line then
                    io.write("  line " .. exp.line .. "\n")
                end
                io.write("\n")
            end
        end
    end
else
    -- JSON output: single object for one file, array for multiple
    local output
    if #results == 1 then
        output = results[1]
    else
        output = results
    end
    -- lunajson encodes nil fields as absent — strip nil values from export entries
    for _, result in ipairs(results) do
        for _, exp in ipairs(result.exports) do
            -- Leave nil fields absent (lunajson skips nil table values)
        end
    end
    local ok, encoded = pcall(json.encode, output)
    if ok then
        io.write(encoded .. "\n")
    else
        io.stderr:write("json encode error: " .. tostring(encoded) .. "\n")
        had_error = true
    end
end

os.exit(had_error and 1 or 0)
