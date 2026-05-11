if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- feature_flags: feature toggle system with rollout, rules, variants, and overrides.
-- Pure Lua — no external dependencies.

local M = {}
M._tier = "pure"

local bit = require("bit")

--:: Registry = { _flags: { [string]: any }, _overrides: { [string]: any }, _listeners: { [integer]: any }, ... }

-- Deterministic hash of a string → float in [0, 1).
-- Uses a simple FNV-1a variant, good enough for consistent rollout.
--: (string) -> number
local function hash_to_float(s)
  local h = math.floor(2166136261)  -- FNV offset basis (uint32)
  for i = 1, #s do
    h = bit.bxor(h, string.byte(s, i))
    -- FNV prime multiply, keep in 32-bit range via modulo
    -- LuaJIT numbers are doubles; we stay in integer range with modulo
    h = math.floor((h * 16777619) % 4294967296)
  end
  return h / 4294967296
end

-- Registry prototype
local Registry = {}
Registry.__index = Registry

-- Create a new flag registry.
--: () -> Registry
function M.new()
  local self = setmetatable({ _flags = {}, _overrides = {}, _listeners = {} }, Registry) --[[: unknown]] --[[:! Registry]]
  return self
end

-- Restore a registry from a snapshot table.
function M.from_snapshot(snapshot)
  local self = M.new()
  for name, entry in pairs(snapshot.flags or {}) do
    -- Reconstruct flag def from snapshot (rules/variants not serialisable; omit)
    self._flags[name] = {
      default      = entry.default,
      description  = entry.description,
      rollout      = entry.rollout,
      rules        = nil,
      variants     = entry.variants,
      default_variant = entry.default_variant,
      value        = entry.value,
    }
  end
  for name, v in pairs(snapshot.overrides or {}) do
    self._overrides[name] = v
  end
  return self
end

-- Internal: emit a change event.
--: (Registry, string, unknown, unknown) -> nil
local function emit(self, name, old_val, new_val)
  local self_ = self --[[:! Registry]]
  for _, listener in ipairs(self_._listeners) do
    local l = listener --[[:! { event: string, fn: (string, unknown, unknown) -> unknown }]]
    if l.event == "change" then
      l.fn(name, old_val, new_val)
    end
  end
end

-- Internal: get current effective boolean value for a flag, given optional ctx.
-- Returns value, err.
--: (Registry, string, { user_id: unknown, ... } | nil) -> (unknown, string | nil)
local function eval_flag(self, name, ctx)
  local self_ = self --[[:! Registry]]
  local flag = self_._flags[name]
  if not flag then
    return nil, "unknown flag: " .. tostring(name)
  end

  -- Override takes highest precedence.
  if self_._overrides[name] ~= nil then
    return self_._overrides[name], nil
  end

  -- Programmatic set takes next precedence.
  if flag.value ~= nil then
    return flag.value, nil
  end

  -- Rules evaluation (first match wins).
  if flag.rules and ctx then
    for _, rule in ipairs(flag.rules) do
      if rule.condition(ctx) then
        return rule.value, nil
      end
    end
  end

  -- Rollout (percentage-based, requires ctx.user_id).
  if flag.rollout and ctx and ctx.user_id then
    local h = hash_to_float(tostring(ctx.user_id) .. name)
    return h < flag.rollout, nil
  end

  -- Default.
  return flag.default, nil
end

-- Define a flag.
-- def: { default, description, rollout, rules, variants, default_variant }
function Registry:define(name, def)
  self._flags[name] = {
    default         = def.default ~= nil and def.default or false,
    description     = def.description or "",
    rollout         = def.rollout,
    rules           = def.rules,
    variants        = def.variants,
    default_variant = def.default_variant,
    value           = nil,
  }
end

-- Boolean check (no user context).
function Registry:enabled(name)
  return eval_flag(self, name, nil)
end

-- Boolean check with user context (rollout + rules).
function Registry:enabled_for(name, ctx)
  return eval_flag(self, name, ctx)
end

-- Variant selection for A/B testing flags.
-- Returns variant name, or nil+err.
function Registry:variant(name, ctx)
  local flag = self._flags[name]
  if not flag then
    return nil, "unknown flag: " .. tostring(name)
  end

  -- Override: if override is a string, treat as variant name.
  if self._overrides[name] ~= nil then
    local ov = self._overrides[name]
    if type(ov) == "string" then return ov, nil end
    -- boolean override: true → default_variant, false → nil
    if ov then return flag.default_variant, nil end
    return nil, nil
  end

  -- Programmatic set (string value = explicit variant).
  if type(flag.value) == "string" then
    return flag.value, nil
  end

  if not flag.variants then
    return nil, "flag has no variants: " .. name
  end

  -- Weighted selection using consistent hash.
  local user_id = ctx and ctx.user_id or ""
  local h = hash_to_float(tostring(user_id) .. tostring(name) .. ":variant") --: number
  local total = 0
  for _, v in ipairs(flag.variants) do
    total = total + (v.weight or 1)
  end
  local target = h * total
  local cumulative = 0
  for _, v in ipairs(flag.variants) do
    cumulative = cumulative + (v.weight or 1)
    if target < cumulative then
      return v.name, nil
    end
  end
  -- Fallback (rounding edge case): return last variant.
  return flag.variants[#flag.variants].name, nil
end

-- Programmatic enable.
function Registry:enable(name)
  local flag = self._flags[name]
  if not flag then return nil, "unknown flag: " .. tostring(name) end
  local old = flag.value
  flag.value = true
  if old ~= true then emit(self, name, old, true) end
  return true, nil
end

-- Programmatic disable.
function Registry:disable(name)
  local flag = self._flags[name]
  if not flag then return nil, "unknown flag: " .. tostring(name) end
  local old = flag.value
  flag.value = false
  if old ~= false then emit(self, name, old, false) end
  return true, nil
end

-- Programmatic set (boolean or string for variant).
function Registry:set(name, value)
  local flag = self._flags[name]
  if not flag then return nil, "unknown flag: " .. tostring(name) end
  local old = flag.value
  flag.value = value
  if old ~= value then emit(self, name, old, value) end
  return true, nil
end

-- Bulk load from config table.
-- Values: boolean → sets flag.value; string → sets as variant value.
function Registry:load(config)
  for name, value in pairs(config) do
    if self._flags[name] then
      local old = self._flags[name].value
      self._flags[name].value = value
      if old ~= value then emit(self, name, old, value) end
    end
  end
end

-- Force a value regardless of rules/rollout (for testing).
function Registry:override(name, value)
  if not self._flags[name] then
    return nil, "unknown flag: " .. tostring(name)
  end
  local old = self._overrides[name]
  self._overrides[name] = value
  if old ~= value then emit(self, name, old, value) end
  return true, nil
end

-- Clear a testing override.
function Registry:clear_override(name)
  if not self._flags[name] then
    return nil, "unknown flag: " .. tostring(name)
  end
  local old = self._overrides[name]
  self._overrides[name] = nil
  if old ~= nil then emit(self, name, old, nil) end
  return true, nil
end

-- Export current state as a serialisable table.
-- Note: rules (functions) are not included — they must be re-registered.
function Registry:snapshot()
  local flags = {}
  for name, flag in pairs(self._flags) do
    flags[name] = {
      default         = flag.default,
      description     = flag.description,
      rollout         = flag.rollout,
      variants        = flag.variants,
      default_variant = flag.default_variant,
      value           = flag.value,
    }
  end
  local overrides = {}
  for name, v in pairs(self._overrides) do
    overrides[name] = v
  end
  return { flags = flags, overrides = overrides }
end

-- Return a table mapping flag name → full flag info (def + current value).
function Registry:all()
  local result = {}
  for name, flag in pairs(self._flags) do
    result[name] = {
      default         = flag.default,
      description     = flag.description,
      rollout         = flag.rollout,
      variants        = flag.variants,
      default_variant = flag.default_variant,
      value           = flag.value,
      override        = self._overrides[name],
    }
  end
  return result
end

-- Return array of flag names that currently evaluate to true (no ctx).
function Registry:enabled_flags()
  local result = {}
  for name in pairs(self._flags) do
    local v = eval_flag(self, name, nil)
    if v then
      result[#result + 1] = name
    end
  end
  table.sort(result)
  return result
end

-- Register an event listener.
-- Currently only "change" is supported.
function Registry:on(event, fn)
  self._listeners[#self._listeners + 1] = { event = event, fn = fn }
end

return M
