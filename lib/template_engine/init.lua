-- lib/template_engine/init.lua
-- Jinja2-inspired template engine with inheritance, filters, macros, and blocks.
if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

--:: TextToken = { type: "text", value: string, raw: string | nil, strip_after: boolean | nil }
--:: ExprToken = { type: "expr", value: string, raw: string | nil }
--:: TagToken = { type: "tag", value: string, raw: string, strip_after: boolean }
--:: CommentToken = { type: "comment", value: string, raw: string | nil }
--:: Token = TextToken | ExprToken | TagToken | CommentToken
--:: ASTNode = { type: string, ... }

-- ---------------------------------------------------------------------------
-- HTML escape
-- ---------------------------------------------------------------------------
local escape_map = { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;",
                     ['"'] = "&quot;", ["'"] = "&#39;" }
local function html_escape(s)
  return (tostring(s):gsub('[&<>"\']', escape_map))
end

-- ---------------------------------------------------------------------------
-- Lexer
-- ---------------------------------------------------------------------------
-- Token types: "text", "expr", "tag", "comment"
-- Each token: { type, value, raw }  (raw = original source slice including delimiters)

--: (src: string) -> ({ [integer]: Token } | nil, string | nil)
local function lex(src)
  local tokens = {} --: { [integer]: Token }
  local pos = 1
  local len = #src

  while pos <= len do
    -- Find next delimiter
    local s_expr_raw = src:find("{{",  pos, true)
    local s_tag_raw  = src:find("{%",  pos, true)
    local s_com_raw  = src:find("{#",  pos, true)
    local s_expr = s_expr_raw --: integer | nil
    local s_tag  = s_tag_raw  --: integer | nil
    local s_com  = s_com_raw  --: integer | nil

    -- Pick the earliest delimiter (ipairs stops at nil, so compare manually)
    local earliest = nil --: integer | nil
    if s_expr then if not earliest or (s_expr --[[:! integer]]) < (earliest --[[:! integer]]) then earliest = s_expr end end
    if s_tag  then if not earliest or (s_tag  --[[:! integer]]) < (earliest --[[:! integer]]) then earliest = s_tag  end end
    if s_com  then if not earliest or (s_com  --[[:! integer]]) < (earliest --[[:! integer]]) then earliest = s_com  end end

    if not earliest then
      -- Rest is plain text
      tokens[#tokens + 1] = { type = "text", value = src:sub(pos), raw = nil, strip_after = nil }
      break
    end

    local earliest_ = earliest --[[:! integer]]

    -- Text before delimiter
    if earliest_ > pos then
      tokens[#tokens + 1] = { type = "text", value = src:sub(pos, earliest_ - 1), raw = nil, strip_after = nil }
    end

    if s_expr and earliest_ == s_expr and (not s_tag or (s_expr --[[:! integer]]) <= (s_tag --[[:! integer]])) and (not s_com or (s_expr --[[:! integer]]) <= (s_com --[[:! integer]])) then
      -- Expression {{ ... }}
      local e_raw = src:find("}}", earliest_ + 2, true)
      if not e_raw then return nil, "unclosed {{ at position " .. earliest_ end
      local e = e_raw --[[:! integer]]
      local inner = src:sub(earliest_ + 2, e - 1)
      tokens[#tokens + 1] = { type = "expr", value = inner, raw = src:sub(earliest_, e + 1), strip_after = nil }
      pos = e + 2
    elseif s_tag and earliest_ == s_tag and (not s_com or (s_tag --[[:! integer]]) <= (s_com --[[:! integer]])) then
      -- Tag {% ... %}
      local e_raw = src:find("%}", earliest_ + 2, true)
      if not e_raw then return nil, "unclosed {% at position " .. earliest_ end
      local e = e_raw --[[:! integer]]
      local inner = src:sub(earliest_ + 2, e - 1)
      -- Whitespace control: {%- strips leading whitespace, -%} strips trailing
      local strip_before = inner:sub(1,1) == "-"
      local strip_after  = inner:sub(-1)  == "-"
      if strip_before then inner = (inner --[[:! string]]):sub(2) end
      if strip_after  then inner = (inner --[[:! string]]):sub(1, -2) end
      inner = (inner --[[:! string]]):match("^%s*(.-)%s*$") --[[:! string]]
      if strip_before and #tokens > 0 and tokens[#tokens].type == "text" then
        local last = tokens[#tokens]
        last.value = last.value:gsub("%s*$", "")
      end
      tokens[#tokens + 1] = { type = "tag", value = inner, strip_after = strip_after,
                               raw = src:sub(earliest_, e + 1) }
      pos = e + 2
    else
      -- Comment {# ... #}
      local e_raw = src:find("#}", earliest_ + 2, true)
      if not e_raw then return nil, "unclosed {# at position " .. earliest_ end
      local e = e_raw --[[:! integer]]
      tokens[#tokens + 1] = { type = "comment", value = src:sub(earliest_ + 2, e - 1), raw = nil, strip_after = nil }
      pos = e + 2
    end
  end

  return tokens
end

-- ---------------------------------------------------------------------------
-- Expression evaluator
-- ---------------------------------------------------------------------------
-- Supports: dot notation (a.b.c), bracket index (a[0]), comparisons, and/or/not,
-- string/number literals, function calls on filters.

local function make_eval_env(ctx_stack, macros)
  -- Build a flat lookup table from the context stack
  local function lookup(name)
    for i = #ctx_stack, 1, -1 do
      local v = ctx_stack[i][name]
      if v ~= nil then return v end
    end
    return nil
  end

  local env = setmetatable({}, {
    __index = function(_, k) return lookup(k) end,
  })
  -- Expose macros as callable functions
  if macros then
    for k, v in pairs(macros) do
      if rawget(env, k) == nil then
        rawset(env, k, v)
      end
    end
  end
  -- Safe globals
  env.tostring = tostring
  env.tonumber = tonumber
  env.type = type
  env.pairs = pairs
  env.ipairs = ipairs
  env.math = math
  env.string = string
  env.table = table
  env.true_ = true   -- convenience (Lua keywords can't be identifiers)
  env.false_ = false
  return env
end

local function eval_expr(expr_str, ctx_stack, macros)
  local env = make_eval_env(ctx_stack, macros)
  -- Replace Python-style boolean operators (since Lua uses and/or/not already, these
  -- are fine, but 'is' needs mapping and 'True'/'False'/'None' need mapping)
  local s = expr_str
  -- Attempt to compile
  local fn, err = load("return " .. s, "expr", "t", env)
  if not fn then
    -- Try wrapping in parentheses for things like `not x` that produce nil
    fn, err = load("return (" .. s .. ")", "expr", "t", env)
  end
  if not fn then return nil end
  local ok, val = pcall(fn)
  if not ok then return nil end
  return val
end

-- ---------------------------------------------------------------------------
-- Parser
-- ---------------------------------------------------------------------------
-- AST node types:
--   { type="text",    value }
--   { type="expr",    expr, filters }
--   { type="if",      cond, body, elseifs, else_body }
--   { type="for",     var, iter_expr, body, else_body }
--   { type="while",   cond, body }
--   { type="set",     var, expr }
--   { type="include", name_expr }
--   { type="extends", name_expr }
--   { type="block",   name, body }
--   { type="macro",   name, params, body }
--   { type="call",    name, args_expr }
--   { type="raw",     value }
--   { type="comment" }

local function parse_filters(s)
  -- s is like "name | filter1 | filter2(arg)"
  local parts = {}
  for part in (s .. "|"):gmatch("([^|]+)|") do
    parts[#parts + 1] = part:match("^%s*(.-)%s*$")
  end
  local expr = parts[1]
  local filters = {}
  for i = 2, #parts do
    local fname, fargs = parts[i]:match("^(%w+)%s*%((.*)%)$")
    if fname then
      filters[#filters + 1] = { name = fname, args = fargs }
    else
      fname = parts[i]:match("^(%w+)$") or parts[i]:match("^%s*(.-)%s*$")
      filters[#filters + 1] = { name = fname, args = nil }
    end
  end
  return expr, filters
end

--: (tokens: { [integer]: Token }, start: integer | nil, stop_tags: { [integer]: string } | nil) -> ({ [integer]: ASTNode } | nil, integer | nil, string | nil)
local function parse_tokens(tokens, start, stop_tags)
  local nodes = {} --: { [integer]: ASTNode }
  local i = start or 1
  local max = #tokens

  while i <= max do
    local tok = tokens[i]

    if tok.type == "comment" then
      -- skip comments
      i = i + 1

    elseif tok.type == "text" then
      nodes[#nodes + 1] = { type = "text", value = tok.value }
      i = i + 1

    elseif tok.type == "expr" then
      local raw = tok.value:match("^%s*(.-)%s*$")
      local expr, filters = parse_filters(raw)
      nodes[#nodes + 1] = { type = "expr", expr = expr, filters = filters }
      i = i + 1

    elseif tok.type == "tag" then
      local tag = tok.value
      local strip_after = tok.strip_after

      -- Check stop tags
      if stop_tags then
        for _, st in ipairs(stop_tags) do
          if tag == st or tag:match("^" .. st .. "%s") then
            return nodes, i, tag
          end
        end
      end

      -- {% raw %}
      if tag == "raw" then
        -- Collect until {% endraw %}
        local raw_parts = {}
        i = i + 1
        while i <= max do
          local t = tokens[i]
          if t.type == "tag" and t.value == "endraw" then
            i = i + 1
            break
          end
          raw_parts[#raw_parts + 1] = t.raw or t.value
          i = i + 1
        end
        nodes[#nodes + 1] = { type = "raw", value = table.concat(raw_parts) }

      -- {% if expr %}
      elseif tag:match("^if%s+") then
        local cond = tag:match("^if%s+(.+)$")
        i = i + 1
        local body, next_i, end_tag = parse_tokens(tokens, i, { "elif", "else", "endif" })
        local elseifs = {}
        local else_body = nil
        while end_tag and ((end_tag --[[:! string]]):match("^elif%s") or end_tag == "elif") do
          local elif_cond = (end_tag --[[:! string]]):match("^elif%s+(.+)$") or ""
          local elif_body
          elif_body, next_i, end_tag = parse_tokens(tokens, (next_i or i) + 1, { "elif", "else", "endif" })
          elseifs[#elseifs + 1] = { cond = elif_cond, body = elif_body }
        end
        if end_tag == "else" then
          else_body, next_i, end_tag = parse_tokens(tokens, (next_i or i) + 1, { "endif" })
        end
        i = (next_i --[[:! integer | nil]]) and (next_i --[[:! integer]]) + 1 or i + 1
        nodes[#nodes + 1] = { type = "if", cond = cond, body = body,
                               elseifs = elseifs, else_body = else_body }

      -- {% for var in expr %}
      elseif tag:match("^for%s+") then
        local var_part, iter = tag:match("^for%s+(.-)%s+in%s+(.+)$")
        if not var_part then return nil, nil, "malformed for tag: " .. tag end
        -- var_part may be "k, v" for pairs iteration
        i = i + 1
        local body, next_i, end_tag = parse_tokens(tokens, i, { "else", "endfor" })
        local else_body = nil
        if end_tag == "else" then
          else_body, next_i, end_tag = parse_tokens(tokens, (next_i or i) + 1, { "endfor" })
        end
        i = (next_i --[[:! integer | nil]]) and (next_i --[[:! integer]]) + 1 or i + 1
        nodes[#nodes + 1] = { type = "for", var = var_part, iter_expr = iter,
                               body = body, else_body = else_body }

      -- {% while expr %}
      elseif tag:match("^while%s+") then
        local cond = tag:match("^while%s+(.+)$")
        i = i + 1
        local body, next_i = parse_tokens(tokens, i, { "endwhile" })
        i = (next_i or i) + 1
        nodes[#nodes + 1] = { type = "while", cond = cond, body = body }

      -- {% set var = expr %}
      elseif tag:match("^set%s+") then
        local var, expr = tag:match("^set%s+(%w+)%s*=%s*(.+)$")
        if not var then return nil, nil, "malformed set tag: " .. tag end
        nodes[#nodes + 1] = { type = "set", var = var, expr = expr }
        i = i + 1

      -- {% include "name" %}
      elseif tag:match("^include%s+") then
        local name_expr = tag:match("^include%s+(.+)$")
        nodes[#nodes + 1] = { type = "include", name_expr = name_expr }
        i = i + 1

      -- {% extends "name" %}
      elseif tag:match("^extends%s+") then
        local name_expr = tag:match("^extends%s+(.+)$")
        nodes[#nodes + 1] = { type = "extends", name_expr = name_expr }
        i = i + 1

      -- {% block name %}
      elseif tag:match("^block%s+") then
        local name = tag:match("^block%s+(%S+)$")
        if not name then return nil, nil, "malformed block tag: " .. tag end
        i = i + 1
        local body, next_i = parse_tokens(tokens, i, { "endblock", "endblock " .. name })
        i = (next_i or i) + 1
        nodes[#nodes + 1] = { type = "block", name = name, body = body }

      -- {% macro name(params) %}
      elseif tag:match("^macro%s+") then
        local mname, params_str = tag:match("^macro%s+(%w+)%s*%((.-)%)%s*$")
        if not mname then
          mname = tag:match("^macro%s+(%w+)%s*$")
          params_str = ""
        end
        if not mname then return nil, nil, "malformed macro tag: " .. tag end
        -- Parse params: comma separated names, optional defaults
        local params = {}
        if params_str and params_str ~= "" then
          for p in (params_str .. ","):gmatch("([^,]+),") do
            local pname, pdefault = p:match("^%s*(%w+)%s*=%s*(.-)%s*$")
            if pname then
              params[#params + 1] = { name = pname, default = pdefault }
            else
              pname = p:match("^%s*(%w+)%s*$")
              if pname then params[#params + 1] = { name = pname } end
            end
          end
        end
        i = i + 1
        local body, next_i = parse_tokens(tokens, i, { "endmacro" })
        i = (next_i or i) + 1
        nodes[#nodes + 1] = { type = "macro", name = mname, params = params, body = body }

      -- {% call macro(args) %}
      elseif tag:match("^call%s+") then
        local call_expr = tag:match("^call%s+(.+)$")
        nodes[#nodes + 1] = { type = "call", call_expr = call_expr }
        i = i + 1

      -- Skip end tags that we may have missed (shouldn't happen normally)
      elseif tag:match("^end") then
        i = i + 1

      else
        -- Unknown tag — emit as text for debugging
        nodes[#nodes + 1] = { type = "text", value = "{%" .. tag .. "%}" }
        i = i + 1
      end

    else
      i = i + 1
    end
  end

  return nodes, i, nil
end

local function parse(src)
  local tokens, err = lex(src)
  if not tokens then return nil, err end
  local nodes, _, _ = parse_tokens(tokens, 1, nil)
  return nodes
end

-- ---------------------------------------------------------------------------
-- Renderer
-- ---------------------------------------------------------------------------

local function apply_filters(value, filters, filter_registry, ctx_stack, macros)
  for _, f in ipairs(filters) do
    local fn = filter_registry[f.name]
    if fn then
      if f.args and f.args ~= "" then
        -- Evaluate args as a multi-return table so filters with multiple args work
        local args_fn = load("return {" .. f.args .. "}", "fargs", "t",
                             make_eval_env(ctx_stack, macros))
        if args_fn then
          local ok, args_tbl = pcall(args_fn)
          if ok and type(args_tbl) == "table" then
            value = fn(value, unpack(args_tbl --[[:! { [integer]: unknown }]]))
          else
            -- fallback: single arg
            local arg_val = eval_expr(f.args, ctx_stack, macros)
            value = fn(value, arg_val)
          end
        else
          local arg_val = eval_expr(f.args, ctx_stack, macros)
          value = fn(value, arg_val)
        end
      else
        value = fn(value)
      end
    end
    -- Unknown filters: silently skip
  end
  return value
end

local function render_nodes(nodes, ctx_stack, filter_registry, macros, block_overrides, autoescape, loader)
  local parts = {}

  local function out(s)
    parts[#parts + 1] = tostring(s)
  end

  --: (sub_nodes: { [integer]: ASTNode }, extra_ctx: { [string]: unknown } | nil) -> string
  local function render_sub(sub_nodes, extra_ctx)
    if extra_ctx then ctx_stack[#ctx_stack + 1] = extra_ctx end
    local r = render_nodes(sub_nodes, ctx_stack, filter_registry, macros, block_overrides, autoescape, loader)
    if extra_ctx then ctx_stack[#ctx_stack] = nil end
    return r
  end

  for _, node in ipairs(nodes) do
    if node.type == "text" then
      out(node.value)

    elseif node.type == "raw" then
      out(node.value)

    elseif node.type == "comment" then
      -- nothing

    elseif node.type == "expr" then
      local node_expr = node.expr --[[:! string]]
      local node_filters = node.filters --[[:! { [integer]: unknown }]]
      local val = eval_expr(node_expr, ctx_stack, macros)
      -- Apply filters before nil-to-empty so default() sees nil.
      -- Other filters receive nil as-is; they should guard or return "".
      if #node_filters > 0 then
        val = apply_filters(val, node_filters, filter_registry, ctx_stack, macros)
      end
      if val == nil then val = "" end
      if autoescape and not node._safe then
        val = html_escape(tostring(val))
      else
        val = tostring(val)
      end
      out(val)

    elseif node.type == "set" then
      local node_expr = node.expr --[[:! string]]
      local node_var = node.var --[[:! string]]
      local val = eval_expr(node_expr, ctx_stack, macros)
      -- Set in the nearest scope that already has this variable, else innermost
      local target = ctx_stack[#ctx_stack]
      for i = #ctx_stack, 1, -1 do
        if ctx_stack[i][node_var] ~= nil then
          target = ctx_stack[i]
          break
        end
      end
      target[node_var] = val

    elseif node.type == "if" then
      local node_cond = node.cond --[[:! string]]
      local node_body = node.body --[[:! { [integer]: ASTNode }]]
      local node_elseifs = node.elseifs --[[:! { [integer]: { cond: string, body: { [integer]: ASTNode } } }]]
      local node_else = node.else_body --[[:! { [integer]: ASTNode } | nil]]
      local taken = false
      if eval_expr(node_cond, ctx_stack, macros) then
        out(render_sub(node_body))
        taken = true
      else
        for _, ei in ipairs(node_elseifs or {}) do
          if eval_expr(ei.cond, ctx_stack, macros) then
            out(render_sub(ei.body))
            taken = true
            break
          end
        end
      end
      if not taken and node_else then
        out(render_sub(node_else))
      end

    elseif node.type == "for" then
      local node_iter = node.iter_expr --[[:! string]]
      local node_body = node.body --[[:! { [integer]: ASTNode }]]
      local node_else = node.else_body --[[:! { [integer]: ASTNode } | nil]]
      local iter_val = eval_expr(node_iter, ctx_stack, macros)
      local iterated = false

      if type(iter_val) == "table" then
        -- Determine if it's array-like (ipairs) or dict-like (pairs)
        local var_part = node.var --[[:! string]]
        local key_var, val_var = var_part:match("^%s*(%w+)%s*,%s*(%w+)%s*$")

        if key_var then
          -- for k, v in dict
          for k, v in pairs(iter_val) do
            iterated = true
            out(render_sub(node_body, { [key_var] = k, [val_var] = v }))
          end
        else
          -- for item in list
          local n = #(iter_val --[[:! { [integer]: unknown }]])
          for idx, v in ipairs(iter_val --[[:! { [integer]: unknown }]]) do
            iterated = true
            local loop = {
              index  = idx,
              index0 = idx - 1,
              first  = idx == 1,
              last   = idx == n,
              length = n,
            }
            out(render_sub(node_body, { [var_part] = v, loop = loop }))
          end
        end
      end

      if not iterated and node_else then
        out(render_sub(node_else))
      end

    elseif node.type == "while" then
      local node_cond = node.cond --[[:! string]]
      local node_body = node.body --[[:! { [integer]: ASTNode }]]
      local guard = 0
      while eval_expr(node_cond, ctx_stack, macros) do
        out(render_sub(node_body))
        guard = guard + 1
        if guard > 100000 then break end  -- safety limit
      end

    elseif node.type == "include" then
      if loader then
        local node_name_expr = node.name_expr --[[:! string]]
        local name_val = eval_expr(node_name_expr, ctx_stack, macros)
        if not name_val then
          -- try stripping quotes
          name_val = node_name_expr:match('^["\'](.+)["\']$')
        end
        if name_val then
          local src = (loader --[[:! (string) -> (string | nil)]]) (name_val --[[:! string]])
          if src then
            local sub_nodes_raw, perr = parse(src or "")
            if sub_nodes_raw then
              local sub_nodes = sub_nodes_raw or {} --[[: { [integer]: ASTNode }]]
              out(render_sub(sub_nodes))
            end
          end
        end
      end

    elseif node.type == "extends" then
      -- Template inheritance: load base, merge blocks
      if loader then
        local node_name_expr = node.name_expr --[[:! string]]
        local name_val = node_name_expr:match('^["\'](.+)["\']$') or node_name_expr
        local base_src = (loader --[[:! (string) -> (string | nil)]]) (name_val --[[:! string]])
        if base_src then
          -- Collect block overrides from remaining nodes (after extends)
          local child_blocks = block_overrides or {}
          -- current nodes should have been pre-processed; blocks already in block_overrides
          local base_nodes_raw, _ = parse(base_src or "")
          if base_nodes_raw then
            local base_nodes = base_nodes_raw or {} --[[: { [integer]: ASTNode }]]
            out(render_nodes(base_nodes, ctx_stack, filter_registry, macros, child_blocks, autoescape, loader))
          end
        end
      end

    elseif node.type == "block" then
      local bname = node.name --[[:! string]]
      local node_body = node.body --[[:! { [integer]: ASTNode }]]
      if block_overrides and block_overrides[bname] then
        -- Child override
        out(render_sub(block_overrides[bname]))
      else
        out(render_sub(node_body))
      end

    elseif node.type == "macro" then
      -- Define macro as a callable in macros table
      local mname = node.name --[[:! string]]
      local mbody = node.body --[[:! { [integer]: ASTNode }]]
      local mparams = node.params --[[:! { [integer]: { name: string, default: string | nil } }]]
      macros[mname] = function(...)
        local args = { ... }
        local mctx = {}
        for idx, param in ipairs(mparams) do
          if args[idx] ~= nil then
            mctx[param.name] = args[idx]
          elseif param.default then
            mctx[param.name] = eval_expr(param.default, ctx_stack, macros)
          end
        end
        return render_nodes(mbody, { mctx }, filter_registry, macros, block_overrides, autoescape, loader)
      end
      -- Also expose in ctx so {{ macro_name() }} works via eval_expr
      ctx_stack[#ctx_stack][mname] = macros[mname]

    elseif node.type == "call" then
      -- Call a macro and output its result
      local result = eval_expr(node.call_expr --[[:! string]], ctx_stack, macros)
      if result ~= nil then out(tostring(result)) end
    end
  end

  return table.concat(parts)
end

-- Collect block definitions from child template before rendering base
--: (nodes: { [integer]: ASTNode }) -> { [string]: { [integer]: ASTNode } }
local function collect_blocks(nodes)
  local blocks = {} --: { [string]: { [integer]: ASTNode } }
  for _, node in ipairs(nodes) do
    if node.type == "block" then
      blocks[node.name --[[:! string]]] = node.body --[[:! { [integer]: ASTNode }]]
    end
  end
  return blocks
end

-- Check if template uses extends
--: (nodes: { [integer]: ASTNode }) -> ASTNode | nil
local function find_extends(nodes)
  for _, node in ipairs(nodes) do
    if node.type == "extends" then return node
    else -- not extends, skip
    end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Built-in filters
-- ---------------------------------------------------------------------------
local function builtin_filters()
  return {
    upper      = function(v) if v == nil then return "" end return tostring(v):upper() end,
    lower      = function(v) if v == nil then return "" end return tostring(v):lower() end,
    capitalize = function(v)
                   if v == nil then return "" end
                   local s = tostring(v)
                   return s:sub(1,1):upper() .. s:sub(2):lower()
                 end,
    title      = function(v)
                   if v == nil then return "" end
                   return (tostring(v):gsub("(%a)([%w']*)", function(a, b)
                     local a_ = tostring(a)
                     local b_ = tostring(b)
                     return a_:upper() .. b_:lower()
                   end))
                 end,
    strip      = function(v) if v == nil then return "" end return (tostring(v):match("^%s*(.-)%s*$")) end,
    length     = function(v)
                   if type(v) == "table" then return #v end
                   return #tostring(v)
                 end,
    ["int"]    = function(v) return math.floor(tonumber(v) or 0) end,
    ["float"]  = function(v) return tonumber(v) or 0.0 end,
    ["string"] = function(v) return tostring(v) end,
    abs        = function(v) return math.abs(tonumber(v) or 0) end,
    round      = function(v) return math.floor((tonumber(v) or 0) + 0.5) end,
    ceil       = function(v) return math.ceil(tonumber(v) or 0) end,
    floor      = function(v) return math.floor(tonumber(v) or 0) end,
    first      = function(v) if type(v) == "table" then return v[1] end return tostring(v):sub(1,1) end,
    last       = function(v)
                   if type(v) == "table" then return v[#v] end
                   local s = tostring(v) return s:sub(#s)
                 end,
    reverse    = function(v)
                   if type(v) == "table" then
                     local r = {}
                     for i = #v, 1, -1 do r[#r+1] = v[i] end
                     return r
                   end
                   return tostring(v):reverse()
                 end,
    join       = function(v, sep)
                   if type(v) == "table" then
                     local strs = {}
                     for i, item in ipairs(v) do strs[i] = tostring(item) end
                     return table.concat(strs, sep or "")
                   end
                   return tostring(v)
                 end,
    split      = function(v, sep)
                   sep = sep or "%s"
                   local parts = {}
                   for p in tostring(v):gmatch("[^" .. sep .. "]+") do
                     parts[#parts+1] = p
                   end
                   return parts
                 end,
    ["default"]= function(v, d) if v == nil or v == false then return d end return v end,
    replace    = function(v, old, new_s)
                   return (tostring(v):gsub(old, new_s or ""))
                 end,
    truncate   = function(v, n)
                   local s = tostring(v)
                   local n_ = math.floor(tonumber(n) or 255) --[[:! integer]]
                   if #s <= n_ then return s end
                   return s:sub(1, n_) .. "..."
                 end,
    truncate_words = function(v, n)
                   n = tonumber(n) or 10
                   local words = {}
                   for w in tostring(v):gmatch("%S+") do
                     words[#words+1] = w
                     if #words >= n then break end
                   end
                   return table.concat(words, " ")
                 end,
    escape     = html_escape,
    e          = html_escape,
  }
end

-- ---------------------------------------------------------------------------
-- Environment
-- ---------------------------------------------------------------------------

local Env = {}
Env.__index = Env

function Env:add_filter(name, fn)
  self._filters[name] = fn
end

function Env:compile(src)
  local nodes, err = parse(src)
  if not nodes then return nil, err end

  local tmpl = { _nodes = nodes, _env = self }
  return setmetatable(tmpl, {
    __index = {
      render = function(self2, context)
        local ctx = context or {}
        local ctx_stack = { ctx }
        local macros = {}
        local block_overrides = {}

        -- Pre-pass: collect blocks for inheritance
        local self2_ = self2 --[[:! { _nodes: { [integer]: ASTNode }, _env: { _loader: unknown, _filters: unknown, _autoescape: boolean } }]]
        local s2_nodes = self2_._nodes
        local s2_env = self2_._env
        local ext_node = find_extends(s2_nodes)
        if ext_node then
          -- Collect all blocks defined in child
          block_overrides = collect_blocks(s2_nodes)
          -- Render using extends node (which will load and render base)
          local loader = s2_env._loader
          if loader then
            local node_name_expr = ext_node.name_expr --[[:! string]]
            local name_val = node_name_expr:match('^["\'](.+)["\']$') or node_name_expr
            local base_src = (loader --[[:! (string) -> (string | nil)]]) (name_val)
            if not base_src then return nil, "template not found: " .. tostring(name_val) end
            local base_nodes_raw, perr = parse(base_src or "")
            if not base_nodes_raw then return nil, perr end
            local base_nodes = base_nodes_raw or {} --[[: { [integer]: ASTNode }]]
            return render_nodes(base_nodes, ctx_stack, s2_env._filters, macros,
                                block_overrides, s2_env._autoescape, loader)
          end
          return nil, "loader required for extends"
        end

        return render_nodes(s2_nodes, ctx_stack, s2_env._filters, macros,
                            block_overrides, s2_env._autoescape, s2_env._loader)
      end,
    }
  })
end

function Env:render(src, context)
  local tmpl, err = self:compile(src)
  if not tmpl then return nil, err end
  return tmpl:render(context)
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function M.environment(opts)
  opts = opts or {}
  local env = setmetatable({
    _filters   = builtin_filters(),
    _loader    = opts.loader,
    _autoescape = opts.autoescape or false,
  }, Env)
  return env
end

-- Convenience: create a default environment and render
function M.render(src, context, opts)
  local env = M.environment(opts)
  return env:render(src, context)
end

return M
