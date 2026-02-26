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

local infer_expr, infer_stmt, infer_block

local ExprRule = {}
local StmtRule = {}

ExprRule.Literal = function(ctx, node)
  local v = node.value
  if v == nil then return T.NIL() end
  if v == true then return T.literal("boolean", true) end
  if v == false then return T.literal("boolean", false) end
  if type(v) == "number" then
    if v % 1 == 0 then
      return T.literal("number", v)
    end
    return T.literal("number", v)
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

  -- Special: setmetatable(t, mt)
  if node.callee.kind == "Identifier" and node.callee.name == "setmetatable" then
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

  return T.ANY()
end

ExprRule.MemberExpression = function(ctx, node)
  local obj_ty = infer_expr(ctx, node.object)
  obj_ty = T.resolve(obj_ty)

  if node.computed then
    -- obj[expr]
    local key_ty = infer_expr(ctx, node.property)
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
  -- Don't try to resolve external modules — return any
  return nil
end

function infer_function(ctx, params, body, has_vararg, line)
  local child_scope = env.child(ctx.scope)
  local param_types = {}

  -- Check for annotation on this line
  local ann = ctx.ann_map[line]
  local ann_fn = nil
  if ann and ann.kind == "type_annotation" and ann.type and ann.type.tag == "function" then
    ann_fn = ann.type
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

-- Infer multiple expressions, returning a list of types
local function infer_expr_list(ctx, exprs)
  local result = {}
  for i = 1, #exprs do
    result[i] = infer_expr(ctx, exprs[i])
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
      local ann_ty = ann.type
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
      local ty = rhs_types[i] or T.NIL()
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
  if ann and ann.kind == "type_annotation" and ann.type and ann.type.tag == "function" then
    fn_ty = ann.type
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

StmtRule.IfStatement = function(ctx, node)
  for i = 1, #node.tests do
    infer_expr(ctx, node.tests[i])
    local child = env.child(ctx.scope)
    local saved = ctx.scope
    ctx.scope = child
    infer_block(ctx, node.cons[i])
    ctx.scope = saved
  end
  if node.alternate then
    local child = env.child(ctx.scope)
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

local function process_type_decls(ctx, ann_map)
  for line, ann in pairs(ann_map) do
    if ann.kind == "type_decl" then
      env.bind_type(ctx.scope, ann.name, ann.type)
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
