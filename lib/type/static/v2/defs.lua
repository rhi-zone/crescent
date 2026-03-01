-- lib/type/static/v2/defs.lua
-- FFI struct definitions and integer constants for the v2 typechecker.

local ffi = require("ffi")

ffi.cdef[[
typedef struct {
    uint8_t  kind;
    uint8_t  flags;
    uint16_t col;
    uint32_t line;
    int32_t  data[6];
} ASTNode;  /* 32 bytes */

typedef struct {
    uint8_t  tag;
    uint8_t  flags;
    uint16_t reserved;
    int32_t  data[7];
} TypeSlot;  /* 32 bytes */

typedef struct {
    int32_t  name_id;
    int32_t  type_id;
    uint8_t  optional;
    uint8_t  padding[3];
} FieldEntry;  /* 12 bytes */
]]

local M = {}

-- Node kinds
M.NODE_LITERAL          = 0
M.NODE_IDENTIFIER       = 1
M.NODE_UNARY_EXPR       = 2
M.NODE_BINARY_EXPR      = 3
M.NODE_INDEX_EXPR       = 4
M.NODE_FIELD_EXPR       = 5
M.NODE_METHOD_CALL      = 6
M.NODE_CALL_EXPR        = 7
M.NODE_FUNC_EXPR        = 8
M.NODE_TABLE_EXPR       = 9
M.NODE_TABLE_FIELD      = 10
M.NODE_VARARG_EXPR      = 11
M.NODE_ASSIGN_STMT      = 12
M.NODE_LOCAL_STMT       = 13
M.NODE_DO_STMT          = 14
M.NODE_WHILE_STMT       = 15
M.NODE_REPEAT_STMT      = 16
M.NODE_IF_STMT          = 17
M.NODE_IF_CLAUSE        = 18
M.NODE_FOR_NUM          = 19
M.NODE_FOR_IN           = 20
M.NODE_RETURN_STMT      = 21
M.NODE_BREAK_STMT       = 22
M.NODE_GOTO_STMT        = 23
M.NODE_LABEL_STMT       = 24
M.NODE_EXPR_STMT        = 25
M.NODE_FUNC_DECL        = 26
M.NODE_CHUNK            = 27

-- Type tags
M.TAG_NIL               = 0
M.TAG_BOOLEAN           = 1
M.TAG_NUMBER            = 2
M.TAG_STRING            = 3
M.TAG_ANY               = 4
M.TAG_NEVER             = 5
M.TAG_INTEGER           = 6
M.TAG_LITERAL           = 7
M.TAG_FUNCTION          = 8
M.TAG_TABLE             = 9
M.TAG_UNION             = 10
M.TAG_INTERSECTION      = 11
M.TAG_VAR               = 12
M.TAG_ROWVAR            = 13
M.TAG_TUPLE             = 14
M.TAG_NOMINAL           = 15
M.TAG_MATCH_TYPE        = 16
M.TAG_INTRINSIC         = 17
M.TAG_TYPE_CALL         = 18
M.TAG_FORALL            = 19
M.TAG_SPREAD            = 20
M.TAG_NAMED             = 21
M.TAG_CDATA             = 22

-- Token types: keywords (0-21)
M.TK_AND                = 0
M.TK_BREAK              = 1
M.TK_DO                 = 2
M.TK_ELSE               = 3
M.TK_ELSEIF             = 4
M.TK_END                = 5
M.TK_FALSE              = 6
M.TK_FOR                = 7
M.TK_FUNCTION           = 8
M.TK_GOTO               = 9
M.TK_IF                 = 10
M.TK_IN                 = 11
M.TK_LOCAL              = 12
M.TK_NIL                = 13
M.TK_NOT                = 14
M.TK_OR                 = 15
M.TK_REPEAT             = 16
M.TK_RETURN             = 17
M.TK_THEN               = 18
M.TK_TRUE               = 19
M.TK_UNTIL              = 20
M.TK_WHILE              = 21
M.NUM_KEYWORDS          = 22

-- Token types: operators/punctuation (22+)
M.TK_CONCAT             = 22
M.TK_DOTS               = 23
M.TK_EQ                 = 24
M.TK_GE                 = 25
M.TK_LE                 = 26
M.TK_NE                 = 27
M.TK_LABEL              = 28
M.TK_PLUS               = 29
M.TK_MINUS              = 30
M.TK_STAR               = 31
M.TK_SLASH              = 32
M.TK_PERCENT            = 33
M.TK_CARET              = 34
M.TK_HASH               = 35
M.TK_LT                 = 36
M.TK_GT                 = 37
M.TK_ASSIGN             = 38
M.TK_LPAREN             = 39
M.TK_RPAREN             = 40
M.TK_LBRACKET           = 41
M.TK_RBRACKET           = 42
M.TK_LBRACE             = 43
M.TK_RBRACE             = 44
M.TK_SEMICOLON          = 45
M.TK_COLON              = 46
M.TK_COMMA              = 47
M.TK_DOT                = 48

-- Token types: literals/special (last)
M.TK_NAME               = 49
M.TK_NUMBER             = 50
M.TK_STRING             = 51
M.TK_EOF                = 52

-- Operators (for AST data slots, not token types)
M.OP_ADD                = 0
M.OP_SUB                = 1
M.OP_MUL                = 2
M.OP_DIV                = 3
M.OP_MOD                = 4
M.OP_POW                = 5
M.OP_CONCAT             = 6
M.OP_EQ                 = 7
M.OP_NE                 = 8
M.OP_LT                 = 9
M.OP_LE                 = 10
M.OP_GT                 = 11
M.OP_GE                 = 12
M.OP_AND                = 13
M.OP_OR                 = 14
M.OP_UNM                = 15
M.OP_NOT                = 16
M.OP_LEN                = 17

-- Literal kinds
M.LIT_STRING            = 0
M.LIT_NUMBER            = 1
M.LIT_BOOLEAN           = 2
M.LIT_NIL               = 3

-- Flag bits (nodes)
M.FLAG_VARARG           = 1
M.FLAG_LOCAL            = 2
M.FLAG_COMPUTED         = 4

-- Flag bits (types)
M.FLAG_GENERIC          = 1
M.FLAG_RECURSIVE        = 2

-- Annotation kinds
M.ANN_TYPE              = 0
M.ANN_DECL              = 1
M.ANN_TYPE_ARGS         = 2

-- Operator precedence table (left * 256 + right)
M.binop_priority = {
    [M.OP_ADD]    = 6*256+6,
    [M.OP_SUB]    = 6*256+6,
    [M.OP_MUL]    = 7*256+7,
    [M.OP_DIV]    = 7*256+7,
    [M.OP_MOD]    = 7*256+7,
    [M.OP_POW]    = 10*256+9,
    [M.OP_CONCAT] = 5*256+4,
    [M.OP_EQ]     = 3*256+3,
    [M.OP_NE]     = 3*256+3,
    [M.OP_LT]     = 3*256+3,
    [M.OP_LE]     = 3*256+3,
    [M.OP_GT]     = 3*256+3,
    [M.OP_GE]     = 3*256+3,
    [M.OP_AND]    = 2*256+2,
    [M.OP_OR]     = 1*256+1,
}

-- Token name table (for error messages)
M.token_name = {}
M.token_name[M.TK_AND]       = "and"
M.token_name[M.TK_BREAK]     = "break"
M.token_name[M.TK_DO]        = "do"
M.token_name[M.TK_ELSE]      = "else"
M.token_name[M.TK_ELSEIF]    = "elseif"
M.token_name[M.TK_END]       = "end"
M.token_name[M.TK_FALSE]     = "false"
M.token_name[M.TK_FOR]       = "for"
M.token_name[M.TK_FUNCTION]  = "function"
M.token_name[M.TK_GOTO]      = "goto"
M.token_name[M.TK_IF]        = "if"
M.token_name[M.TK_IN]        = "in"
M.token_name[M.TK_LOCAL]     = "local"
M.token_name[M.TK_NIL]       = "nil"
M.token_name[M.TK_NOT]       = "not"
M.token_name[M.TK_OR]        = "or"
M.token_name[M.TK_REPEAT]    = "repeat"
M.token_name[M.TK_RETURN]    = "return"
M.token_name[M.TK_THEN]      = "then"
M.token_name[M.TK_TRUE]      = "true"
M.token_name[M.TK_UNTIL]     = "until"
M.token_name[M.TK_WHILE]     = "while"
M.token_name[M.TK_CONCAT]    = ".."
M.token_name[M.TK_DOTS]      = "..."
M.token_name[M.TK_EQ]        = "=="
M.token_name[M.TK_GE]        = ">="
M.token_name[M.TK_LE]        = "<="
M.token_name[M.TK_NE]        = "~="
M.token_name[M.TK_LABEL]     = "::"
M.token_name[M.TK_PLUS]      = "+"
M.token_name[M.TK_MINUS]     = "-"
M.token_name[M.TK_STAR]      = "*"
M.token_name[M.TK_SLASH]     = "/"
M.token_name[M.TK_PERCENT]   = "%"
M.token_name[M.TK_CARET]     = "^"
M.token_name[M.TK_HASH]      = "#"
M.token_name[M.TK_LT]        = "<"
M.token_name[M.TK_GT]        = ">"
M.token_name[M.TK_ASSIGN]    = "="
M.token_name[M.TK_LPAREN]    = "("
M.token_name[M.TK_RPAREN]    = ")"
M.token_name[M.TK_LBRACKET]  = "["
M.token_name[M.TK_RBRACKET]  = "]"
M.token_name[M.TK_LBRACE]    = "{"
M.token_name[M.TK_RBRACE]    = "}"
M.token_name[M.TK_SEMICOLON] = ";"
M.token_name[M.TK_COLON]     = ":"
M.token_name[M.TK_COMMA]     = ","
M.token_name[M.TK_DOT]       = "."
M.token_name[M.TK_NAME]      = "<name>"
M.token_name[M.TK_NUMBER]    = "<number>"
M.token_name[M.TK_STRING]    = "<string>"
M.token_name[M.TK_EOF]       = "<eof>"

-- Map from single-char byte to token type (for fast dispatch)
M.char_to_token = {}
M.char_to_token[string.byte("+")] = M.TK_PLUS
M.char_to_token[string.byte("-")] = M.TK_MINUS
M.char_to_token[string.byte("*")] = M.TK_STAR
M.char_to_token[string.byte("/")] = M.TK_SLASH
M.char_to_token[string.byte("%")] = M.TK_PERCENT
M.char_to_token[string.byte("^")] = M.TK_CARET
M.char_to_token[string.byte("#")] = M.TK_HASH
M.char_to_token[string.byte("(")] = M.TK_LPAREN
M.char_to_token[string.byte(")")] = M.TK_RPAREN
M.char_to_token[string.byte("[")] = M.TK_LBRACKET
M.char_to_token[string.byte("]")] = M.TK_RBRACKET
M.char_to_token[string.byte("{")] = M.TK_LBRACE
M.char_to_token[string.byte("}")] = M.TK_RBRACE
M.char_to_token[string.byte(";")] = M.TK_SEMICOLON
M.char_to_token[string.byte(",")] = M.TK_COMMA

-- Keyword strings (ordered by token ID, for intern pre-population)
M.keywords = {
    "and", "break", "do", "else", "elseif", "end", "false", "for",
    "function", "goto", "if", "in", "local", "nil", "not", "or",
    "repeat", "return", "then", "true", "until", "while",
}

return M
