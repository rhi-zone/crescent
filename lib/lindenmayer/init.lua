if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- lib/lindenmayer — Lindenmayer system (L-system) string rewriting with turtle graphics.
-- Pure Lua implementation. No external dependencies.
--
-- Supports:
--   - Deterministic string rules
--   - Stochastic rules {prob=p, rule=s}
--   - Context-sensitive rules "A<B" (B with left context A) / "B>C" (B with right context C)
--   - Parametric rules: "A(x)" → function(params) ... end
--   - Turtle graphics interpretation → drawing commands
--   - SVG output
--   - Common presets

local M = {}
M._tier = "pure"

-- ========================
-- INTERNAL: LCG RNG
-- ========================

local function make_rng(seed)
  local s = seed or 42
  return {
    next = function(self)
      s = (s * 1664525 + 1013904223) % 4294967296
      return s
    end,
    float = function(self)
      s = (s * 1664525 + 1013904223) % 4294967296
      return s / 4294967296
    end,
  }
end

-- ========================
-- RULE PARSING
-- ========================

-- Parse rule key string into a rule descriptor.
-- Returns one of:
--   { kind="simple",    sym=ch }
--   { kind="context_l", sym=ch, left=ch }   -- "A<B"
--   { kind="context_r", sym=ch, right=ch }  -- "B>C"
--   { kind="parametric", sym=ch, param=varname }  -- "A(x)"
local function parse_rule_key(key)
  -- parametric: single char followed by (identifier)
  local psym, pvar = key:match("^([A-Za-z])%(([^)]+)%)$")
  if psym then
    return { kind = "parametric", sym = psym, param = pvar }
  end
  -- context left: "A<B"
  local lctx, lsym = key:match("^([A-Za-z%+%-%[%]])%<([A-Za-z%+%-%[%]])$")
  if lctx and lsym then
    return { kind = "context_l", sym = lsym, left = lctx }
  end
  -- context right: "B>C"
  local rsym, rctx = key:match("^([A-Za-z%+%-%[%]])%>([A-Za-z%+%-%[%]])$")
  if rsym and rctx then
    return { kind = "context_r", sym = rsym, right = rctx }
  end
  -- simple single char
  if #key == 1 then
    return { kind = "simple", sym = key }
  end
  return nil, "invalid rule key: " .. tostring(key)
end

-- Parse and index all rules from spec.rules.
-- Returns:
--   plain_rules[sym]     = value (string | stochastic table | function)
--   context_rules[sym]   = array of {kind, left?, right?, value}
local function index_rules(spec_rules)
  local plain = {}
  local ctx = {}
  for key, value in pairs(spec_rules) do
    local desc, err = parse_rule_key(key)
    if not desc then
      return nil, nil, err
    end
    if desc.kind == "simple" then
      plain[desc.sym] = value
    elseif desc.kind == "parametric" then
      -- store parametric rules keyed by sym
      if not ctx[desc.sym] then ctx[desc.sym] = {} end
      ctx[desc.sym][#ctx[desc.sym] + 1] = { kind = "parametric", param = desc.param, value = value }
    else
      if not ctx[desc.sym] then ctx[desc.sym] = {} end
      ctx[desc.sym][#ctx[desc.sym] + 1] = { kind = desc.kind, left = desc.left, right = desc.right, value = value }
    end
  end
  return plain, ctx
end

-- ========================
-- STRING GENERATION
-- ========================

-- Try to match a parametric token at position i in string s.
-- Returns sym, params_table, end_pos  or  nil
local function match_parametric(s, i)
  local sym = s:sub(i, i)
  if not sym:match("[A-Za-z]") then return nil end
  if i + 1 > #s or s:sub(i + 1, i + 1) ~= "(" then return nil end
  local close = s:find(")", i + 2, true)
  if not close then return nil end
  local inner = s:sub(i + 2, close - 1)
  local params = {}
  for v in inner:gmatch("[^,]+") do
    params[#params + 1] = v
  end
  return sym, params, close
end

-- Apply rules once to a string, return new string.
local function apply_rules_once(s, plain, ctx_rules, rng)
  local parts = {}
  local i = 1
  local n = #s
  while i <= n do
    local ch = s:sub(i, i)
    local advanced = false

    -- Check parametric context rules first
    if ctx_rules[ch] then
      local sym, params, end_pos = match_parametric(s, i)
      if sym and params then
        for _, crule in ipairs(ctx_rules[sym]) do
          if crule.kind == "parametric" then
            local result = crule.value(params)
            if result ~= nil then
              parts[#parts + 1] = result
              i = end_pos + 1
              advanced = true
              break
            end
          end
        end
        if not advanced then
          -- parametric token but no rule matched; emit as-is
          parts[#parts + 1] = s:sub(i, end_pos)
          i = end_pos + 1
          advanced = true
        end
      end
    end

    if not advanced then
      -- Check context-sensitive rules
      local applied_ctx = false
      if ctx_rules[ch] then
        for _, crule in ipairs(ctx_rules[ch]) do
          local match = false
          if crule.kind == "context_l" then
            match = (i > 1 and s:sub(i - 1, i - 1) == crule.left)
          elseif crule.kind == "context_r" then
            match = (i < n and s:sub(i + 1, i + 1) == crule.right)
          end
          if match then
            local value = crule.value
            if type(value) == "string" then
              parts[#parts + 1] = value
            elseif type(value) == "function" then
              parts[#parts + 1] = value({})
            end
            applied_ctx = true
            break
          end
        end
      end

      if applied_ctx then
        i = i + 1
      else
        -- Apply plain rule
        local rule = plain[ch]
        if rule == nil then
          parts[#parts + 1] = ch
        elseif type(rule) == "string" then
          parts[#parts + 1] = rule
        elseif type(rule) == "function" then
          parts[#parts + 1] = rule({})
        else
          -- stochastic: array of {prob=p, rule=s}
          local r = rng:float()
          local cumul = 0
          local chosen = ch
          for _, entry in ipairs(rule) do
            cumul = cumul + entry.prob
            if r < cumul then
              chosen = entry.rule
              break
            end
          end
          parts[#parts + 1] = chosen
        end
        i = i + 1
      end
    end
  end
  return table.concat(parts)
end

-- ========================
-- TURTLE INTERPRETER
-- ========================

local RAD = math.pi / 180

local function interpret_string(s, opts)
  local step    = (opts and opts.step) or 10
  local angle   = (opts and opts.angle) or 90
  local x       = (opts and opts.start_x) or 0
  local y       = (opts and opts.start_y) or 0
  local dir     = (opts and opts.start_angle) or 90  -- degrees, 90 = up

  local cmds   = {}
  local stack  = {}
  local i      = 1
  local n      = #s

  while i <= n do
    local ch = s:sub(i, i)

    if ch == "F" then
      local nx = x + step * math.cos(dir * RAD)
      local ny = y + step * math.sin(dir * RAD)
      cmds[#cmds + 1] = { type = "line", x1 = x, y1 = y, x2 = nx, y2 = ny }
      x, y = nx, ny
    elseif ch == "f" then
      local nx = x + step * math.cos(dir * RAD)
      local ny = y + step * math.sin(dir * RAD)
      cmds[#cmds + 1] = { type = "move", x1 = x, y1 = y, x2 = nx, y2 = ny }
      x, y = nx, ny
    elseif ch == "+" then
      dir = dir + angle
    elseif ch == "-" then
      dir = dir - angle
    elseif ch == "|" then
      dir = dir + 180
    elseif ch == "[" then
      cmds[#cmds + 1] = { type = "push", x = x, y = y, angle = dir }
      stack[#stack + 1] = { x = x, y = y, dir = dir }
    elseif ch == "]" then
      local top = stack[#stack]
      if top then
        stack[#stack] = nil
        x, y, dir = top.x, top.y, top.dir
        cmds[#cmds + 1] = { type = "pop", x = x, y = y, angle = dir }
      end
    elseif ch == "(" then
      -- skip parametric value "(n)" — turtle doesn't act on it
      local close = s:find(")", i + 1, true)
      if close then i = close end
    end
    -- all other symbols ignored in turtle

    i = i + 1
  end
  return cmds
end

-- ========================
-- BOUNDS
-- ========================

local function compute_bounds(cmds)
  local min_x, min_y, max_x, max_y
  for _, cmd in ipairs(cmds) do
    if cmd.type == "line" or cmd.type == "move" then
      if min_x == nil then
        min_x, min_y = cmd.x1, cmd.y1
        max_x, max_y = cmd.x1, cmd.y1
      end
      if cmd.x1 < min_x then min_x = cmd.x1 end
      if cmd.y1 < min_y then min_y = cmd.y1 end
      if cmd.x1 > max_x then max_x = cmd.x1 end
      if cmd.y1 > max_y then max_y = cmd.y1 end
      if cmd.x2 < min_x then min_x = cmd.x2 end
      if cmd.y2 < min_y then min_y = cmd.y2 end
      if cmd.x2 > max_x then max_x = cmd.x2 end
      if cmd.y2 > max_y then max_y = cmd.y2 end
    end
  end
  if min_x == nil then
    return { min_x = 0, min_y = 0, max_x = 0, max_y = 0, width = 0, height = 0 }
  end
  return {
    min_x  = min_x,
    min_y  = min_y,
    max_x  = max_x,
    max_y  = max_y,
    width  = max_x - min_x,
    height = max_y - min_y,
  }
end

-- ========================
-- SVG OUTPUT
-- ========================

local function fmt(n)
  -- Format a float for SVG without excessive decimals
  return string.format("%.4g", n)
end

local function to_svg(cmds, opts)
  local w      = (opts and opts.width)  or 400
  local h      = (opts and opts.height) or 400
  local stroke = (opts and opts.stroke) or "black"
  local bg     = (opts and opts.bg)     or "white"
  local stroke_w = (opts and opts.stroke_width) or 1

  -- compute bounds to fit
  local bbox = compute_bounds(cmds)

  -- scale to fit
  local scale = 1
  local ox, oy = 0, 0
  if bbox.width > 0 and bbox.height > 0 then
    local sx = (w * 0.9) / bbox.width
    local sy = (h * 0.9) / bbox.height
    scale = math.min(sx, sy)
  end
  ox = (w - bbox.width * scale) / 2 - bbox.min_x * scale
  oy = (h - bbox.height * scale) / 2 - bbox.min_y * scale

  local parts = {}
  parts[#parts + 1] = '<svg xmlns="http://www.w3.org/2000/svg" width="' .. w .. '" height="' .. h .. '">'
  if bg and bg ~= "none" then
    parts[#parts + 1] = '<rect width="100%" height="100%" fill="' .. bg .. '"/>'
  end
  parts[#parts + 1] = '<g stroke="' .. stroke .. '" stroke-width="' .. stroke_w .. '" fill="none">'

  for _, cmd in ipairs(cmds) do
    if cmd.type == "line" then
      -- SVG y-axis is flipped (down is +y), our turtle has up as +y
      local x1 = fmt(cmd.x1 * scale + ox)
      local y1 = fmt(h - (cmd.y1 * scale + oy))
      local x2 = fmt(cmd.x2 * scale + ox)
      local y2 = fmt(h - (cmd.y2 * scale + oy))
      parts[#parts + 1] = '<line x1="' .. x1 .. '" y1="' .. y1 .. '" x2="' .. x2 .. '" y2="' .. y2 .. '"/>'
    end
  end

  parts[#parts + 1] = '</g>'
  parts[#parts + 1] = '</svg>'
  return table.concat(parts, "\n")
end

-- ========================
-- LSYSTEM OBJECT
-- ========================

local Ls = {}
Ls.__index = Ls

function Ls:generate(n)
  if type(n) ~= "number" or n < 0 or n ~= math.floor(n) then
    return nil, "generate: n must be a non-negative integer"
  end
  local s = self._axiom
  for _ = 1, n do
    s = apply_rules_once(s, self._plain, self._ctx, self._rng)
  end
  return s
end

function Ls:interpret(str, opts)
  if type(str) ~= "string" then
    return nil, "interpret: argument must be a string"
  end
  local merged = {}
  if opts then for k, v in pairs(opts) do merged[k] = v end end
  if merged.angle == nil then merged.angle = self._angle end
  return interpret_string(str, merged)
end

function Ls:bounds(cmds)
  if type(cmds) ~= "table" then
    return nil, "bounds: argument must be a table of commands"
  end
  return compute_bounds(cmds)
end

function Ls:to_svg(str, opts)
  if type(str) ~= "string" then
    return nil, "to_svg: first argument must be a string"
  end
  local merged = {}
  if opts then for k, v in pairs(opts) do merged[k] = v end end
  if merged.angle == nil then merged.angle = self._angle end
  local cmds = interpret_string(str, merged)
  return to_svg(cmds, opts)
end

-- ========================
-- CONSTRUCTOR
-- ========================

function M.new(spec)
  if type(spec) ~= "table" then
    return nil, "new: spec must be a table"
  end
  if spec.axiom == nil then
    return nil, "new: spec.axiom is required"
  end
  if type(spec.axiom) ~= "string" then
    return nil, "new: spec.axiom must be a string"
  end
  if spec.rules == nil then
    return nil, "new: spec.rules is required"
  end
  if type(spec.rules) ~= "table" then
    return nil, "new: spec.rules must be a table"
  end

  local plain, ctx_rules, err = index_rules(spec.rules)
  if err then return nil, "new: " .. err end

  -- Validate stochastic rules
  for sym, rule in pairs(plain) do
    if type(rule) == "table" then
      local total = 0
      for _, entry in ipairs(rule) do
        if type(entry) ~= "table" or type(entry.prob) ~= "number" or (type(entry.rule) ~= "string" and type(entry.rule) ~= "function") then
          return nil, "new: stochastic rule entries must be {prob=number, rule=string|function}, got invalid entry for sym " .. sym
        end
        total = total + entry.prob
      end
      if math.abs(total - 1.0) > 0.01 then
        return nil, "new: stochastic probabilities must sum to 1.0, got " .. total .. " for sym " .. sym
      end
    elseif type(rule) ~= "string" and type(rule) ~= "function" then
      return nil, "new: rule value must be string, function, or stochastic table"
    end
  end

  local angle = spec.angle or 90
  local seed  = spec.seed  or 42

  local ls = setmetatable({
    _axiom  = spec.axiom,
    _plain  = plain,
    _ctx    = ctx_rules,
    _angle  = angle,
    _rng    = make_rng(seed),
  }, Ls)
  return ls
end

-- ========================
-- PRESETS
-- ========================

M.KOCH_SNOWFLAKE = {
  axiom = "F--F--F",
  rules = { F = "F+F--F+F" },
  angle = 60,
}

M.SIERPINSKI_TRIANGLE = {
  axiom = "F-G-G",
  rules = { F = "F-G+F+G-F", G = "GG" },
  angle = 120,
}

M.DRAGON_CURVE = {
  axiom = "FX",
  rules = {
    X = "X+YF+",
    Y = "-FX-Y",
  },
  angle = 90,
}

M.FERN = {
  axiom = "X",
  rules = {
    X = "F+[[X]-X]-F[-FX]+X",
    F = "FF",
  },
  angle = 25,
}

M.BINARY_TREE = {
  axiom = "0",
  rules = {
    ["1"] = "11",
    ["0"] = "1[0]0",
  },
  angle = 45,
}

return M
