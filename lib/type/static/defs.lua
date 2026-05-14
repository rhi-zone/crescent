-- lib/type/static/defs.lua
-- FFI struct definitions and integer constants for the typechecker.

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
    uint8_t  flags;
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
M.NODE_CAST_EXPR        = 28

-- Type tags
M.TAG_NIL               = 0
M.TAG_BOOLEAN           = 1
M.TAG_NUMBER            = 2
M.TAG_STRING            = 3
M.TAG_ANY               = 4
M.TAG_NEVER             = 5
M.TAG_INTEGER           = 6
M.TAG_UNKNOWN           = 7   -- top type: everything assignable to it, but must narrow before use
M.TAG_LITERAL           = 8
M.TAG_FUNCTION          = 9
M.TAG_TABLE             = 10
M.TAG_UNION             = 11
M.TAG_INTERSECTION      = 12
M.TAG_VAR               = 13
M.TAG_ROWVAR            = 14
M.TAG_TUPLE             = 15
M.TAG_NOMINAL           = 16
M.TAG_MATCH_TYPE        = 17
M.TAG_INTRINSIC         = 18
M.TAG_TYPE_CALL         = 19
M.TAG_FORALL            = 20
M.TAG_SPREAD            = 21
M.TAG_NAMED             = 22
M.TAG_CDATA             = 23
M.TAG_ENUM_MEMBER       = 24  -- named enum member: EnumName.MemberName
-- TypeSlot layout for TAG_ENUM_MEMBER:
--   data[0] = enum_name_id   (intern ID of the enum table variable name)
--   data[1] = member_name_id (intern ID of the member field name)
--   data[2] = lit_kind       (LIT_INTEGER or LIT_STRING)
--   data[3] = value          (LIT_INTEGER: int32 value; LIT_STRING: intern ID)
M.TAG_TYPEOF            = 25  -- annotation-only: typeof <ident> — capture inferred type of a binding
-- TypeSlot layout for TAG_TYPEOF (annotation arena only, never in the checker's type arena):
--   data[0] = name_id  (intern ID of the identifier to look up)
M.TAG_FFIC              = 26  -- magic: the live ffi.C table for this compilation unit
-- TAG_FFIC has no data slots; it resolves to ctx.T_FFI_C at check time.
-- Written as $FfiC in annotations; the solver substitutes it with ctx.T_FFI_C.
M.TAG_CAPTURE           = 27  -- pattern-position capture variable: %Name
-- TypeSlot layout for TAG_CAPTURE:
--   data[0] = name_id  (intern ID of the capture variable name)
-- When encountered in a match pattern, binds name_id -> resolved input type.
-- Always succeeds (acts as wildcard). Used only in annotation arena; never in checker arena.
M.TAG_PAT_ALL_FIELDS    = 28  -- { ...[%K]: %V } pattern: distributes over all fields of input
-- TypeSlot layout for TAG_PAT_ALL_FIELDS:
--   data[0] = k_name_id  (intern ID of the key capture variable name)
--   data[1] = v_name_id  (intern ID of the value capture variable name)
-- Evaluator: for each named field -> K = lit_string(name), V = field_type;
--            for each indexer -> K = key_type, V = value_type;
--            TAG_ANY/TAG_UNKNOWN -> one iteration K=unknown, V=unknown;
--            TAG_NEVER -> zero iterations -> never.
-- Always matches (total pattern). Used only in annotation arena pattern positions.
M.TAG_PAT_REST_FIELDS   = 29  -- { ...[%Rest] } pattern: rest-field capture in table pattern
-- TypeSlot layout for TAG_PAT_REST_FIELDS:
--   data[0] = name_id  (intern ID of the rest capture variable name)
-- When encountered in a table match pattern, collects all fields NOT explicitly matched
-- by named fields in the pattern into a synthetic table type and binds name_id → that type.
-- Used only in annotation arena pattern positions; never in checker arena result positions.
M.TAG_PAT_META_SPREAD   = 30  -- { #...%M } pattern: captures all meta slots of input as a table
-- TypeSlot layout for TAG_PAT_META_SPREAD:
--   data[0] = name_id  (intern ID of the capture variable name)
-- Succeeds if the input type has at least one meta slot; fails otherwise (enabling _ => nil fallback).
-- Binds name_id → a synthetic table type with empty regular fields and meta list = input's meta slots.
-- Used only in annotation arena pattern positions; never in checker arena result positions.
M.TAG_PARTIAL_APP       = 31  -- partially-applied generic alias: Alias<A> with fewer args than required
-- TypeSlot layout for TAG_PARTIAL_APP:
--   data[0] = name_id    (intern ID of the alias name)
--   data[1] = list start (partial args list in ctx.lists)
--   data[2] = list length
-- Created by resolve_named_type when arg_ids_len >= 1 and arg_ids_len < required_count.
-- Consumed by apply_type_fn (intrinsic.lua): appends one more arg and calls resolve_named_type.
-- Passes through substitute_inner unchanged (partial args are already concrete at creation time).
M.TAG_INDEX_TYPE        = 32  -- TS-style indexed access: T[K]
-- TypeSlot layout for TAG_INDEX_TYPE:
--   data[0] = subject tid (the indexed type T)
--   data[1] = key tid     (the key type K)
-- Annotation arena only — resolved away by resolve_annotation_type:
--   - If subject is concrete, evaluated immediately via match.lookup_index.
--   - If subject is a TAG_NAMED placeholder (deferred generic context), kept and re-evaluated
--     via env.substitute_inner once the placeholder is replaced with a concrete type.
-- Miss is a hard error: INDEX_KEY_NOT_FOUND. Distributes over unions; intersects over intersections.

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
M.LIT_NUMBER            = 1   -- float literal; data[1] = numval index (per-file)
M.LIT_BOOLEAN           = 2
M.LIT_NIL               = 3
M.LIT_INTEGER           = 4   -- integer literal; data[1] = value directly (int32_t, globally comparable)
M.LIT_OPAQUE_KEY        = 5   -- opaque table-valued key; data[1] = intern ID of the variable name

-- Flag bits (nodes)
M.FLAG_VARARG           = 1
M.FLAG_LOCAL            = 2
M.FLAG_COMPUTED         = 4
M.FLAG_FORCE_CAST       = 1  -- NODE_CAST_EXPR: --[[:! T]] overlap-checked force cast

-- Flag bits (types)
M.FLAG_GENERIC          = 1
M.FLAG_RECURSIVE        = 2
M.FLAG_SKOLEM           = 4   -- type variable that must never be bound (used for generic body checking)
M.FLAG_ROWVAR_INFER     = 8   -- row variable created for type inference (vs. declared open record's `...`)

-- Flag bits (field entries)
M.FLAG_OPTIONAL         = 0x01  -- field may be absent; access returns T|nil
M.FLAG_READONLY         = 0x02  -- assignment to this field is a type error
M.FLAG_PRIVATE          = 0x04  -- inaccessible outside the defining file
M.FLAG_OPAQUE_KEY       = 0x08  -- field keyed by an opaque table value (typeclass dispatch: t[TC])

-- Annotation kinds
M.ANN_TYPE              = 0
M.ANN_DECL              = 1
M.ANN_TYPE_ARGS         = 2
M.ANN_MODULE            = 3  -- --:: module "name": T  (declares require("name") return type)
M.ANN_UNSEAL            = 4  -- --:: unseal Name        (rebinds opaque variable to inner type)
M.ANN_REQUIRE           = 5  -- --:: require "mod.path"  (load declaration file into scope)
M.ANN_AUGMENT           = 6  -- --:: augment Name { field: T, ... }  (merge fields into existing binding)
M.ANN_TEMPLATE          = 7  -- --:: template  (marks next function as template: body re-checked at each call site)

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

-- Diagnostic error codes
M.E = {
    FIELD_NOT_FOUND       = 1,   -- `obj.field` doesn't exist
    CALL_ARG_MISMATCH     = 2,   -- named or positional argument type mismatch
    CALL_ARG_MISSING      = 3,   -- required argument not supplied
    ARITH_TYPE            = 4,   -- cannot perform arithmetic on T
    LENGTH_TYPE           = 5,   -- cannot get length of T
    COMPARE_TYPE          = 6,   -- cannot compare T (no ordering metamethod)
    COMPARE_CROSS         = 7,   -- cannot compare T with U (cross-type mismatch)
    CONCAT_TYPE           = 8,   -- cannot concatenate T
    UNHANDLED_EXPR        = 9,   -- internal: unhandled expression kind
    UNKNOWN_IDENTIFIER    = 10,  -- undefined identifier
    VARARG_OUTSIDE_FN     = 11,  -- '...' used outside vararg function
    BINARY_OP_UNKNOWN     = 12,  -- internal: unknown binary operator
    TYPE_MISMATCH         = 13,  -- declared type vs initializer mismatch (local with annotation)
    ASSIGN_MISMATCH       = 14,  -- variable assignment type mismatch
    FIELD_REASSIGN        = 15,  -- field re-assigned with incompatible type
    INDEX_ASSIGN_MISMATCH = 16,  -- index assignment doesn't match indexer type
    NO_MATCHING_OVERLOAD  = 17,  -- no overload accepts the given arguments
    UNION_CALL_MISMATCH   = 18,  -- argument doesn't satisfy all union members
    CANNOT_CALL           = 19,  -- cannot call a non-function type
    METHOD_NOT_FOUND      = 20,  -- no method on type
    UNNAMED_PARAMS        = 21,  -- declared function type has unnamed parameters (warning)
    EXPLICIT_ANY          = 22,  -- explicit `any` in annotation (warning)
    FIELD_READONLY        = 23,  -- assignment to a readonly field
    NON_EXHAUSTIVE        = 24,  -- if-chain over union doesn't cover all members (warning)
    FIELD_ON_PRIMITIVE    = 25,  -- field access on a type that cannot have fields (nil, boolean, number literal)
    CONSTRAINT_MISMATCH   = 26,  -- type alias body does not satisfy declared constraint
    INDEX_KEY_NOT_FOUND   = 27,  -- T[K] where T has no member K
    FORCE_CAST_TO_ANY     = 28,  -- `--[[:! any]]` is disallowed (use `--[[: unknown]]`)
    LOCAL_NEEDS_INIT      = 29,  -- annotated local without initializer when nil ∉ T (Gap 9)
    MATCH_CONTAINS_ANY    = 30,  -- match type contains `any`; exhaustiveness cannot be verified (warning)
    ANY_IN_TYPE           = 31,  -- `any` used as a component of a compound type (warning)
    FORCE_CAST            = 32,  -- `--[[:! T]]` force cast used; fix upstream annotation instead (warning)
    MODULE_DECL           = 33,  -- `--:: module` declaration in user code; require() return types are inferred from return M (warning)
    REDUNDANT_CAST        = 34,  -- `--[[:! T]]` is redundant: actual type is already assignable to T; remove the cast
    MISSING_PARAM_ANNOTATION = 35,  -- (deprecated) function parameter has no annotation — superseded by MISSING_FUNCTION_SIGNATURE
    MISSING_FUNCTION_SIGNATURE = 36,  -- function definition has no `--:` annotation; signatures are mandatory at statement position (error)
    IMPLICIT_ANY               = 37,  -- inference fell back to `any` at this site; narrow the source type or annotate (warning)
}

-- Keyword strings (ordered by token ID, for intern pre-population)
M.keywords = {
    "and", "break", "do", "else", "elseif", "end", "false", "for",
    "function", "goto", "if", "in", "local", "nil", "not", "or",
    "repeat", "return", "then", "true", "until", "while",
}

-- Double ↔ int32×2 reinterpret helpers.
-- LIT_NUMBER stores float values inline in data[1]+data[2] as two int32s,
-- enabling globally comparable float literals across files.
local _f64buf = ffi.new("union { double d; int32_t i[2]; }")
function M.double_to_i32x2(v)
    _f64buf.d = v
    return _f64buf.i[0], _f64buf.i[1]
end
function M.i32x2_to_double(lo, hi)
    _f64buf.i[0] = lo
    _f64buf.i[1] = hi
    return _f64buf.d
end

-- Populate rule_defaults after M.E is available.
do
    local E = M.E
    M.rule_defaults = {
        [E.EXPLICIT_ANY]       = { severity = "warning", name = "explicit_any" },
        [E.ANY_IN_TYPE]        = { severity = "warning", name = "any_in_type" },
        [E.FORCE_CAST]         = { severity = "warning", name = "force_cast" },
        [E.REDUNDANT_CAST]     = { severity = "error",   name = "redundant_cast" },
        [E.MATCH_CONTAINS_ANY] = { severity = "warning", name = "match_contains_any" },
        [E.MODULE_DECL]        = { severity = "warning", name = "module_decl" },
        [E.UNNAMED_PARAMS]     = { severity = "warning", name = "unnamed_params" },
        [E.NON_EXHAUSTIVE]     = { severity = "warning", name = "non_exhaustive" },
        [E.MISSING_PARAM_ANNOTATION]   = { severity = "warning", name = "missing_param_annotation" },
        [E.MISSING_FUNCTION_SIGNATURE] = { severity = "error",   name = "missing_function_signature" },
        [E.IMPLICIT_ANY]               = { severity = "warning", name = "implicit_any" },
    }
end

-- fnv31: FNV-1a hash of a string, kept in int32 range.
-- Used to derive stable nominal type identities from source positions.
-- Collision probability is negligible for practical type declaration counts.
do
    local bxor, tobit = require("bit").bxor, require("bit").tobit
    function M.fnv31(s)
        local h = tobit(0x811c9dc5)
        for i = 1, #s do
            h = bxor(h, s:byte(i))
            h = tobit(h * 0x01000193)
        end
        return h
    end
end

return M
