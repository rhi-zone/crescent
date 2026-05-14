-- lib/format/json/ffi.lua
-- LuaJIT FFI scalar JSON encoder and decoder. Tier 2.
-- Same semantics as pure.lua; independent implementation.
-- Falls back to pure.lua if FFI is not available.
--
-- Key implementation choices vs pure.lua:
--   Decoder: uses `const uint8_t *` pointer for direct byte access (0-indexed).
--            Unlike pure.lua, upvalue-based state (_ptr8, _pos, _len, _null)
--            allows LuaJIT to trace through the mutually-recursive
--            decode_value/decode_array/decode_object calls without
--            `NYI: return to lower frame` aborts. De-recursification was tried
--            (goto-based iterative form) but added frame-table overhead that
--            outweighed the recursion cost — recursive form is 10-20% faster
--            on nested structures.
--            Whitespace skip: string.find C call, no byte loop competing for
--            JIT root-trace budget.
--            String extraction: str_sub (avoids ffi.string() overhead for the
--            short strings typical in JSON keys/values).
--   Encoder: pre-built escape table (256 entries, loaded once); string
--            building via table buffer + table.concat. Encoder uses ffi.cast
--            to scan for escape bytes on the escape path.
--   Number parsing: delegates to tonumber (LuaJIT JIT-compiles it).
--   Performance profile vs pure.lua:
--     FFI faster: small objects (~20%), deeply nested (up to 12%)
--     FFI slower: large flat objects (~12-14%)
--     FFI equal:  integer arrays, encode
--   Real throughput gains require a C library (simd tier — see simd.lua).

if not pcall(require, "ffi") then
    -- FFI unavailable: fall back to pure tier.
    return require("lib.format.json.pure")
end

local ffi = require("ffi")

local M = {}

-- ── Null sentinel ──────────────────────────────────────────────────────────────

local _ok, _null_mod = pcall(require, "lib.null")
M.null = _ok and _null_mod.null or {}

-- ── FFI type declarations ─────────────────────────────────────────────────────

ffi.cdef[[
    typedef unsigned char uint8_t;
]]

-- ── String scanning patterns ──────────────────────────────────────────────────

-- Skip whitespace: find first non-ws byte.
local WS_SKIP_PAT = "[^ \t\n\r]"

-- Find next JSON string special character: closing ", backslash, or control
-- chars 1-31. NUL (0x00) is formally invalid in JSON strings and excluded from
-- this range to avoid NUL-terminated C string issues in the pattern engine.
local STR_SCAN_PAT = '["\\\1-\31]'

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

-- Pre-built escape table: ESC_TABLE[byte_value] = replacement string, or false.
local ESC_TABLE = {} --: { [integer]: string | boolean }
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

local ESC_PAT = '[%z\1-\31"\\]'

--: (s: string, buf: { [integer]: string }, n: integer) -> integer
local function ffi_encode_string(s, buf, n)
    buf[n] = '"'; n = n + 1
    if not str_find(s, ESC_PAT) then
        buf[n] = s; n = n + 1
    else
        local len = #s
        -- ffi.cast("const uint8_t *", s) returns opaque `cdata` in stdlib (the
        -- pointer-typed CTypeMap overload only covers unqualified scalars).
        -- Hold the pointer as `number` for arithmetic, and re-cast each
        -- offset back to Ptr<integer> for ffi.string. These are FFI-boundary
        -- casts: there's no source we can fix without extending stdlib's
        -- ffi.cast overloads to cover qualified pointer types.
        local ptr = ffi.cast("const uint8_t *", s) --[[:! Ptr<integer>]]
        local start = 0
        local i = 0
        while i < len do
            local b = ptr[i]
            local esc = ESC_TABLE[b]
            if type(esc) == "string" then
                if i > start then
                    buf[n] = ffi.string((ptr + start) --[[:! Ptr<integer>]], i - start); n = n + 1
                end
                buf[n] = esc; n = n + 1
                start = i + 1
            end
            i = i + 1
        end
        if start < len then
            buf[n] = ffi.string((ptr + start) --[[:! Ptr<integer>]], len - start); n = n + 1
        end
    end
    buf[n] = '"'; n = n + 1
    return n
end

--:: FfiEncodeValueFn = (v: unknown, buf: { [integer]: string }, n: integer, null_sentinel: unknown, visited: { [unknown]: boolean | nil }, depth: integer) -> integer
-- Forward decl for mutual recursion; assigned below before any call.
local ffi_encode_value --: FfiEncodeValueFn | nil

--: (t: { [unknown]: unknown }, buf: { [integer]: string }, n: integer, null_sentinel: unknown, visited: { [unknown]: boolean | nil }, depth: integer) -> integer
local function ffi_encode_table(t, buf, n, null_sentinel, visited, depth)
    if depth > 512 then error("maximum nesting depth (512) exceeded") end
    if visited[t] then error("circular reference detected") end
    visited[t] = true

    local len = #t
    local is_array = len > 0
    if is_array then
        local count = 0
        for _ in pairs(t) do count = count + 1 end
        if count ~= len then is_array = false end
    end

    if not ffi_encode_value then error("ffi_encode_value not initialized") end
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
            if type(k) ~= "string" then
                error("object key must be a string, got " .. type(k))
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

--: (v: unknown, buf: { [integer]: string }, n: integer, null_sentinel: unknown, visited: { [unknown]: boolean | nil }, depth: integer) -> integer
ffi_encode_value = function(v, buf, n, null_sentinel, visited, depth)
    if v == null_sentinel then
        buf[n] = "null"; n = n + 1
    elseif type(v) == "nil" then
        buf[n] = "null"; n = n + 1
    elseif type(v) == "boolean" then
        buf[n] = v and "true" or "false"; n = n + 1
    elseif type(v) == "number" then
        if v ~= v or v == math_huge or v == -math_huge then
            error("invalid number (nan or inf)")
        end
        if v == math_floor(v) and v >= -2^53 and v <= 2^53 then
            buf[n] = str_format("%d", v); n = n + 1
        else
            buf[n] = str_format("%.17g", v); n = n + 1
        end
    elseif type(v) == "string" then
        n = ffi_encode_string(v, buf, n)
    elseif type(v) == "table" then
        n = ffi_encode_table(v, buf, n, null_sentinel, visited, depth)
    else
        error("cannot encode value of type " .. type(v))
    end
    return n
end

--: (v: unknown, null_sentinel: unknown) -> string
local function encode_raw(v, null_sentinel)
    null_sentinel = null_sentinel or M.null
    local buf = {}
    if not ffi_encode_value then error("ffi_encode_value not initialized") end
    ffi_encode_value(v, buf, 1, null_sentinel, {}, 0)
    return tbl_concat(buf)
end

--: (v: unknown, null_sentinel: unknown) -> (string | nil, string | nil)
M.encode = function(v, null_sentinel)
    local ok, result = pcall(encode_raw, v, null_sentinel)
    if ok then return result end
    return nil, result
end

M._encode_raw = encode_raw

-- ── Decode ────────────────────────────────────────────────────────────────────

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
        return str_char(0xC0 + math_floor(cp / 0x40), 0x80 + (cp % 0x40))
    elseif cp < 0x10000 then
        return str_char(
            0xE0 + math_floor(cp / 0x1000),
            0x80 + math_floor((cp % 0x1000) / 0x40),
            0x80 + (cp % 0x40))
    else
        return str_char(
            0xF0 + math_floor(cp / 0x40000),
            0x80 + math_floor((cp % 0x40000) / 0x1000),
            0x80 + math_floor((cp % 0x1000) / 0x40),
            0x80 + (cp % 0x40))
    end
end

local _ptr8 --: cdata | nil
local _src  = "" --: string
local _len  = 0  --: integer
local _pos  = 0  --: integer
local _null --: unknown

local function decode_error(msg)
    error("unexpected token at offset " .. _pos .. ": " .. msg, 2)
end

-- Decode a JSON string starting after the opening `"`.
-- _pos (0-indexed) points to the first byte of string content on entry.
-- Byte access uses _ptr8[_pos]; string extraction uses str_sub (faster than
-- ffi.string() for the short strings typical in JSON keys/values).
--: () -> string
local function decode_string()
    local start = _pos
    local buf = nil --: { [integer]: string } | nil

    while _pos < _len do
        local b = _ptr8[_pos]
        if b == 0x22 then  -- closing "
            -- content: 0-indexed [start, _pos-1] = 1-indexed [start+1, _pos]
            local result
            if buf then
                if _pos > start then
                    buf[#buf + 1] = str_sub(_src, start + 1, _pos)
                end
                result = tbl_concat(buf)
            else
                result = str_sub(_src, start + 1, _pos)
            end
            _pos = _pos + 1
            return result
        elseif b < 0x20 then
            decode_error("unescaped control character in string")
        elseif b == 0x5C then  -- backslash
            local sbuf
            if not buf then
                sbuf = {} --: { [integer]: string }
                if _pos > start then
                    sbuf[1] = str_sub(_src, start + 1, _pos)
                end
                buf = sbuf
            else
                sbuf = buf
                if _pos > start then
                    sbuf[#sbuf + 1] = str_sub(_src, start + 1, _pos)
                end
            end
            _pos = _pos + 1
            if _pos >= _len then decode_error("truncated escape sequence") end
            local esc = _ptr8[_pos]
            _pos = _pos + 1
            if esc == 0x22 then sbuf[#sbuf + 1] = '"'
            elseif esc == 0x5C then sbuf[#sbuf + 1] = '\\'
            elseif esc == 0x2F then sbuf[#sbuf + 1] = '/'
            elseif esc == 0x62 then sbuf[#sbuf + 1] = '\b'
            elseif esc == 0x66 then sbuf[#sbuf + 1] = '\f'
            elseif esc == 0x6E then sbuf[#sbuf + 1] = '\n'
            elseif esc == 0x72 then sbuf[#sbuf + 1] = '\r'
            elseif esc == 0x74 then sbuf[#sbuf + 1] = '\t'
            elseif esc == 0x75 then
                if _pos + 3 >= _len then decode_error("truncated \\u escape") end
                local va = HEX_VAL[_ptr8[_pos]]
                local vb = HEX_VAL[_ptr8[_pos + 1]]
                local vc = HEX_VAL[_ptr8[_pos + 2]]
                local vd = HEX_VAL[_ptr8[_pos + 3]]
                if not (va and vb and vc and vd) then
                    decode_error("invalid \\u escape")
                end
                local cp = va * 0x1000 + vb * 0x100 + vc * 0x10 + vd
                _pos = _pos + 4
                if cp >= 0xD800 and cp <= 0xDBFF then
                    if _pos + 5 < _len and _ptr8[_pos] == 0x5C and _ptr8[_pos + 1] == 0x75 then
                        local va2 = HEX_VAL[_ptr8[_pos + 2]]
                        local vb2 = HEX_VAL[_ptr8[_pos + 3]]
                        local vc2 = HEX_VAL[_ptr8[_pos + 4]]
                        local vd2 = HEX_VAL[_ptr8[_pos + 5]]
                        if va2 and vb2 and vc2 and vd2 then
                            local cp2 = va2 * 0x1000 + vb2 * 0x100 + vc2 * 0x10 + vd2
                            if cp2 >= 0xDC00 and cp2 <= 0xDFFF then
                                _pos = _pos + 6
                                cp = 0x10000 + (cp - 0xD800) * 0x400 + (cp2 - 0xDC00)
                                sbuf[#sbuf + 1] = codepoint_to_utf8(cp)
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
                    sbuf[#sbuf + 1] = codepoint_to_utf8(cp)
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


-- Decoder is structured as mutually-recursive functions sharing upvalue state.
-- Unlike pure.lua, upvalue-based state (_ptr8, _pos, _len, _null) allows LuaJIT
-- to trace through the recursive calls without `NYI: return to lower frame`
-- aborts — all hot state lives in the outer upvalue scope, not in call frames.
-- De-recursification (goto-based iterative approach) was tried but adds frame-
-- table access overhead that exceeds the recursion cost; the recursive form is
-- 10–20% faster on nested structures.

local _depth = 0

local function decode_number()
    local start = _pos
    if _ptr8[_pos] == 0x2D then _pos = _pos + 1 end
    if _pos >= _len then decode_error("truncated number") end
    local b = _ptr8[_pos]
    if b == 0x30 then
        _pos = _pos + 1
    elseif b >= 0x31 and b <= 0x39 then
        _pos = _pos + 1
        while _pos < _len do
            b = _ptr8[_pos]
            if b >= 0x30 and b <= 0x39 then _pos = _pos + 1 else break end
        end
    else
        decode_error("invalid number")
    end
    if _pos < _len and _ptr8[_pos] == 0x2E then
        _pos = _pos + 1
        local had = false
        while _pos < _len do
            b = _ptr8[_pos]
            if b >= 0x30 and b <= 0x39 then _pos = _pos + 1; had = true else break end
        end
        if not had then decode_error("invalid number: trailing decimal point") end
    end
    if _pos < _len then
        b = _ptr8[_pos]
        if b == 0x65 or b == 0x45 then
            _pos = _pos + 1
            if _pos < _len then
                b = _ptr8[_pos]
                if b == 0x2B or b == 0x2D then _pos = _pos + 1 end
            end
            local had = false
            while _pos < _len do
                b = _ptr8[_pos]
                if b >= 0x30 and b <= 0x39 then _pos = _pos + 1; had = true else break end
            end
            if not had then decode_error("invalid number: empty exponent") end
        end
    end
    -- content: 0-indexed [start, _pos-1] = 1-indexed [start+1, _pos]
    local s = str_sub(_src, start + 1, _pos)
    local n = tonumber(s)
    if not n then decode_error("invalid number: " .. s) end
    return n
end

local decode_value

local function skip_ws()
    if _pos >= _len then return end
    local b = _ptr8[_pos]
    if b ~= 0x20 and b ~= 0x09 and b ~= 0x0A and b ~= 0x0D then return end
    local nws = str_find(_src, WS_SKIP_PAT, _pos + 1)  -- +1: 0→1-indexed
    if nws then _pos = nws - 1 else _pos = _len end  -- back to 0-indexed
end

local function decode_array()
    _depth = _depth + 1
    if _depth > 512 then decode_error("nesting depth exceeds 512") end
    local arr = {}
    local i = 0
    skip_ws()
    if _pos >= _len then decode_error("truncated array") end
    if _ptr8[_pos] == 0x5D then
        _pos = _pos + 1; _depth = _depth - 1; return arr
    end
    while true do
        i = i + 1
        arr[i] = decode_value()
        skip_ws()
        if _pos >= _len then decode_error("truncated array") end
        local b = _ptr8[_pos]
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

local function decode_object()
    _depth = _depth + 1
    if _depth > 512 then decode_error("nesting depth exceeds 512") end
    local obj = {}
    skip_ws()
    if _pos >= _len then decode_error("truncated object") end
    if _ptr8[_pos] == 0x7D then
        _pos = _pos + 1; _depth = _depth - 1; return obj
    end
    while true do
        if _pos >= _len or _ptr8[_pos] ~= 0x22 then
            decode_error("expected string key in object")
        end
        _pos = _pos + 1
        local key = decode_string()
        skip_ws()
        if _pos >= _len or _ptr8[_pos] ~= 0x3A then
            decode_error("expected ':' after object key")
        end
        _pos = _pos + 1
        skip_ws()
        obj[key] = decode_value()
        skip_ws()
        if _pos >= _len then decode_error("truncated object") end
        local b = _ptr8[_pos]
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
    local b = _ptr8[_pos]
    _pos = _pos + 1
    if b == 0x22 then         return decode_string()
    elseif b == 0x7B then     return decode_object()
    elseif b == 0x5B then     return decode_array()
    elseif b == 0x74 then
        if _pos + 2 < _len and _ptr8[_pos] == 0x72 and _ptr8[_pos+1] == 0x75 and _ptr8[_pos+2] == 0x65 then
            _pos = _pos + 3; return true
        end
        decode_error("invalid token")
    elseif b == 0x66 then
        if _pos + 3 < _len and _ptr8[_pos] == 0x61 and _ptr8[_pos+1] == 0x6C
                and _ptr8[_pos+2] == 0x73 and _ptr8[_pos+3] == 0x65 then
            _pos = _pos + 4; return false
        end
        decode_error("invalid token")
    elseif b == 0x6E then
        if _pos + 2 < _len and _ptr8[_pos] == 0x75 and _ptr8[_pos+1] == 0x6C and _ptr8[_pos+2] == 0x6C then
            _pos = _pos + 3; return _null
        end
        decode_error("invalid token")
    elseif b == 0x2D or (b >= 0x30 and b <= 0x39) then
        _pos = _pos - 1; return decode_number()
    else
        decode_error("unexpected character '" .. str_char(b) .. "'")
    end
end

--: (s: string, null_sentinel: unknown) -> unknown
local function decode_raw(s, null_sentinel)
    _src   = s
    _len   = #s
    _ptr8  = ffi.cast("const uint8_t *", s)
    _pos   = 0
    _null  = null_sentinel or M.null
    _depth = 0
    local v = decode_value()
    skip_ws()
    if _pos < _len then decode_error("trailing garbage after JSON value") end
    return v
end

--: (s: string, null_sentinel: unknown) -> (unknown, string | nil)
M.decode = function(s, null_sentinel)
    local ok, result = pcall(decode_raw, s, null_sentinel)
    if ok then return result end
    return nil, result
end

M._decode_raw = decode_raw

M.value_to_json = M._encode_raw
M.json_to_value = M._decode_raw

return M
