local ts = require("dep.tree_sitter.ffi")

local mod = {}

---@class Scope
local Scope = {}
Scope.__index = Scope

---@param parent? Scope Parent scope
---@param variables? table<string, unknown> Initial variables
function Scope:new(parent, variables)
  ---@class Scope
  local scope = {
    variables = variables or {},
    parent = parent,
  }
  return setmetatable(scope, self)
end

---@param key string
function Scope:get(key)
  local scope = self
  while scope do
    local value = scope.variables[key]
    if value then return value end
    scope = scope.parent
  end
  return nil
end

---@param key string
---@param value unknown
function Scope:set(key, value)
  self.variables[key] = value
end

---@type lua_tc_opaque_type
local intrinsic_any_type = { type = "opaque", name = "any" }
---@type lua_tc_opaque_type
local intrinsic_never_type = { type = "opaque", name = "never" }
---@type lua_tc_opaque_type
local intrinsic_nil_type = { type = "opaque", name = "nil" }
---@type lua_tc_opaque_type
local intrinsic_boolean_type = { type = "opaque", name = "boolean" }
---@type lua_tc_opaque_type
local intrinsic_integer_type = { type = "opaque", name = "integer" }
---@type lua_tc_opaque_type
local intrinsic_number_type = { type = "opaque", name = "number" }
---@type lua_tc_opaque_type
local intrinsic_string_type = { type = "opaque", name = "string" }
---@type lua_tc_opaque_type
local intrinsic_userdata_type = { type = "opaque", name = "userdata" }
local array_of_any_type = {
  type = "table",
  key = intrinsic_integer_type,
  value = intrinsic_any_type
}
---@type lua_tc_generic_type
local intrinsic_function_type = {
  type = "generic",
  name = "function",
  parameters = {
    { name = "parameters", constraint = array_of_any_type },
    { name = "returns",    constraint = array_of_any_type }
  },
  definition = { type = "opaque" }
}
---@type lua_tc_generic_type
local intrinsic_all_type = {
  type = "generic",
  name = "all",
  parameters = {
    { name = "members", constraint = array_of_any_type }
  },
  definition = { type = "opaque" }
}
---@type lua_tc_generic_type
local intrinsic_some_type = {
  type = "generic",
  name = "some",
  parameters = {
    { name = "members", constraint = array_of_any_type }
  },
  definition = { type = "opaque" }
}

local initial_type_scope = Scope:new(nil, {
  ["any"] = intrinsic_any_type,
  ["never"] = intrinsic_never_type,
  ["nil"] = intrinsic_nil_type,
  ["boolean"] = intrinsic_boolean_type,
  ["integer"] = intrinsic_integer_type,
  ["number"] = intrinsic_number_type,
  ["string"] = intrinsic_string_type,
  ["userdata"] = intrinsic_userdata_type,
  ["function"] = intrinsic_function_type,
  ["some"] = intrinsic_some_type,
})

---@param a lua_tc_type
---@param b lua_tc_type
local function are_types_equal(a, b)
  if a == b then
    return true
  elseif a.type ~= b.type then
    return false
  elseif a.type == "opaque" and b.type == "opaque" then
    -- assume opaque types are only equal when they are reference equal
    return false
  elseif a.type == "literal" and b.type == "literal" then
    return a.type == "literal" and b.type == "literal" and a.literal == b.literal
  elseif a.type == "generic_instantiation" and b.type == "generic_instantiation" then
    -- `a` and `b` must be instances of the same generic type
    if a.generic ~= b.generic then return false end
    -- FIXME: finish implementation
  elseif a.type == "generic" and b.type == "generic" then
  elseif a.type == "in_progress" and b.type == "in_progress" then
    return a.is_numeric == b.is_numeric
  else
    -- `a.type ~= b.type`. this should not be able to happen because of the second check above
    return false
  end
end

-- Helper to get the text of a node from the source string
local function get_node_text(node, source)
  local start_byte = ts.ts_node_start_byte(node)
  local end_byte = ts.ts_node_end_byte(node)
  return source:sub(start_byte + 1, end_byte)
end

local unescape_char = {
  ["\\a"] = "\a",
  ["\\b"] = "\b",
  ["\\f"] = "\f",
  ["\\n"] = "\n",
  ["\\r"] = "\r",
  ["\\t"] = "\t",
  ["\\v"] = "\v",
  ["\\\\"] = "\\",
  ['\\"'] = '"',
}

-- Helper to decode Lua string escapes
---@param s string The string to decode
local function decode_lua_string(s)
  return (s:gsub('\\([\\"abfnrtv])', unescape_char)
    :gsub('\\x(%x%x)', function(hex) return string.char(tonumber(hex, 16) or 0) end)
    :gsub('\\(%d%d?%d?)', function(d) return string.char(tonumber(d, 10)) end))
end

-- Recursive descent parser for type annotations
---@param comment string The comment string to parse
---@return lua_tc_type_node? type The parsed type or nil if not found
local function parse_type_annotation(comment)
  local type_str = comment:match("%-%-%-?@?type%s+([^\n]+)")
  if not type_str then
    type_str = comment:match("%-%-:%s*([^\n]+)")
  end
  if not type_str then return nil end
  type_str = type_str:match("^%s*(.-)%s*$")

  local tokens = {}
  local i = 1
  local len = #type_str
  while i <= len do
    local c = type_str:sub(i, i)
    if c:match("%s") then
      i = i + 1
    elseif c == "<" or c == ">" or c == "," then
      table.insert(tokens, { type = c, value = c })
      i = i + 1
    elseif c == '"' then
      local j = i + 1
      local str_val = {}
      while j <= len do
        local cj = type_str:sub(j, j)
        if cj == "\\" then
          local nextc = type_str:sub(j + 1, j + 1)
          if nextc ~= "" then
            table.insert(str_val, "\\" .. nextc)
            j = j + 2
          else
            table.insert(str_val, "\\")
            j = j + 1
          end
        elseif cj == '"' then
          break
        else
          table.insert(str_val, cj)
          j = j + 1
        end
      end
      local value = table.concat(str_val)
      value = decode_lua_string(value)
      table.insert(tokens, { type = "string", value = value })
      i = j + 1
    elseif c:match("%d") or (c == "-" and type_str:sub(i + 1, i + 1):match("%d")) then
      local j = i
      while j <= len and type_str:sub(j, j):match("[%d%.%-]") do j = j + 1 end
      local value = type_str:sub(i, j - 1)
      table.insert(tokens, { type = "number", value = tonumber(value) })
      i = j
    else
      local j = i
      while j <= len and type_str:sub(j, j):match("[%w_]") do j = j + 1 end
      local value = type_str:sub(i, j - 1)
      table.insert(tokens, { type = "name", value = value })
      i = j
    end
  end
  local pos = 1
  local function peek() return tokens[pos] end
  local function next_token()
    local t = tokens[pos]; pos = pos + 1; return t
  end

  local function parse_type()
    local t = peek()
    if not t then return nil end
    if t.type == "string" or t.type == "number" then
      next_token()
      return { type = "literal", literal = t.value }
    elseif t.type == "name" then
      local base = t.value
      next_token()
      if peek() and peek().type == "<" then
        next_token()
        local generics = {}
        while true do
          table.insert(generics, parse_type())
          if peek() and peek().type == "," then
            next_token()
          else
            break
          end
        end
        if peek() and peek().type == ">" then
          next_token()
        end
        return {
          type = "generic_instantiation",
          generic = { type = "name", name = base },
          arguments = generics
        }
      else
        return { type = "name", name = base }
      end
    end
    return nil
  end
  return parse_type()
end

--- Collects and associates comment nodes with the next non-comment node, including trailing comments
---@param node TSNode
---@param node_comments? table<TSNode, TSNode[]> A table to store comments associated with nodes
local function associate_comments(node, node_comments)
  ---@type table<TSNode, TSNode[]>
  node_comments = node_comments or setmetatable({}, { __mode = "k" })
  local count = ts.ts_node_child_count(node)
  local pending_comments = {}
  for i = 0, count - 1 do
    local child = ts.ts_node_child(node, i)
    local type = ts.ts_node_type(child)
    if type == "comment" then
      pending_comments[#pending_comments + 1] = child
    else
      -- Attach preceding comments
      if #pending_comments > 0 then
        node_comments[child] = { table.unpack(pending_comments) }
        pending_comments = {}
      end
      -- Check for trailing comment (next sibling is a comment on the same line)
      if i + 1 < count then
        local next_sibling = ts.ts_node_child(node, i + 1)
        if ts.ts_node_type(next_sibling) == "comment" then
          if ts.ts_node_end_point(child) == ts.ts_node_start_point(next_sibling) then
            node_comments[child] = node_comments[child] or {}
            table.insert(node_comments[child], next_sibling)
          end
        end
      end
      associate_comments(child, node_comments)
    end
  end
  return node_comments
end

---@param node TSNode
---@param source string
local typecheck = function(node, source)
  ---@type table<TSNode, lua_tc_type>
  local types = setmetatable({}, { __mode = "k" })
  local node_comments = associate_comments(node)
  local count = ts.ts_node_child_count(node)
  for i = 0, count - 1 do
    local child = ts.ts_node_child(node, i)
    local comments = node_comments[child]
    if comments then
      for _, comment_node in ipairs(comments) do
        local comment_text = get_node_text(comment_node, source)
        local typ = parse_type_annotation(comment_text)
        if typ then
          types[child] = typ
          break
        end
      end
    end
    -- TODO: type checking logic here
  end
end
mod.typecheck = typecheck

return mod

---@class lua_tc_string_type_node
---@field type "string"
---@field value string

---@class lua_tc_number_type_node
---@field type "number"
---@field value number

---@class lua_tc_name_type_node
---@field type "name"
---@field name string

---@class lua_tc_generic_parameter_type_node
---@field type "generic_parameter"
---@field name string
---@field constraint? lua_tc_type_node

---@class lua_tc_generic_type_node
---@field type "generic"
---@field name? string
---@field parameters lua_tc_generic_parameter_type_node[]
---@field definition lua_tc_type_node

---@class lua_tc_generic_instantiation_type_node
---@field type "generic_instantiation"
---@field generic lua_tc_type_node
---@field arguments lua_tc_type_node[]

---@alias lua_tc_type_node lua_tc_string_type_node | lua_tc_number_type_node | lua_tc_name_type_node | lua_tc_generic_type_node


---@class lua_tc_opaque_type
---@field type "opaque"
---@field name? string

-- doubles as an array type when key is `intrinsic_integer_type`
---@class lua_tc_table_type
---@field type "table"
---@field name? string
---@field key? lua_tc_type
---@field value? lua_tc_type
---@field fields? table<unknown, lua_tc_type>

---@class lua_tc_literal_type
---@field type "literal"
---@field literal string | number

---@class lua_tc_generic_parameter
---@field name string
---@field constraint? lua_tc_type

---@class lua_tc_generic_type
---@field type "generic"
---@field name? string
---@field parameters lua_tc_generic_parameter[]
---@field definition lua_tc_type

---@class lua_tc_generic_instantiation_type
---@field type "generic_instantiation"
---@field generic lua_tc_generic_type
---@field arguments lua_tc_type[]

---@class lua_tc_in_progress_type
---@field type "in_progress"
---@field is_numeric boolean

---@alias lua_tc_type lua_tc_opaque_type | lua_tc_table_type | lua_tc_literal_type | lua_tc_generic_type | lua_tc_generic_instantiation_type | lua_tc_in_progress_type
