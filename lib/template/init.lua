if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

-- HTML escape
local escape_map = { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;" }
local function html_escape(s)
  return (tostring(s):gsub('[&<>"]', escape_map))
end

-- Built-in filters
local builtin_filters = {
  upper   = function(v) return tostring(v):upper() end,
  lower   = function(v) return tostring(v):lower() end,
  trim    = function(v) return (tostring(v):match("^%s*(.-)%s*$")) end,
  escape  = function(v) return html_escape(v) end,
  raw     = function(v) return tostring(v) end,
}
-- "default:fallback" is handled specially during filter application

-- Global partial registry and filter registry
local global_partials = {}
local global_filters  = {}

-- Register a partial globally
function M.partial(name, tmpl_str)
  global_partials[name] = tmpl_str
end

-- Register a filter globally
function M.filter(name, fn)
  global_filters[name] = fn
end

-- ============================================================
-- Lexer: split template string into tokens
-- Token types: "text", "var", "raw_var", "block_open", "block_else", "block_close", "partial", "comment"
-- ============================================================

local function lex(template)
  local tokens = {}
  local pos = 1
  local len = #template

  while pos <= len do
    -- Look for {{ or {{{
    local s = template:find("{{", pos, true)
    if not s then
      -- Rest is literal text
      tokens[#tokens+1] = { type = "text", value = template:sub(pos) }
      break
    end

    -- Emit any text before this tag
    if s > pos then
      tokens[#tokens+1] = { type = "text", value = template:sub(pos, s - 1) }
    end

    -- Check for triple brace
    local triple = template:sub(s, s + 2) == "{{{"
    if triple then
      local e = template:find("}}}", s + 3, true)
      if not e then
        return nil, "unclosed {{{ at position " .. s
      end
      local inner = template:sub(s + 3, e - 1):match("^%s*(.-)%s*$")
      tokens[#tokens+1] = { type = "raw_var", value = inner }
      pos = e + 3
    else
      local e = template:find("}}", s + 2, true)
      if not e then
        return nil, "unclosed {{ at position " .. s
      end
      local inner = template:sub(s + 2, e - 1):match("^%s*(.-)%s*$")
      -- Dispatch based on first char
      local first = inner:sub(1, 1)
      if first == "!" then
        -- Comment — discard
        tokens[#tokens+1] = { type = "comment" }
      elseif first == ">" then
        -- Partial
        local name = inner:sub(2):match("^%s*(.-)%s*$")
        tokens[#tokens+1] = { type = "partial", name = name }
      elseif first == "#" then
        -- Block open: #if, #each, #else embedded as #else
        local tag = inner:sub(2)
        if tag:match("^else%s*$") then
          tokens[#tokens+1] = { type = "block_else" }
        else
          local keyword, arg = tag:match("^(%S+)%s*(.*)")
          tokens[#tokens+1] = { type = "block_open", keyword = keyword, arg = arg }
        end
      elseif first == "/" then
        local keyword = inner:sub(2):match("^%s*(.-)%s*$")
        tokens[#tokens+1] = { type = "block_close", keyword = keyword }
      else
        -- Variable (possibly with filter)
        tokens[#tokens+1] = { type = "var", value = inner }
      end
      pos = e + 2
    end
  end

  return tokens
end

-- ============================================================
-- Parser: build AST from tokens
-- Node types:
--   { type="text", value }
--   { type="var", value, raw }         raw=true for {{{...}}}
--   { type="if", cond, body, alt }     alt may be nil or a node list
--   { type="each", var, body }
--   { type="partial", name }
-- ============================================================

local function parse(tokens)
  local pos = 1
  local n = #tokens

  local function peek() return tokens[pos] end
  local function advance() local t = tokens[pos]; pos = pos + 1; return t end

  local parse_nodes  -- forward declaration

  parse_nodes = function(stop_keywords)
    local nodes = {}
    while pos <= n do
      local tok = peek()
      if tok.type == "text" then
        advance()
        nodes[#nodes+1] = { type = "text", value = tok.value }
      elseif tok.type == "comment" then
        advance()  -- discard
      elseif tok.type == "raw_var" then
        advance()
        nodes[#nodes+1] = { type = "var", value = tok.value, raw = true }
      elseif tok.type == "var" then
        advance()
        nodes[#nodes+1] = { type = "var", value = tok.value, raw = false }
      elseif tok.type == "partial" then
        advance()
        nodes[#nodes+1] = { type = "partial", name = tok.name }
      elseif tok.type == "block_else" then
        -- Signal to caller to switch to alt branch
        break
      elseif tok.type == "block_close" then
        if stop_keywords and stop_keywords[tok.keyword] then
          break  -- caller will consume this token
        else
          return nil, "unexpected {{/" .. tok.keyword .. "}}"
        end
      elseif tok.type == "block_open" then
        advance()
        if tok.keyword == "if" then
          local body, err = parse_nodes({ ["if"] = true })
          if not body then return nil, err end
          local alt = nil
          local cur = peek()
          if cur and cur.type == "block_else" then
            advance()  -- consume {{#else}}
            local alt_nodes, err2 = parse_nodes({ ["if"] = true })
            if not alt_nodes then return nil, err2 end
            alt = alt_nodes
            cur = peek()
          end
          if not cur or cur.type ~= "block_close" or cur.keyword ~= "if" then
            return nil, "missing {{/if}}"
          end
          advance()  -- consume {{/if}}
          nodes[#nodes+1] = { type = "if", cond = tok.arg, body = body, alt = alt }
        elseif tok.keyword == "each" then
          local body, err = parse_nodes({ ["each"] = true })
          if not body then return nil, err end
          local cur = peek()
          if not cur or cur.type ~= "block_close" or cur.keyword ~= "each" then
            return nil, "missing {{/each}}"
          end
          advance()  -- consume {{/each}}
          nodes[#nodes+1] = { type = "each", var = tok.arg, body = body }
        else
          return nil, "unknown block keyword: " .. tok.keyword
        end
      else
        advance()  -- skip unknown token types
      end
    end
    return nodes
  end

  local nodes, err = parse_nodes(nil)
  if not nodes then return nil, err end
  return nodes
end

-- ============================================================
-- Evaluator
-- ============================================================

-- Resolve a dotted path like "a.b.c" in a context stack.
-- Special paths: "." = current item, "@index" / "@key" = loop meta.
-- ctx_stack entries are tables; meta keys like "." and "@index" are stored directly in the loop_ctx.
local function resolve(path, ctx_stack)
  -- Special: "." and "@..." — look only in the topmost context's meta keys
  if path == "." or path:sub(1,1) == "@" then
    for i = #ctx_stack, 1, -1 do
      local v = ctx_stack[i][path]
      if v ~= nil then return v end
    end
    return nil
  end

  -- Dotted path: split and walk
  local parts = {}
  for part in path:gmatch("[^%.]+") do
    parts[#parts+1] = part
  end

  for i = #ctx_stack, 1, -1 do
    local ctx = ctx_stack[i]
    if type(ctx) == "table" and ctx[parts[1]] ~= nil then
      local v = ctx
      local ok = true
      for _, part in ipairs(parts) do
        if type(v) == "table" then
          v = v[part]
        else
          ok = false
          break
        end
      end
      if ok then return v end
    end
  end
  return nil
end

-- Apply a filter spec like "upper" or "default:fallback" to a value.
-- Returns (result, is_raw) — is_raw=true means caller should not HTML-escape.
local function apply_filter(filter_spec, value, filters)
  local colon = filter_spec:find(":", 1, true)
  local name, arg
  if colon then
    name = filter_spec:sub(1, colon - 1):match("^%s*(.-)%s*$")
    arg  = filter_spec:sub(colon + 1)
  else
    name = filter_spec:match("^%s*(.-)%s*$")
    arg  = nil
  end

  if name == "default" then
    if value == nil or value == false then
      return arg or "", false
    end
    return value, false
  end

  if name == "raw" then
    return tostring(value == nil and "" or value), true
  end

  -- Check custom filters first, then built-ins
  local fn = filters[name] or builtin_filters[name]
  if fn then
    local result = fn(value == nil and "" or value, arg)
    -- escape filter returns already-escaped HTML — mark as raw to avoid double-escaping
    local is_raw = (name == "escape")
    return result, is_raw
  end

  return value, false  -- unknown filter: pass through
end

-- Render a node list into the output buffer
local function render_nodes(nodes, ctx_stack, out, partials, filters)
  for _, node in ipairs(nodes) do
    if node.type == "text" then
      out[#out+1] = node.value

    elseif node.type == "var" then
      -- Parse variable name and optional filter
      local pipe = node.value:find("|", 1, true)
      local varpart, filter_spec
      if pipe then
        varpart     = node.value:sub(1, pipe - 1):match("^%s*(.-)%s*$")
        filter_spec = node.value:sub(pipe + 1):match("^%s*(.-)%s*$")
      else
        varpart     = node.value:match("^%s*(.-)%s*$")
        filter_spec = nil
      end

      local val = resolve(varpart, ctx_stack)

      local is_raw = node.raw  -- triple-brace → always raw
      if filter_spec then
        local fval, fraw = apply_filter(filter_spec, val, filters)
        val = fval
        if fraw then is_raw = true end
      end

      if val == nil then val = "" end

      if is_raw then
        out[#out+1] = tostring(val)
      else
        out[#out+1] = html_escape(val)
      end

    elseif node.type == "if" then
      local val = resolve(node.cond, ctx_stack)
      local truthy = val ~= nil and val ~= false
      if truthy then
        render_nodes(node.body, ctx_stack, out, partials, filters)
      elseif node.alt then
        render_nodes(node.alt, ctx_stack, out, partials, filters)
      end

    elseif node.type == "each" then
      local val = resolve(node.var, ctx_stack)
      if type(val) == "table" then
        -- Determine if array or map
        local is_array = #val > 0 or next(val) == nil
        if is_array then
          for i, item in ipairs(val) do
            -- Loop context: item fields merged, plus meta "." and "@index"
            local loop_ctx = { ["."] = item, ["@index"] = i }
            if type(item) == "table" then
              for k, v in pairs(item) do loop_ctx[k] = v end
            end
            ctx_stack[#ctx_stack+1] = loop_ctx
            render_nodes(node.body, ctx_stack, out, partials, filters)
            ctx_stack[#ctx_stack] = nil
          end
        else
          -- Map iteration
          for k, v in pairs(val) do
            local loop_ctx = { ["."] = v, ["@key"] = k }
            if type(v) == "table" then
              for fk, fv in pairs(v) do loop_ctx[fk] = fv end
            end
            ctx_stack[#ctx_stack+1] = loop_ctx
            render_nodes(node.body, ctx_stack, out, partials, filters)
            ctx_stack[#ctx_stack] = nil
          end
        end
      end

    elseif node.type == "partial" then
      local tmpl_str = partials[node.name]
      if tmpl_str then
        local toks, err = lex(tmpl_str)
        if toks then
          local pnodes, perr = parse(toks)
          if pnodes then
            render_nodes(pnodes, ctx_stack, out, partials, filters)
          end
        end
      end
    end
  end
end

-- ============================================================
-- Engine instance
-- ============================================================

local Engine = {}
Engine.__index = Engine

function Engine:partial(name, tmpl_str)
  self._partials[name] = tmpl_str
end

function Engine:filter(name, fn)
  self._filters[name] = fn
end

function Engine:compile(tmpl_str)
  local toks, err = lex(tmpl_str)
  if not toks then return nil, err end
  local nodes, perr = parse(toks)
  if not nodes then return nil, perr end

  local partials = self._partials
  local filters  = self._filters

  return function(data)
    local out = {}
    local ctx_stack = { data or {} }
    render_nodes(nodes, ctx_stack, out, partials, filters)
    return table.concat(out)
  end
end

function Engine:render(tmpl_str, data)
  local fn, err = self:compile(tmpl_str)
  if not fn then return nil, err end
  return fn(data)
end

function M.new()
  -- Inherit global partials and filters at creation time (copy)
  local partials = {}
  for k, v in pairs(global_partials) do partials[k] = v end
  local filters = {}
  for k, v in pairs(global_filters) do filters[k] = v end

  return setmetatable({ _partials = partials, _filters = filters }, Engine)
end

-- ============================================================
-- Module-level API (uses global registries)
-- ============================================================

function M.compile(tmpl_str)
  local toks, err = lex(tmpl_str)
  if not toks then return nil, err end
  local nodes, perr = parse(toks)
  if not nodes then return nil, perr end

  return function(data)
    local out = {}
    local ctx_stack = { data or {} }
    render_nodes(nodes, ctx_stack, out, global_partials, global_filters)
    return table.concat(out)
  end
end

function M.render(tmpl_str, data)
  local fn, err = M.compile(tmpl_str)
  if not fn then return nil, err end
  return fn(data)
end

return M
