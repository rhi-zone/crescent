-- lib/multipart/init.lua
-- MIME multipart encoder and decoder (RFC 2046).
-- Handles multipart/form-data (HTTP file uploads), multipart/mixed, and email attachments.
-- Pure Lua — no dependencies, works on LuaJIT and PUC-Rio Lua 5.2+.

if not package.path:find("./?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

local concat = table.concat
local byte, char, find, sub, format = string.byte, string.char, string.find, string.sub, string.format

--:: HeaderMap = { [string]: string, ... }
--:: Part = { headers: HeaderMap, body: string }
--:: DecodedPart = { headers: HeaderMap, body: string, name: string | nil, filename: string | nil }
--:: Builder = { _boundary: string, _parts: { [integer]: Part }, ... }

-- ── Boundary generation ───────────────────────────────────────────────────────

local BOUNDARY_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

local function gen_boundary(seed)
    if not seed then error("multipart: seed is required for boundary generation") end
    local seed_ = seed --[[:! integer]]
    math.randomseed(seed_)
    local t = {} --: { [integer]: string }
    for _ = 1, 24 do
        local r = math.floor(math.random() * #BOUNDARY_CHARS) + 1
        table.insert(t, string.sub(BOUNDARY_CHARS, r, r))
    end
    return concat(t)
end

-- ── Header parsing ────────────────────────────────────────────────────────────

-- Parse a single header line "Name: value" -> name (lowercase), value
--: (string) -> (string | nil, string | nil)
local function parse_header_line(line)
    local colon = find(line, ":", 1, true)
    if not colon then return nil, nil end
    local name = sub(line, 1, colon - 1):lower():match("^%s*(.-)%s*$")
    local value = sub(line, colon + 1):match("^%s*(.-)%s*$")
    return name, value
end

-- Parse Content-Disposition parameters from a value like:
--   form-data; name="field1"; filename="test.txt"
-- Returns a table { disposition="form-data", name="field1", filename="test.txt" }
--:: DispositionMap = { disposition: string | nil, name: string | nil, filename: string | nil, [string]: string }
--: (string) -> DispositionMap
local function parse_disposition(value)
    local result = {} --[[: unknown]]
    local result_ = result --[[:! DispositionMap]]
    -- Extract main disposition type (before first ;)
    local disp = value:match("^%s*([^;]+)")
    if disp then
        result_["disposition"] = disp:match("^%s*(.-)%s*$") or ""
    end
    -- More robust param extraction
    for param in value:gmatch(";([^;]+)") do
        local k = param:match("^%s*([%w%-]+)%s*=")
        if k then
            -- Try quoted
            local v = param:match("^%s*[%w%-]+%s*=%s*\"([^\"]*)\"")
            if not v then
                v = param:match("^%s*[%w%-]+%s*=%s*(.-)%s*$")
            end
            if v then result_[k] = v end
        end
    end
    return result_
end

-- ── Builder ───────────────────────────────────────────────────────────────────

local Builder = {}
Builder.__index = Builder

--- Create a new multipart builder.
-- If boundary is not provided, seed is required to generate one.
--: (string | nil, integer | nil) -> Builder
function M.new(boundary, seed)
    if not boundary and not seed then error("multipart.new: boundary or seed is required") end
    local self = setmetatable({}, Builder) --[[: unknown]]
    local self_ = self --[[:! Builder]]
    self_._boundary = boundary or gen_boundary(seed)
    self_._parts = {}
    return self_
end

--- Add a plain form field.
--: (Builder, string, string) -> nil
function Builder:field(name, value)
    local self_ = self --[[:! Builder]]
    local headers = { ["Content-Disposition"] = format('form-data; name="%s"', name) } --: HeaderMap
    Builder.part(self_, headers, value)
end

--- Add a file part.
--: (Builder, string, string, string, string | nil) -> nil
function Builder:file(name, filename, content, content_type)
    local self_ = self --[[:! Builder]]
    local headers = {
        ["Content-Disposition"] = format('form-data; name="%s"; filename="%s"', name, filename),
        ["Content-Type"] = content_type or "application/octet-stream",
    } --: HeaderMap
    Builder.part(self_, headers, content)
end

--- Add a part with custom headers and body.
--: (Builder, HeaderMap, string) -> nil
function Builder:part(headers, body)
    local self_ = self --[[:! Builder]]
    self_._parts[#self_._parts + 1] = { headers = headers, body = body }
end

--- Finalize and return the multipart body and boundary.
--: (Builder) -> (string, string)
function Builder:body()
    local self_ = self --[[:! Builder]]
    local t = {} --: { [integer]: string }
    local k = 1
    local boundary = self_._boundary
    for _, part in ipairs(self_._parts) do
        local part_ = part --[[:! Part]]
        t[k] = "--"; k = k + 1
        t[k] = boundary; k = k + 1
        t[k] = "\r\n"; k = k + 1
        -- Write headers in deterministic order: Content-Disposition first, then others
        local cd = part_.headers["Content-Disposition"]
        if cd then
            t[k] = "Content-Disposition: "; k = k + 1
            t[k] = cd; k = k + 1
            t[k] = "\r\n"; k = k + 1
        end
        for hname, hval in pairs(part_.headers) do
            if hname:lower() ~= "content-disposition" then
                t[k] = hname; k = k + 1
                t[k] = ": "; k = k + 1
                t[k] = hval; k = k + 1
                t[k] = "\r\n"; k = k + 1
            end
        end
        t[k] = "\r\n"; k = k + 1
        t[k] = part_.body; k = k + 1
        t[k] = "\r\n"; k = k + 1
    end
    t[k] = "--"; k = k + 1
    t[k] = boundary; k = k + 1
    t[k] = "--\r\n"; k = k + 1
    return concat(t), boundary
end

--- Return the Content-Type header value for this multipart body.
--: (Builder) -> string
function Builder:content_type()
    local self_ = self --[[:! Builder]]
    return format("multipart/form-data; boundary=%s", self_._boundary)
end

-- ── One-shot encode ───────────────────────────────────────────────────────────

--- One-shot encode an array of parts into a multipart body.
-- Each part is either:
--   { name="f", value="v" }                               -- plain field
--   { name="f", filename="x.txt", data="...", type="..." } -- file part
--   { headers={...}, body="..." }                          -- raw part
--: ({ [integer]: { [string]: unknown } }, string | nil, integer | nil) -> (string, string)
function M.encode(parts, boundary, seed)
    local mp = M.new(boundary, seed)
    for _, p in ipairs(parts) do
        local p_ = p --[[:! { [string]: unknown }]]
        if p_["headers"] then
            local h_ = p_["headers"] --[[:! HeaderMap]]
            local b_ = (p_["body"] or "")
            Builder.part(mp, h_, b_)
        elseif p_["filename"] then
            local name_ = p_["name"] --[[:! string]]
            local fn_ = p_["filename"] --[[:! string]]
            local data_ = (p_["data"] or "")
            local type_ = p_["type"] --[[:! string | nil]]
            Builder.file(mp, name_, fn_, data_, type_)
        else
            local name_ = p_["name"] --[[:! string]]
            local val_ = (p_["value"] or "")
            Builder.field(mp, name_, val_)
        end
    end
    return Builder.body(mp)
end

-- ── Decode ────────────────────────────────────────────────────────────────────

--- Decode a multipart body given its boundary.
-- Returns array of { headers={...}, body="..." }, or (nil, errmsg) on error.
--: (string, string) -> ({ [integer]: DecodedPart } | nil, string | nil)
function M.decode(body, boundary)
    if not boundary or boundary == "" then
        return nil, "multipart.decode: boundary is required"
    end

    local parts = {} --: { [integer]: DecodedPart }

    -- Normalize line endings to \n for easier splitting, but preserve body bytes.
    -- We work with the original body and track positions to preserve exact bytes.

    local delim = "--" .. boundary
    local delim_end = "--" .. boundary .. "--"
    local dlen = #delim

    -- Find all boundary positions
    local pos = 1
    local n = #body

    -- Skip preamble: find first boundary
    local s, e = find(body, delim, pos, true)
    if not s then
        return nil, "multipart.decode: no boundary found"
    end
    local e_ = e --[[:! integer]]

    -- Check if immediately followed by --  (empty body with just closing boundary)
    local after_first = sub(body, e_ + 1, e_ + 2)
    if after_first == "--" then
        return parts  -- no parts
    end

    -- Move past the first boundary line (skip \r\n or \n)
    pos = e_ + 1
    if sub(body, pos, pos) == "\r" then pos = pos + 1 end
    if sub(body, pos, pos) == "\n" then pos = pos + 1 end

    -- Parse parts
    while (pos --[[:! integer]]) <= n do
        local pos_ = pos --[[:! integer]]
        -- Find the next boundary (could be closing --)
        local bs, be = find(body, delim, pos_, true)
        if not bs then
            -- No more boundaries; remaining content is a malformed final part
            break
        end
        local bs_ = bs --[[:! integer]]
        local be_ = be --[[:! integer]]

        -- Part content runs from pos to just before the boundary line
        -- (strip the \r\n before the boundary delimiter)
        local part_end = bs_ - 1
        if part_end >= 1 and byte(body, part_end) == 10 then  -- \n
            part_end = part_end - 1
        end
        local part_end2 = part_end --[[:! integer]]
        if part_end2 >= 1 and byte(body, part_end2) == 13 then  -- \r
            part_end = part_end2 - 1
        end

        local part_content = sub(body, pos_, part_end)

        -- Parse headers from part_content
        -- Headers end at first blank line (\r\n\r\n or \n\n)
        local header_end = part_content:find("\r\n\r\n", 1, true)
        local body_start
        if header_end then
            body_start = header_end + 4
        else
            header_end = part_content:find("\n\n", 1, true)
            if header_end then
                body_start = header_end + 2
            else
                -- No blank line: entire content is headers, body is empty
                header_end = #part_content
                body_start = #part_content + 1
            end
        end
        local header_end_ = header_end --[[:! integer]]
        local body_start_ = body_start --[[:! integer]]

        local header_block = sub(part_content, 1, header_end_ - 1)
        local part_body = sub(part_content, body_start_)

        -- Parse individual headers
        local headers = {} --: HeaderMap
        for line in (header_block .. "\n"):gmatch("([^\r\n]*)\r?\n") do
            if line ~= "" then
                local hname, hval = parse_header_line(line)
                if hname then
                    local hval_ = (hval or "")
                    headers[hname] = hval_
                end
            end
        end

        -- Parse Content-Disposition for convenience fields
        local cd_raw = headers["content-disposition"]
        local name, filename
        if cd_raw then
            local cd = parse_disposition(cd_raw)
            name = cd["name"]
            filename = cd["filename"]
        end

        parts[#parts + 1] = {
            headers = headers,
            body = part_body,
            name = name,
            filename = filename,
        }

        -- Advance past boundary
        -- Check for closing boundary
        local after = sub(body, be_ + 1, be_ + 2)
        if after == "--" then
            break  -- closing boundary reached
        end

        -- Move past boundary line ending
        pos = be_ + 1
        if sub(body, pos, pos) == "\r" then pos = pos + 1 end
        if sub(body, pos, pos) == "\n" then pos = pos + 1 end
    end

    return parts
end

-- ── Boundary parsing ──────────────────────────────────────────────────────────

--- Extract the boundary parameter from a Content-Type header value.
-- e.g. "multipart/form-data; boundary=abc123" -> "abc123"
--: (string) -> (string | nil, string | nil)
function M.parse_boundary(content_type)
    if not content_type then
        return nil, "multipart.parse_boundary: content_type is required"
    end
    -- Try quoted boundary first
    local b = content_type:match('[Bb]oundary%s*=%s*"([^"]*)"')
    if b then return b end
    -- Try unquoted boundary
    b = content_type:match('[Bb]oundary%s*=%s*([^;%s]+)')
    if b then return b end
    return nil, "multipart.parse_boundary: no boundary found in Content-Type"
end

return M
