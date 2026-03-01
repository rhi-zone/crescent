-- lib/type/static/v2/lex.lua
-- Lexer for the v2 typechecker.
-- Produces integer token types, interns identifiers/strings on the spot,
-- captures annotation comments during lex.

local ffi = require("ffi")
local band = bit.band
local char = string.char
local format = string.format
local sub = string.sub
local tonumber = tonumber

local defs = require("lib.type.static.v2.defs")
local intern_mod = require("lib.type.static.v2.intern")

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

-- Escape table: byte -> replacement char (or nil)
local escapes = {
    [97]  = "\a",  -- a
    [98]  = "\b",  -- b
    [102] = "\f",  -- f
    [B_n] = "\n",  -- n
    [B_r] = "\r",  -- r
    [B_t] = "\t",  -- t
    [B_v] = "\v",  -- v
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

local Lexer = {}
Lexer.__index = Lexer

function M.new(source, filename, pool)
    pool = pool or intern_mod.new()
    local src = ffi.cast(uint8_ptr, source)
    local len = #source
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
        filename = filename or "?",
        -- lookahead storage
        _la_tk  = defs.TK_EOF,
        _la_val = 0,
        _la_line = 0,
        _la_col  = 0,
        _la_valid = false,
        -- number values side array
        numvals = {},
        numval_next = 0,
        -- annotations captured during lex
        annotations = {},
        -- save buffer for building strings/numbers
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

function Lexer:_peekbyte()
    if self.pos >= self.srclen then return EOF end
    return self.src[self.pos]
end

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
-- Save buffer (for building identifier/string/number text)
---------------------------------------------------------------------------

function Lexer:_buf_reset()
    self._bufn = 0
end

function Lexer:_buf_save(b)
    local n = self._bufn + 1
    self._buf[n] = b
    self._bufn = n
end

function Lexer:_buf_save_and_next()
    self:_buf_save(self.b)
    self:_nextbyte()
end

function Lexer:_buf_tostring(skip_start, skip_end)
    skip_start = skip_start or 0
    skip_end = skip_end or 0
    local t = {}
    for i = 1 + skip_start, self._bufn - skip_end do
        t[#t + 1] = char(self._buf[i])
    end
    return table.concat(t)
end

---------------------------------------------------------------------------
-- Error handling
---------------------------------------------------------------------------

function Lexer:error(msg)
    error(format("%s:%d:%d: %s", self.filename, self.line, self.col, msg), 0)
end

function Lexer:_tk_error(msg)
    error(format("%s:%d:%d: %s", self.filename, self._tk_line, self._tk_col, msg), 0)
end

---------------------------------------------------------------------------
-- Long string / long comment
---------------------------------------------------------------------------

function Lexer:_skip_sep()
    local count = 0
    local s = self.b
    assert(s == B_LBRK or s == B_RBRK)
    self:_buf_save_and_next()
    while self.b == B_EQ do
        self:_buf_save_and_next()
        count = count + 1
    end
    return self.b == s and count or (-count - 1)
end

function Lexer:_read_long_string(sep, ret_value)
    self:_buf_save_and_next()  -- skip 2nd '['
    if is_newline(self.b) then self:_incline() end
    while true do
        if self.b == EOF then
            self:error(ret_value and "unfinished long string" or "unfinished long comment")
        elseif self.b == B_RBRK then
            local old_bufn = self._bufn
            if self:_skip_sep() == sep then
                self:_buf_save_and_next()
                break
            else
                -- _skip_sep dirtied buffer but didn't match; keep contents
            end
        elseif is_newline(self.b) then
            self:_buf_save(B_NL)
            self:_incline()
            if not ret_value then self:_buf_reset() end
        elseif ret_value then
            self:_buf_save_and_next()
        else
            self:_nextbyte()
        end
    end
    if ret_value then
        return self:_buf_tostring(2 + sep, 2 + sep)
    end
end

-- Skip a long comment body. Caller already advanced past the opening [=*[
-- and leading newline.
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

function Lexer:_read_escape()
    local c = self:_nextbyte()  -- skip '\\'
    local esc = escapes[c]
    if esc then
        self:_buf_save(string.byte(esc))
        self:_nextbyte()
    elseif c == B_x then  -- \xNN
        local h1 = hex_val(self:_nextbyte())
        if h1 < 0 then self:error("invalid escape sequence") end
        local h2 = hex_val(self:_nextbyte())
        if h2 < 0 then self:error("invalid escape sequence") end
        self:_buf_save(h1 * 16 + h2)
        self:_nextbyte()
    elseif c == B_z then  -- \z skip whitespace
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

function Lexer:_read_string(delim)
    self:_nextbyte()  -- skip opening delimiter
    while self.b ~= delim do
        if self.b == EOF then self:error("unfinished string")
        elseif is_newline(self.b) then self:error("unfinished string")
        elseif self.b == B_BSLSH then self:_read_escape()
        else self:_buf_save_and_next() end
    end
    self:_nextbyte()  -- skip closing delimiter
    return self:_buf_tostring()
end

---------------------------------------------------------------------------
-- Number reading
---------------------------------------------------------------------------

function Lexer:_read_number()
    local xp = B_e  -- exponent marker: 'e' for decimal, 'p' for hex
    if self.b == B_0 then
        self:_buf_save_and_next()
        if self.b == B_x or self.b == B_X then
            xp = B_p
        end
    end
    while is_ident(self.b) or self.b == B_DOT
        or ((self.b == B_MINUS or self.b == B_PLUS) and lower(self._buf[self._bufn] or 0) == xp) do
        self:_buf_save(lower(self.b))
        self:_nextbyte()
    end
    local str = self:_buf_tostring()
    local x = tonumber(str)
    if not x then self:error("malformed number") end
    return x
end

---------------------------------------------------------------------------
-- Annotation capture
---------------------------------------------------------------------------

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
    local content = ffi.string(self.src + start, content_end - start)
    self.annotations[ann_line] = {
        kind = kind,
        content = content,
        col = ann_col,
    }
    return true
end

function Lexer:_capture_block_annotation(sep, ann_line, ann_col)
    -- Caller already advanced past the 2nd '[' and skipped leading newline.
    -- Check if content starts with ':'
    if self.b ~= B_COLON then return false end
    local kind = defs.ANN_TYPE
    self:_nextbyte()
    if self.b == B_COLON then
        kind = defs.ANN_DECL
        self:_nextbyte()
    elseif self.b == B_LT then
        kind = defs.ANN_TYPE_ARGS
    end
    -- Read content until closing ]=]
    local parts = {}
    while true do
        if self.b == EOF then
            self:error("unfinished long comment")
        elseif self.b == B_RBRK then
            -- Check for matching close
            local save_pos = self.pos
            local save_b = self.b
            local save_col = self.col
            -- Manual sep check without dirtying main buffer
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
    -- Trim trailing whitespace
    content = content:match("^(.-)%s*$") or content
    self.annotations[ann_line] = {
        kind = kind,
        content = content,
        col = ann_col,
    }
    return true
end

---------------------------------------------------------------------------
-- Main lex function
---------------------------------------------------------------------------

function Lexer:_lex()
    self:_buf_reset()
    while true do
        self._tk_line = self.line
        self._tk_col = self.col
        local b = self.b

        -- Identifier or keyword or digit
        if is_ident(b) then
            if is_digit(b) then
                local num = self:_read_number()
                local id = self.numval_next
                self.numvals[id] = num
                self.numval_next = id + 1
                return defs.TK_NUMBER, id
            end
            -- Identifier / keyword
            repeat
                self:_buf_save_and_next()
            until not is_ident(self.b)
            local s = self:_buf_tostring()
            local kw_id = self.pool.map[s]
            if kw_id ~= nil and kw_id < defs.NUM_KEYWORDS then
                return kw_id, 0  -- keyword token = its intern ID
            end
            local name_id = intern_mod.intern(self.pool, s)
            return defs.TK_NAME, name_id
        end

        -- Whitespace
        if is_newline(b) then
            self:_incline()
        elseif is_space(b) then
            self:_nextbyte()

        -- Minus / comment
        elseif b == B_MINUS then
            self:_nextbyte()
            if self.b ~= B_MINUS then return defs.TK_MINUS, 0 end
            -- Comment
            local ann_line = self.line
            local ann_col = self._tk_col
            self:_nextbyte()  -- skip second '-'
            if self.b == B_LBRK then
                -- Possible long comment
                self:_buf_reset()
                local sep = self:_skip_sep()
                self:_buf_reset()
                if sep >= 0 then
                    -- Long comment: --[=*[ ... ]=*]
                    -- _skip_sep left self.b on the 2nd '['. Advance past it.
                    self:_nextbyte()
                    if is_newline(self.b) then self:_incline() end
                    -- Check for annotation prefix
                    if not self:_capture_block_annotation(sep, ann_line, ann_col) then
                        -- Regular long comment: skip content until close
                        self:_skip_long_comment(sep)
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
            self:_buf_reset()
            local sep = self:_skip_sep()
            if sep >= 0 then
                local str = self:_read_long_string(sep, true)
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
            -- '~' alone is not a valid Lua token, but return it for error recovery
            self:error("unexpected character '~'")

        -- Colon / label
        elseif b == B_COLON then
            self:_nextbyte()
            if self.b == B_COLON then self:_nextbyte(); return defs.TK_LABEL, 0 end
            return defs.TK_COLON, 0

        -- String literals
        elseif b == B_DQUOT or b == B_SQUOT then
            self:_buf_reset()
            local str = self:_read_string(b)
            local id = intern_mod.intern(self.pool, str)
            return defs.TK_STRING, id

        -- Dot / concat / dots / number starting with '.'
        elseif b == B_DOT then
            self:_nextbyte()
            if self.b == B_DOT then
                self:_nextbyte()
                if self.b == B_DOT then self:_nextbyte(); return defs.TK_DOTS, 0 end
                return defs.TK_CONCAT, 0
            elseif is_digit(self.b) then
                self:_buf_reset()
                self:_buf_save(B_DOT)
                local num = self:_read_number()
                local id = self.numval_next
                self.numvals[id] = num
                self.numval_next = id + 1
                return defs.TK_NUMBER, id
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
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

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

function Lexer:lookahead()
    if self._la_valid then return self._la_tk end
    local save_line = self._tk_line
    local save_col = self._tk_col
    self._la_tk, self._la_val = self:_lex()
    self._la_line = self._tk_line
    self._la_col = self._tk_col
    self._la_valid = true
    self._tk_line = save_line
    self._tk_col = save_col
    return self._la_tk
end

function Lexer:expect(tk)
    if self.tk ~= tk then
        self:error(format("expected '%s', got '%s'",
            defs.token_name[tk] or "?",
            defs.token_name[self.tk] or "?"))
    end
    return self:next()
end

function Lexer:opt(tk)
    if self.tk == tk then
        self:next()
        return true
    end
    return false
end

return M
