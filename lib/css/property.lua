if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- Construct a @property rule.
-- name: CssVar name string (must start with --)
-- opts: { syntax: string, inherits: boolean, initial_value: string? }
-- Returns a table with _type = "property"
--: (name: string, opts: { syntax: unknown, inherits: unknown, initial_value: unknown | nil }) -> { _type: string, name: string, syntax: unknown, inherits: unknown, initial_value: unknown }
function M.property_rule(name, opts)
  if name:sub(1, 2) ~= "--" then
    error("@property name must start with --: " .. name)
  end
  if opts.syntax == nil then error("@property requires syntax field") end
  if opts.inherits == nil then error("@property requires inherits field") end
  return {
    _type         = "property",
    name          = name,
    syntax        = opts.syntax,
    inherits      = opts.inherits,
    initial_value = opts.initial_value,
  }
end

-- Render a @property rule to a CSS string.
--: (rule: { name: string, syntax: unknown, inherits: unknown, initial_value: unknown | nil }) -> string
function M.render_property(rule)
  local parts = { "@property " .. rule.name .. " {" }
  parts[#parts+1] = '  syntax: "' .. tostring(rule.syntax) .. '";'
  parts[#parts+1] = "  inherits: " .. (rule.inherits and "true" or "false") .. ";"
  if rule.initial_value ~= nil then
    parts[#parts+1] = "  initial-value: " .. tostring(rule.initial_value) .. ";"
  end
  parts[#parts+1] = "}"
  return table.concat(parts, "\n")
end

-- Scope analysis: given a stylesheet (flat item list), return a report table:
--   report[var_name] = { declared = { ... rule selectors ... }, referenced = { ... rule selectors ... } }
-- "declared" = rule has var_name as a property key
-- "referenced" = rule has a value containing "var(var_name)"
-- Also reports @property registrations under report[var_name].registered = true
--: (sheet: { items: { [integer]: unknown }, ... }, var_names: { [integer]: string }) -> { [string]: unknown }
function M.analyze(sheet, var_names)
  local watched = {}
  for _, name in ipairs(var_names) do watched[name] = true end

  local report = {}
  for _, name in ipairs(var_names) do
    report[name] = { declared = {}, referenced = {}, registered = false }
  end

  local function analyze_items(items)
    for _, item in ipairs(items) do
      if item._type == "rule" then
        local sel_str = type(item.selector) == "table" and item.selector._str or tostring(item.selector)
        for k, v in pairs(item.decls) do
          local key_str = type(k) == "string" and k or tostring(k)
          if watched[key_str] then
            local r = report[key_str]
            r.declared[#r.declared+1] = sel_str
          end
          local val_str = tostring(v)
          for name in pairs(watched) do
            local pat, _ = name:gsub("%-", "%%-")
            if val_str:find("var%(" .. pat .. "%)", 1) then
              local r = report[name]
              r.referenced[#r.referenced+1] = sel_str
            end
          end
        end
      elseif item._type == "media" then
        analyze_items(item.items)
      elseif item._type == "property" then
        if watched[item.name] then
          report[item.name].registered = true
        end
      end
    end
  end

  analyze_items(sheet.items)
  return report
end

return M
