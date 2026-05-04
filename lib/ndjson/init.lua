-- lib/ndjson/init.lua
-- Newline-Delimited JSON (NDJSON / JSON Lines) encoder and decoder.
--
-- Each line is a complete JSON value separated by \n.
-- Blank lines and lines starting with # are skipped on decode.
--
-- Public API:
--   ndjson.encode(values)       -> string | (nil, errmsg)
--   ndjson.decode(data)         -> array  | (nil, errmsg)
--   ndjson.encode_line(value)   -> string | (nil, errmsg)  (single value + \n)
--   ndjson.decode_line(line)    -> value  | (nil, errmsg)
--   ndjson.iter(data)           -> iterator: () -> value, err
--   ndjson.encoder()            -> Encoder object
--   ndjson._tier                = "pure"

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local json = require("lib.format.json") --[[: any]]

local M = {}

M._tier = "pure"

-- Encode a single value to one NDJSON line (with trailing newline).
function M.encode_line(value)
    local s, err = json.encode(value)
    if not s then
        return nil, err
    end
    return s .. "\n"
end

-- Encode an array of values to an NDJSON string.
function M.encode(values)
    local parts = {}
    for i = 1, #values do
        local s, err = json.encode(values[i])
        if not s then
            return nil, "line " .. i .. ": " .. err
        end
        parts[i] = s
    end
    if #parts == 0 then
        return ""
    end
    return table.concat(parts, "\n") .. "\n"
end

-- Decode a single JSON line to a value.
function M.decode_line(line)
    return json.decode(line)
end

-- Decode an NDJSON string to an array of values.
-- Skips blank lines and lines starting with #.
function M.decode(data)
    local results = {}
    local n = 0
    local line_num = 0
    for line in (data .. "\n"):gmatch("([^\n]*)\n") do
        line_num = line_num + 1
        -- skip blank lines
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local value, err = json.decode(line)
            if value == nil and err then
                return nil, "line " .. line_num .. ": " .. err
            end
            n = n + 1
            results[n] = value
        end
    end
    return results
end

-- Streaming iterator over NDJSON data.
-- Usage: for value, err in M.iter(data) do ... end
-- On parse error, yields nil, errmsg then stops.
function M.iter(data)
    local lines = {}
    local n = 0
    for line in (data .. "\n"):gmatch("([^\n]*)\n") do
        if line ~= "" and line:sub(1, 1) ~= "#" then
            n = n + 1
            lines[n] = line
        end
    end
    local i = 0
    return function()
        i = i + 1
        if i > n then return nil end
        local value, err = json.decode(lines[i])
        if value == nil and err then
            -- signal error then stop on next call
            i = n + 1
            return nil, err
        end
        return value
    end
end

-- Stateful encoder object.
-- enc:write(value)  -> encoded line string | (nil, errmsg)
-- enc:lines()       -> table of all lines written so far
local Encoder = {}
Encoder.__index = Encoder

function Encoder:write(value)
    local line, err = M.encode_line(value)
    if not line then
        return nil, err
    end
    self._lines[#self._lines + 1] = line
    return line
end

function Encoder:lines()
    local copy = {}
    for i = 1, #self._lines do
        copy[i] = self._lines[i]
    end
    return copy
end

-- Create a new Encoder instance.
function M.encoder()
    return setmetatable({ _lines = {} }, Encoder)
end

return M
