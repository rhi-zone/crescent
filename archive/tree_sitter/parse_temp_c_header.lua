local cparser = require("dep.cparser")

local function dbg(obj)
  require("dep.pretty_print").pretty_print_(obj, function(...)
    io.stderr:write(...)
  end)
end

local type_replacements = {
  ["char"] = "integer",
  ["short"] = "integer",
  ["int"] = "integer",
  ["long"] = "integer",
  ["long long"] = "integer",
  ["unsigned char"] = "integer",
  ["unsigned short"] = "integer",
  ["unsigned int"] = "integer",
  ["unsigned long"] = "integer",
  ["unsigned long long"] = "integer",
  ["uint8_t"] = "integer",
  ["int8_t"] = "integer",
  ["uint16_t"] = "integer",
  ["int16_t"] = "integer",
  ["uint32_t"] = "integer",
  ["int32_t"] = "integer",
  ["uint64_t"] = "integer",
  ["int64_t"] = "integer",
  ["size_t"] = "integer",
  ["ssize_t"] = "integer",
  ["usize_t"] = "integer",
  ["double"] = "number",
  ["float"] = "number",
  ["_Bool"] = "boolean",
  ["bool"] = "boolean",
  ["void"] = "nil",
  ["intptr_t"] = "ptr_c<integer>",
  ["uintptr_t"] = "ptr_c<integer>",
  ["ptrdiff_t"] = "ptr_c<integer>",
}

-- Recursively resolve type name
local function get_type_(t)
  if type(t) ~= "table" then
    return tostring(t)
  elseif t.tag == "Function" then
    -- Function type: t.t is return type, t[1..n] are arguments
    local ret = get_type_(t.t)
    local args = {}
    for i = 1, #t do
      args[i] = get_type_(t[i])
    end
    return "fun(" .. table.concat(args, ", ") .. "): " .. ret
  end
  if t.n then
    return type_replacements[t.n] or t.n
  end
  if t.t then
    local type = get_type_(t.t)
    if t.tag == "Pointer" and not type:match("^fun%(") then
      local type_name = t.t and t.t.t and t.t.t.n
      if type_name == "char" then
        return "string_c"
      else
        return "ptr_c<" .. type .. ">?"
      end
    else
      return type
    end
  end
  if t.const and t.t then return get_type_(t.t) end
  return t.tag or "any"
end

---@param t table The type to resolve
---@return string The resolved type name
local function get_type(t)
  local str = get_type_(t)
  return type_replacements[str] or str
end

---@param t table The type to resolve
---@param name? string Optional name for the type
local function c_type_str_(t, name)
  if type(t) ~= "table" then
    return tostring(t)
  elseif t.tag == "Pointer" then
    if t.t and t.t.tag == "Function" then
      local ret = c_type_str_(t.t.t)
      local args = {}
      for _, arg in ipairs(t.t) do
        local at = arg[1] or arg
        local an = arg[2] or ""
        table.insert(args, c_type_str_(at) .. (an ~= "" and (" " .. an) or ""))
      end
      return ret .. " (*" .. (name or "") .. ")(" .. table.concat(args, ", ") .. ")"
    end
    return c_type_str_(t.t) .. "*"
  elseif t.tag == "Array" then
    local size = t.size and ("[" .. t.size .. "]") or "[]"
    return c_type_str_(t.t) .. (name and (" " .. name) or "") .. size
  elseif t.tag == "Qualified" then
    return "const " .. c_type_str_(t.t)
  elseif t.tag == "Struct" then
    return "struct " .. (t.n or "")
  elseif t.tag == "Type" then
    return t.n or "void"
  else
    return t.n or t.tag or "void"
  end
end

---@param t table The type to resolve
---@param name? string Optional name for the type
local function c_type_str(t, name)
  local str = c_type_str_(t, name)
  if str:match("[)%]]$") then
    return str
  elseif name then
    return str .. " " .. name
  else
    return str
  end
end

---@param header string Path to the C header file
---@param outpath string Name of the Lua library to generate
---@param namespace_name string Namespace name for the Lua library
---@return nil
-- Parses the C header file and generates Lua FFI definitions
-- Writes the definitions to <outpath>.lua and <outpath>.d.lua
-- The .d.lua file contains type annotations for the Lua library
-- The .lua file contains the actual FFI definitions
-- The namespace_name is used to create a class-like structure in the .d.lua file
local function parse_and_emit(header, outpath, libname, namespace_name)
  local li = cparser.declarationIterator({}, io.lines(header), header)
  local enum_members = {}
  local lua_file = assert(io.open(outpath .. ".lua", "w"))
  local d_lua_file = assert(io.open(outpath .. ".d.lua", "w"))
  lua_file:write("local ffi = require('ffi')\n")
  lua_file:write("ffi.cdef[[\n")
  d_lua_file:write("---@diagnostic disable: unused-local\n---@meta\n")
  local was_toplevel_function = false
  for action in li do
    if action.tag == "Definition" and action.sclass == "[enum]" and action.name then
      local enumname = nil
      if action.type and action.type._enum then
        local first = action.type._enum[1]
        if first and type(first) == "table" and first[1] then
          enumname = action.type._enum.tag or action.name:match("^([A-Za-z0-9_]+)")
        end
      end
      enumname = enumname or action.name:match("^([A-Za-z0-9_]+)")
      if enumname then
        enum_members[enumname] = enum_members[enumname] or {}
        table.insert(enum_members[enumname], { name = action.name, value = action.intval })
      end
    elseif action.tag == "TypeDef" and action.name and action.type then
      if action.type.tag == "Enum" then
        local enumname = action.type.n or action.name:gsub("^enum ", "")
        lua_file:write("typedef int ", enumname, ";\n")
        d_lua_file:write("\n---@enum ", enumname, "\n")
        d_lua_file:write("local ", enumname, " = {\n")
        for i, pair in ipairs(action.type) do
          local membername = pair[1]
          local membervalue = pair[2] or
              (enum_members[enumname] and enum_members[enumname][i] and enum_members[enumname][i].value) or (i - 1)
          d_lua_file:write("  ", membername, " = ", membervalue, ",\n")
        end
        d_lua_file:write("}\n")
      elseif action.type.n then
        if not action.name:match("^struct ") then
          lua_file:write("typedef ", action.type.n, " ", action.name, ";\n")
        end
        if action.type.n:match("^struct ") and action.type._def then
          local structname = action.name
          lua_file:write("struct ", structname, " {\n")
          d_lua_file:write("\n---@class ", structname, ": ffi.cdata*\n")
          for _, field in ipairs(action.type._def) do
            local fname = field[2]
            local ftype = field[1]
            lua_file:write("  ", c_type_str(ftype, fname), ";\n")
            d_lua_file:write("---@field ", fname, " ", get_type(ftype), "\n")
          end
          lua_file:write("};\n")
        elseif action.type.n:match("^enum ") or action.name:match("^struct ") then
          -- ignored
        elseif action.type.n:match("^struct ") then
          d_lua_file:write("\n---@class ", action.name, "\n")
        else
          local replacement = type_replacements[action.type.n]
          if replacement then
            d_lua_file:write("---@class ", action.name, ": ", replacement, "\n")
          else
            d_lua_file:write("---@alias ", action.name, " ", action.type.n, "\n")
          end
        end
      elseif action.type.tag == "Struct" then
        local structname = action.name
        lua_file:write("typedef struct {\n")
        d_lua_file:write("\n---@class ", structname, "\n")
        for _, field in ipairs(action.type) do
          local fname = field[2]
          local ftype = field[1]
          lua_file:write("  ", c_type_str(ftype), " ", fname, ";\n")
          d_lua_file:write("---@field ", fname, " ", get_type(ftype), "\n")
        end
        lua_file:write("} ", structname, ";\n")
      elseif action.type.tag == "Pointer" and action.type.t and action.type.t.tag == "Function" then
        local ftype = action.type.t
        lua_file:write("typedef ", c_type_str(ftype.t), " (*", action.name, ")(")
        d_lua_file:write("---@alias ", action.name, " fun(")
        for i, arg in ipairs(ftype) do
          local t = arg[1] or arg
          local name = arg[2] or "_"
          if i > 1 then
            lua_file:write(", ")
            d_lua_file:write(", ")
          end
          lua_file:write(c_type_str(t, name))
          d_lua_file:write(name, ": ", get_type(t))
        end
        lua_file:write(");\n")
        d_lua_file:write("): ", get_type(ftype.t), "\n")
      else
        print("unknown typedef:", action.name)
      end
    elseif action.tag == "Declaration" and action.type and action.type.tag == "Function" and action.name then
      local ftype = action.type
      local c_ret = c_type_str(ftype.t)
      lua_file:write(c_ret, " ", action.name, "(")
      if not was_toplevel_function then
        d_lua_file:write("\n---@class ", namespace_name, "\n")
      end
      d_lua_file:write("---@field ", action.name, " fun(")
      local first = true
      for _, arg in ipairs(ftype) do
        local t = arg[1] or arg
        local name = arg[2] or "_"
        if first then
          first = false
        else
          lua_file:write(", ")
          d_lua_file:write(", ")
        end
        lua_file:write(c_type_str(t, name))
        d_lua_file:write(name, ": ", get_type(t))
      end
      lua_file:write(");\n")
      d_lua_file:write("): ", get_type(ftype.t), "\n")
    end
    was_toplevel_function = action.tag == "Declaration" and action.type and action.type.tag == "Function" and action
        .name
  end
  lua_file:write("]]\n\n---@type ", namespace_name,
    "\n---@diagnostic disable-next-line: assign-type-mismatch\nlocal lib = ffi.load('", libname, "')\nreturn lib\n")
  lua_file:close()
  d_lua_file:close()
end

parse_and_emit("dep/tree_sitter/temp_c_header.h", "dep/tree_sitter/ffi", "tree-sitter", "tree_sitter_ffi")
