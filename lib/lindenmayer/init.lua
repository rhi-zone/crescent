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
--: (spec_rules: { [string]: unknown }) -> ({ [string]: unknown } | nil, { [string]: { [integer]: LsRule } } | nil, string | nil)
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
  return plain, ctx, nil
end

-- ========================
-- STRING GENERATION
-- ========================

--:: LsCmd = { type: string, x1: number, y1: number, x2: number, y2: number, x: number, y: number, angle: number, ... }
--:: LsRule = { kind: string, left: string | nil, right: string | nil, param: string | nil, value: unknown, prob: number | nil, rule: unknown, ... }
--:: LsRng = { next: (self: LsRng) -> integer, float: (self: LsRng) -> number }
--:: LsOpts = { step: number | nil, angle: number | nil, start_x: number | nil, start_y: number | nil, start_angle: number | nil, width: number | nil, height: number | nil, stroke: string | nil, bg: string | nil, stroke_width: number | nil, ... }

-- Try to match a parametric token at position i in string s.
-- Returns sym, params_table, end_pos  or  nil
--: (s: string, i: integer) -> (string | nil, { [integer]: string } | nil, integer | nil)
local function match_parametric(s, i)
  local sym = s:sub(i, i)
  if not sym:match("[A-Za-z]") then return nil end
  if i + 1 > #s or s:sub(i + 1, i + 1) ~= "(" then return nil end
  local close = s:find(")", i + 2, true)
  if not close then return nil end
  local inner = s:sub(i + 2, (close --[[:! integer]]) - 1)
  local params = {}
  for v in inner:gmatch("[^,]+") do
    params[#params + 1] = v
  end
  return sym, params, close
end

-- Apply rules once to a string, return new string.
--: (s: string, plain: { [string]: unknown }, ctx_rules: { [string]: { [integer]: LsRule } }, rng: LsRng) -> string
local function apply_rules_once(s, plain, ctx_rules, rng)
  local parts = {} --: { [integer]: string }
  local parts_ = parts --[[: any]]
  local i = 1 --: integer
  local n = #s
  while i <= n do
    local ch = s:sub(i, i)
    local advanced = false

    -- Check parametric context rules first
    if ctx_rules[ch] then
      local sym, params, end_pos = match_parametric(s, i)
      if sym and params and end_pos then
        local end_pos_ = end_pos
        for _, crule in ipairs(ctx_rules[sym]) do
          if crule.kind == "parametric" then
            local vfn = crule.value --[[:! (...unknown) -> unknown]]
            local result = vfn(params)
            if result ~= nil then
              parts_[#parts + 1] = result
              i = end_pos_ + 1
              advanced = true
              break
            end
          end
        end
        if not advanced then
          -- parametric token but no rule matched; emit as-is
          parts_[#parts + 1] = s:sub(i, end_pos_)
          i = end_pos_ + 1
          advanced = true
        end
      end
    end

    if not advanced then
      -- Check context-sensitive rules
      local applied_ctx = false
      if ctx_rules[ch] then
        for _, crule in ipairs(ctx_rules[ch]) do
          local match = false --: boolean
          if crule.kind == "context_l" then
            match = (i > 1 and s:sub(i - 1, i - 1) == crule.left) and true or false
          elseif crule.kind == "context_r" then
            match = (i < n and s:sub(i + 1, i + 1) == crule.right) and true or false
          end
          if match then
            local value = crule.value
            if type(value) == "string" then
              parts_[#parts + 1] = value
            elseif type(value) == "function" then
              local vfn2 = value --[[:! (...unknown) -> string]]
              parts_[#parts + 1] = vfn2({})
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
          parts_[#parts + 1] = ch
        elseif type(rule) == "string" then
          parts_[#parts + 1] = rule
        elseif type(rule) == "function" then
          local rfn = rule --[[:! (...unknown) -> string]]
          parts_[#parts + 1] = rfn({})
        else
          -- stochastic: array of {prob=p, rule=s}
          local r = rng:float()
          local cumul = 0 --: number
          local chosen = ch
          for _, entry in ipairs(rule) do
            local eprob = (entry.prob or 0) --[[:! number]]
            cumul = cumul + eprob
            if r < cumul then
              chosen = (entry.rule or ch) --[[:! string]]
              break
            end
          end
          parts_[#parts + 1] = chosen
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

--: (s: string, opts: LsOpts | nil) -> { [integer]: LsCmd }
local function interpret_string(s, opts)
  local step    = ((opts and opts.step) or 10) --[[:! number]]
  local angle   = ((opts and opts.angle) or 90) --[[:! number]]
  local x       = ((opts and opts.start_x) or 0) --[[:! number]]
  local y       = ((opts and opts.start_y) or 0) --[[:! number]]
  local dir     = ((opts and opts.start_angle) or 90) --[[:! number]] -- degrees, 90 = up

  local cmds   = {} --: { [integer]: LsCmd }
  local cmds_  = cmds --[[: any]]
  local stack  = {} --: { [integer]: { x: number, y: number, dir: number } }
  local stack_ = stack --[[: any]]
  local i      = 1 --: integer
  local n      = #s

  while i <= n do
    local ch = s:sub(i, i)

    if ch == "F" then
      local nx = x + step * math.cos(dir * RAD)
      local ny = y + step * math.sin(dir * RAD)
      cmds_[#cmds + 1] = { type = "line", x1 = x, y1 = y, x2 = nx, y2 = ny }
      x, y = nx, ny
    elseif ch == "f" then
      local nx = x + step * math.cos(dir * RAD)
      local ny = y + step * math.sin(dir * RAD)
      cmds_[#cmds + 1] = { type = "move", x1 = x, y1 = y, x2 = nx, y2 = ny }
      x, y = nx, ny
    elseif ch == "+" then
      dir = dir + angle
    elseif ch == "-" then
      dir = dir - angle
    elseif ch == "|" then
      dir = dir + 180
    elseif ch == "[" then
      cmds_[#cmds + 1] = { type = "push", x = x, y = y, angle = dir }
      stack_[#stack + 1] = { x = x, y = y, dir = dir }
    elseif ch == "]" then
      local top = stack[#stack]
      if top then
        stack_[#stack] = nil
        x, y, dir = top.x, top.y, top.dir
        cmds_[#cmds + 1] = { type = "pop", x = x, y = y, angle = dir }
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

--:: LsBounds = { min_x: number, min_y: number, max_x: number, max_y: number, width: number, height: number }
--: (cmds: { [integer]: LsCmd }) -> LsBounds
local function compute_bounds(cmds)
  local min_x = 0 --: number
  local min_y = 0 --: number
  local max_x = 0 --: number
  local max_y = 0 --: number
  local seen = false
  for _, cmd in ipairs(cmds) do
    if cmd.type == "line" or cmd.type == "move" then
      local x1 = cmd.x1
      local y1 = cmd.y1
      local x2 = cmd.x2
      local y2 = cmd.y2
      if not seen then
        min_x, min_y = x1, y1
        max_x, max_y = x1, y1
        seen = true
      end
      if x1 < min_x then min_x = x1 end
      if y1 < min_y then min_y = y1 end
      if x1 > max_x then max_x = x1 end
      if y1 > max_y then max_y = y1 end
      if x2 < min_x then min_x = x2 end
      if y2 < min_y then min_y = y2 end
      if x2 > max_x then max_x = x2 end
      if y2 > max_y then max_y = y2 end
    end
  end
  if not seen then
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

--: (cmds: { [integer]: LsCmd }, opts: LsOpts | nil) -> string
local function to_svg(cmds, opts)
  local w      = ((opts and opts.width)  or 400) --[[:! number]]
  local h      = ((opts and opts.height) or 400) --[[:! number]]
  local stroke = ((opts and opts.stroke) or "black") --[[:! string]]
  local bg     = ((opts and opts.bg)     or "white") --[[:! string]]
  local stroke_w = ((opts and opts.stroke_width) or 1) --[[:! number]]

  -- compute bounds to fit
  local bbox = compute_bounds(cmds)

  -- scale to fit
  local scale = 1 --: number
  local ox = 0 --: number
  local oy = 0 --: number
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

--:: LsObj = { _axiom: string, _plain: { [string]: unknown }, _ctx: { [string]: { [integer]: LsRule } }, _angle: number, _rng: LsRng, ... }

local Ls = {}
Ls.__index = Ls

--: (self: LsObj, n: number) -> (string | nil, string | nil)
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

--: (self: LsObj, str: string, opts: LsOpts | nil) -> ({ [integer]: LsCmd } | nil, string | nil)
function Ls:interpret(str, opts)
  if type(str) ~= "string" then
    return nil, "interpret: argument must be a string"
  end
  local merged = {} --[[: any]]
  if opts then for k, v in pairs(opts) do merged --[[: any]][k] = v end end
  if merged.angle == nil then merged.angle = self._angle end
  return interpret_string(str, merged --[[:! LsOpts]])
end

--: (self: LsObj, cmds: { [integer]: LsCmd }) -> (LsBounds | nil, string | nil)
function Ls:bounds(cmds)
  if type(cmds) ~= "table" then
    return nil, "bounds: argument must be a table of commands"
  end
  return compute_bounds(cmds)
end

--: (self: LsObj, str: string, opts: LsOpts | nil) -> (string | nil, string | nil)
function Ls:to_svg(str, opts)
  if type(str) ~= "string" then
    return nil, "to_svg: first argument must be a string"
  end
  local merged = {} --[[: any]]
  if opts then for k, v in pairs(opts) do merged --[[: any]][k] = v end end
  if merged.angle == nil then merged.angle = self._angle end
  local cmds = interpret_string(str, merged --[[:! LsOpts]])
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

  local plain, ctx_rules, err = index_rules(spec.rules --[[:! { [string]: unknown }]])
  if err then return nil, "new: " .. err end
  local plain_ = plain --[[:! { [string]: unknown }]]
  local ctx_rules_ = ctx_rules --[[:! { [string]: { [integer]: LsRule } }]]

  -- Validate stochastic rules
  for sym, rule in pairs(plain_) do
    local sym_ = tostring(sym)
    if type(rule) == "table" then
      local total = 0 --: number
      local rule_ = rule --[[: any]]
      for _, entry in ipairs(rule_) do
        local entry_ = entry --[[: any]]
        if type(entry_) ~= "table" or type(entry_.prob) ~= "number" or (type(entry_.rule) ~= "string" and type(entry_.rule) ~= "function") then
          return nil, "new: stochastic rule entries must be {prob=number, rule=string|function}, got invalid entry for sym " .. sym_
        end
        total = total + (entry_.prob --[[:! number]])
      end
      if math.abs(total - 1.0) > 0.01 then
        return nil, "new: stochastic probabilities must sum to 1.0, got " .. total .. " for sym " .. sym_
      end
    elseif type(rule) ~= "string" and type(rule) ~= "function" then
      return nil, "new: rule value must be string, function, or stochastic table"
    end
  end

  local angle = (spec.angle or 90) --[[:! number]]
  local seed  = (spec.seed  or 42) --[[:! integer]]

  local ls = setmetatable({
    _axiom  = spec.axiom --[[:! string]],
    _plain  = plain_,
    _ctx    = ctx_rules_,
    _angle  = angle,
    _rng    = make_rng(seed),
  }, Ls) --[[: any]] --[[:! LsObj]]
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
