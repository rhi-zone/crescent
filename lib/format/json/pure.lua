-- lib/format/json/pure.lua
-- Pure Lua JSON encoder and decoder. Tier 1 of the three-tier JSON library.
-- Works on PUC-Rio Lua 5.2+ and LuaJIT. No dependencies.
--
-- Public API (same as the module):
--   M.encode(value)  -> string | (nil, errmsg)
--   M.decode(str)    -> value  | (nil, errmsg)
--   M.null           -- sentinel for JSON null
--
-- Encoder rules:
--   nil            → omitted from objects (error if top-level or array element)
--   M.null         → "null"
--   boolean        → "true" / "false"
--   number         → %.17g for doubles, integer format for exact integers
--   string         → UTF-8 bytes with minimal escaping
--   table (array)  → [v1,v2,...] when #t>0 and keys are consecutive 1..#t
--   table (object) → {"k":v,...} otherwise
--   cycle          → error
--   depth > 512    → error
--
-- Decoder rules:
--   Full JSON spec: objects, arrays, strings, numbers, true/false/null.
--   Strict: trailing garbage after top-level value is an error.
--   Error messages include byte offset: "unexpected token at offset N".

local M = {}

-- ── Null sentinel ──────────────────────────────────────────────────────────────

-- Try to share the null sentinel with lib.null if it exists.
local _ok, _null_mod = pcall(require, "lib.null")
M.null = _ok and _null_mod.null or {}

-- ── Encode ────────────────────────────────────────────────────────────────────

local str_format  = string.format
local str_byte    = string.byte
local str_char    = string.char
local str_find    = string.find
local str_sub     = string.sub
local tbl_concat  = table.concat
local math_floor  = math.floor
local math_huge   = math.huge
local type_fn     = type

-- Escape table for the 256 possible byte values.
-- Built once at module load; indexed by byte value (0-255).
-- nil means: emit the byte as-is (no escaping needed).
local ESC = {}
-- Control characters U+0000..U+001F
for i = 0, 31 do
    ESC[i] = str_format("\\u%04X", i)
end
-- Override the named escapes (more compact):
ESC[0x22] = '\\"'          -- "
ESC[0x5C] = '\\\\'         -- \
ESC[0x08] = "\\b"
ESC[0x0C] = "\\f"
ESC[0x0A] = "\\n"
ESC[0x0D] = "\\r"
ESC[0x09] = "\\t"

-- Pattern: any byte that needs escaping.
-- Matches control chars (0x00-0x1F), double-quote (0x22), backslash (0x5C).
local ESC_PAT = '[%z\1-\31"\\]'

-- Encode a Lua string into a JSON string (with surrounding quotes).
-- Appends to `buf` starting at index `n`; returns new `n`.
local function encode_string(s, buf, n)
    buf[n] = '"'; n = n + 1
    -- Fast path: no escaping needed.
    if not str_find(s, ESC_PAT) then
        buf[n] = s; n = n + 1
    else
        -- Walk the string; emit runs of safe bytes, then escape sequences.
        local len = #s
        local start = 1
        local i = 1
        while i <= len do
            local b = str_byte(s, i)
            local esc = ESC[b]
            if esc then
                -- Flush safe run before this byte.
                if i > start then
                    buf[n] = str_sub(s, start, i - 1); n = n + 1
                end
                buf[n] = esc; n = n + 1
                start = i + 1
            end
            i = i + 1
        end
        -- Flush trailing safe run.
        if start <= len then
            buf[n] = str_sub(s, start, len); n = n + 1
        end
    end
    buf[n] = '"'; n = n + 1
    return n
end

-- Forward declaration for mutual recursion.
local encode_value

-- Encode a Lua table. Determines array vs object heuristic.
local function encode_table(t, buf, n, null_sentinel, visited, depth)
    if depth > 512 then
        error("maximum nesting depth (512) exceeded")
    end
    if visited[t] then
        error("circular reference detected")
    end
    visited[t] = true

    -- Array detection: #t > 0 and all keys are consecutive integers 1..#t.
    -- We also check there are no extra non-integer or out-of-range keys.
    local len = #t
    local is_array = len > 0
    if is_array then
        -- Verify no extra keys beyond 1..len.
        local count = 0
        for _ in pairs(t) do count = count + 1 end
        if count ~= len then is_array = false end
    end

    if is_array then
        buf[n] = "["; n = n + 1
        for i = 1, len do
            if i > 1 then buf[n] = ","; n = n + 1 end
            n = encode_value(t[i], buf, n, null_sentinel, visited, depth + 1)
        end
        buf[n] = "]"; n = n + 1
    else
        buf[n] = "{"; n = n + 1
        local first = true
        for k, v in pairs(t) do
            if type_fn(k) ~= "string" then
                error("object key must be a string, got " .. type_fn(k))
            end
            if not first then buf[n] = ","; n = n + 1 end
            first = false
            n = encode_string(k, buf, n)
            buf[n] = ":"; n = n + 1
            n = encode_value(v, buf, n, null_sentinel, visited, depth + 1)
        end
        buf[n] = "}"; n = n + 1
    end

    visited[t] = nil
    return n
end

-- Encode any Lua value to JSON, appending to `buf` at index `n`.
encode_value = function(v, buf, n, null_sentinel, visited, depth)
    local t = type_fn(v)
    if v == null_sentinel then
        buf[n] = "null"; n = n + 1
    elseif t == "nil" then
        -- nil inside an array becomes null (caller must handle omission in objects)
        buf[n] = "null"; n = n + 1
    elseif t == "boolean" then
        buf[n] = v and "true" or "false"; n = n + 1
    elseif t == "number" then
        if v ~= v or v == math_huge or v == -math_huge then
            error("invalid number (nan or inf)")
        end
        -- Use integer formatting for values that are exact integers in safe range.
        if v == math_floor(v) and v >= -2^53 and v <= 2^53 then
            buf[n] = str_format("%d", v); n = n + 1
        else
            buf[n] = str_format("%.17g", v); n = n + 1
        end
    elseif t == "string" then
        n = encode_string(v, buf, n)
    elseif t == "table" then
        n = encode_table(v, buf, n, null_sentinel, visited, depth)
    else
        error("cannot encode value of type " .. t)
    end
    return n
end

-- Raw encode: throws on error.
local function encode_raw(v, null_sentinel)
    null_sentinel = null_sentinel or M.null
    local buf = {}
    local n = encode_value(v, buf, 1, null_sentinel, {}, 0)
    return tbl_concat(buf)
end

-- Public encode: returns (result) or (nil, errmsg).
M.encode = function(v, null_sentinel)
    local ok, result = pcall(encode_raw, v, null_sentinel)
    if ok then return result end
    return nil, result
end

-- Internal (throws).
M._encode_raw = encode_raw

-- ── Decode ────────────────────────────────────────────────────────────────────

-- Hex digit value table (byte value → nibble, or nil for non-hex).
local HEX_VAL = {}
for i = 0, 9  do HEX_VAL[str_byte(tostring(i))]  = i end
for i = 0, 5  do
    HEX_VAL[str_byte("abcdef", i + 1)] = 10 + i
    HEX_VAL[str_byte("ABCDEF", i + 1)] = 10 + i
end

-- Encode a Unicode codepoint (U+0000..U+10FFFF) as a UTF-8 byte sequence.
local function codepoint_to_utf8(cp)
    if cp < 0x80 then
        return str_char(cp)
    elseif cp < 0x800 then
        return str_char(
            0xC0 + math_floor(cp / 0x40),
            0x80 + (cp % 0x40)
        )
    elseif cp < 0x10000 then
        return str_char(
            0xE0 + math_floor(cp / 0x1000),
            0x80 + math_floor((cp % 0x1000) / 0x40),
            0x80 + (cp % 0x40)
        )
    else
        return str_char(
            0xF0 + math_floor(cp / 0x40000),
            0x80 + math_floor((cp % 0x40000) / 0x1000),
            0x80 + math_floor((cp % 0x1000) / 0x40),
            0x80 + (cp % 0x40)
        )
    end
end

-- Parse four hex digits from `s` at position `pos`.
-- Returns the 16-bit value, or nil on failure.
local function parse_hex4(s, pos)
    local a, b, c, d = str_byte(s, pos, pos + 3)
    if not d then return nil end
    local va = HEX_VAL[a]; if not va then return nil end
    local vb = HEX_VAL[b]; if not vb then return nil end
    local vc = HEX_VAL[c]; if not vc then return nil end
    local vd = HEX_VAL[d]; if not vd then return nil end
    return va * 0x1000 + vb * 0x100 + vc * 0x10 + vd
end

-- Decoder state (all upvalues to avoid passing through every call).
-- These are set by decode_raw before each parse.
local _src     -- the JSON string
local _len     -- #_src
local _pos     -- current byte offset (1-indexed)
local _null    -- null sentinel value
local _depth   -- current recursion depth

local function decode_error(msg)
    error("unexpected token at offset " .. (_pos - 1) .. ": " .. msg, 2)
end

-- Skip whitespace. Advances _pos.
local function skip_ws()
    while _pos <= _len do
        local b = str_byte(_src, _pos)
        if b == 0x20 or b == 0x09 or b == 0x0A or b == 0x0D then
            _pos = _pos + 1
        else
            break
        end
    end
end

-- Forward declaration.
local decode_value

-- Decode a JSON string starting after the opening `"`.
-- On entry _pos points to the first byte of string content.
-- Returns the Lua string; advances _pos past the closing `"`.
local function decode_string()
    local start = _pos
    local buf = nil   -- lazy: only allocated when escapes present

    while _pos <= _len do
        local b = str_byte(_src, _pos)
        if b == 0x22 then  -- closing "
            local result
            if buf then
                -- Flush remaining safe run.
                if _pos > start then
                    buf[#buf + 1] = str_sub(_src, start, _pos - 1)
                end
                result = tbl_concat(buf)
            else
                result = str_sub(_src, start, _pos - 1)
            end
            _pos = _pos + 1  -- consume "
            return result
        elseif b < 0x20 then  -- unescaped control character
            decode_error("unescaped control character in string")
        elseif b == 0x5C then  -- backslash
            if not buf then
                -- Lazy-allocate: flush bytes before this backslash.
                buf = {}
                if _pos > start then
                    buf[1] = str_sub(_src, start, _pos - 1)
                end
            else
                if _pos > start then
                    buf[#buf + 1] = str_sub(_src, start, _pos - 1)
                end
            end
            _pos = _pos + 1  -- consume backslash
            if _pos > _len then decode_error("truncated escape sequence") end
            local esc = str_byte(_src, _pos)
            _pos = _pos + 1
            if esc == 0x22 then buf[#buf + 1] = '"'
            elseif esc == 0x5C then buf[#buf + 1] = '\\'
            elseif esc == 0x2F then buf[#buf + 1] = '/'
            elseif esc == 0x62 then buf[#buf + 1] = '\b'
            elseif esc == 0x66 then buf[#buf + 1] = '\f'
            elseif esc == 0x6E then buf[#buf + 1] = '\n'
            elseif esc == 0x72 then buf[#buf + 1] = '\r'
            elseif esc == 0x74 then buf[#buf + 1] = '\t'
            elseif esc == 0x75 then  -- \uXXXX
                local cp = parse_hex4(_src, _pos)
                if not cp then decode_error("invalid \\u escape") end
                _pos = _pos + 4
                -- Surrogate pair handling.
                if cp >= 0xD800 and cp <= 0xDBFF then
                    -- High surrogate: expect \uDC00..\uDFFF immediately after.
                    if str_byte(_src, _pos) == 0x5C and str_byte(_src, _pos + 1) == 0x75 then
                        local cp2 = parse_hex4(_src, _pos + 2)
                        if cp2 and cp2 >= 0xDC00 and cp2 <= 0xDFFF then
                            _pos = _pos + 6
                            cp = 0x10000 + (cp - 0xD800) * 0x400 + (cp2 - 0xDC00)
                            buf[#buf + 1] = codepoint_to_utf8(cp)
                        else
                            decode_error("unpaired high surrogate")
                        end
                    else
                        decode_error("unpaired high surrogate")
                    end
                elseif cp >= 0xDC00 and cp <= 0xDFFF then
                    decode_error("unpaired low surrogate")
                else
                    buf[#buf + 1] = codepoint_to_utf8(cp)
                end
            else
                decode_error("invalid escape sequence: \\" .. str_char(esc))
            end
            start = _pos
        else
            _pos = _pos + 1
        end
    end
    decode_error("unterminated string")
end

-- Decode a JSON number starting at _pos (the first byte, e.g. '-' or digit).
local function decode_number()
    local start = _pos
    -- Optional minus.
    if str_byte(_src, _pos) == 0x2D then _pos = _pos + 1 end
    if _pos > _len then decode_error("truncated number") end
    local b = str_byte(_src, _pos)
    if b == 0x30 then  -- leading zero: only "0", "0.xxx", "0eXXX" allowed
        _pos = _pos + 1
    elseif b >= 0x31 and b <= 0x39 then  -- 1-9
        _pos = _pos + 1
        while _pos <= _len do
            b = str_byte(_src, _pos)
            if b >= 0x30 and b <= 0x39 then _pos = _pos + 1
            else break end
        end
    else
        decode_error("invalid number")
    end
    -- Optional fractional part.
    if _pos <= _len and str_byte(_src, _pos) == 0x2E then
        _pos = _pos + 1
        local had_digit = false
        while _pos <= _len do
            b = str_byte(_src, _pos)
            if b >= 0x30 and b <= 0x39 then _pos = _pos + 1; had_digit = true
            else break end
        end
        if not had_digit then decode_error("invalid number: trailing decimal point") end
    end
    -- Optional exponent.
    if _pos <= _len then
        b = str_byte(_src, _pos)
        if b == 0x65 or b == 0x45 then  -- e or E
            _pos = _pos + 1
            if _pos <= _len then
                b = str_byte(_src, _pos)
                if b == 0x2B or b == 0x2D then _pos = _pos + 1 end
            end
            local had_digit = false
            while _pos <= _len do
                b = str_byte(_src, _pos)
                if b >= 0x30 and b <= 0x39 then _pos = _pos + 1; had_digit = true
                else break end
            end
            if not had_digit then decode_error("invalid number: empty exponent") end
        end
    end
    local s = str_sub(_src, start, _pos - 1)
    local n = tonumber(s)
    if not n then decode_error("invalid number: " .. s) end
    return n
end

-- Decode a JSON array. _pos points past the opening '['.
local function decode_array()
    _depth = _depth + 1
    if _depth > 512 then decode_error("nesting depth exceeds 512") end
    local arr = {}
    local i = 0
    skip_ws()
    if _pos > _len then decode_error("truncated array") end
    if str_byte(_src, _pos) == 0x5D then  -- empty array: ']'
        _pos = _pos + 1
        _depth = _depth - 1
        return arr
    end
    while true do
        i = i + 1
        arr[i] = decode_value()
        skip_ws()
        if _pos > _len then decode_error("truncated array") end
        local b = str_byte(_src, _pos)
        if b == 0x5D then  -- ']'
            _pos = _pos + 1
            break
        elseif b == 0x2C then  -- ','
            _pos = _pos + 1
            skip_ws()
        else
            decode_error("expected ',' or ']' in array")
        end
    end
    _depth = _depth - 1
    return arr
end

-- Decode a JSON object. _pos points past the opening '{'.
local function decode_object()
    _depth = _depth + 1
    if _depth > 512 then decode_error("nesting depth exceeds 512") end
    local obj = {}
    skip_ws()
    if _pos > _len then decode_error("truncated object") end
    if str_byte(_src, _pos) == 0x7D then  -- empty object: '}'
        _pos = _pos + 1
        _depth = _depth - 1
        return obj
    end
    while true do
        -- Key must be a string.
        if _pos > _len or str_byte(_src, _pos) ~= 0x22 then
            decode_error("expected string key in object")
        end
        _pos = _pos + 1  -- consume opening "
        local key = decode_string()
        skip_ws()
        -- Colon.
        if _pos > _len or str_byte(_src, _pos) ~= 0x3A then
            decode_error("expected ':' after object key")
        end
        _pos = _pos + 1
        skip_ws()
        obj[key] = decode_value()
        skip_ws()
        if _pos > _len then decode_error("truncated object") end
        local b = str_byte(_src, _pos)
        if b == 0x7D then  -- '}'
            _pos = _pos + 1
            break
        elseif b == 0x2C then  -- ','
            _pos = _pos + 1
            skip_ws()
        else
            decode_error("expected ',' or '}' in object")
        end
    end
    _depth = _depth - 1
    return obj
end

-- Decode a single JSON value; _pos points at the first byte (after whitespace).
decode_value = function()
    skip_ws()
    if _pos > _len then decode_error("unexpected end of input") end
    local b = str_byte(_src, _pos)
    _pos = _pos + 1
    if b == 0x22 then          -- "  → string
        return decode_string()
    elseif b == 0x7B then      -- {  → object
        return decode_object()
    elseif b == 0x5B then      -- [  → array
        return decode_array()
    elseif b == 0x74 then      -- t  → true
        if str_sub(_src, _pos, _pos + 2) == "rue" then
            _pos = _pos + 3; return true
        end
        decode_error("invalid token")
    elseif b == 0x66 then      -- f  → false
        if str_sub(_src, _pos, _pos + 3) == "alse" then
            _pos = _pos + 4; return false
        end
        decode_error("invalid token")
    elseif b == 0x6E then      -- n  → null
        if str_sub(_src, _pos, _pos + 2) == "ull" then
            _pos = _pos + 3; return _null
        end
        decode_error("invalid token")
    elseif b == 0x2D or (b >= 0x30 and b <= 0x39) then  -- - or 0-9
        _pos = _pos - 1  -- unget so decode_number sees the first byte
        return decode_number()
    else
        decode_error("unexpected character '" .. str_char(b) .. "'")
    end
end

-- Raw decode: throws on error.
local function decode_raw(s, null_sentinel)
    _src   = s
    _len   = #s
    _pos   = 1
    _null  = null_sentinel or M.null
    _depth = 0
    local v = decode_value()
    skip_ws()
    if _pos <= _len then
        decode_error("trailing garbage after JSON value")
    end
    return v
end

-- Public decode: returns (result) or (nil, errmsg).
M.decode = function(s, null_sentinel)
    local ok, result = pcall(decode_raw, s, null_sentinel)
    if ok then return result end
    return nil, result
end

-- Internal (throws).
M._decode_raw = decode_raw

-- ── Aliases ───────────────────────────────────────────────────────────────────

M.value_to_json = M._encode_raw
M.json_to_value = M._decode_raw

return M
