-- tooling/grammar_gen/canon.lua
--
-- Canonicalization + structural fingerprinting over luaparse.lua's AST.
--
-- Two separable jobs:
--
-- 1. canonicalize(block): rewrite AST subtrees that are semantically the
--    same idiom but syntactically different into one shared node shape.
--    Currently handles exactly one such rewrite, the ground-truth case this
--    tool must clear: a "conditional value assignment" expressed either as
--    a ternary (`x and a or b`) or as an if/else with a single, identically
--    targeted assignment in each branch. Both become a `cond_assign` node.
--    This is a GENERIC rewrite (keyed on shape, not on variable names or
--    file identity) — it fires on any ternary or if/else fitting the shape,
--    anywhere in the corpus, not just the known dispatcher files.
--
-- 2. fingerprint(node): produce a string key abstract enough that two
--    instances of "the same production" collide, but concrete enough that
--    unrelated code doesn't. Identifiers and literal values become
--    placeholders; tags, operators, and argument-count/shape are kept.
--
--    For `cond_assign` specifically, the fingerprint deliberately DROPS the
--    condition's own internal shape and keeps only the coarse ("what kind
--    of expression") shape of the then/else branches. This is a modeling
--    choice, documented here and in docs/design/codebase-as-grammar.md: the
--    condition is the instance-specific "decision content" of a
--    conditional-assignment idiom (what varies from call site to call
--    site), while the branch shapes (name-reference vs. fresh call vs.
--    literal) are what characterize the idiom itself ("try an existing
--    value, else compute one" vs. "pick between two literals", etc.).
--    Dropping the condition's shape is exactly what lets a plain `if ok
--    then` (compress/crypto) and a compound `(ok and type(x)=="table")`
--    ternary guard (regex) collide into the same slot — matching them on
--    condition shape too would keep them apart, which is the token/AST-
--    shingling failure mode this tool exists to fix. The tradeoff, stated
--    plainly: this also collides unrelated conditional-assignments that
--    happen to share a branch-shape pattern but nothing else semantically.
--    See the design doc for how this shows up at whole-corpus scale.
--
-- Substrate note: every AST node is an open, dynamically-tagged record
-- (luaparse.lua's own header comment explains why: one shape per `.tag`,
-- matched at runtime, not a closed struct any single variable holds one
-- shape of). The principled static typing for this is a proper closed
-- discriminated union (one record type per tag, unioned, narrowed via
-- `.tag ==` comparisons — this checker DOES support that narrowing
-- pattern; see TODO.md's y_crdt notes on Struct-union kind-discriminant
-- narrowing). Doing that here would mean duplicating ~20 variant record
-- types across every file that walks this tree (luaparse.lua, canon.lua,
-- discover.lua), because this checker has no cross-file named-type-sharing
-- path for a locally-defined (non-stdlib) module's types that doesn't hit
-- the same friction TODO.md already documents for y_crdt's typeof/
-- self-referential-type gap — and `--[[:! T]]` force casts past `unknown`
-- are rejected outright by `bin/cr check` (not just discouraged; see
-- TODO.md's base64/json force-cast note for the identical rejection).
-- Field reads below go through get/gs/gb/gl, which narrow `unknown` via
-- real `type()` checks (the established corpus pattern for this — see
-- lib/y_crdt's `pairs()`-over-unknown workaround) rather than casting past
-- it; a shape mismatch is an internal-consistency bug in this tool's own
-- parser/canonicalizer, so it hard-errors instead of returning (nil, err).

local M = {}

-- ═══════════════════════ node field access ═══════════════════════

--: (n: unknown) -> { [string]: unknown }
local function as_record(n)
  if type(n) ~= "table" then error("grammar_gen: expected a node table, got " .. type(n)) end
  return n --[[: { [string]: unknown } ]]
end

--: (n: unknown, key: string) -> unknown
local function get(n, key)
  return as_record(n)[key]
end
M.get = get

--: (n: unknown, key: string) -> string
local function gs(n, key)
  local v = get(n, key)
  if type(v) ~= "string" then error("grammar_gen: expected field '" .. key .. "' to be a string, got " .. type(v)) end
  return v
end

--: (n: unknown, key: string) -> boolean
local function gb(n, key)
  local v = get(n, key)
  if type(v) ~= "boolean" then error("grammar_gen: expected field '" .. key .. "' to be a boolean, got " .. type(v)) end
  return v
end

--: (n: unknown, key: string) -> { [integer]: unknown }
local function gl(n, key)
  local v = get(n, key)
  if type(v) ~= "table" then error("grammar_gen: expected field '" .. key .. "' to be a table, got " .. type(v)) end
  return v --[[: { [integer]: unknown } ]]
end

--: (n: unknown, key: string) -> number
local function gi(n, key)
  local v = get(n, key)
  if type(v) ~= "number" then error("grammar_gen: expected field '" .. key .. "' to be a number, got " .. type(v)) end
  return v
end
M.gs, M.gb, M.gl, M.gi = gs, gb, gl, gi

-- ═══════════════════════ canonicalization ═══════════════════════

--: (a: unknown, b: unknown) -> boolean
local function target_eq(a, b)
  if a == nil or b == nil then return false end
  local a_tag, b_tag = gs(a, "tag"), gs(b, "tag")
  if a_tag ~= b_tag then return false end
  if a_tag == "name" then return gs(a, "name") == gs(b, "name") end
  if a_tag == "index" then
    local a_key, b_key = get(a, "key"), get(b, "key")
    if gb(a, "dot") ~= gb(b, "dot") then return false end
    if gs(a_key, "tag") == "string" and gs(b_key, "tag") == "string" then
      return gs(a_key, "value") == gs(b_key, "value") and target_eq(get(a, "obj"), get(b, "obj"))
    end
    return false
  end
  return false
end

-- Recognize `V and A or B` (optionally with `V` parenthesized/compound),
-- i.e. binop(or, binop(and, C, A), B). Returns (cond, then_expr, else_expr)
-- or nil if `expr` isn't this shape.
--: (expr: unknown) -> (unknown, unknown, unknown) | nil
local function match_ternary(expr)
  if gs(expr, "tag") ~= "binop" or gs(expr, "op") ~= "or" then return nil end
  local lhs = get(expr, "lhs")
  if gs(lhs, "tag") == "paren" then lhs = get(lhs, "expr") end
  if gs(lhs, "tag") ~= "binop" or gs(lhs, "op") ~= "and" then return nil end
  return get(lhs, "lhs"), get(lhs, "rhs"), get(expr, "rhs")
end

-- Recognize an `if C then <single-assign> else <single-assign> end`
-- statement where both branches assign to the same target. Returns
-- (cond, target, then_val, else_val) or nil.
--: (stat: unknown) -> (unknown, unknown, unknown, unknown) | nil
local function match_if_else_assign(stat)
  if gs(stat, "tag") ~= "if" then return nil end
  local orelse = get(stat, "orelse")
  if not orelse then return nil end
  local clauses = gl(stat, "clauses")
  if #clauses ~= 1 then return nil end
  local clause = clauses[1]
  local then_stats = gl(get(clause, "body"), "stats")
  local else_stats = gl(orelse, "stats")
  if #then_stats ~= 1 or #else_stats ~= 1 then return nil end
  local ts, es = then_stats[1], else_stats[1]
  if gs(ts, "tag") ~= "assign" or gs(es, "tag") ~= "assign" then return nil end
  local ts_targets, es_targets = gl(ts, "targets"), gl(es, "targets")
  local ts_values, es_values = gl(ts, "values"), gl(es, "values")
  if #ts_targets ~= 1 or #es_targets ~= 1 or #ts_values ~= 1 or #es_values ~= 1 then return nil end
  if not target_eq(ts_targets[1], es_targets[1]) then return nil end
  return get(clause, "cond"), ts_targets[1], ts_values[1], es_values[1]
end

-- Walk a block's statement list, replacing recognized patterns with a
-- `cond_assign` node in place, and recursing into nested blocks (function
-- bodies, if/while/for bodies) so the rewrite applies at every nesting
-- level, not just the top.
--: (block: unknown) -> nil
local function canonicalize_block(block)
  local stats = gl(block, "stats")
  for i, s in ipairs(stats) do
    local tag = gs(s, "tag")
    if tag == "local" and #gl(s, "names") == 1 and #gl(s, "values") == 1 then
      local cond, then_v, else_v = match_ternary(gl(s, "values")[1])
      if cond then
        stats[i] = {
          tag = "cond_assign", line = get(s, "line"), form = "ternary", is_local = true,
          target = { tag = "name", name = gl(s, "names")[1] },
          cond = cond, then_val = then_v, else_val = else_v,
        }
      end
    elseif tag == "if" then
      local cond, target, then_v, else_v = match_if_else_assign(s)
      if cond then
        stats[i] = {
          tag = "cond_assign", line = get(s, "line"), form = "if_else", is_local = false,
          target = target, cond = cond, then_val = then_v, else_val = else_v,
        }
      else
        for _, clause in ipairs(gl(s, "clauses")) do canonicalize_block(get(clause, "body")) end
        local orelse = get(s, "orelse")
        if orelse then canonicalize_block(orelse) end
      end
    elseif tag == "while" or tag == "do" or tag == "repeat" or tag == "fornum" or tag == "forin" then
      canonicalize_block(get(s, "body"))
    elseif tag == "localfunction" then
      canonicalize_block(get(get(s, "fn"), "body"))
    elseif tag == "assign" or tag == "local" then
      for _, v in ipairs(gl(s, "values")) do
        if gs(v, "tag") == "function" then canonicalize_block(get(v, "body")) end
      end
    end
  end
end
M.canonicalize_block = canonicalize_block

-- ═══════════════════════ fingerprinting ═══════════════════════

-- Coarse ("one level deep") shape of an expression: enough to distinguish
-- "a bare reference" from "a call" from "a literal" from "a binary op",
-- without recursing into operands. Used for cond_assign's then/else holes.
--: (e: unknown) -> string
local function coarse_shape(e)
  local tag = gs(e, "tag")
  if tag == "name" then return "NAME" end
  if tag == "string" then return "STR" end
  if tag == "number" then return "NUM" end
  if tag == "nil" or tag == "true" or tag == "false" then return "LIT" end
  if tag == "call" then return "CALL(" .. #gl(e, "args") .. ")" end
  if tag == "methodcall" then return "METHODCALL(" .. #gl(e, "args") .. ")" end
  if tag == "index" then return "INDEX" end
  if tag == "binop" then return "BINOP(" .. gs(e, "op") .. ")" end
  if tag == "unop" then return "UNOP(" .. gs(e, "op") .. ")" end
  if tag == "table" then return "TABLE(" .. #gl(e, "fields") .. ")" end
  if tag == "paren" then return "PAREN(" .. coarse_shape(get(e, "expr")) .. ")" end
  return tag
end
M.coarse_shape = coarse_shape

-- Full recursive structural fingerprint of an expression: identifiers and
-- literal values collapse to placeholders, but tags/operators/arity are
-- preserved at every depth. Two expressions with the same fingerprint have
-- the same shape all the way down, modulo names and literal content.
--: (e: unknown) -> string
local function fp_expr(e)
  if type(e) ~= "table" then return tostring(e) end
  local tag = gs(e, "tag")
  if tag == "name" then return "ID"
  elseif tag == "string" then return "STR"
  elseif tag == "number" then return "NUM"
  elseif tag == "nil" then return "NIL"
  elseif tag == "true" or tag == "false" then return "BOOL"
  elseif tag == "vararg" then return "VARARG"
  elseif tag == "paren" then return "(" .. fp_expr(get(e, "expr")) .. ")"
  elseif tag == "index" then
    local suffix = gb(e, "dot") and ".FLD" or ("[" .. fp_expr(get(e, "key")) .. "]")
    return "IDX[" .. fp_expr(get(e, "obj")) .. suffix .. "]"
  elseif tag == "call" then
    local parts = {}
    for _, a in ipairs(gl(e, "args")) do parts[#parts + 1] = fp_expr(a) end
    return "CALL(" .. fp_expr(get(e, "fn")) .. ";" .. table.concat(parts, ",") .. ")"
  elseif tag == "methodcall" then
    local parts = {}
    for _, a in ipairs(gl(e, "args")) do parts[#parts + 1] = fp_expr(a) end
    return "MCALL(" .. fp_expr(get(e, "obj")) .. ";" .. table.concat(parts, ",") .. ")"
  elseif tag == "binop" then return "BIN_" .. gs(e, "op") .. "(" .. fp_expr(get(e, "lhs")) .. "," .. fp_expr(get(e, "rhs")) .. ")"
  elseif tag == "unop" then return "UN_" .. gs(e, "op") .. "(" .. fp_expr(get(e, "expr")) .. ")"
  elseif tag == "table" then
    local parts = {}
    for _, f in ipairs(gl(e, "fields")) do parts[#parts + 1] = gs(f, "kind") .. ":" .. fp_expr(get(f, "value")) end
    return "TBL(" .. table.concat(parts, ",") .. ")"
  elseif tag == "function" then return "FN(" .. #gl(e, "params") .. (gb(e, "vararg") and "+" or "") .. ")"
  else return tag
  end
end
M.fp_expr = fp_expr

-- Fingerprint one statement (after canonicalize_block has already run over
-- its enclosing block). Returns nil for statement kinds with no useful
-- shape to compare (labels, breaks — too small to be meaningfully "a
-- production" on their own).
--: (s: unknown) -> string | nil
local function fp_stat(s)
  local tag = gs(s, "tag")
  if tag == "cond_assign" then
    -- Deliberately excludes s.cond's shape AND s.is_local/s.form (whether
    -- the binding is a fresh `local x = ternary` or an assignment to an
    -- already-declared local via if/else) — see file header. `is_local`/
    -- `form` are the syntactic-alternative axis this slot's instances
    -- split on (if_else vs. ternary); they belong in the hole tuple
    -- (canon.holes, below), not the clustering key, or the two forms would
    -- never collide into one slot — which is exactly the miss this tool
    -- exists to avoid.
    return "COND_ASSIGN(" .. coarse_shape(get(s, "then_val")) .. ";" .. coarse_shape(get(s, "else_val")) .. ")"
  elseif tag == "local" then
    local parts = {}
    for _, v in ipairs(gl(s, "values")) do parts[#parts + 1] = fp_expr(v) end
    return "LOCAL(" .. #gl(s, "names") .. ";" .. table.concat(parts, ",") .. ")"
  elseif tag == "assign" then
    local tparts, vparts = {}, {}
    for _, t in ipairs(gl(s, "targets")) do tparts[#tparts + 1] = fp_expr(t) end
    for _, v in ipairs(gl(s, "values")) do vparts[#vparts + 1] = fp_expr(v) end
    return "ASSIGN(" .. table.concat(tparts, ",") .. ";" .. table.concat(vparts, ",") .. ")"
  elseif tag == "if" then
    local parts = {}
    for _, c in ipairs(gl(s, "clauses")) do
      parts[#parts + 1] = fp_expr(get(c, "cond")) .. ":" .. #gl(get(c, "body"), "stats")
    end
    local orelse = get(s, "orelse")
    return "IF(" .. table.concat(parts, "|") .. (orelse and (";ELSE:" .. #gl(orelse, "stats")) or "") .. ")"
  elseif tag == "exprstat" then return "EXPRSTAT(" .. fp_expr(get(s, "expr")) .. ")"
  elseif tag == "return" then
    local parts = {}
    for _, v in ipairs(gl(s, "exprs")) do parts[#parts + 1] = fp_expr(v) end
    return "RETURN(" .. table.concat(parts, ",") .. ")"
  elseif tag == "localfunction" then return "LOCALFUNCTION(" .. #gl(get(s, "fn"), "params") .. ")"
  elseif tag == "while" then return "WHILE(" .. fp_expr(get(s, "cond")) .. ";" .. #gl(get(s, "body"), "stats") .. ")"
  elseif tag == "fornum" then return "FORNUM(" .. #gl(get(s, "body"), "stats") .. ")"
  elseif tag == "forin" then return "FORIN(" .. #gl(s, "names") .. ";" .. #gl(get(s, "body"), "stats") .. ")"
  elseif tag == "repeat" then return "REPEAT(" .. #gl(get(s, "body"), "stats") .. ")"
  elseif tag == "do" then return "DO(" .. #gl(get(s, "body"), "stats") .. ")"
  else return nil
  end
end
M.fp_stat = fp_stat

-- The "hole values" for a statement: the concrete content that fingerprint
-- abstracted away, in a fixed order, so that instances sharing a
-- fingerprint can be compared for whether they're all IDENTICAL (a plain
-- rule, zero variance) or DIFFER (a slot with distinct alternatives).
-- Rendered as a plain string per hole, not fully structural, since these
-- are for human-facing reporting and equality comparison, not further
-- fingerprinting.
--: (e: unknown) -> string
local function render(e)
  if e == nil then return "<nil>" end
  if type(e) ~= "table" then return tostring(e) end
  local tag = gs(e, "tag")
  if tag == "name" then return gs(e, "name")
  elseif tag == "string" then return "\"" .. gs(e, "value") .. "\""
  elseif tag == "number" then return gs(e, "value")
  elseif tag == "nil" then return "nil"
  elseif tag == "true" then return "true"
  elseif tag == "false" then return "false"
  elseif tag == "vararg" then return "..."
  elseif tag == "paren" then return "(" .. render(get(e, "expr")) .. ")"
  elseif tag == "index" then
    if gb(e, "dot") then
      local key_str = render(get(e, "key")):gsub("\"", "")
      return render(get(e, "obj")) .. "." .. key_str
    else return render(get(e, "obj")) .. "[" .. render(get(e, "key")) .. "]" end
  elseif tag == "call" then
    local parts = {}
    for _, a in ipairs(gl(e, "args")) do parts[#parts + 1] = render(a) end
    return render(get(e, "fn")) .. "(" .. table.concat(parts, ", ") .. ")"
  elseif tag == "methodcall" then
    local parts = {}
    for _, a in ipairs(gl(e, "args")) do parts[#parts + 1] = render(a) end
    return render(get(e, "obj")) .. ":" .. gs(e, "method") .. "(" .. table.concat(parts, ", ") .. ")"
  elseif tag == "binop" then return render(get(e, "lhs")) .. " " .. gs(e, "op") .. " " .. render(get(e, "rhs"))
  elseif tag == "unop" then return gs(e, "op") .. " " .. render(get(e, "expr"))
  elseif tag == "table" then return "{...}"
  elseif tag == "function" then return "function(...)"
  else return tag
  end
end
M.render = render

--: (s: unknown) -> { [integer]: string }
local function holes(s)
  local tag = gs(s, "tag")
  if tag == "cond_assign" then
    return { gs(s, "form"), render(get(s, "target")), render(get(s, "cond")), render(get(s, "then_val")), render(get(s, "else_val")) }
  elseif tag == "local" then
    local h = {}
    for _, v in ipairs(gl(s, "values")) do h[#h + 1] = render(v) end
    return h
  elseif tag == "assign" then
    local h = {}
    for _, t in ipairs(gl(s, "targets")) do h[#h + 1] = render(t) end
    for _, v in ipairs(gl(s, "values")) do h[#h + 1] = render(v) end
    return h
  elseif tag == "if" then
    local h = {}
    for _, c in ipairs(gl(s, "clauses")) do h[#h + 1] = render(get(c, "cond")) end
    return h
  elseif tag == "exprstat" then return { render(get(s, "expr")) }
  elseif tag == "return" then
    local h = {}
    for _, v in ipairs(gl(s, "exprs")) do h[#h + 1] = render(v) end
    return h
  else return {}
  end
end
M.holes = holes

return M
