-- lib/type/static/cdecl_lex.lua
-- Zero-copy C declaration lexer for the typechecker.
-- Shares the intern pool with the Lua lexer — identifier IDs are
-- deduplicated across both.  Follows the same FFI/pointer patterns as lex.lua.

local ffi = require("ffi")
local intern_mod = require("lib.type.static.intern")

local M = {}

---------------------------------------------------------------------------
-- Token type constants
---------------------------------------------------------------------------

M.TK_IDENT   = 0   -- val = intern_id
M.TK_INT     = 1   -- val = integer value
M.TK_SEMI    = 2
M.TK_COMMA   = 3
M.TK_STAR    = 4
M.TK_LPAREN  = 5
M.TK_RPAREN  = 6
M.TK_LBRACE  = 7
M.TK_RBRACE  = 8
M.TK_LBRACK  = 9
M.TK_RBRACK  = 10
M.TK_ASSIGN  = 11
M.TK_ELLIPSIS = 12
M.TK_COLON   = 13
M.TK_EOF     = 14

---------------------------------------------------------------------------
-- Byte constants
---------------------------------------------------------------------------

local B_0     = 48   -- '0'
local B_9     = 57   -- '9'
local B_a     = 97   -- 'a'
local B_f     = 102  -- 'f'
local B_z     = 122  -- 'z'
local B_A     = 65   -- 'A'
local B_F     = 70   -- 'F'
local B_Z     = 90   -- 'Z'
local B_UNDER = 95   -- '_'
local B_NL    = 10   -- '\n'
local B_CR    = 13   -- '\r'
local B_SPACE = 32   -- ' '
local B_TAB   = 9    -- '\t'
local B_FF    = 12   -- '\f'
local B_VT    = 11   -- '\v'
local B_SLASH = 47   -- '/'
local B_STAR  = 42   -- '*'
local B_DOT   = 46   -- '.'
local B_x     = 120  -- 'x'
local B_X     = 88   -- 'X'
local B_u     = 117  -- 'u'
local B_U     = 85   -- 'U'
local B_l     = 108  -- 'l'
local B_L     = 76   -- 'L'
local B_DQUOT = 34   -- '"'
local B_SQUOT = 39   -- "'"
local B_BSLSH = 92   -- '\\'

local EOF = 256  -- sentinel: no valid byte

local uint8_ptr = ffi.typeof("const uint8_t*")

---------------------------------------------------------------------------
-- Character classification helpers
---------------------------------------------------------------------------

local function is_ident_start(b)
    return (b >= B_a and b <= B_z) or (b >= B_A and b <= B_Z) or b == B_UNDER
end

local function is_ident_cont(b)
    return (b >= B_a and b <= B_z) or (b >= B_A and b <= B_Z)
        or (b >= B_0 and b <= B_9) or b == B_UNDER
end

local function is_digit(b)
    return b >= B_0 and b <= B_9
end

local function is_hex_digit(b)
    return (b >= B_0 and b <= B_9)
        or (b >= B_a and b <= B_f)
        or (b >= B_A and b <= B_F)
end

local function is_space(b)
    return b == B_SPACE or b == B_TAB or b == B_FF or b == B_VT
end

local function is_newline(b)
    return b == B_NL or b == B_CR
end

local function is_int_suffix(b)
    return b == B_u or b == B_U or b == B_l or b == B_L
end

---------------------------------------------------------------------------
-- Lexer state
---------------------------------------------------------------------------

--[[::
CdeclLexState = {
  src: any, srclen: integer, pos: integer, b: integer,
  tk: integer, val: integer, pool: { ht_cap: integer, ht_mask: integer, ht_count: integer, next_id: integer, buf_count: integer, entries: { [integer]: unknown, ... }, bufs: { [integer]: unknown, ... }, rev: { [integer]: unknown, ... }, map: { [string]: integer, ... }, _anchors: { [integer]: string, ... }, ... }, _buf_id: integer,
  _nextbyte: (CdeclLexState) -> integer,
  _peekbyte: (CdeclLexState) -> integer,
  _lex: (CdeclLexState) -> (integer, integer),
  next: (CdeclLexState) -> integer,
  ...
}
]]

local Lexer = {}
Lexer.__index = Lexer

--: (source: string, pool: { ht_cap: integer, ht_mask: integer, ht_count: integer, next_id: integer, buf_count: integer, entries: { [integer]: unknown, ... }, bufs: { [integer]: unknown, ... }, rev: { [integer]: unknown, ... }, map: { [string]: integer, ... }, _anchors: { [integer]: string, ... }, ... } | nil) -> CdeclLexState
function M.new(source, pool)
    pool = pool or intern_mod.new()
    local src = ffi.cast(uint8_ptr, source)
    local len = #source
    local buf_id = intern_mod.register_buf(pool, src, source)
    --: CdeclLexState
    local ls = setmetatable({
        src    = src,
        srclen = len,
        pos    = 0,      -- next byte to read (0-based)
        b      = EOF,    -- current byte
        tk     = M.TK_EOF,
        val    = 0,
        pool   = pool,
        _buf_id = buf_id,
    }, Lexer)
    ls:_nextbyte()
    ls:next()
    return ls
end

---------------------------------------------------------------------------
-- Byte-level helpers
---------------------------------------------------------------------------

--: (CdeclLexState) -> integer
function Lexer:_nextbyte()
    if self.pos >= self.srclen then
        self.b = EOF
        return EOF
    end
    local b = self.src[self.pos]
    self.pos = self.pos + 1
    self.b = b
    return b
end

--: (CdeclLexState) -> integer
function Lexer:_peekbyte()
    if self.pos >= self.srclen then return EOF end
    return self.src[self.pos]
end

---------------------------------------------------------------------------
-- Internal lex implementation
---------------------------------------------------------------------------

--: (CdeclLexState) -> (integer, integer)
function Lexer:_lex()
    while true do
        local b = self.b

        -- EOF
        if b == EOF then
            return M.TK_EOF, 0
        end

        -- Whitespace (space, tab, \f, \v)
        if is_space(b) then
            self:_nextbyte()

        -- Newlines
        elseif is_newline(b) then
            -- Handle CRLF as a single newline
            local old = b
            self:_nextbyte()
            if is_newline(self.b) and self.b ~= old then
                self:_nextbyte()
            end

        -- '/' — line comment or block comment
        elseif b == B_SLASH then
            self:_nextbyte()
            if self.b == B_SLASH then
                -- Line comment: skip to end of line
                self:_nextbyte()
                while self.b ~= EOF and not is_newline(self.b) do
                    self:_nextbyte()
                end
            elseif self.b == B_STAR then
                -- Block comment: skip until */
                self:_nextbyte()
                while true do
                    if self.b == EOF then break end
                    if self.b == B_STAR then
                        self:_nextbyte()
                        if self.b == B_SLASH then
                            self:_nextbyte()
                            break
                        end
                    else
                        self:_nextbyte()
                    end
                end
            else
                -- Lone '/' — skip (unrecognized in cdefs)
            end

        -- Identifiers: [a-zA-Z_][a-zA-Z0-9_]*
        elseif is_ident_start(b) then
            local start = self.pos - 1
            local src = self.src
            local p = self.pos
            local srclen = self.srclen
            while p < srclen and is_ident_cont(src[p]) do
                p = p + 1
            end
            -- Advance pos; load next byte
            self.pos = p
            if p < srclen then
                self.b = src[p]
                self.pos = p + 1
            else
                self.b = EOF
            end
            local name_id = intern_mod.intern_raw(
                self.pool, src + start, p - start, self._buf_id, start)
            return M.TK_IDENT, name_id

        -- Integer literals: decimal or 0x hex, optional u/U/l/L suffixes
        elseif is_digit(b) then
            local val = 0
            if b == B_0 and (self:_peekbyte() == B_x or self:_peekbyte() == B_X) then
                -- Hex literal
                self:_nextbyte()  -- consume 'x'/'X'
                self:_nextbyte()  -- advance to first hex digit
                while is_hex_digit(self.b) do
                    local c = self.b
                    local digit
                    if c >= B_0 and c <= B_9 then
                        digit = c - B_0
                    elseif c >= B_a and c <= B_f then
                        digit = c - B_a + 10
                    else
                        digit = c - B_A + 10
                    end
                    val = val * 16 + digit
                    self:_nextbyte()
                end
            else
                -- Decimal literal
                val = b - B_0
                self:_nextbyte()
                while is_digit(self.b) do
                    val = val * 10 + (self.b - B_0)
                    self:_nextbyte()
                end
            end
            -- Skip integer suffixes: u, U, l, L (any combination)
            while is_int_suffix(self.b) do
                self:_nextbyte()
            end
            return M.TK_INT, val

        -- '.' — possibly ellipsis '...', otherwise skip
        elseif b == B_DOT then
            self:_nextbyte()
            if self.b == B_DOT then
                self:_nextbyte()
                if self.b == B_DOT then
                    self:_nextbyte()
                    return M.TK_ELLIPSIS, 0
                end
                -- Two dots: skip (unusual in cdefs)
            end
            -- Single dot (or two dots): skip

        -- String literals — skip entirely (appear in __attribute__, etc.)
        elseif b == B_DQUOT or b == B_SQUOT then
            local delim = b
            self:_nextbyte()
            while self.b ~= EOF and self.b ~= delim do
                if self.b == B_BSLSH then
                    self:_nextbyte()  -- skip escape char
                    if self.b ~= EOF then self:_nextbyte() end
                else
                    self:_nextbyte()
                end
            end
            if self.b == delim then self:_nextbyte() end
            -- No token emitted — loop continues

        -- Single-character punctuation
        elseif b == 59  then self:_nextbyte(); return M.TK_SEMI,   0  -- ';'
        elseif b == 44  then self:_nextbyte(); return M.TK_COMMA,  0  -- ','
        elseif b == B_STAR then self:_nextbyte(); return M.TK_STAR, 0  -- '*'
        elseif b == 40  then self:_nextbyte(); return M.TK_LPAREN, 0  -- '('
        elseif b == 41  then self:_nextbyte(); return M.TK_RPAREN, 0  -- ')'
        elseif b == 123 then self:_nextbyte(); return M.TK_LBRACE, 0  -- '{'
        elseif b == 125 then self:_nextbyte(); return M.TK_RBRACE, 0  -- '}'
        elseif b == 91  then self:_nextbyte(); return M.TK_LBRACK, 0  -- '['
        elseif b == 93  then self:_nextbyte(); return M.TK_RBRACK, 0  -- ']'
        elseif b == 61  then self:_nextbyte(); return M.TK_ASSIGN, 0  -- '='
        elseif b == 58  then self:_nextbyte(); return M.TK_COLON,  0  -- ':'

        -- Anything else: skip (unrecognized byte — &, ~, #, etc.)
        else
            self:_nextbyte()
        end
    end
    return M.TK_EOF, 0 --[[ unreachable ]]
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

--: (CdeclLexState) -> integer
function Lexer:next()
    self.tk, self.val = self:_lex()
    return self.tk
end

return M
