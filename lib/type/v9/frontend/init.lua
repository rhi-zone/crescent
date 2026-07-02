-- lib/type/v9/frontend/init.lua
-- v9 FRONTEND SEAM: Lua source text -> plain-table AST with line/col on every
-- node.
--
-- This wires the PROVEN in-tree full-Lua parser (lib/type/static/{lex,parse}:
-- parse-only, zero checker imports, parses all of lib/ — verified standalone)
-- plus the v4 arena->POJO decoder (lib/type/static-v4/driver/decoder) behind a
-- v9-owned interface. The legacy modules are required IN PLACE — vendoring
-- them would be churn; this seam is the swap point if the parser is ever
-- replaced. Downstream v9 code (lower/check) depends only on THIS module's
-- contract:
--
--   parse(source, filename) -> (Ast | nil, errmsg)
--
--   Ast = a plain Lua table tree; every node carries `tag` (an integer
--   defs.NODE_* kind), `line`, `col`, plus kind-specific fields (see the
--   decoder's per-kind field contract). Node kinds are CLOSED: the parser
--   emits kinds 0..28 and defs.NODE_MATCH_EXPR (29) is a walker-only
--   synthetic — M.NODE_NAME names all 30 so consumers can be TOTAL over them.
--
-- Errors are data (`nil, errmsg`), never thrown: the legacy parser throws on
-- syntax errors; this seam pcall-fences it.
--
-- NOT lifted: lib/type/static/ann.lua (the annotation-string parser) — it is
-- entangled with the legacy type algebra. Annotations reach v9 later, behind
-- their own seam; until then `--:`/`--::` strings ride along unparsed on the
-- lexer and NODE_CAST_EXPR carries a raw annotation id.

if not package.path:find("?/init.lua", 1, true) then
    package.path = "./?/init.lua;" .. package.path
end

local parse_mod = require("lib.type.static.parse")
local decoder = require("lib.type.static-v4.driver.decoder")
local defs = require("lib.type.static.defs")

-- The decoded-node shape v9 consumes. Open record: kind-specific fields are
-- read as `unknown` and narrowed at each use site (the same force-cast-free
-- discipline as the engine's opaque cells — see engine/ARCHITECTURE.md).
--:: Ast = { tag: integer, line: integer, col: integer, ... }

local M = {}

--: (x: unknown) -> x is Ast
local function is_node(x) return type(x) == "table" end
M.is_node = is_node

--: (x: unknown) -> x is { [integer]: Ast }
local function is_list(x) return type(x) == "table" end
M.is_list = is_list

-- Narrow the legacy parser's arena result at the seam boundary.
--: (x: unknown) -> x is { nodes: unknown, lists: unknown, pool: unknown, root: integer, lexer: unknown, ... }
local function is_parse_result(x) return type(x) == "table" end

-- All 30 node kinds, named for diagnostics and for totality checks. This is
-- the closed roster a total consumer must cover — kebab-case names double as
-- the `unsupported:<construct>` bucket names.
local NODE_NAME = {} --: { [integer]: string }
NODE_NAME[defs.NODE_LITERAL] = "literal"
NODE_NAME[defs.NODE_IDENTIFIER] = "identifier"
NODE_NAME[defs.NODE_UNARY_EXPR] = "unary-expr"
NODE_NAME[defs.NODE_BINARY_EXPR] = "binary-expr"
NODE_NAME[defs.NODE_INDEX_EXPR] = "index-expr"
NODE_NAME[defs.NODE_FIELD_EXPR] = "field-expr"
NODE_NAME[defs.NODE_METHOD_CALL] = "method-call"
NODE_NAME[defs.NODE_CALL_EXPR] = "call-expr"
NODE_NAME[defs.NODE_FUNC_EXPR] = "func-expr"
NODE_NAME[defs.NODE_TABLE_EXPR] = "table-constructor"
NODE_NAME[defs.NODE_TABLE_FIELD] = "table-field"
NODE_NAME[defs.NODE_VARARG_EXPR] = "vararg"
NODE_NAME[defs.NODE_ASSIGN_STMT] = "assign-stmt"
NODE_NAME[defs.NODE_LOCAL_STMT] = "local-stmt"
NODE_NAME[defs.NODE_DO_STMT] = "do-stmt"
NODE_NAME[defs.NODE_WHILE_STMT] = "while-stmt"
NODE_NAME[defs.NODE_REPEAT_STMT] = "repeat-stmt"
NODE_NAME[defs.NODE_IF_STMT] = "if-stmt"
NODE_NAME[defs.NODE_IF_CLAUSE] = "if-clause"
NODE_NAME[defs.NODE_FOR_NUM] = "for-num"
NODE_NAME[defs.NODE_FOR_IN] = "for-in"
NODE_NAME[defs.NODE_RETURN_STMT] = "return-stmt"
NODE_NAME[defs.NODE_BREAK_STMT] = "break-stmt"
NODE_NAME[defs.NODE_GOTO_STMT] = "goto-stmt"
NODE_NAME[defs.NODE_LABEL_STMT] = "label-stmt"
NODE_NAME[defs.NODE_EXPR_STMT] = "expr-stmt"
NODE_NAME[defs.NODE_FUNC_DECL] = "func-decl"
NODE_NAME[defs.NODE_CHUNK] = "chunk"
NODE_NAME[defs.NODE_CAST_EXPR] = "cast-expr"
NODE_NAME[defs.NODE_MATCH_EXPR] = "match-expr"
M.NODE_NAME = NODE_NAME

-- Total count of node kinds (for totality assertions in tests).
M.NODE_KIND_COUNT = 30

--: (integer) -> string
function M.node_name(tag)
    local n = NODE_NAME[tag]
    if n ~= nil then return n end
    return "node#" .. tostring(tag)
end

-- Parse Lua source to a decoded plain-table AST. `(nil, errmsg)` on syntax
-- errors (errmsg already carries file:line:col from the parser).
--: (source: string, filename: string) -> (Ast | nil, string | nil)
function M.parse(source, filename)
    local ok, res = pcall(parse_mod.parse, source, filename)
    if not ok then return nil, tostring(res) end
    -- Widen to `unknown`, then narrow by predicate: the pcall result is a
    -- union the predicate cannot refine directly.
    local raw = res --: unknown
    if not is_parse_result(raw) then return nil, filename .. ": parser returned a non-table result" end
    local ok2, decoded = pcall(decoder.decode, raw)
    if not ok2 then return nil, filename .. ": decode error: " .. tostring(decoded) end
    local dec = decoded --: unknown
    if not is_node(dec) then return nil, filename .. ": decoder returned a non-node" end
    return dec, nil
end

return M
