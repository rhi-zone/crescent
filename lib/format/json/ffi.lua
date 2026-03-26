-- lib/format/json/ffi.lua
-- LuaJIT FFI scalar JSON encoder and decoder. Tier 2.
-- Same semantics as pure.lua; independent implementation.
-- Falls back to pure.lua if FFI is not available.
--
-- Key implementation choices vs pure.lua:
--   Decoder: works on a `const uint8_t *` pointer cast from the source string.
--            Byte access is `ptr[i]` (O(1), JIT-compiled) rather than
--            string.byte(s, pos) calls.
--   Encoder: pre-built escape table (256 entries, loaded once); string building
--            via table buffer + table.concat to avoid repeated .. concatenation.
--   String scanning in the decoder: tight loop advancing a raw pointer to find
--            the end of a string token.
--   Number parsing: delegates to tonumber (LuaJIT JIT-compiles it).

if not pcall(require, "ffi") then
    -- FFI unavailable: fall back to pure tier.
    return require("lib.format.json.pure")
end

local ffi = require("ffi")

local M = {}

-- ── Null sentinel ──────────────────────────────────────────────────────────────

local _ok, _null_mod = pcall(require, "lib.null")
M.null = _ok and _null_mod.null or {}

-- ── Encode ────────────────────────────────────────────────────────────────────

local str_format = string.format
local str_char   = string.char
local str_byte   = string.byte
local str_sub    = string.sub
local str_find   = string.find
local tbl_concat = table.concat
local math_floor = math.floor
local math_huge  = math.huge
local type_fn    = type

-- Pre-built escape table: ESC_TABLE[byte_value] = replacement string, or false
-- for bytes that need no escaping (pass through as-is).
local ESC_TABLE = {}
for i = 0, 255 do ESC_TABLE[i] = false end
for i = 0, 31 do
    ESC_TABLE[i] = str_format("\\u%04X", i)
end
ESC_TABLE[0x22] = '\\"'
ESC_TABLE[0x5C] = '\\\\'
ESC_TABLE[0x08] = "\\b"
ESC_TABLE[0x0C] = "\\f"
ESC_TABLE[0x0A] = "\\n"
ESC_TABLE[0x0D] = "\\r"
ESC_TABLE[0x09] = "\\t"

-- Pattern for bytes needing escaping (used to short-circuit the slow path).
local ESC_PAT = '[%z\1-\31"\\]'

-- Encode a Lua string into a JSON string. Appends to `buf` at index `n`.
local function ffi_encode_string(s, buf, n)
    buf[n] = '"'; n = n + 1
    if not str_find(s, ESC_PAT) then
        -- Fast path: no escaping needed.
        buf[n] = s; n = n + 1
    else
        -- Scan via FFI pointer for maximum throughput.
        local len = #s
        local ptr = ffi.cast("const uint8_t *", s)
        local start = 0  -- 0-indexed start of current safe run
        local i = 0
        while i < len do
            local b = ptr[i]
            local esc = ESC_TABLE[b]
            if esc then
                -- Flush safe run.
                if i > start then
                    buf[n] = ffi.string(ptr + start, i - start); n = n + 1
                end
                buf[n] = esc; n = n + 1
                start = i + 1
            end
            i = i + 1
        end
        -- Flush trailing safe run.
        if start < len then
            buf[n] = ffi.string(ptr + start, len - start); n = n + 1
        end
    end
    buf[n] = '"'; n = n + 1
    return n
end

-- Forward declaration for mutual recursion.
local ffi_encode_value

-- Encode a Lua table.
local function ffi_encode_table(t, buf, n, null_sentinel, visited, depth)
    if depth > 512 then
        error("maximum nesting depth (512) exceeded")
    end
    if visited[t] then
        error("circular reference detected")
    end
    visited[t] = true

    -- Array detection: same as pure tier.
    local len = #t
    local is_array = len > 0
    if is_array then
        local count = 0
        for _ in pairs(t) do count = count + 1 end
        if count ~= len then is_array = false end
    end

    if is_array then
        buf[n] = "["; n = n + 1
        for i = 1, len do
            if i > 1 then buf[n] = ","; n = n + 1 end
            n = ffi_encode_value(t[i], buf, n, null_sentinel, visited, depth + 1)
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
            n = ffi_encode_string(k, buf, n)
            buf[n] = ":"; n = n + 1
            n = ffi_encode_value(v, buf, n, null_sentinel, visited, depth + 1)
        end
        buf[n] = "}"; n = n + 1
    end

    visited[t] = nil
    return n
end

ffi_encode_value = function(v, buf, n, null_sentinel, visited, depth)
    local t = type_fn(v)
    if v == null_sentinel then
        buf[n] = "null"; n = n + 1
    elseif t == "nil" then
        buf[n] = "null"; n = n + 1
    elseif t == "boolean" then
        buf[n] = v and "true" or "false"; n = n + 1
    elseif t == "number" then
        if v ~= v or v == math_huge or v == -math_huge then
            error("invalid number (nan or inf)")
        end
        if v == math_floor(v) and v >= -2^53 and v <= 2^53 then
            buf[n] = str_format("%d", v); n = n + 1
        else
            buf[n] = str_format("%.17g", v); n = n + 1
        end
    elseif t == "string" then
        n = ffi_encode_string(v, buf, n)
    elseif t == "table" then
        n = ffi_encode_table(v, buf, n, null_sentinel, visited, depth)
    else
        error("cannot encode value of type " .. t)
    end
    return n
end

local function encode_raw(v, null_sentinel)
    null_sentinel = null_sentinel or M.null
    local buf = {}
    ffi_encode_value(v, buf, 1, null_sentinel, {}, 0)
    return tbl_concat(buf)
end

M.encode = function(v, null_sentinel)
    local ok, result = pcall(encode_raw, v, null_sentinel)
    if ok then return result end
    return nil, result
end

M._encode_raw = encode_raw

-- ── Decode ────────────────────────────────────────────────────────────────────

-- Hex nibble table (byte value → nibble or nil).
local HEX_VAL = {}
for i = 0, 9  do HEX_VAL[str_byte(tostring(i))]  = i end
for i = 0, 5  do
    HEX_VAL[str_byte("abcdef", i + 1)] = 10 + i
    HEX_VAL[str_byte("ABCDEF", i + 1)] = 10 + i
end

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

-- Decoder state: module-level to avoid passing via call stack.
local _ptr    -- const uint8_t* pointing to source string data
local _src    -- kept alive so GC does not collect the string
local _len    -- #_src
local _pos    -- current offset, 0-indexed
local _null   -- null sentinel
local _depth  -- recursion depth

local function decode_error(msg)
    error("unexpected token at offset " .. _pos .. ": " .. msg, 2)
end

-- Advance past whitespace (space, tab, CR, LF).
local function skip_ws()
    while _pos < _len do
        local b = _ptr[_pos]
        if b == 0x20 or b == 0x09 or b == 0x0A or b == 0x0D then
            _pos = _pos + 1
        else
            break
        end
    end
end

local decode_value  -- forward

-- Decode a JSON string starting after the opening `"`.
-- Returns the Lua string value; _pos is left past the closing `"`.
local function decode_string()
    local start = _pos
    local buf = nil  -- lazy

    while _pos < _len do
        local b = _ptr[_pos]
        if b == 0x22 then  -- closing "
            local result
            if buf then
                if _pos > start then
                    buf[#buf + 1] = ffi.string(_ptr + start, _pos - start)
                end
                result = tbl_concat(buf)
            else
                result = ffi.string(_ptr + start, _pos - start)
            end
            _pos = _pos + 1
            return result
        elseif b < 0x20 then
            decode_error("unescaped control character in string")
        elseif b == 0x5C then  -- backslash
            if not buf then
                buf = {}
                if _pos > start then
                    buf[1] = ffi.string(_ptr + start, _pos - start)
                end
            else
                if _pos > start then
                    buf[#buf + 1] = ffi.string(_ptr + start, _pos - start)
                end
            end
            _pos = _pos + 1
            if _pos >= _len then decode_error("truncated escape sequence") end
            local esc = _ptr[_pos]
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
                if _pos + 3 >= _len then decode_error("truncated \\u escape") end
                local va = HEX_VAL[_ptr[_pos]]
                local vb = HEX_VAL[_ptr[_pos + 1]]
                local vc = HEX_VAL[_ptr[_pos + 2]]
                local vd = HEX_VAL[_ptr[_pos + 3]]
                if not (va and vb and vc and vd) then
                    decode_error("invalid \\u escape")
                end
                local cp = va * 0x1000 + vb * 0x100 + vc * 0x10 + vd
                _pos = _pos + 4
                if cp >= 0xD800 and cp <= 0xDBFF then
                    -- High surrogate: look for \uDC00..\uDFFF.
                    if _pos + 5 < _len and _ptr[_pos] == 0x5C and _ptr[_pos + 1] == 0x75 then
                        local va2 = HEX_VAL[_ptr[_pos + 2]]
                        local vb2 = HEX_VAL[_ptr[_pos + 3]]
                        local vc2 = HEX_VAL[_ptr[_pos + 4]]
                        local vd2 = HEX_VAL[_ptr[_pos + 5]]
                        if va2 and vb2 and vc2 and vd2 then
                            local cp2 = va2 * 0x1000 + vb2 * 0x100 + vc2 * 0x10 + vd2
                            if cp2 >= 0xDC00 and cp2 <= 0xDFFF then
                                _pos = _pos + 6
                                cp = 0x10000 + (cp - 0xD800) * 0x400 + (cp2 - 0xDC00)
                                buf[#buf + 1] = codepoint_to_utf8(cp)
                            else
                                decode_error("unpaired high surrogate")
                            end
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

-- Decode a JSON number. _pos points at the first byte ('-' or digit).
local function decode_number()
    local start = _pos
    if _ptr[_pos] == 0x2D then _pos = _pos + 1 end
    if _pos >= _len then decode_error("truncated number") end
    local b = _ptr[_pos]
    if b == 0x30 then
        _pos = _pos + 1
    elseif b >= 0x31 and b <= 0x39 then
        _pos = _pos + 1
        while _pos < _len do
            b = _ptr[_pos]
            if b >= 0x30 and b <= 0x39 then _pos = _pos + 1
            else break end
        end
    else
        decode_error("invalid number")
    end
    if _pos < _len and _ptr[_pos] == 0x2E then
        _pos = _pos + 1
        local had = false
        while _pos < _len do
            b = _ptr[_pos]
            if b >= 0x30 and b <= 0x39 then _pos = _pos + 1; had = true
            else break end
        end
        if not had then decode_error("invalid number: trailing decimal point") end
    end
    if _pos < _len then
        b = _ptr[_pos]
        if b == 0x65 or b == 0x45 then
            _pos = _pos + 1
            if _pos < _len then
                b = _ptr[_pos]
                if b == 0x2B or b == 0x2D then _pos = _pos + 1 end
            end
            local had = false
            while _pos < _len do
                b = _ptr[_pos]
                if b >= 0x30 and b <= 0x39 then _pos = _pos + 1; had = true
                else break end
            end
            if not had then decode_error("invalid number: empty exponent") end
        end
    end
    local s = ffi.string(_ptr + start, _pos - start)
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
    if _pos >= _len then decode_error("truncated array") end
    if _ptr[_pos] == 0x5D then  -- ']'
        _pos = _pos + 1
        _depth = _depth - 1
        return arr
    end
    while true do
        i = i + 1
        arr[i] = decode_value()
        skip_ws()
        if _pos >= _len then decode_error("truncated array") end
        local b = _ptr[_pos]
        if b == 0x5D then
            _pos = _pos + 1; break
        elseif b == 0x2C then
            _pos = _pos + 1; skip_ws()
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
    if _pos >= _len then decode_error("truncated object") end
    if _ptr[_pos] == 0x7D then  -- '}'
        _pos = _pos + 1
        _depth = _depth - 1
        return obj
    end
    while true do
        if _pos >= _len or _ptr[_pos] ~= 0x22 then
            decode_error("expected string key in object")
        end
        _pos = _pos + 1
        local key = decode_string()
        skip_ws()
        if _pos >= _len or _ptr[_pos] ~= 0x3A then
            decode_error("expected ':' after object key")
        end
        _pos = _pos + 1
        skip_ws()
        obj[key] = decode_value()
        skip_ws()
        if _pos >= _len then decode_error("truncated object") end
        local b = _ptr[_pos]
        if b == 0x7D then
            _pos = _pos + 1; break
        elseif b == 0x2C then
            _pos = _pos + 1; skip_ws()
        else
            decode_error("expected ',' or '}' in object")
        end
    end
    _depth = _depth - 1
    return obj
end

decode_value = function()
    skip_ws()
    if _pos >= _len then decode_error("unexpected end of input") end
    local b = _ptr[_pos]
    _pos = _pos + 1
    if b == 0x22 then         return decode_string()
    elseif b == 0x7B then     return decode_object()
    elseif b == 0x5B then     return decode_array()
    elseif b == 0x74 then     -- t → true
        if _pos + 2 < _len and _ptr[_pos] == 0x72 and _ptr[_pos+1] == 0x75 and _ptr[_pos+2] == 0x65 then
            _pos = _pos + 3; return true
        end
        decode_error("invalid token")
    elseif b == 0x66 then     -- f → false
        if _pos + 3 < _len and _ptr[_pos] == 0x61 and _ptr[_pos+1] == 0x6C
                and _ptr[_pos+2] == 0x73 and _ptr[_pos+3] == 0x65 then
            _pos = _pos + 4; return false
        end
        decode_error("invalid token")
    elseif b == 0x6E then     -- n → null
        if _pos + 2 < _len and _ptr[_pos] == 0x75 and _ptr[_pos+1] == 0x6C and _ptr[_pos+2] == 0x6C then
            _pos = _pos + 3; return _null
        end
        decode_error("invalid token")
    elseif b == 0x2D or (b >= 0x30 and b <= 0x39) then
        _pos = _pos - 1
        return decode_number()
    else
        decode_error("unexpected character '" .. str_char(b) .. "'")
    end
end

local function decode_raw(s, null_sentinel)
    _src   = s  -- keep string alive
    _len   = #s
    _ptr   = ffi.cast("const uint8_t *", s)
    _pos   = 0   -- 0-indexed
    _null  = null_sentinel or M.null
    _depth = 0
    local v = decode_value()
    skip_ws()
    if _pos < _len then
        decode_error("trailing garbage after JSON value")
    end
    return v
end

M.decode = function(s, null_sentinel)
    local ok, result = pcall(decode_raw, s, null_sentinel)
    if ok then return result end
    return nil, result
end

M._decode_raw = decode_raw

-- ── Aliases ───────────────────────────────────────────────────────────────────

M.value_to_json = M._encode_raw
M.json_to_value = M._decode_raw

return M
