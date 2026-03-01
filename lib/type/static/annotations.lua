-- lib/type/static/annotations.lua
-- Parse --: / --:: / --[[as]] / --[[:]] annotations from source text.
-- Returns a map of { [line_number] -> annotation }.

local types = require("lib.type.static.types")

local M = {}

---------------------------------------------------------------------------
-- Type expression parser (recursive descent)
---------------------------------------------------------------------------

local Parser = {}
Parser.__index = Parser

function Parser.new(src, pos)
  return setmetatable({ src = src, pos = pos or 1, len = #src }, Parser)
end

function Parser:skip_ws()
  local s, e = self.src:find("^%s+", self.pos)
  if s then self.pos = e + 1 end
end

function Parser:peek()
  self:skip_ws()
  return self.src:sub(self.pos, self.pos)
end

function Parser:peek_word()
  self:skip_ws()
  local _, e, w = self.src:find("^([%a_][%w_]*)", self.pos)
  return w, e
end

function Parser:match_char(ch)
  self:skip_ws()
  if self.src:sub(self.pos, self.pos) == ch then
    self.pos = self.pos + 1
    return true
  end
  return false
end

function Parser:expect_char(ch)
  if not self:match_char(ch) then
    error("expected '" .. ch .. "' at position " .. self.pos .. " in: " .. self.src)
  end
end

function Parser:match_str(s)
  self:skip_ws()
  if self.src:sub(self.pos, self.pos + #s - 1) == s then
    self.pos = self.pos + #s
    return true
  end
  return false
end

function Parser:at_end()
  self:skip_ws()
  return self.pos > self.len
end

-- type = union
function Parser:parse_type()
  return self:parse_union()
end

-- union = intersection ("|" intersection)*
function Parser:parse_union()
  local t = self:parse_intersection()
  local parts
  while self:match_char("|") do
    if not parts then parts = { t } end
    parts[#parts + 1] = self:parse_intersection()
  end
  if parts then return types.union(parts) end
  return t
end

-- intersection = suffix ("&" suffix)*
function Parser:parse_intersection()
  local t = self:parse_suffix()
  local parts
  while self:match_char("&") do
    if not parts then parts = { t } end
    parts[#parts + 1] = self:parse_suffix()
  end
  if parts then return types.intersection(parts) end
  return t
end

-- suffix = primary "?"* "[]"*
function Parser:parse_suffix()
  local t = self:parse_primary()
  while true do
    if self:match_char("?") then
      t = types.optional(t)
    elseif self:match_str("[]") then
      t = types.array(t)
    else
      break
    end
  end
  return t
end

-- primary = "nil" | "boolean" | "number" | "integer" | "string"
--         | "any" | "never" | "true" | "false"
--         | literal_string | literal_number
--         | "(" ... ")" "->" return_type   (function type)
--         | "(" type ")"                   (grouping)
--         | "{" field_list "}"             (record/dict)
--         | "[" type "]"                   (array)
--         | "..." type                     (vararg -- only in param context)
--         | name ("<" type_list ">")?       (named/generic)
function Parser:parse_primary()
  self:skip_ws()
  local ch = self.src:sub(self.pos, self.pos)

  -- String literal
  if ch == '"' or ch == "'" then
    return self:parse_string_literal()
  end

  -- Number literal
  if ch:match("[%d]") or (ch == "-" and self.src:sub(self.pos + 1, self.pos + 1):match("[%d]")) then
    return self:parse_number_literal()
  end

  -- Array type [T]
  if ch == "[" then
    self.pos = self.pos + 1
    local elem = self:parse_type()
    self:expect_char("]")
    return types.array(elem)
  end

  -- Record/dict type { ... }
  if ch == "{" then
    return self:parse_table_type()
  end

  -- Parenthesized: either grouping or function type
  if ch == "(" then
    return self:parse_paren_or_func()
  end

  -- Vararg
  if self.src:sub(self.pos, self.pos + 2) == "..." then
    self.pos = self.pos + 3
    local t = self:parse_type()
    return { tag = "vararg_marker", type = t }
  end

  -- Forall generic function: <T, U>(params) -> ret
  if ch == "<" then
    return self:parse_forall()
  end

  -- $Intrinsic
  if ch == "$" then
    self.pos = self.pos + 1
    local iname, iend = self:peek_word()
    if not iname then
      error("expected intrinsic name after '$' at position " .. self.pos)
    end
    self.pos = iend + 1
    -- Intrinsic may have type args: $Keys<T>
    if self:match_char("<") then
      local args = { self:parse_type() }
      while self:match_char(",") do
        args[#args + 1] = self:parse_type()
      end
      self:expect_char(">")
      return types.type_call(types.intrinsic(iname), args)
    end
    return types.intrinsic(iname)
  end

  -- Keywords and names
  local word, word_end = self:peek_word()
  if not word then
    error("unexpected character '" .. ch .. "' at position " .. self.pos .. " in: " .. self.src)
  end

  self.pos = word_end + 1

  -- Built-in type names
  if word == "nil" then return types.NIL() end
  if word == "boolean" then return types.BOOLEAN() end
  if word == "number" then return types.NUMBER() end
  if word == "integer" then return types.INTEGER() end
  if word == "string" then return types.STRING() end
  if word == "any" then return types.ANY() end
  if word == "never" then return types.NEVER() end
  if word == "true" then return types.literal("boolean", true) end
  if word == "false" then return types.literal("boolean", false) end

  -- match type: match T { pattern => result, ... }
  if word == "match" then
    return self:parse_match_type()
  end

  -- Named type, possibly generic: Name<T, U>
  if self:match_char("<") then
    local args = { self:parse_type() }
    while self:match_char(",") do
      args[#args + 1] = self:parse_type()
    end
    self:expect_char(">")
    -- Check for type call: Name<T>(Args) — F(Args) syntax
    if self:match_char("(") then
      local call_args = {}
      if not self:match_char(")") then
        call_args[1] = self:parse_type()
        while self:match_char(",") do
          call_args[#call_args + 1] = self:parse_type()
        end
        self:expect_char(")")
      end
      return types.type_call({ tag = "named", name = word, args = args }, call_args)
    end
    return { tag = "named", name = word, args = args }
  end

  -- Type call without generics: F(Args) — disambiguate from function type by absence of ->
  if self:peek() == "(" then
    local save = self.pos
    self:expect_char("(")
    if self:match_char(")") then
      -- F() — type call with no args
      if not self:match_str("->") then
        return types.type_call({ tag = "named", name = word, args = {} }, {})
      end
      -- F() -> R — that's a function type, backtrack
      self.pos = save
    else
      -- Try parsing as type call: F(T, U)
      local first = self:parse_type()
      if self:match_char(",") then
        local call_args = { first }
        repeat
          call_args[#call_args + 1] = self:parse_type()
        until not self:match_char(",")
        if self:match_char(")") then
          if not self:match_str("->") then
            return types.type_call({ tag = "named", name = word, args = {} }, call_args)
          end
          -- Has -> so it's a function, backtrack
          self.pos = save
        else
          self.pos = save
        end
      elseif self:match_char(")") then
        if not self:match_str("->") then
          return types.type_call({ tag = "named", name = word, args = {} }, { first })
        end
        -- Has -> so it's a function, backtrack
        self.pos = save
      else
        self.pos = save
      end
    end
  end

  return { tag = "named", name = word, args = {} }
end

function Parser:parse_forall()
  self:expect_char("<")
  local type_params = {}
  repeat
    local name, ne = self:peek_word()
    if not name then
      error("expected type parameter name in forall at position " .. self.pos)
    end
    self.pos = ne + 1
    local constraint = nil
    if self:match_char(":") then
      constraint = self:parse_type()
    end
    type_params[#type_params + 1] = { name = name, constraint = constraint }
  until not self:match_char(",")
  self:expect_char(">")
  local body = self:parse_type()
  return { tag = "forall", type_params = type_params, body = body }
end

function Parser:parse_match_type()
  local param = self:parse_type()
  self:expect_char("{")
  local arms = {}
  if not self:match_char("}") then
    repeat
      local pattern = self:parse_type()
      self:skip_ws()
      if not self:match_str("=>") then
        error("expected '=>' in match type arm at position " .. self.pos)
      end
      local result = self:parse_type()
      arms[#arms + 1] = { pattern = pattern, result = result }
    until not self:match_char(",")
    self:expect_char("}")
  end
  return types.match_type(param, arms)
end

function Parser:parse_string_literal()
  local quote = self.src:sub(self.pos, self.pos)
  self.pos = self.pos + 1
  local start = self.pos
  while self.pos <= self.len do
    local c = self.src:sub(self.pos, self.pos)
    if c == quote then
      local val = self.src:sub(start, self.pos - 1)
      self.pos = self.pos + 1
      return types.literal("string", val)
    end
    if c == "\\" then self.pos = self.pos + 1 end
    self.pos = self.pos + 1
  end
  error("unterminated string literal in type expression")
end

function Parser:parse_number_literal()
  local s, e, num = self.src:find("^(%-?%d+%.?%d*)", self.pos)
  if not s then error("expected number literal") end
  self.pos = e + 1
  return types.literal("number", tonumber(num))
end

function Parser:parse_table_type()
  self:expect_char("{")
  local fields = {}
  local indexers = {}
  local meta = {}
  local positional = {}
  local has_named = false

  if self:match_char("}") then
    return types.table(fields, indexers, nil, meta)
  end

  repeat
    self:skip_ws()
    -- Spread: ...Type
    if self.src:sub(self.pos, self.pos + 2) == "..." then
      self.pos = self.pos + 3
      local inner = self:parse_type()
      positional[#positional + 1] = types.spread(inner)
    -- Indexer: [type]: type
    elseif self:peek() == "[" then
      self.pos = self.pos + 1
      local key = self:parse_type()
      self:expect_char("]")
      self:expect_char(":")
      local value = self:parse_type()
      indexers[#indexers + 1] = { key = key, value = value }
      has_named = true
    -- Meta field: #name: type
    elseif self:peek() == "#" then
      self.pos = self.pos + 1
      local mname, mend = self:peek_word()
      if not mname then
        error("expected metamethod name after '#' at position " .. self.pos)
      end
      self.pos = mend + 1
      self:expect_char(":")
      local mty = self:parse_type()
      meta[mname] = { type = mty, optional = false }
      has_named = true
    else
      -- Could be "name?: type" (field) or just a type (positional/tuple element).
      -- Disambiguate: save position, try parsing as "word" then check for ":" or "?:".
      local save = self.pos
      local word, word_end = self:peek_word()
      if word then
        -- Check if this is a field: word followed by ":" or "?:"
        local after = word_end + 1
        local _, ws_end = self.src:find("^%s*", after)
        if ws_end then after = ws_end + 1 end
        local next_ch = self.src:sub(after, after)
        if next_ch == ":" then
          -- Named field: name: type
          self.pos = after + 1
          local ty = self:parse_type()
          fields[word] = { type = ty, optional = false }
          has_named = true
        elseif next_ch == "?" then
          -- Check for "?:"
          local after2 = after + 1
          local _, ws2 = self.src:find("^%s*", after2)
          if ws2 then after2 = ws2 + 1 end
          if self.src:sub(after2, after2) == ":" then
            -- Optional field: name?: type
            self.pos = after2 + 1
            local ty = self:parse_type()
            fields[word] = { type = ty, optional = true }
            has_named = true
          else
            -- Just a type starting with a word
            self.pos = save
            positional[#positional + 1] = self:parse_type()
          end
        else
          -- Positional type element
          self.pos = save
          positional[#positional + 1] = self:parse_type()
        end
      else
        -- Non-word type (e.g. string literal, number, parenthesized)
        positional[#positional + 1] = self:parse_type()
      end
    end
  until not self:match_char(",")

  self:expect_char("}")

  -- If we have positional elements and no named fields/indexers, it's a tuple
  if #positional > 0 and not has_named then
    -- Check if any element is a spread — if so, we need to merge
    local has_spread = false
    for i = 1, #positional do
      if positional[i].tag == "spread" then
        has_spread = true
        break
      end
    end
    if has_spread then
      -- Return a table with spread markers for later expansion
      return types.tuple(positional)
    end
    return types.tuple(positional)
  end

  -- Mixed positional + named: positional entries become spread overlay
  if #positional > 0 and has_named then
    -- Spread syntax: { ...Base, name: type } means merge base fields with overrides
    -- For now, just return the table with fields/indexers (spreads resolved later)
    return types.table(fields, indexers, nil, meta)
  end

  return types.table(fields, indexers, nil, meta)
end

-- Parse "(..." which could be a function type or grouping
function Parser:parse_paren_or_func()
  self:expect_char("(")

  -- Empty parens: () -> ...
  if self:match_char(")") then
    if self:match_str("->") then
      local ret = self:parse_return_type()
      return types.func({}, ret)
    end
    -- () by itself = unit/void, treat as nil
    return types.NIL()
  end

  -- Try to determine if this is a function type or grouping.
  -- Heuristic: if we see "name:" pattern (named param) or if after parsing
  -- the full contents we see "->", it's a function type.
  -- Save position for backtracking.
  local save_pos = self.pos

  -- Try parsing as param list
  local params, vararg = self:try_parse_params()
  if params and self:match_char(")") and self:match_str("->") then
    local ret = self:parse_return_type()
    return types.func(params, ret, vararg)
  end

  -- Backtrack and parse as grouping or function with positional params
  self.pos = save_pos
  local inner = self:parse_type()

  -- Check for comma (multi-param function)
  if self:match_char(",") then
    local param_types = { inner }
    local va = nil
    repeat
      self:skip_ws()
      if self.src:sub(self.pos, self.pos + 2) == "..." then
        self.pos = self.pos + 3
        va = self:parse_type()
        break
      end
      param_types[#param_types + 1] = self:parse_type()
    until not self:match_char(",")
    self:expect_char(")")
    if self:match_str("->") then
      local ret = self:parse_return_type()
      return types.func(param_types, ret, va)
    end
    -- Multi-value in parens without -> : treat as tuple? Error for now.
    error("unexpected tuple without ->")
  end

  self:expect_char(")")

  -- After closing paren, check for ->
  if self:match_str("->") then
    local ret = self:parse_return_type()
    return types.func({ inner }, ret)
  end

  -- Just grouping
  return inner
end

function Parser:try_parse_params()
  local params = {}
  local vararg = nil

  -- Check for vararg
  if self.src:sub(self.pos, self.pos + 2) == "..." then
    self.pos = self.pos + 3
    vararg = self:parse_type()
    return params, vararg
  end

  -- Try to parse first param
  local p = self:try_parse_param()
  if not p then return nil end
  params[1] = p

  while self:match_char(",") do
    self:skip_ws()
    if self.src:sub(self.pos, self.pos + 2) == "..." then
      self.pos = self.pos + 3
      vararg = self:parse_type()
      return params, vararg
    end
    p = self:try_parse_param()
    if not p then return nil end
    params[#params + 1] = p
  end

  return params, vararg
end

function Parser:try_parse_param()
  local save = self.pos
  -- Try "name: type" form
  local word, word_end = self:peek_word()
  if word then
    local after_word = word_end + 1
    -- Skip whitespace after word
    local _, ws_end = self.src:find("^%s*", after_word)
    if ws_end then after_word = ws_end + 1 end
    if self.src:sub(after_word, after_word) == ":" then
      self.pos = after_word + 1
      local ty = self:parse_type()
      return ty -- Named param: we just return the type
    end
  end
  -- Not named param, try bare type
  self.pos = save
  local ok, ty = pcall(function() return self:parse_type() end)
  if ok then return ty end
  self.pos = save
  return nil
end

function Parser:parse_return_type()
  self:skip_ws()
  if self:peek() == "(" then
    local save = self.pos
    self:expect_char("(")
    if self:match_char(")") then
      return {} -- () return = void
    end
    local first = self:parse_type()
    if self:match_char(",") then
      -- Multi-return
      local rets = { first }
      repeat
        rets[#rets + 1] = self:parse_type()
      until not self:match_char(",")
      self:expect_char(")")
      return rets
    end
    self:expect_char(")")
    -- Single type in parens -- could be grouping
    -- Check if there's more (suffix operators etc)
    return { first }
  end
  return { self:parse_type() }
end

---------------------------------------------------------------------------
-- Public API: parse a type expression string
---------------------------------------------------------------------------

function M.parse_type(src)
  local parser = Parser.new(src)
  local ty = parser:parse_type()
  return ty
end

-- Parse a comma-separated list of types (handles nested generics like Dict<string, number>).
function M.parse_type_list(src)
  local parser = Parser.new(src)
  local list = { parser:parse_type() }
  while parser:match_char(",") do
    list[#list + 1] = parser:parse_type()
  end
  return list
end

---------------------------------------------------------------------------
-- Extract annotations from source text
---------------------------------------------------------------------------

-- Find the position where an actual line comment starts (not inside a string).
-- Returns the position of the first `--` that is not inside quotes, or nil.
local function find_comment_start(line)
  local i = 1
  local len = #line
  while i <= len do
    local c = line:sub(i, i)
    if c == '"' or c == "'" then
      -- Skip string literal
      local quote = c
      i = i + 1
      while i <= len do
        local sc = line:sub(i, i)
        if sc == "\\" then
          i = i + 2 -- skip escaped char
        elseif sc == quote then
          i = i + 1
          break
        else
          i = i + 1
        end
      end
    elseif c == "[" then
      -- Check for long string [[ or [=*[
      local eq = line:match("^%[(=*)%[", i)
      if eq then
        -- Long string — won't close on this line typically, skip rest
        return nil
      end
      i = i + 1
    elseif c == "-" and line:sub(i + 1, i + 1) == "-" then
      return i
    else
      i = i + 1
    end
  end
  return nil
end

function M.extract(source)
  local annotations = {}
  local line_num = 0
  local in_long_string = false
  local long_string_close = nil
  -- Block annotation accumulator (for --[[:: and --[[ : multi-line forms).
  -- Use "" as the inactive sentinel to avoid nil-narrowing false positives.
  local block_ann_kind = ""  -- "" = inactive, "decl" | "signature" = accumulating
  local block_ann_start = 0
  local block_ann_lines = {}

  for line in (source .. "\n"):gmatch("([^\n]*)\n") do
    line_num = line_num + 1

    -- Track multi-line long strings
    if in_long_string then
      if line:find(long_string_close, 1, true) then
        in_long_string = false
        long_string_close = nil
      end
      goto continue
    end

    -- Accumulate lines inside a multi-line block annotation.
    -- Keep the nil resets OUTSIDE the narrowed `block_ann_kind ~= ""` block to
    -- avoid a false positive from narrowing + nil-assignment.
    local block_closed = false
    if block_ann_kind ~= "" then
      local close = line:find("]]", 1, true)
      if close then
        local piece = line:sub(1, close - 1):match("^%s*(.-)%s*$")
        if #piece > 0 then block_ann_lines[#block_ann_lines + 1] = piece end
        annotations[block_ann_start] = {
          kind = block_ann_kind,
          text = table.concat(block_ann_lines, " "),
        }
        block_closed = true
      else
        local trimmed = line:match("^%s*(.-)%s*$")
        if #trimmed > 0 then block_ann_lines[#block_ann_lines + 1] = trimmed end
      end
      if not block_closed then goto continue end
    end
    -- Reset outside the narrowed block (avoids assign-nil-to-narrowed false positive).
    if block_closed then
      block_ann_kind = ""
      block_ann_start = 0
      block_ann_lines = {}
      goto continue
    end

    -- Check for long string start on this line (outside comments)
    -- We handle this simply: if a [[ or [=[ appears before any comment, skip
    local comment_pos = find_comment_start(line)

    -- Check for long string opening before the comment
    local ls_start, ls_eq
    local search_end = comment_pos and (comment_pos - 1) or #line
    local ls_s, ls_e, eq_signs = line:find("%[(=*)%[", 1)
    if ls_s and ls_s <= search_end then
      -- Check this isn't inside a string literal (simplified: just check position)
      local close_pat = "]" .. eq_signs .. "]"
      if not line:find(close_pat, ls_e + 1, true) then
        in_long_string = true
        long_string_close = close_pat
        -- Still process annotations before the long string
      end
    end

    -- Block form --[[:: ... ]] (equivalent to --:: but allows multi-line).
    -- Must check before --[[ : to avoid ambiguity.
    local blk_decl = line:match("^%s*%-%-%[%[::(.*)$")
    if blk_decl then
      local close = blk_decl:find("]]", 1, true)
      if close then
        local text = blk_decl:sub(1, close - 1):match("^%s*(.-)%s*$")
        if #text > 0 then
          annotations[line_num] = { kind = "decl", text = text }
        end
      else
        block_ann_kind = "decl"
        block_ann_start = line_num
        local trimmed = blk_decl:match("^%s*(.-)%s*$")
        block_ann_lines = {}
        if #trimmed > 0 then block_ann_lines[1] = trimmed end
      end
      goto continue
    end

    -- Block form --[[ : ... ]] (equivalent to --: but allows multi-line).
    local blk_sig = line:match("^%s*%-%-%[%[:(.*)$")
    if blk_sig then
      local close = blk_sig:find("]]", 1, true)
      if close then
        local text = blk_sig:sub(1, close - 1):match("^%s*(.-)%s*$")
        if #text > 0 then
          annotations[line_num] = { kind = "signature", text = text }
        end
      else
        block_ann_kind = "signature"
        block_ann_start = line_num
        local trimmed = blk_sig:match("^%s*(.-)%s*$")
        block_ann_lines = {}
        if #trimmed > 0 then block_ann_lines[1] = trimmed end
      end
      goto continue
    end

    -- --:: type declaration: entire line is a comment starting with --::
    local decl = line:match("^%s*%-%-::(.+)$")
    if decl then
      annotations[line_num] = { kind = "decl", text = decl }
      goto continue
    end

    -- --: type signature on its own line (preceding line form)
    local sig = line:match("^%s*%-%-:(.+)$")
    if sig then
      annotations[line_num] = { kind = "signature", text = sig }
      goto continue
    end

    -- End-of-line --: annotation (must be in actual comment, not in string)
    if comment_pos then
      local comment_text = line:sub(comment_pos)
      -- Check for --: annotation
      local eol_ann = comment_text:match("^%-%-:%s*(.+)%s*$")
      if eol_ann then
        annotations[line_num] = { kind = "eol_type", text = eol_ann }
        goto continue
      end
    end

    -- Inline block comment annotations: --[[:<T>]] / --[[: T]] / --[[as T]] / --[[as! T]]
    -- --[[:<>]] must be checked before --[[: to avoid ambiguous prefix match.
    if comment_pos then
      local rest = line:sub(comment_pos)
      -- Type application: --[[:<T, U, _>]] (explicit type args at call site)
      -- Use greedy (.+) so nested generics like Dict<string, number> work.
      local targs_text = rest:match("^%-%-%%[%%[:<(.+)>%]%]")
      if targs_text then
        annotations[line_num] = { kind = "type_args", text = targs_text }
        goto continue
      end
      local ty_text = rest:match("^%-%-%%[%%[:%s*(.-)%]%]")
      if ty_text then
        annotations[line_num] = { kind = "inline", text = ty_text, col = comment_pos }
        goto continue
      end
      ty_text = rest:match("^%-%-%%[%%[as!%s+(.-)%]%]")
      if ty_text then
        annotations[line_num] = { kind = "force_cast", text = ty_text, col = comment_pos }
        goto continue
      end
      ty_text = rest:match("^%-%-%%[%%[as%s+(.-)%]%]")
      if ty_text then
        annotations[line_num] = { kind = "cast", text = ty_text, col = comment_pos }
        goto continue
      end
    end

    ::continue::
  end

  return annotations
end

---------------------------------------------------------------------------
-- Build annotation map: resolve preceding-line signatures to target lines
---------------------------------------------------------------------------

function M.build_map(source)
  local raw = M.extract(source)
  local map = {}

  -- Collect multi-line --:: declarations
  local decl_acc = nil
  local decl_start = nil
  local lines = {}
  local line_num = 0
  for line in (source .. "\n"):gmatch("([^\n]*)\n") do
    line_num = line_num + 1
    lines[line_num] = line
  end

  -- First pass: merge consecutive --:: continuation lines
  -- A --:: line that contains "=" starts a new declaration.
  -- Continuation lines (no "=") are appended to the previous declaration.
  local merged_decls = {}
  local i = 1
  while i <= line_num do
    local ann = raw[i]
    if ann and ann.kind == "decl" then
      local start = i
      local text = ann.text
      local j = i + 1
      while j <= line_num and raw[j] and raw[j].kind == "decl"
        and not raw[j].text:match("%s*[%a_][%w_]*%s*=") do
        text = text .. " " .. raw[j].text
        j = j + 1
      end
      merged_decls[start] = text
      i = j
    else
      i = i + 1
    end
  end

  -- Parse type declarations
  for ln, text in pairs(merged_decls) do
    -- Check for nominal type keywords: newtype/opaque
    local nominal_kind, nominal_rest = text:match("^%s*(newtype)%s+(.+)$")
    if not nominal_kind then
      nominal_kind, nominal_rest = text:match("^%s*(opaque)%s+(.+)$")
    end

    local decl_text = nominal_kind and nominal_rest or text

    -- Parse: Name<T, U> = type
    local name, params, rest = decl_text:match("^%s*([%a_][%w_]*)%s*<(.-)>%s*=%s*(.+)%s*$")
    if not name then
      name, rest = decl_text:match("^%s*([%a_][%w_]*)%s*=%s*(.+)%s*$")
    end
    if name and rest then
      -- Check for "= intrinsic" declaration
      if rest:match("^%s*intrinsic%s*$") then
        local parsed_params
        if params then
          parsed_params = {}
          for param in params:gmatch("[^,]+") do
            param = param:match("^%s*(.-)%s*$")
            parsed_params[#parsed_params + 1] = { name = param }
          end
        end
        map[ln] = {
          kind = "type_decl",
          name = name,
          type = types.intrinsic(name),
          params = parsed_params,
          is_intrinsic = true,
          nominal = nominal_kind or nil,
        }
        goto next_decl
      end
      local ok, ty = pcall(M.parse_type, rest)
      if ok then
        -- Parse params string into structured list: { { name = "T", constraint = ty? }, ... }
        local parsed_params
        if params then
          parsed_params = {}
          for param in params:gmatch("[^,]+") do
            param = param:match("^%s*(.-)%s*$") -- trim
            local pname, constraint_str = param:match("^([%a_][%w_]*)%s*:%s*(.+)$")
            if pname then
              local cok, cty = pcall(M.parse_type, constraint_str)
              parsed_params[#parsed_params + 1] = { name = pname, constraint = cok and cty or nil }
            else
              parsed_params[#parsed_params + 1] = { name = param }
            end
          end
        end
        map[ln] = {
          kind = "type_decl",
          name = name,
          type = ty,
          params = parsed_params,
          nominal = nominal_kind or nil,
        }
      end
    end
    ::next_decl::
  end

  -- Second pass: resolve signatures and eol annotations
  local pending_sig = nil
  local pending_sig_line = nil
  for ln = 1, line_num do
    local ann = raw[ln]
    if ann then
      if ann.kind == "signature" then
        local text = ann.text:match("^%s*(.-)%s*$")
        -- declare directive: --: declare name: type
        local decl_name, decl_rest = text:match("^declare%s+([%a_][%w_]*)%s*:%s*(.+)$")
        if decl_name then
          local ok, ty = pcall(M.parse_type, decl_rest)
          if ok then map[ln] = { kind = "value_decl", name = decl_name, type = ty } end
        else
          -- extend directive: --: extend name: { ... }
          local ext_name, ext_rest = text:match("^extend%s+([%a_][%w_]*)%s*:%s*(.+)$")
          if not ext_name then
            -- extend without colon: extend name { ... }
            ext_name, ext_rest = text:match("^extend%s+([%a_][%w_]*)%s*(%b{}.*)$")
          end
          if ext_name then
            local ok, ty = pcall(M.parse_type, ext_rest)
            if ok then map[ln] = { kind = "extend_decl", name = ext_name, type = ty } end
          else
            -- Regular signature: attach to next code line
            pending_sig = text
            pending_sig_line = ln
          end
        end
      elseif ann.kind == "eol_type" then
        local ok, ty = pcall(M.parse_type, ann.text)
        if ok then
          map[ln] = { kind = "type_annotation", type = ty }
        end
      elseif ann.kind == "cast" then
        local ok, ty = pcall(M.parse_type, ann.text)
        if ok then
          map[ln] = { kind = "cast", type = ty, col = ann.col }
        end
      elseif ann.kind == "force_cast" then
        local ok, ty = pcall(M.parse_type, ann.text)
        if ok then
          map[ln] = { kind = "force_cast", type = ty, col = ann.col }
        end
      elseif ann.kind == "type_args" then
        -- Call-site explicit type args: --[[:<T, U, _>]]
        -- _ is a wildcard meaning "infer this param". Other names are resolved at call site.
        local ok, type_list = pcall(M.parse_type_list, ann.text)
        if ok then
          map[ln] = { kind = "type_args", types = type_list }
        end
      end
    else
      -- Non-annotation line: attach pending signature
      if pending_sig then
        local ok, ty = pcall(M.parse_type, pending_sig)
        if ok then
          map[ln] = { kind = "type_annotation", type = ty, from_line = pending_sig_line }
        end
        pending_sig = nil
        pending_sig_line = nil
      end
    end
  end

  return map
end

return M
