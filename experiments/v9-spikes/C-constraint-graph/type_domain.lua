-- TYPE domain: unannotated inference as union-flow constraints (MLsub flavor).
--
-- Each program value gets a fresh cell whose lattice value is the SET of atoms
-- that can flow into it. Subtyping a <: b is encoded as "b's cell joins a's
-- cell": values flow forward and the join produces union types automatically.
-- No annotations are read; literal cells are the only seeds.
--
-- Flow-sensitivity is SSA: every assignment makes a fresh version cell, and an
-- `if` ends with phi cells that join the per-branch versions. So `x` after the
-- if is a phi cell = join(then-x, else-x) = {int, str} = int | str.
--
-- This module references NOTHING from the liveness domain.

local Set = require("lattice")

local function lower(engine, prog)
  local n = 0
  local function fresh(tag) n = n + 1; return "T:" .. tag .. "#" .. n end
  local version = {}            -- variable name -> current SSA cell id
  local result_cell = "T:result"

  -- returns a cell id holding the inferred type-set of expression `e`
  local function expr(e)
    if e.kind == "lit" then
      local c = fresh("lit-" .. e.ty)
      engine:constrain({}, { c }, function() return { [c] = Set.of(e.ty) } end)
      return c
    elseif e.kind == "var" then
      -- use of a variable: its current SSA cell (free vars get a bottom cell)
      local c = version[e.name]
      if not c then c = fresh("free-" .. e.name); version[e.name] = c; engine:cell(c) end
      return c
    end
  end

  local function define(name, valueExpr)
    local src = expr(valueExpr)
    local dst = fresh(name)
    version[name] = dst
    -- subtyping constraint: dst :> src   (src flows into dst)
    engine:constrain({ src }, { dst }, function(get) return { [dst] = get(src) } end)
  end

  local function stmts(list)
    for _, s in ipairs(list) do
      if s.kind == "local" or s.kind == "assign" then
        define(s.name, s.value)
      elseif s.kind == "call" then
        for _, a in ipairs(s.args) do expr(a) end          -- arg types (unused result)
      elseif s.kind == "if" then
        expr(s.cond)
        local before = {}
        for k, v in pairs(version) do before[k] = v end
        stmts(s.body)
        local thenV = {}; for k, v in pairs(version) do thenV[k] = v end
        version = {}; for k, v in pairs(before) do version[k] = v end
        stmts(s.els)
        local elseV = {}; for k, v in pairs(version) do elseV[k] = v end
        -- phi-merge every variable touched in either branch
        local names = {}
        for k in pairs(thenV) do names[k] = true end
        for k in pairs(elseV) do names[k] = true end
        version = {}
        for name in pairs(names) do
          local t, e = thenV[name], elseV[name]
          if t == e then
            version[name] = t
          else
            local phi = fresh(name .. "-phi")
            local reads = {}
            if t then reads[#reads + 1] = t end
            if e then reads[#reads + 1] = e end
            engine:constrain(reads, { phi }, function(get)
              local acc = Set.bottom()
              if t then acc = Set.join(acc, get(t)) end
              if e then acc = Set.join(acc, get(e)) end
              return { [phi] = acc }
            end)
            version[name] = phi
          end
        end
      elseif s.kind == "return" then
        local src = expr(s.value)
        engine:constrain({ src }, { result_cell }, function(get) return { [result_cell] = get(src) } end)
      end
    end
  end

  stmts(prog)
  return { result = result_cell, version = version }
end

return { lower = lower }
