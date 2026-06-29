-- LIVENESS domain: classic backward dataflow, forced through the SAME engine.
--
-- We build a CFG over the AST, then encode the standard equations as constraints
-- on cells holding sets of live variable names:
--
--   out[n] = U over successors s of  in[s]
--   in[n]  = gen[n]  U  (out[n] \ kill[n])
--
-- The join lattice is set-union (monotone, like the type domain). The set-MINUS
-- (kill) lives INSIDE a constraint's apply function -- it is NOT a join. This is
-- the honest seam: the engine's lattice can't express "kill"; it can only host a
-- transfer function that happens to be monotone because gen/kill are constants.
-- See FINDINGS.md #4. This module references NOTHING from the type domain.

local Set = require("lattice")

-- ---- CFG construction (generic walk over the AST) -------------------------
local function build_cfg(prog)
  local nodes = {}                                  -- id -> {gen,kill,succ={ids},label}
  local function add(label, gen, kill)
    nodes[#nodes + 1] = { label = label, gen = gen, kill = kill, succ = {} }
    return #nodes
  end
  local function uses(e, acc)
    if e.kind == "var" then acc[e.name] = true end
    return acc
  end

  -- returns entry-id, { exit-ids } for a statement list
  local function walk(list)
    local entry, prevExits = nil, nil
    local function link(toId)
      if prevExits then for _, p in ipairs(prevExits) do
        nodes[p].succ[#nodes[p].succ + 1] = toId
      end end
    end
    for _, s in ipairs(list) do
      if s.kind == "local" or s.kind == "assign" then
        local n = add(s.kind .. " " .. s.name, uses(s.value, {}), Set.of(s.name))
        if not entry then entry = n end; link(n); prevExits = { n }
      elseif s.kind == "call" then
        local g = {}; for _, a in ipairs(s.args) do uses(a, g) end
        local n = add("call " .. s.fn, g, {})
        if not entry then entry = n end; link(n); prevExits = { n }
      elseif s.kind == "if" then
        local n = add("if-cond", uses(s.cond, {}), {})
        if not entry then entry = n end; link(n); prevExits = { n }
        local tE, tX = walk(s.body)
        local eE, eX = walk(s.els)
        nodes[n].succ = { tE, eE }
        prevExits = {}
        for _, x in ipairs(tX) do prevExits[#prevExits + 1] = x end
        for _, x in ipairs(eX) do prevExits[#prevExits + 1] = x end
      elseif s.kind == "return" then
        local n = add("return", uses(s.value, {}), {})
        if not entry then entry = n end; link(n)
        prevExits = {}                              -- return has no successor
      end
    end
    return entry, prevExits or {}
  end

  walk(prog)
  return nodes
end

-- ---- Encode the dataflow as engine constraints ----------------------------
local function lower(engine, prog)
  local nodes = build_cfg(prog)
  local function inC(i) return "L:in#" .. i end
  local function outC(i) return "L:out#" .. i end

  for i, node in ipairs(nodes) do
    -- out[i] = U in[successors]
    local reads = {}
    for _, s in ipairs(node.succ) do reads[#reads + 1] = inC(s) end
    engine:constrain(reads, { outC(i) }, function(get)
      local acc = Set.bottom()
      for _, s in ipairs(node.succ) do acc = Set.join(acc, get(inC(s))) end
      return { [outC(i)] = acc }
    end)
    -- in[i] = gen[i] U (out[i] \ kill[i])
    engine:constrain({ outC(i) }, { inC(i) }, function(get)
      return { [inC(i)] = Set.join(node.gen, Set.minus(get(outC(i)), node.kill)) }
    end)
  end

  return { nodes = nodes, inC = inC, outC = outC }
end

return { lower = lower }
