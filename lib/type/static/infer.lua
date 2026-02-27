-- lib/type/static/infer.lua
-- AST walker: constraint generation + solving.
-- Dispatch table on AST node.kind.

local types = require("lib.type.static.types")
local env = require("lib.type.static.env")
local unify = require("lib.type.static.unify")
local annotations = require("lib.type.static.annotations")

local T = types

local M = {}

---------------------------------------------------------------------------
-- Inference context
---------------------------------------------------------------------------

local function new_ctx(err_ctx, source, filename, ann_map, scope)
  return {
    err = err_ctx,
    source = source,
    filename = filename,
    ann_map = ann_map or {},
    scope = scope,
    return_types = {},    -- stack of return type collectors
    module_types = {},    -- cache: module path -> type
  }
end

local function push_return_collector(ctx)
  ctx.return_types[#ctx.return_types + 1] = {}
end

local function pop_return_collector(ctx)
  local collector = ctx.return_types[#ctx.return_types]
  ctx.return_types[#ctx.return_types] = nil
  return collector
end

local function add_return(ctx, ret_types)
  local collector = ctx.return_types[#ctx.return_types]
  if collector then
    collector[#collector + 1] = ret_types
  end
end

local function report(ctx, line, msg)
  local errors = require("lib.type.static.errors")
  errors.error(ctx.err, ctx.filename, line, msg)
end

---------------------------------------------------------------------------
-- Expression inference
---------------------------------------------------------------------------

local infer_expr, infer_stmt, infer_block, resolve_annotation_type

local ExprRule = {}
local StmtRule = {}

ExprRule.Literal = function(ctx, node)
  local v = node.value
  if v == nil then return T.NIL() end
  if v == true then return T.literal("boolean", true) end
  if v == false then return T.literal("boolean", false) end
  if type(v) == "number" then
    if v % 1 == 0 then
      return T.INTEGER()
    end
    return T.NUMBER()
  end
  if type(v) == "string" then
    return T.literal("string", v)
  end
  return T.ANY()
end

ExprRule.Identifier = function(ctx, node)
  local ty = env.lookup(ctx.scope, node.name)
  if ty then
    return env.instantiate(ty, ctx.scope.level)
  end
  -- Unknown identifier — gradual typing: return any
  return T.ANY()
end

ExprRule.Vararg = function(ctx, node)
  local ty = env.lookup(ctx.scope, "...")
  if ty then return ty end
  return T.ANY()
end

ExprRule.ExpressionValue = function(ctx, node)
  -- Bracketed expression — truncate to single value
  return infer_expr(ctx, node.value)
end

ExprRule.BinaryExpression = function(ctx, node)
  local left = infer_expr(ctx, node.left)
  local right = infer_expr(ctx, node.right)
  local op = node.operator

  -- Arithmetic operators
  if op == "+" or op == "-" or op == "*" or op == "/" or op == "%" or op == "^" then
    local left_r = T.resolve(left)
    local right_r = T.resolve(right)
    -- Check operands are numeric
    if left_r.tag ~= "any" and left_r.tag ~= "number" and left_r.tag ~= "integer"
      and not (left_r.tag == "literal" and left_r.kind == "number")
      and left_r.tag ~= "var" then
      report(ctx, node.line, "cannot perform arithmetic on '" .. T.display(left) .. "'")
    end
    if right_r.tag ~= "any" and right_r.tag ~= "number" and right_r.tag ~= "integer"
      and not (right_r.tag == "literal" and right_r.kind == "number")
      and right_r.tag ~= "var" then
      report(ctx, node.line, "cannot perform arithmetic on '" .. T.display(right) .. "'")
    end
    -- Division and exponentiation always produce number
    if op == "/" or op == "^" then
      return T.NUMBER()
    end
    -- For +, -, *, %: if both operands are integer-compatible, result is integer
    local function is_int_compat(r)
      return r.tag == "integer" or (r.tag == "literal" and r.kind == "number" and r.value % 1 == 0)
    end
    if is_int_compat(left_r) and is_int_compat(right_r) then
      return T.INTEGER()
    end
    return T.NUMBER()
  end

  -- Comparison operators
  if op == "==" or op == "~=" then
    return T.BOOLEAN()
  end
  if op == "<" or op == ">" or op == "<=" or op == ">=" then
    return T.BOOLEAN()
  end

  return T.ANY()
end

ExprRule.LogicalExpression = function(ctx, node)
  local left = infer_expr(ctx, node.left)
  local right = infer_expr(ctx, node.right)
  if node.operator == "and" then
    -- Type is right if left is truthy
    return T.union({ T.NIL(), right })
  end
  if node.operator == "or" then
    return T.union({ left, right })
  end
  return T.ANY()
end

ExprRule.UnaryExpression = function(ctx, node)
  local arg = infer_expr(ctx, node.argument)
  if node.operator == "not" then
    return T.BOOLEAN()
  end
  if node.operator == "-" then
    return T.NUMBER()
  end
  if node.operator == "#" then
    return T.INTEGER()
  end
  return T.ANY()
end

ExprRule.ConcatenateExpression = function(ctx, node)
  for _, term in ipairs(node.terms) do
    local ty = infer_expr(ctx, term)
    local r = T.resolve(ty)
    if r.tag ~= "any" and r.tag ~= "string" and r.tag ~= "number" and r.tag ~= "integer"
      and not (r.tag == "literal" and (r.kind == "string" or r.kind == "number"))
      and r.tag ~= "var" then
      report(ctx, node.line, "cannot concatenate '" .. T.display(ty) .. "'")
    end
  end
  return T.STRING()
end

ExprRule.Table = function(ctx, node)
  local fields = {}
  local indexers = {}
  local arr_idx = 0

  for _, kv in ipairs(node.keyvals) do
    local val = kv[1]
    local key = kv[2]
    local val_ty = infer_expr(ctx, val)

    if key then
      if key.kind == "Literal" and type(key.value) == "string" then
        fields[key.value] = { type = val_ty, optional = false }
      elseif key.kind == "Identifier" then
        -- { [expr] = val } with computed key
        infer_expr(ctx, key)
      else
        infer_expr(ctx, key)
      end
    else
      -- Sequential array entry
      arr_idx = arr_idx + 1
      -- Could track as array indexer
    end
  end

  -- If there were sequential entries, add number indexer
  if arr_idx > 0 then
    -- Collect all array element types (simplified: use any)
    local elem_types = {}
    local idx = 0
    for _, kv in ipairs(node.keyvals) do
      if not kv[2] then
        idx = idx + 1
        elem_types[idx] = infer_expr(ctx, kv[1])
      end
    end
    -- Union of all element types
    if #elem_types > 0 then
      indexers[#indexers + 1] = { key = T.NUMBER(), value = T.union(elem_types) }
    end
  end

  return T.table(fields, indexers)
end

ExprRule.FunctionExpression = function(ctx, node)
  return infer_function(ctx, node.params, node.body, node.vararg, node.firstline)
end

ExprRule.CallExpression = function(ctx, node)
  local callee_ty = infer_expr(ctx, node.callee)
  local arg_types = {}
  for i = 1, #node.arguments do
    arg_types[i] = infer_expr(ctx, node.arguments[i])
  end

  -- Special: require("...") calls
  if node.callee.kind == "Identifier" and node.callee.name == "require" then
    if #node.arguments == 1 and node.arguments[1].kind == "Literal"
      and type(node.arguments[1].value) == "string" then
      local mod_path = node.arguments[1].value
      local mod_ty = resolve_require(ctx, mod_path)
      if mod_ty then return mod_ty end
    end
    return T.ANY()
  end

  -- Special: assert(x) narrows x to truthy in continuation
  if node.callee.kind == "Identifier" and node.callee.name == "assert" then
    if #node.arguments >= 1 and node.arguments[1].kind == "Identifier" then
      local var_name = node.arguments[1].name
      local var_ty = env.lookup(ctx.scope, var_name)
      if var_ty then
        var_ty = T.resolve(var_ty)
        local narrowed = T.subtract(var_ty, T.NIL())
        narrowed = T.subtract(narrowed, T.literal("boolean", false))
        env.bind(ctx.scope, var_name, narrowed)
      end
    end
    if #arg_types >= 1 then return arg_types[1] end
    return T.ANY()
  end

  -- Special: setmetatable(t, mt) — merge __index fields into t
  if node.callee.kind == "Identifier" and node.callee.name == "setmetatable" then
    if #arg_types >= 2 then
      local t_ty = T.resolve(arg_types[1])
      local mt_ty = T.resolve(arg_types[2])
      if t_ty.tag == "table" and mt_ty.tag == "table" then
        -- Look for __index field in metatable
        local index_field = mt_ty.fields["__index"]
        if index_field then
          local index_ty = T.resolve(index_field.type)
          if index_ty.tag == "table" then
            -- Merge __index fields into t (t's own fields take priority)
            for name, f in pairs(index_ty.fields) do
              if not t_ty.fields[name] then
                t_ty.fields[name] = { type = f.type, optional = f.optional }
              end
            end
          end
        end
        -- Look for __call metamethod
        local call_field = mt_ty.fields["__call"]
        if call_field then
          local call_ty = T.resolve(call_field.type)
          if call_ty.tag == "function" then
            t_ty._call = call_ty
          end
        end
      end
      return arg_types[1]
    end
    if #arg_types >= 1 then return arg_types[1] end
    return T.ANY()
  end

  callee_ty = T.resolve(callee_ty)

  if callee_ty.tag == "any" then return T.ANY() end

  if callee_ty.tag == "function" then
    -- Check argument types
    check_call_args(ctx, callee_ty, arg_types, node.line)
    -- Return first return type
    if #callee_ty.returns > 0 then
      return callee_ty.returns[1]
    end
    return T.NIL()
  end

  -- Union of functions: overload resolution
  if callee_ty.tag == "union" then
    local best_fn = nil
    local best_score = math.huge
    local ambiguous = false
    for i = 1, #callee_ty.types do
      local member = T.resolve(callee_ty.types[i])
      if member.tag == "function" then
        local total_score = 0
        local all_ok = true
        for j = 1, #member.params do
          local actual = arg_types[j]
          if actual then
            local score, ok = unify.try_unify(actual, member.params[j])
            if ok then
              total_score = total_score + score
            else
              all_ok = false
              break
            end
          end
        end
        if all_ok then
          if total_score < best_score then
            best_fn = member
            best_score = total_score
            ambiguous = false
          elseif total_score == best_score then
            ambiguous = true
          end
        end
      end
    end
    if best_fn then
      if ambiguous then
        report(ctx, node.line, "ambiguous overload resolution")
      end
      check_call_args(ctx, best_fn, arg_types, node.line)
      if #best_fn.returns > 0 then return best_fn.returns[1] end
      return T.NIL()
    end
    report(ctx, node.line, "no matching overload")
    return T.ANY()
  end

  -- Table with __call metamethod
  if callee_ty.tag == "table" and callee_ty._call then
    local call_fn = T.resolve(callee_ty._call)
    if call_fn.tag == "function" then
      -- __call first param is self, skip it
      local method_params = {}
      for i = 2, #call_fn.params do
        method_params[#method_params + 1] = call_fn.params[i]
      end
      check_call_args(ctx, T.func(method_params, call_fn.returns, call_fn.vararg), arg_types, node.line)
      if #call_fn.returns > 0 then return call_fn.returns[1] end
      return T.NIL()
    end
  end

  if callee_ty.tag == "var" then
    -- Constrain the var to be a function
    local ret_var = T.typevar(ctx.scope.level)
    local fn_ty = T.func(arg_types, { ret_var })
    unify.unify(callee_ty, fn_ty)
    return ret_var
  end

  return T.ANY()
end

ExprRule.SendExpression = function(ctx, node)
  local recv_ty = infer_expr(ctx, node.receiver)
  local arg_types = {}
  for i = 1, #node.arguments do
    arg_types[i] = infer_expr(ctx, node.arguments[i])
  end

  recv_ty = T.resolve(recv_ty)
  local method_name = node.method.name

  -- Look up method on receiver
  if recv_ty.tag == "table" then
    local f = recv_ty.fields[method_name]
    if f then
      local ft = T.resolve(f.type)
      if ft.tag == "function" then
        -- Method call: first param is self, skip it for arg checking
        local method_params = {}
        for i = 2, #ft.params do
          method_params[#method_params + 1] = ft.params[i]
        end
        check_call_args(ctx, T.func(method_params, ft.returns, ft.vararg), arg_types, node.line)
        if #ft.returns > 0 then return ft.returns[1] end
        return T.NIL()
      end
    end
  end

  -- String method resolution: s:method(...) looks up string.method
  if recv_ty.tag == "string" or (recv_ty.tag == "literal" and recv_ty.kind == "string") then
    local str_ty = env.lookup(ctx.scope, "string")
    if str_ty then
      str_ty = T.resolve(str_ty)
      if str_ty.tag == "table" then
        local f = str_ty.fields[method_name]
        if f then
          local ft = T.resolve(f.type)
          if ft.tag == "function" then
            -- Method call: first param is self (string), skip it
            local method_params = {}
            for i = 2, #ft.params do
              method_params[#method_params + 1] = ft.params[i]
            end
            check_call_args(ctx, T.func(method_params, ft.returns, ft.vararg), arg_types, node.line)
            if #ft.returns > 0 then return ft.returns[1] end
            return T.NIL()
          end
        end
      end
    end
  end

  return T.ANY()
end

ExprRule.MemberExpression = function(ctx, node)
  local obj_ty = infer_expr(ctx, node.object)
  obj_ty = T.resolve(obj_ty)

  if node.computed then
    -- obj[expr]
    local key_ty = infer_expr(ctx, node.property)
    if obj_ty.tag == "tuple" then
      -- Tuple indexing with literal number
      local key_r = T.resolve(key_ty)
      if key_r.tag == "literal" and key_r.kind == "number" then
        local idx = key_r.value
        if idx >= 1 and idx <= #obj_ty.elements then
          return obj_ty.elements[idx]
        end
        report(ctx, node.line, "tuple index " .. idx .. " out of range (tuple has " .. #obj_ty.elements .. " elements)")
        return T.NEVER()
      end
      return T.ANY()
    end
    if obj_ty.tag == "table" then
      -- Check indexers
      for i = 1, #obj_ty.indexers do
        local idx = obj_ty.indexers[i]
        local ok = unify.unify(key_ty, idx.key)
        if ok then return idx.value end
      end
    end
    return T.ANY()
  else
    -- obj.name
    local name = node.property.name
    if obj_ty.tag == "table" then
      local f = obj_ty.fields[name]
      if f then return f.type end
      -- Check string indexers
      for i = 1, #obj_ty.indexers do
        local idx = obj_ty.indexers[i]
        if idx.key.tag == "string" then return idx.value end
      end
      -- Open table with row var: return any
      if obj_ty.row then return T.ANY() end
    end
    if obj_ty.tag == "any" then return T.ANY() end
    if obj_ty.tag == "var" then
      -- Constrain to have this field
      local field_var = T.typevar(ctx.scope.level)
      local tbl = T.table({ [name] = { type = field_var, optional = false } }, {}, T.rowvar(ctx.scope.level))
      unify.unify(obj_ty, tbl)
      return field_var
    end
    return T.ANY()
  end
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

function check_call_args(ctx, fn_ty, arg_types, line)
  for i = 1, #fn_ty.params do
    local expected = fn_ty.params[i]
    local actual = arg_types[i]
    if actual then
      local ok, err = unify.unify(actual, expected)
      if not ok then
        report(ctx, line, "argument " .. i .. ": cannot pass '" .. T.display(actual)
          .. "' where '" .. T.display(expected) .. "' expected")
      end
    end
    -- Missing args are nil — only error if param is not optional
  end
end

function resolve_require(ctx, mod_path)
  if ctx.module_types[mod_path] then
    return ctx.module_types[mod_path]
  end

  -- Prevent circular requires
  if ctx.resolving and ctx.resolving[mod_path] then
    report(ctx, 0, "warning: circular require '" .. mod_path .. "'")
    ctx.module_types[mod_path] = T.ANY()
    return T.ANY()
  end

  -- Try to resolve the module file
  local resolver = require("lib.type.static.resolve")
  local lua_path, decl_path = resolver.resolve(mod_path)
  local target = decl_path or lua_path
  if not target then return nil end

  -- Read and parse the target file
  local f = io.open(target, "r")
  if not f then return nil end
  local source = f:read("*a")
  f:close()

  -- Mark as resolving (circular detection)
  if not ctx.resolving then ctx.resolving = {} end
  ctx.resolving[mod_path] = true

  -- Typecheck the module
  local checker = require("lib.type.static")
  local err_ctx = checker.check_string(source, target)

  ctx.resolving[mod_path] = nil

  -- For now, return any — full module return type tracking is Phase 5+
  ctx.module_types[mod_path] = T.ANY()
  return T.ANY()
end

function infer_function(ctx, params, body, has_vararg, line)
  local child_scope = env.child(ctx.scope)
  local param_types = {}

  -- Check for annotation on this line
  local ann = ctx.ann_map[line]
  local ann_fn = nil
  if ann and ann.kind == "type_annotation" and ann.type then
    local resolved = resolve_annotation_type(ctx, ann.type)
    if resolved and resolved.tag == "function" then
      ann_fn = resolved
    end
  end

  for i = 1, #params do
    local p = params[i]
    if p.kind == "Vararg" then
      local va_ty = (ann_fn and ann_fn.vararg) or T.ANY()
      env.bind(child_scope, "...", va_ty)
    else
      local p_ty
      if ann_fn and ann_fn.params[i] then
        p_ty = ann_fn.params[i]
      else
        p_ty = T.typevar(child_scope.level)
      end
      param_types[#param_types + 1] = p_ty
      env.bind(child_scope, p.name, p_ty)
    end
  end

  if has_vararg and not env.lookup(child_scope, "...") then
    env.bind(child_scope, "...", T.ANY())
  end

  push_return_collector(ctx)
  local saved_scope = ctx.scope
  ctx.scope = child_scope
  infer_block(ctx, body)
  ctx.scope = saved_scope

  local collected = pop_return_collector(ctx)
  local return_types
  if ann_fn then
    return_types = ann_fn.returns
  elseif #collected > 0 then
    -- Use first return's types (simplified)
    return_types = collected[1]
  else
    return_types = {}
  end

  local vararg_ty = nil
  if has_vararg then
    vararg_ty = (ann_fn and ann_fn.vararg) or T.ANY()
  end

  return T.func(param_types, return_types, vararg_ty)
end

---------------------------------------------------------------------------
-- Statement inference
---------------------------------------------------------------------------

function infer_expr(ctx, node)
  if not node then return T.NIL() end
  local rule = ExprRule[node.kind]
  if rule then return rule(ctx, node) end
  return T.ANY()
end

-- Get the full return type list from a call/send node's resolved callee.
-- This does NOT perform inference or argument checking — call infer_expr first.
local function get_callee_returns(ctx, node)
  if node.kind == "CallExpression" then
    -- Skip require() — returns are handled specially
    if node.callee.kind == "Identifier" and node.callee.name == "require" then
      return nil
    end
    -- Re-resolve the callee type (cheap: just a lookup)
    local callee_ty = infer_expr(ctx, node.callee)
    callee_ty = T.resolve(callee_ty)
    if callee_ty.tag == "function" and #callee_ty.returns > 1 then
      return callee_ty.returns
    end
  elseif node.kind == "SendExpression" then
    local recv_ty = infer_expr(ctx, node.receiver)
    recv_ty = T.resolve(recv_ty)
    local method_name = node.method.name
    local ft
    if recv_ty.tag == "table" then
      local f = recv_ty.fields[method_name]
      if f then ft = T.resolve(f.type) end
    end
    if not ft and (recv_ty.tag == "string" or (recv_ty.tag == "literal" and recv_ty.kind == "string")) then
      local str_ty = env.lookup(ctx.scope, "string")
      if str_ty then
        str_ty = T.resolve(str_ty)
        if str_ty.tag == "table" then
          local f = str_ty.fields[method_name]
          if f then ft = T.resolve(f.type) end
        end
      end
    end
    if ft and ft.tag == "function" and #ft.returns > 1 then
      return ft.returns
    end
  end
  return nil
end

-- Infer multiple expressions, returning a list of types.
-- When the last expression is a call, expand its full return type list.
local function infer_expr_list(ctx, exprs)
  local result = {}
  for i = 1, #exprs do
    -- Always infer the expression (does full type checking)
    local ty = infer_expr(ctx, exprs[i])
    if i == #exprs and (exprs[i].kind == "CallExpression" or exprs[i].kind == "SendExpression") then
      -- Last expression is a call: try to expand multi-return
      local ret_types = get_callee_returns(ctx, exprs[i])
      if ret_types then
        for j = 1, #ret_types do
          result[#result + 1] = ret_types[j]
        end
      else
        result[#result + 1] = ty
      end
    else
      result[i] = ty
    end
  end
  return result
end

function infer_stmt(ctx, node)
  if not node then return end
  local rule = StmtRule[node.kind]
  if rule then
    rule(ctx, node)
  elseif ExprRule[node.kind] then
    -- Expression used as statement (e.g. function call)
    infer_expr(ctx, node)
  end
end

function infer_block(ctx, stmts)
  if not stmts then return end
  for i = 1, #stmts do
    infer_stmt(ctx, stmts[i])
  end
end

StmtRule.LocalDeclaration = function(ctx, node)
  local rhs_types = infer_expr_list(ctx, node.expressions)

  for i = 1, #node.names do
    local name = node.names[i].name
    local line = node.line

    -- Check for annotation
    local ann = ctx.ann_map[line]
    if ann and ann.kind == "type_annotation" then
      local ann_ty = resolve_annotation_type(ctx, ann.type)
      -- If there's a RHS, check compatibility
      if rhs_types[i] then
        local ok, err = unify.unify(rhs_types[i], ann_ty)
        if not ok then
          report(ctx, line, "type mismatch: '" .. T.display(rhs_types[i])
            .. "' is not assignable to '" .. T.display(ann_ty) .. "'")
        end
      end
      env.bind(ctx.scope, name, ann_ty)
    else
      local ty
      if rhs_types[i] then
        ty = T.widen(rhs_types[i])
      elseif i > #node.expressions then
        -- Forward-declared local with no RHS expression
        ty = T.typevar(ctx.scope.level)
      else
        ty = T.NIL()
      end
      env.bind(ctx.scope, name, ty)
    end
  end
end

StmtRule.AssignmentExpression = function(ctx, node)
  local rhs_types = infer_expr_list(ctx, node.right)

  for i = 1, #node.left do
    local lhs = node.left[i]
    local rhs_ty = rhs_types[i] or T.NIL()

    if lhs.kind == "Identifier" then
      local existing = env.lookup(ctx.scope, lhs.name)
      if existing then
        local ok, err = unify.unify(rhs_ty, existing)
        if not ok then
          report(ctx, node.line, "type mismatch: cannot assign '" .. T.display(rhs_ty)
            .. "' to '" .. T.display(existing) .. "'")
        end
      else
        -- Global assignment
        env.bind(ctx.scope, lhs.name, rhs_ty)
      end
    elseif lhs.kind == "MemberExpression" then
      -- obj.field = val or obj[key] = val
      local obj_ty = infer_expr(ctx, lhs.object)
      obj_ty = T.resolve(obj_ty)

      if not lhs.computed and obj_ty.tag == "table" then
        local name = lhs.property.name
        -- Add or update field on the table
        if not obj_ty.fields[name] then
          obj_ty.fields[name] = { type = rhs_ty, optional = false }
        else
          local ok, err = unify.unify(rhs_ty, obj_ty.fields[name].type)
          if not ok then
            report(ctx, node.line, "field '" .. name .. "': " .. (err or "type mismatch"))
          end
        end
      end
    end
  end
end

StmtRule.FunctionDeclaration = function(ctx, node)
  local fn_ty = infer_function(ctx, node.params, node.body, node.vararg, node.firstline or node.line)

  -- Check for preceding annotation
  local line = node.firstline or node.line
  local ann = ctx.ann_map[line]
  if ann and ann.kind == "type_annotation" and ann.type then
    local resolved = resolve_annotation_type(ctx, ann.type)
    if resolved and resolved.tag == "function" then
      fn_ty = resolved
    end
    -- Still infer the body for error checking but use annotated type
    -- (already done above via infer_function which checks ann_map)
  end

  local id = node.id
  if id.kind == "Identifier" then
    env.bind(ctx.scope, id.name, fn_ty)
  elseif id.kind == "MemberExpression" and not id.computed then
    -- mod.func = ...
    local obj_ty = infer_expr(ctx, id.object)
    obj_ty = T.resolve(obj_ty)
    if obj_ty.tag == "table" then
      obj_ty.fields[id.property.name] = { type = fn_ty, optional = false }
    end
  end
end

StmtRule.ReturnStatement = function(ctx, node)
  local ret_types = infer_expr_list(ctx, node.arguments)
  add_return(ctx, ret_types)
end

-- Extract narrowing info from a test expression.
-- Returns { var_name, positive_type, negative_type } or nil.
local function extract_narrowing(ctx, test)
  if not test then return nil end

  -- type(x) == "typename"
  if test.kind == "BinaryExpression" and (test.operator == "==" or test.operator == "~=") then
    local call, lit
    if test.left.kind == "CallExpression" and test.right.kind == "Literal" then
      call, lit = test.left, test.right
    elseif test.right.kind == "CallExpression" and test.left.kind == "Literal" then
      call, lit = test.right, test.left
    end
    if call and lit and type(lit.value) == "string"
      and call.callee.kind == "Identifier" and call.callee.name == "type"
      and #call.arguments == 1 and call.arguments[1].kind == "Identifier" then
      local var_name = call.arguments[1].name
      local type_str = lit.value
      local tag = T.typeof_map[type_str]
      if tag then
        local target
        if tag == "nil" then target = T.NIL()
        elseif tag == "boolean" then target = T.BOOLEAN()
        elseif tag == "number" then target = T.NUMBER()
        elseif tag == "string" then target = T.STRING()
        elseif tag == "table" then target = T.table({}, {})
        elseif tag == "function" then target = T.func({}, {})
        end
        local positive = test.operator == "=="
        return { name = var_name, target = target, positive = positive }
      end
    end

    -- x ~= nil / x == nil
    if test.left.kind == "Identifier" and test.right.kind == "Literal" and test.right.value == nil then
      local var_name = test.left.name
      -- then_removes_nil: true means then-branch has x ~= nil (removes nil)
      return { name = var_name, is_nil_check = true, then_removes_nil = (test.operator == "~=") }
    end
    if test.right.kind == "Identifier" and test.left.kind == "Literal" and test.left.value == nil then
      local var_name = test.right.name
      return { name = var_name, is_nil_check = true, then_removes_nil = (test.operator == "~=") }
    end
  end

  -- Simple truthiness: if x then (narrows out nil and false)
  if test.kind == "Identifier" then
    return { name = test.name, is_truthy = true }
  end

  -- not x
  if test.kind == "UnaryExpression" and test.operator == "not" and test.argument.kind == "Identifier" then
    return { name = test.argument.name, is_truthy = true, negated = true }
  end

  return nil
end

-- Apply narrowing to a child scope.
local function apply_narrowing(ctx, child_scope, narrowing, positive)
  if not narrowing then return end
  local var_ty = env.lookup(ctx.scope, narrowing.name)
  if not var_ty then return end
  var_ty = T.resolve(var_ty)

  if narrowing.is_truthy then
    local is_positive = positive
    if narrowing.negated then is_positive = not is_positive end
    if is_positive then
      -- Truthy branch: remove nil and false
      local narrowed = T.subtract(var_ty, T.NIL())
      narrowed = T.subtract(narrowed, T.literal("boolean", false))
      env.bind(child_scope, narrowing.name, narrowed)
    else
      -- Falsy branch: type is nil | false
      -- (we don't narrow to nil|false since it's not very useful)
    end
  elseif narrowing.is_nil_check then
    local removes_nil = (narrowing.then_removes_nil == positive)
    if removes_nil then
      -- x is not nil: subtract nil
      env.bind(child_scope, narrowing.name, T.subtract(var_ty, T.NIL()))
    else
      -- x is nil: narrow to nil
      env.bind(child_scope, narrowing.name, T.NIL())
    end
  elseif narrowing.target then
    if (narrowing.positive and positive) or (not narrowing.positive and not positive) then
      -- Positive match: narrow to target
      env.bind(child_scope, narrowing.name, T.narrow_to(var_ty, narrowing.target))
    else
      -- Negative match: subtract target
      env.bind(child_scope, narrowing.name, T.subtract(var_ty, narrowing.target))
    end
  end
end

StmtRule.IfStatement = function(ctx, node)
  -- Track narrowings for the else branch (accumulated negatives)
  local all_narrowings = {}

  for i = 1, #node.tests do
    infer_expr(ctx, node.tests[i])
    local narrowing = extract_narrowing(ctx, node.tests[i])
    all_narrowings[i] = narrowing

    local child = env.child(ctx.scope)
    apply_narrowing(ctx, child, narrowing, true)
    local saved = ctx.scope
    ctx.scope = child
    infer_block(ctx, node.cons[i])
    ctx.scope = saved
  end

  if node.alternate then
    local child = env.child(ctx.scope)
    -- Apply all negative narrowings for the else branch
    for i = 1, #all_narrowings do
      apply_narrowing(ctx, child, all_narrowings[i], false)
    end
    local saved = ctx.scope
    ctx.scope = child
    infer_block(ctx, node.alternate)
    ctx.scope = saved
  end
end

StmtRule.WhileStatement = function(ctx, node)
  infer_expr(ctx, node.test)
  local child = env.child(ctx.scope)
  local saved = ctx.scope
  ctx.scope = child
  infer_block(ctx, node.body)
  ctx.scope = saved
end

StmtRule.RepeatStatement = function(ctx, node)
  local child = env.child(ctx.scope)
  local saved = ctx.scope
  ctx.scope = child
  infer_block(ctx, node.body)
  infer_expr(ctx, node.test)
  ctx.scope = saved
end

StmtRule.ForStatement = function(ctx, node)
  infer_expr(ctx, node.init.value)
  infer_expr(ctx, node.last)
  if node.step then infer_expr(ctx, node.step) end
  local child = env.child(ctx.scope)
  env.bind(child, node.init.id.name, T.NUMBER())
  local saved = ctx.scope
  ctx.scope = child
  infer_block(ctx, node.body)
  ctx.scope = saved
end

StmtRule.ForInStatement = function(ctx, node)
  local iter_types = infer_expr_list(ctx, node.explist)
  local child = env.child(ctx.scope)
  for i = 1, #node.namelist.names do
    local name = node.namelist.names[i].name
    env.bind(child, name, T.ANY())
  end
  local saved = ctx.scope
  ctx.scope = child
  infer_block(ctx, node.body)
  ctx.scope = saved
end

StmtRule.DoStatement = function(ctx, node)
  local child = env.child(ctx.scope)
  local saved = ctx.scope
  ctx.scope = child
  infer_block(ctx, node.body)
  ctx.scope = saved
end

StmtRule.ExpressionStatement = function(ctx, node)
  infer_expr(ctx, node.expression)
end

StmtRule.Chunk = function(ctx, node)
  infer_block(ctx, node.body)
end

StmtRule.BreakStatement = function() end
StmtRule.LabelStatement = function() end
StmtRule.GotoStatement = function() end

---------------------------------------------------------------------------
-- Type declarations from annotations
---------------------------------------------------------------------------

-- Resolve named type references in an annotation type tree.
-- Walks the type, replacing { tag = "named" } nodes with their resolved aliases.
resolve_annotation_type = function(ctx, ty, seen)
  if not ty then return ty end
  seen = seen or {}
  local tag = ty.tag

  if tag == "named" then
    -- Resolve args first
    local resolved_args
    if ty.args and #ty.args > 0 then
      resolved_args = {}
      for i = 1, #ty.args do
        resolved_args[i] = resolve_annotation_type(ctx, ty.args[i], seen)
      end
    else
      resolved_args = ty.args
    end

    local resolved, err = env.resolve_named_type(ctx.scope, ty.name, resolved_args)
    if resolved then
      -- Guard against infinite recursion
      local key = ty.name .. "#" .. (resolved_args and #resolved_args or 0)
      if seen[key] then return T.ANY() end
      seen[key] = true
      return resolve_annotation_type(ctx, resolved, seen)
    end
    -- Unknown named type — leave as-is (will be caught later or is a type param)
    return { tag = "named", name = ty.name, args = resolved_args or {} }
  end

  if tag == "function" then
    local params = {}
    for i = 1, #ty.params do
      params[i] = resolve_annotation_type(ctx, ty.params[i], seen)
    end
    local returns = {}
    for i = 1, #ty.returns do
      returns[i] = resolve_annotation_type(ctx, ty.returns[i], seen)
    end
    local vararg = ty.vararg and resolve_annotation_type(ctx, ty.vararg, seen)
    return T.func(params, returns, vararg)
  end

  if tag == "table" then
    local fields = {}
    for name, f in pairs(ty.fields) do
      fields[name] = { type = resolve_annotation_type(ctx, f.type, seen), optional = f.optional }
    end
    local indexers = {}
    for i = 1, #ty.indexers do
      indexers[i] = {
        key = resolve_annotation_type(ctx, ty.indexers[i].key, seen),
        value = resolve_annotation_type(ctx, ty.indexers[i].value, seen),
      }
    end
    return T.table(fields, indexers, ty.row)
  end

  if tag == "union" then
    local ts = {}
    for i = 1, #ty.types do
      ts[i] = resolve_annotation_type(ctx, ty.types[i], seen)
    end
    return T.union(ts)
  end

  if tag == "intersection" then
    local ts = {}
    for i = 1, #ty.types do
      ts[i] = resolve_annotation_type(ctx, ty.types[i], seen)
    end
    return T.intersection(ts)
  end

  if tag == "type_call" then
    local callee = resolve_annotation_type(ctx, ty.callee, seen)
    local resolved_args = {}
    for i = 1, #ty.args do
      resolved_args[i] = resolve_annotation_type(ctx, ty.args[i], seen)
    end
    -- If callee is an intrinsic, evaluate it
    if callee and callee.tag == "intrinsic" then
      local intrinsics = require("lib.type.static.intrinsics")
      return intrinsics.evaluate(callee.name, resolved_args)
    end
    -- If callee is a named type (alias), try to resolve as type application
    if callee and callee.tag == "named" then
      local resolved, err = env.resolve_named_type(ctx.scope, callee.name, resolved_args)
      if resolved then
        return resolve_annotation_type(ctx, resolved, seen)
      end
    end
    return T.type_call(callee, resolved_args)
  end

  if tag == "match_type" then
    local param = resolve_annotation_type(ctx, ty.param, seen)
    local arms = {}
    for i = 1, #ty.arms do
      arms[i] = {
        pattern = resolve_annotation_type(ctx, ty.arms[i].pattern, seen),
        result = resolve_annotation_type(ctx, ty.arms[i].result, seen),
      }
    end
    local match_ty = T.match_type(param, arms)
    -- Try to evaluate immediately if param is concrete
    local matcher = require("lib.type.static.match")
    local result = matcher.evaluate(match_ty)
    if result.tag ~= "never" then return result end
    return match_ty
  end

  if tag == "tuple" then
    local elems = {}
    for i = 1, #ty.elements do
      elems[i] = resolve_annotation_type(ctx, ty.elements[i], seen)
    end
    return T.tuple(elems)
  end

  if tag == "spread" then
    return T.spread(resolve_annotation_type(ctx, ty.inner, seen))
  end

  return ty
end

-- Unique identity counter for nominal types
local nominal_id = 0

-- Two-pass type declaration processing:
-- Pass 1: register all type names (so forward references work)
-- Pass 2: resolve bodies (which may reference types from pass 1)
local function process_type_decls(ctx, ann_map)
  local decls = {}

  -- Pass 1: register names with unresolved bodies
  for line, ann in pairs(ann_map) do
    if ann.kind == "type_decl" then
      env.bind_type(ctx.scope, ann.name, { body = ann.type, params = ann.params, nominal = ann.nominal })
      decls[#decls + 1] = ann
    end
  end

  -- Pass 2: resolve bodies and create nominal wrappers
  for _, ann in ipairs(decls) do
    local alias = env.lookup_type(ctx.scope, ann.name)
    if alias and alias.body then
      alias.body = resolve_annotation_type(ctx, alias.body)
      -- Wrap in nominal type if newtype/opaque
      if alias.nominal then
        nominal_id = nominal_id + 1
        alias.body = T.nominal(ann.name, nominal_id, alias.body)
        alias.body.nominal_kind = alias.nominal -- "newtype" or "opaque"
        alias.body.module = ctx.filename
      end
    end
  end
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

function M.infer_chunk(ast_chunk, err_ctx, source, filename, scope, module_types)
  local ann_map = annotations.build_map(source)
  local ctx = new_ctx(err_ctx, source, filename, ann_map, scope)
  ctx.module_types = module_types or {}

  -- Process type declarations first
  process_type_decls(ctx, ann_map)

  -- Infer the chunk
  infer_block(ctx, ast_chunk.body)

  return ctx
end

return M
