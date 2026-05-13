-- lib/type/static/lex.lua
-- Lexer for the typechecker.
-- Produces integer token types, interns identifiers/strings on the spot,
-- captures annotation comments during lex.

local ffi = require("ffi")
local band = bit.band
local char = string.char
local format = string.format

local defs = require("lib.type.static.defs")
local intern_mod = require("lib.type.static.intern")

local M = {}

-- Byte constants
local B_0     = 48   -- '0'
local B_9     = 57   -- '9'
local B_a     = 97   -- 'a'
local B_f     = 102  -- 'f'
local B_z     = 122  -- 'z'
local B_A     = 65   -- 'A'
local B_Z     = 90   -- 'Z'
local B_UNDER = 95   -- '_'
local B_NL    = 10   -- '\n'
local B_CR    = 13   -- '\r'
local B_SPACE = 32   -- ' '
local B_TAB   = 9    -- '\t'
local B_FF    = 12   -- '\f'
local B_VT    = 11   -- '\v'
local B_BS    = 8    -- '\b'
local B_MINUS = 45   -- '-'
local B_LBRK  = 91   -- '['
local B_RBRK  = 93   -- ']'
local B_EQ    = 61   -- '='
local B_LT    = 60   -- '<'
local B_GT    = 62   -- '>'
local B_TILDE = 126  -- '~'
local B_COLON = 58   -- ':'
local B_DOT   = 46   -- '.'
local B_DQUOT = 34   -- '"'
local B_SQUOT = 39   -- "'"
local B_BSLSH = 92   -- '\\'
local B_HASH  = 35   -- '#'
local B_BOM1  = 0xEF
local B_BOM2  = 0xBB
local B_BOM3  = 0xBF
local B_x     = 120  -- 'x'
local B_X     = 88   -- 'X'
local B_e     = 101  -- 'e'
local B_E     = 69   -- 'E'
local B_p     = 112  -- 'p'
local B_P     = 80   -- 'P'
local B_PLUS  = 43   -- '+'
local B_i     = 105  -- 'i'
local B_l     = 108  -- 'l'
local B_u     = 117  -- 'u'
local B_n     = 110  -- 'n'
local B_r     = 114  -- 'r'
local B_t     = 116  -- 't'
local B_v     = 118  -- 'v'

local EOF = 256  -- sentinel: no valid byte

local uint8_ptr = ffi.typeof("const uint8_t*")

-- Escape table: byte -> replacement byte (or nil)
local escapes = {
    [97]  = 7,    -- a -> \a
    [98]  = 8,    -- b -> \b
    [102] = 12,   -- f -> \f
    [B_n] = 10,   -- n -> \n
    [B_r] = 13,   -- r -> \r
    [B_t] = 9,    -- t -> \t
    [B_v] = 11,   -- v -> \v
}

-- Character classification (inline for hot path)
local function is_ident(b)
    return (b >= B_a and b <= B_z) or (b >= B_A and b <= B_Z)
        or (b >= B_0 and b <= B_9) or b == B_UNDER
end

local function is_digit(b)
    return b >= B_0 and b <= B_9
end

local function is_space(b)
    return b == B_SPACE or b == B_TAB or b == B_FF or b == B_VT or b == B_BS
end

local function is_newline(b)
    return b == B_NL or b == B_CR
end

local function hex_val(b)
    if b >= B_0 and b <= B_9 then return b - B_0
    elseif b >= B_a and b <= B_f then return b - B_a + 10
    elseif b >= B_A and b <= (B_A + 5) then return b - B_A + 10
    else return -1 end
end

-- Lower-case a single byte
local function lower(b)
    if b >= B_A and b <= B_Z then return b + 32 end
    return b
end

---------------------------------------------------------------------------
-- Lexer state
---------------------------------------------------------------------------

--[[::
LexState = {
  src: number, srclen: integer, pos: integer, b: integer,
  line: integer, col: integer, tk: integer, val: unknown,
  pool: InternPool, _buf_id: integer, filename: string,
  _la_tk: integer, _la_val: unknown, _la_line: integer, _la_col: integer,
  _la_valid: boolean, _pending_cast_id: integer | nil, _cast_id_seq: integer,
  _buf: { [integer]: integer, ... }, _bufn: integer,
  _tk_line: integer | nil, _tk_col: integer | nil,
  _tk_line_out: integer | nil, _tk_col_out: integer | nil,
  annotations: { [integer]: unknown, ... },
  _nextbyte: (LexState) -> integer,
  _peekbyte: (LexState) -> integer,
  _incline: (LexState) -> (),
  _buf_reset: (LexState) -> (),
  _buf_save: (LexState, integer) -> (),
  _buf_tostring: (LexState) -> string,
  error: (LexState, string) -> never,
  _tk_error: (LexState, string) -> never,
  _skip_sep: (LexState) -> integer,
  _read_long_string: (LexState, integer) -> string,
  _skip_long_comment: (LexState, integer) -> (),
  _read_escape: (LexState) -> (),
  _read_string: (LexState, integer) -> integer,
  _read_number: (LexState) -> number,
  _capture_line_annotation: (LexState, integer, integer) -> boolean,
  _capture_block_annotation: (LexState, integer, integer, integer) -> boolean,
  _lex: (LexState) -> (integer, unknown),
  next: (LexState) -> integer,
  lookahead: (LexState) -> integer,
  expect: (LexState, integer) -> integer,
  opt: (LexState, integer) -> boolean,
  ...
}
]]

local Lexer = {}
Lexer.__index = Lexer

--: (source: string, filename: string | nil, pool: InternPool | nil) -> LexState
function M.new(source, filename, pool)
    pool = pool or intern_mod.new()
    local src = ffi.cast(uint8_ptr, source)
    local len = #source
    local buf_id = intern_mod.register_buf(pool, src, source)
    --: LexState
    local ls = setmetatable({
        src    = src,
        srclen = len,
        pos    = 0,          -- current byte position (0-based)
        b      = EOF,        -- current byte
        line   = 1,
        col    = 0,
        tk     = defs.TK_EOF,
        val    = 0,          -- token value (name_id or numval_id)
        pool   = pool,
        _buf_id = buf_id,
        filename = filename or "?",
        -- lookahead storage
        _la_tk  = defs.TK_EOF,
        _la_val = 0,
        _la_line = 0,
        _la_col  = 0,
        _la_valid = false,
        -- annotations captured during lex
        annotations = {},
        -- pending expression cast: set by block-cast lexing, consumed by parser
        _pending_cast_id = nil,
        _cast_id_seq = 0,
        -- save buffer for building escape-sequence strings
        _buf = {},
        _bufn = 0,
    }, Lexer)
    -- Read first byte
    ls:_nextbyte()
    -- Skip UTF-8 BOM
    if ls.b == B_BOM1 and ls.pos + 1 < len and src[ls.pos] == B_BOM2 and src[ls.pos + 1] == B_BOM3 then
        ls.pos = ls.pos + 2
        ls:_nextbyte()
        ls.col = 1
    end
    -- Skip shebang
    if ls.b == B_HASH then
        repeat
            ls:_nextbyte()
            if ls.b == EOF then
                ls.tk = defs.TK_EOF
                return ls
            end
        until is_newline(ls.b)
        ls:_incline()
    end
    -- Prime first token
    ls:next()
    return ls
end

---------------------------------------------------------------------------
-- Byte-level helpers
---------------------------------------------------------------------------

--: (LexState) -> integer
function Lexer:_nextbyte()
    if self.pos >= self.srclen then
        self.b = EOF
        return EOF
    end
    local b = self.src[self.pos]
    self.pos = self.pos + 1
    self.b = b
    self.col = self.col + 1
    return b
end

--: (LexState) -> integer
function Lexer:_peekbyte()
    if self.pos >= self.srclen then return EOF end
    return self.src[self.pos]
end

--: (LexState) -> ()
function Lexer:_incline()
    local old = self.b
    self:_nextbyte()
    if is_newline(self.b) and self.b ~= old then
        self:_nextbyte()
    end
    self.line = self.line + 1
    self.col = 1
end

---------------------------------------------------------------------------
-- Save buffer (only for escape-sequence strings)
---------------------------------------------------------------------------

--: (LexState) -> ()
function Lexer:_buf_reset()
    self._bufn = 0
end

--: (LexState, integer) -> ()
function Lexer:_buf_save(b)
    local n = self._bufn + 1
    self._buf[n] = b
    self._bufn = n
end

--: (LexState) -> string
function Lexer:_buf_tostring()
    local t = {}
    for i = 1, self._bufn do
        t[i] = char(self._buf[i])
    end
    return table.concat(t)
end

---------------------------------------------------------------------------
-- Error handling
---------------------------------------------------------------------------

--: (LexState, string) -> never
function Lexer:error(msg)
    error(format("%s:%d:%d: %s", self.filename, self.line, self.col, msg), 0)
end

--: (LexState, string) -> never
function Lexer:_tk_error(msg)
    error(format("%s:%d:%d: %s", self.filename, self._tk_line, self._tk_col, msg), 0)
end

---------------------------------------------------------------------------
-- Long string / long comment
---------------------------------------------------------------------------

-- Count separator level: self.b must be '[' or ']'.
-- Returns count of '=' between matching brackets, or negative if no match.
-- Advances past the bracket + equals + (matching bracket stays in self.b).
--: (LexState) -> integer
function Lexer:_skip_sep()
    local count = 0
    local s = self.b
    assert(s == B_LBRK or s == B_RBRK)
    self:_nextbyte()
    while self.b == B_EQ do
        self:_nextbyte()
        count = count + 1
    end
    return self.b == s and count or (-count - 1)
end

--: (LexState, integer) -> string
function Lexer:_read_long_string(sep)
    -- self.b is on the 2nd '['. Advance past it.
    self:_nextbyte()
    if is_newline(self.b) then self:_incline() end
    -- Record content start
    --: integer
    local start = self.pos - 1
    if self.b == EOF then start = self.pos end
    -- Scan for closing bracket
    -- Long strings can contain newlines, so we need to track lines.
    -- Content between open and close brackets (minus the brackets/separators).
    local parts = nil  -- only allocate if we hit newlines (CR normalization)
    local plain = true -- true if we can use a single ffi.string slice
    while true do
        if self.b == EOF then
            self:error("unfinished long string")
        elseif self.b == B_RBRK then
            --: integer
            local content_end = self.pos - 1  -- position before ']'
            local count = 0
            self:_nextbyte()
            while self.b == B_EQ do self:_nextbyte(); count = count + 1 end
            if self.b == B_RBRK and count == sep then
                self:_nextbyte()
                if plain then
                    return ffi.string(((self.src + start) --[[: unknown]]) --[[:! cdata]], content_end - start)
                else
                    -- flush remaining plain segment
                    --: integer
                    local s0 = start
                    if content_end > s0 then
                        parts[#parts + 1] = ffi.string(((self.src + s0) --[[: unknown]]) --[[:! cdata]], content_end - s0)
                    end
                    return table.concat(parts)
                end
            end
            -- Not a match — the bytes we consumed are part of content, continue
        elseif is_newline(self.b) then
            -- Normalize CR/CRLF/LFCR to LF
            if plain then
                if self.b == B_CR then
                    -- Need to normalize, switch to parts mode
                    plain = false
                    parts = {}
                    --: integer
                    local s1 = start
                    if self.pos - 1 > s1 then
                        parts[#parts + 1] = ffi.string(((self.src + s1) --[[: unknown]]) --[[:! cdata]], self.pos - 1 - s1)
                    end
                    parts[#parts + 1] = "\n"
                    self:_incline()
                    start = self.pos - 1
                    if self.b == EOF then start = self.pos end
                else
                    -- LF: check if next is CR (LFCR), need normalization
                    local next_pos = self.pos  -- pos after the LF byte
                    if next_pos < self.srclen and self.src[next_pos] == B_CR then
                        plain = false
                        parts = {}
                        --: integer
                        local s2 = start
                        if self.pos - 1 > s2 then
                            parts[#parts + 1] = ffi.string(((self.src + s2) --[[: unknown]]) --[[:! cdata]], self.pos - 1 - s2)
                        end
                        parts[#parts + 1] = "\n"
                        self:_incline()
                        start = self.pos - 1
                        if self.b == EOF then start = self.pos end
                    else
                        self:_incline()
                    end
                end
            else
                -- Already in parts mode
                --: integer
                local s3 = start
                if self.pos - 1 > s3 then
                    parts[#parts + 1] = ffi.string(((self.src + s3) --[[: unknown]]) --[[:! cdata]], self.pos - 1 - s3)
                end
                parts[#parts + 1] = "\n"
                self:_incline()
                start = self.pos - 1
                if self.b == EOF then start = self.pos end
            end
        else
            self:_nextbyte()
        end
    end
    return ""  -- unreachable: loop only exits via return or error
end

-- Skip a long comment body. Caller already advanced past the opening [=*[
-- and leading newline.
--: (LexState, integer) -> ()
function Lexer:_skip_long_comment(sep)
    while true do
        if self.b == EOF then
            self:error("unfinished long comment")
        elseif self.b == B_RBRK then
            -- Check for matching close bracket
            local count = 0
            self:_nextbyte()
            while self.b == B_EQ do self:_nextbyte(); count = count + 1 end
            if self.b == B_RBRK and count == sep then
                self:_nextbyte()
                return
            end
        elseif is_newline(self.b) then
            self:_incline()
        else
            self:_nextbyte()
        end
    end
end

---------------------------------------------------------------------------
-- String reading
---------------------------------------------------------------------------

--: (LexState) -> ()
function Lexer:_read_escape()
    local c = self:_nextbyte()  -- skip '\\'
    local esc = escapes[c]
    if esc then
        self:_buf_save(esc)
        self:_nextbyte()
    elseif c == B_x then  -- \xNN
        --: integer
        local h1 = hex_val(self:_nextbyte())
        if h1 < 0 then self:error("invalid escape sequence") end
        --: integer
        local h2 = hex_val(self:_nextbyte())
        if h2 < 0 then self:error("invalid escape sequence") end
        self:_buf_save(h1 * 16 + h2)
        self:_nextbyte()
    elseif c == 122 then  -- \z skip whitespace (B_z = 122)
        self:_nextbyte()
        while true do
            if is_newline(self.b) then self:_incline()
            elseif is_space(self.b) then self:_nextbyte()
            else break end
        end
    elseif is_newline(c) then
        self:_buf_save(B_NL)
        self:_incline()
    elseif c == B_BSLSH or c == B_DQUOT or c == B_SQUOT then
        self:_buf_save(c)
        self:_nextbyte()
    elseif c == EOF then
        self:error("unfinished string")
    elseif is_digit(c) then
        local bc = band(c, 15)
        local nc = self:_nextbyte()
        if is_digit(nc) then
            bc = bc * 10 + band(nc, 15)
            nc = self:_nextbyte()
            if is_digit(nc) then
                bc = bc * 10 + band(nc, 15)
                if bc > 255 then self:error("invalid escape sequence") end
                self:_nextbyte()
            end
        end
        self:_buf_save(bc)
    else
        self:error("invalid escape sequence")
    end
end

-- Returns intern ID directly.
--: (LexState, integer) -> integer
function Lexer:_read_string(delim)
    -- self.b is on the opening delimiter. Skip it.
    self:_nextbyte()
    -- Fast path: scan forward looking for delimiter or backslash.
    -- If no backslash, use intern_raw (zero Lua string allocation).
    local start = self.pos - 1  -- pos of first content byte (already in self.b)
    if self.b == EOF then start = self.pos end
    while true do
        local b = self.b
        if b == delim then
            -- End of string, no escapes encountered
            local len = self.pos - 1 - start
            local id = intern_mod.intern_raw(
                self.pool, self.src + start, len, self._buf_id, start)
            self:_nextbyte()  -- skip closing delimiter
            return id
        elseif b == EOF or is_newline(b) then
            self:error("unfinished string")
        elseif b == B_BSLSH then
            -- Escape found: flush prefix into _buf, then process escapes
            self:_buf_reset()
            -- Copy bytes [start, pos-1) into _buf
            local prefix_end = self.pos - 1
            for i = start, prefix_end - 1 do
                self:_buf_save(self.src[i])
            end
            -- Process this escape
            self:_read_escape()
            -- Continue with _buf for rest of string
            while self.b ~= delim do
                if self.b == EOF or is_newline(self.b) then
                    self:error("unfinished string")
                elseif self.b == B_BSLSH then
                    self:_read_escape()
                else
                    self:_buf_save(self.b)
                    self:_nextbyte()
                end
            end
            self:_nextbyte()  -- skip closing delimiter
            local str = self:_buf_tostring()
            return intern_mod.intern(self.pool, str)
        else
            self:_nextbyte()
        end
    end
    return 0  -- unreachable: loop only exits via return or error
end

---------------------------------------------------------------------------
-- Number reading
---------------------------------------------------------------------------

--: (LexState) -> number
function Lexer:_read_number()
    -- Scan the number token using pointer arithmetic.
    -- Numbers: digits, hex digits, '.', 'e'/'E'/'p'/'P' optionally followed by +/-.
    -- We need to track the previous byte for the exponent +/- lookaback.
    local start = self.pos - 1  -- pos of first byte (already in self.b)
    local xp = B_e  -- exponent marker
    if self.b == B_0 then
        self:_nextbyte()
        if self.b == B_x or self.b == B_X then
            xp = B_p
        end
    end
    while true do
        local b = self.b
        if is_ident(b) or b == B_DOT then
            self:_nextbyte()
        elseif (b == B_MINUS or b == B_PLUS) then
            -- Check previous byte for exponent marker
            local prev = self.src[self.pos - 2]
            if lower(prev) == xp then
                self:_nextbyte()
            else
                break
            end
        else
            break
        end
    end
    local str = ffi.string(((self.src + start) --[[: unknown]]) --[[:! cdata]], self.pos - 1 - start)
    if self.b == EOF then
        str = ffi.string(((self.src + start) --[[: unknown]]) --[[:! cdata]], self.srclen - start)
    end
    -- Strip LuaJIT integer suffixes (ULL, LL, UL, L, case-insensitive)
    -- e.g. 0x1ULL, 255ULL, 0xFF00LL
    do
        local s = str --: string
        s = (string.gsub(s, "[Uu][Ll][Ll]$", ""))
        s = (string.gsub(s, "[Ll][Ll]$", ""))
        s = (string.gsub(s, "[Uu][Ll]$", ""))
        str = (string.gsub(s, "[Ll]$", ""))
    end
    local xraw = tonumber(str)
    if not xraw then self:error("malformed number") end
    return xraw or 0
end

---------------------------------------------------------------------------
-- Annotation capture
---------------------------------------------------------------------------

--: (LexState, integer, integer) -> boolean
function Lexer:_capture_line_annotation(ann_line, ann_col)
    -- We've already consumed "--". Check what follows.
    -- --: type      → ANN_TYPE
    -- --:: Name = T → ANN_DECL
    -- We're positioned right after "--", self.b is next char
    if self.b ~= B_COLON then return false end
    local kind = defs.ANN_TYPE
    self:_nextbyte()  -- skip first ':'
    if self.b == B_COLON then
        kind = defs.ANN_DECL
        self:_nextbyte()  -- skip second ':'
    elseif self.b == B_LT then
        kind = defs.ANN_TYPE_ARGS
        -- don't skip '<', it's part of content
    end
    -- Skip optional leading space
    if self.b == B_SPACE then self:_nextbyte() end
    -- Capture rest of line as content
    local start = self.pos - 1  -- current byte is already read
    while self.b ~= EOF and not is_newline(self.b) do
        self:_nextbyte()
    end
    local content_end = self.pos
    if self.b ~= EOF then
        content_end = self.pos - 1  -- don't include the newline byte
    end
    local content = ffi.string(((self.src + start) --[[: unknown]]) --[[:! cdata]], content_end - start)

    -- For ANN_DECL, check for continuation lines starting with --::
    -- Only continue if brackets are unbalanced (the declaration isn't complete yet).
    if kind == defs.ANN_DECL then
        local parts = { content }
        local depth = 0
        for i = 1, #content do
            local c = content:byte(i)
            if c == 123 or c == 40 or c == 91 then depth = depth + 1  -- { ( [
            elseif c == 125 or c == 41 or c == 93 then depth = depth - 1  -- } ) ]
            end
        end
        while depth > 0 and self.b ~= EOF do
            -- Save position to restore if next line isn't a continuation
            local save_pos = self.pos
            local save_b = self.b
            local save_line = self.line
            local save_col = self.col
            -- Skip newline
            if is_newline(self.b) then self:_incline() end
            -- Skip leading whitespace (spaces/tabs)
            while self.b == B_SPACE or self.b == 9 do self:_nextbyte() end
            -- Check for --::
            local is_cont = false
            if self.b == B_MINUS then
                self:_nextbyte()
                if self.b == B_MINUS then
                    self:_nextbyte()
                    if self.b == B_COLON then
                        self:_nextbyte()
                        if self.b == B_COLON then
                            self:_nextbyte()
                            is_cont = true
                        end
                    end
                end
            end
            if not is_cont then
                -- Not a continuation line, restore position
                self.pos = save_pos
                self.b = save_b
                self.line = save_line
                self.col = save_col
                break
            end
            -- Continuation line confirmed, skip optional space
            if self.b == B_SPACE then self:_nextbyte() end
            -- Capture rest of line
            local cstart = self.pos - 1
            while self.b ~= EOF and not is_newline(self.b) do
                self:_nextbyte()
            end
            local cend = self.pos
            if self.b ~= EOF then cend = self.pos - 1 end
            local line_content = ffi.string(((self.src + cstart) --[[: unknown]]) --[[:! cdata]], cend - cstart)
            parts[#parts + 1] = line_content
            -- Update bracket depth
            for i = 1, #line_content do
                local c = line_content:byte(i)
                if c == 123 or c == 40 or c == 91 then depth = depth + 1
                elseif c == 125 or c == 41 or c == 93 then depth = depth - 1
                end
            end
        end
        if #parts > 1 then
            content = table.concat(parts, " ")
        end
    end

    self.annotations[ann_line] = {
        kind = kind,
        content = content,
        col = ann_col,
    }
    return true
end

--: (LexState, integer, integer, integer) -> boolean
function Lexer:_capture_block_annotation(sep, ann_line, ann_col)
    -- Caller already advanced past the 2nd '[' and skipped leading newline.
    -- Check if content starts with ':'
    if self.b ~= B_COLON then return false end
    local kind = defs.ANN_TYPE
    local force_cast = false
    self:_nextbyte()
    if self.b == B_COLON then
        kind = defs.ANN_DECL
        self:_nextbyte()
    elseif self.b == B_LT then
        kind = defs.ANN_TYPE_ARGS
    elseif self.b == 33 then  -- '!' — overlap-checked force cast: --[[:! T]]
        force_cast = true
        self:_nextbyte()
    end
    -- Read content until closing ]=]
    local parts = {}
    while true do
        if self.b == EOF then
            self:error("unfinished long comment")
        elseif self.b == B_RBRK then
            -- Check for matching close
            local count = 0
            self:_nextbyte()
            while self.b == B_EQ do self:_nextbyte(); count = count + 1 end
            if self.b == B_RBRK and count == sep then
                self:_nextbyte()  -- skip final ']'
                break
            end
            -- Not a match, save what we consumed
            parts[#parts + 1] = "]"
            for j = 1, count do parts[#parts + 1] = "=" end
        elseif is_newline(self.b) then
            parts[#parts + 1] = "\n"
            self:_incline()
        else
            parts[#parts + 1] = char(self.b)
            self:_nextbyte()
        end
    end
    local content = table.concat(parts)
    -- Strip inline -- comments (from -- to end of line) so that
    -- --[[:: ... ]] blocks can contain documentation comments.
    content = content:gsub("%-%-[^\n]*", "")
    -- Trim trailing whitespace
    content = content:match("^(.-)%s*$") or content
    self.annotations[ann_line] = {
        kind = kind,
        content = content,
        col = ann_col,
        force_cast = force_cast,
    }
    return true
end

---------------------------------------------------------------------------
-- Main lex function
---------------------------------------------------------------------------

--: (LexState) -> (integer, unknown)
function Lexer:_lex()
    while true do
        self._tk_line = self.line
        self._tk_col = self.col
        local b = self.b

        -- Identifier or keyword or digit
        if is_ident(b) then
            if is_digit(b) then
                local num = self:_read_number()
                return defs.TK_NUMBER, num
            end
            -- Identifier / keyword: scan forward with pointer arithmetic
            local start = self.pos - 1  -- pos of first byte (already in self.b)
            local src = self.src
            local p = self.pos
            local srclen = self.srclen
            while p < srclen and is_ident(src[p]) do
                p = p + 1
            end
            -- Advance col for scanned bytes, then load next byte
            self.col = self.col + (p - self.pos)
            self.pos = p
            -- Load next byte (like _nextbyte but we already set pos)
            if self.pos < srclen then
                self.b = src[self.pos]
                self.pos = self.pos + 1
                self.col = self.col + 1
            else
                self.b = EOF
            end
            local name_id = intern_mod.intern_raw(
                self.pool, src + start, p - start, self._buf_id, start)
            if name_id < defs.NUM_KEYWORDS then
                return name_id, 0  -- keyword token = its intern ID
            end
            return defs.TK_NAME, name_id
        end

        -- Whitespace
        if is_newline(b) then
            self:_incline()
        elseif is_space(b) then
            self:_nextbyte()

        -- Minus / comment
        elseif b == B_MINUS then
            -- Byte offset (0-indexed) of the first '-' of this possible comment.
            local comment_byte_start = self.pos - 1
            self:_nextbyte()
            if self.b ~= B_MINUS then return defs.TK_MINUS, 0 end
            -- Comment
            local ann_line = self.line
            local ann_col = self._tk_col or 0
            self:_nextbyte()  -- skip second '-'
            if self.b == B_LBRK then
                -- Possible long comment
                local sep = self:_skip_sep()
                if sep >= 0 then
                    -- Long comment: --[=*[ ... ]=*]
                    -- _skip_sep left self.b on the 2nd '['. Advance past it.
                    self:_nextbyte()
                    if is_newline(self.b) then self:_incline() end
                    -- Check for annotation prefix
                    if not self:_capture_block_annotation(sep, ann_line, ann_col) then
                        -- Regular long comment: skip content until close
                        self:_skip_long_comment(sep)
                    else
                        -- _capture_block_annotation has consumed the closing ']]'.
                        -- self.pos is now the byte index AFTER the final ']'.
                        -- byte_end (exclusive) = self.pos - 1.
                        local comment_byte_end = self.pos - 1
                        -- For ANN_TYPE expression casts: rekey to a unique negative
                        -- ID so it doesn't collide with real line numbers, and signal
                        -- the parser to wrap the next expression in NODE_CAST_EXPR.
                        local stored = self.annotations[ann_line]
                        if stored and stored.kind == defs.ANN_TYPE then
                            stored.byte_start = comment_byte_start
                            stored.byte_end   = comment_byte_end
                            stored.line       = ann_line
                            self._cast_id_seq = self._cast_id_seq - 1
                            local cast_id = self._cast_id_seq
                            self.annotations[ann_line] = nil
                            self.annotations[cast_id] = stored
                            self._pending_cast_id = cast_id
                        end
                    end
                else
                    -- Not a long comment, check for line annotation
                    -- The '[' was consumed by _skip_sep but wasn't a long bracket.
                    -- This is a normal line comment starting with "--["
                    -- We need to skip to end of line
                    while self.b ~= EOF and not is_newline(self.b) do
                        self:_nextbyte()
                    end
                end
            else
                -- Line comment: check for annotation
                if not self:_capture_line_annotation(ann_line, ann_col) then
                    -- Regular comment, skip to end of line
                    while self.b ~= EOF and not is_newline(self.b) do
                        self:_nextbyte()
                    end
                end
            end

        -- Long string
        elseif b == B_LBRK then
            local sep = self:_skip_sep()
            if sep >= 0 then
                local str = self:_read_long_string(sep)
                local id = intern_mod.intern(self.pool, str)
                return defs.TK_STRING, id
            elseif sep == -1 then
                return defs.TK_LBRACKET, 0
            else
                self:error("invalid long string delimiter")
            end

        -- Equality / assign
        elseif b == B_EQ then
            self:_nextbyte()
            if self.b == B_EQ then self:_nextbyte(); return defs.TK_EQ, 0 end
            return defs.TK_ASSIGN, 0

        -- Less than
        elseif b == B_LT then
            self:_nextbyte()
            if self.b == B_EQ then self:_nextbyte(); return defs.TK_LE, 0 end
            return defs.TK_LT, 0

        -- Greater than
        elseif b == B_GT then
            self:_nextbyte()
            if self.b == B_EQ then self:_nextbyte(); return defs.TK_GE, 0 end
            return defs.TK_GT, 0

        -- Not equal
        elseif b == B_TILDE then
            self:_nextbyte()
            if self.b == B_EQ then self:_nextbyte(); return defs.TK_NE, 0 end
            self:error("unexpected character '~'")

        -- Colon / label
        elseif b == B_COLON then
            self:_nextbyte()
            if self.b == B_COLON then self:_nextbyte(); return defs.TK_LABEL, 0 end
            return defs.TK_COLON, 0

        -- String literals
        elseif b == B_DQUOT or b == B_SQUOT then
            local id = self:_read_string(b)
            return defs.TK_STRING, id

        -- Dot / concat / dots / number starting with '.'
        elseif b == B_DOT then
            self:_nextbyte()
            if self.b == B_DOT then
                self:_nextbyte()
                if self.b == B_DOT then self:_nextbyte(); return defs.TK_DOTS, 0 end
                return defs.TK_CONCAT, 0
            elseif is_digit(self.b) then
                -- Number starting with '.': rewind so _read_number sees the dot
                -- After _nextbyte: pos is past the digit, digit is at pos-1,
                -- dot is at pos-2. Rewind to make dot the "current byte".
                self.pos = self.pos - 1
                self.col = self.col - 1
                self.b = B_DOT
                local num = self:_read_number()
                return defs.TK_NUMBER, num
            end
            return defs.TK_DOT, 0

        -- EOF
        elseif b == EOF then
            return defs.TK_EOF, 0

        -- Single-char tokens from lookup table, or error
        else
            local tk = defs.char_to_token[b]
            if tk then
                self:_nextbyte()
                return tk, 0
            end
            self:error(format("unexpected character '%s'", char(b)))
        end
    end
    return 0, nil  -- unreachable: loop only exits via return or error
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

--: (LexState) -> integer
function Lexer:next()
    if self._la_valid then
        self.tk   = self._la_tk
        self.val  = self._la_val
        self._tk_line_out = self._la_line
        self._tk_col_out  = self._la_col
        self._la_valid = false
        return self.tk
    end
    self.tk, self.val = self:_lex()
    self._tk_line_out = self._tk_line
    self._tk_col_out = self._tk_col
    return self.tk
end

--: (LexState) -> integer
function Lexer:lookahead()
    if self._la_valid then return self._la_tk end
    local save_line = self._tk_line or 0
    local save_col = self._tk_col or 0
    self._la_tk, self._la_val = self:_lex()
    self._la_line = self._tk_line or 0
    self._la_col = self._tk_col or 0
    self._la_valid = true
    self._tk_line = save_line
    self._tk_col = save_col
    return self._la_tk
end

--: (LexState, integer) -> integer
function Lexer:expect(tk)
    if self.tk ~= tk then
        self:error(format("expected '%s', got '%s'",
            defs.token_name[tk] or "?",
            defs.token_name[self.tk] or "?"))
    end
    return self:next()
end

--: (LexState, integer) -> boolean
function Lexer:opt(tk)
    if self.tk == tk then
        self:next()
        return true
    end
    return false
end

return M
