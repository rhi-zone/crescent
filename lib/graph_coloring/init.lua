if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

-- Graph coloring algorithms: vertex coloring, edge coloring, chromatic polynomial.
-- Input graphs use adjacency list representation: {[node]={neighbor,...}, ...}
-- Nodes are 1-indexed integers.

local M = {}
M._tier = "pure"

-- ========================
-- HELPERS
-- ========================

-- Collect all node IDs from a graph (union of keys and values).
local function nodes(graph)
  local seen = {}
  local list = {}
  for u, neighbors in pairs(graph) do
    if not seen[u] then
      seen[u] = true
      list[#list + 1] = u
    end
    for _, v in ipairs(neighbors) do
      if not seen[v] then
        seen[v] = true
        list[#list + 1] = v
      end
    end
  end
  table.sort(list)
  return list
end

-- Degree of a node (length of adjacency list, default 0).
local function degree(graph, u)
  return graph[u] and #graph[u] or 0
end

-- Return a set of colors used by neighbors of u in the given coloring.
local function neighbor_colors(graph, coloring, u)
  local used = {}
  for _, v in ipairs(graph[u] or {}) do
    if coloring[v] then
      used[coloring[v]] = true
    end
  end
  return used
end

-- Lowest positive integer not in the set `used`.
local function lowest_free(used)
  local c = 1
  while used[c] do c = c + 1 end
  return c
end

-- ========================
-- GREEDY (WELSH-POWELL)
-- ========================

-- Greedy coloring using Welsh-Powell: sort nodes by degree descending,
-- assign the lowest available color not used by any already-colored neighbor.
-- Returns {[node]=color, ...} with colors as integers 1..k.
function M.greedy(graph)
  local ns = nodes(graph)
  -- sort by degree descending, break ties by node id ascending for determinism
  table.sort(ns, function(a, b)
    local da, db = degree(graph, a), degree(graph, b)
    if da ~= db then return da > db end
    return a < b
  end)
  local coloring = {}
  for _, u in ipairs(ns) do
    local used = neighbor_colors(graph, coloring, u)
    coloring[u] = lowest_free(used)
  end
  return coloring
end

-- ========================
-- DSatur
-- ========================

-- DSatur: at each step, pick the uncolored node with highest saturation
-- (number of distinct colors in its colored neighborhood). Ties broken by
-- degree, then node id. Assign the lowest available color.
-- Returns {[node]=color, ...}.
function M.dsatur(graph)
  local ns = nodes(graph)
  local n = #ns
  if n == 0 then return {} end

  -- saturation[u] = number of distinct neighbor colors
  local saturation = {} --: { [unknown]: integer }
  -- neighbor_color_sets[u] = set of colors used by colored neighbors
  local neighbor_color_sets = {}
  local colored = {}

  for _, u in ipairs(ns) do
    saturation[u] = 0
    neighbor_color_sets[u] = {}
  end

  local coloring = {}
  local remaining = n

  while remaining > 0 do
    -- pick node with max saturation, break ties by degree desc, then node id asc
    local best = nil
    for _, u in ipairs(ns) do
      if not colored[u] then
        if best == nil then
          best = u
        else
          local su, sb = saturation[u], saturation[best]
          if su > sb then
            best = u
          elseif su == sb then
            local du, db = degree(graph, u), degree(graph, best)
            if du > db then
              best = u
            elseif du == db and u < best then
              best = u
            end
          end
        end
      end
    end

    -- assign lowest free color
    local c = lowest_free(neighbor_color_sets[best])
    coloring[best] = c
    colored[best] = true
    remaining = remaining - 1

    -- update saturation of uncolored neighbors
    for _, v in ipairs(graph[best] or {}) do
      if not colored[v] then
        if not neighbor_color_sets[v][c] then
          neighbor_color_sets[v][c] = true
          saturation[v] = saturation[v] + 1
        end
      end
    end
  end

  return coloring
end

-- ========================
-- BACKTRACKING k-COLORING
-- ========================

-- Try to assign colors 1..k to each node in order using backtracking.
-- Forward checking: if any uncolored node has no valid color remaining, prune.
-- Returns (coloring, true) if k-colorable, or (nil, false) if not.
function M.backtrack(graph, k)
  local ns = nodes(graph)
  local n = #ns
  if n == 0 then return {}, true end

  -- build neighbor index for fast lookup
  local adj = {}
  for _, u in ipairs(ns) do
    adj[u] = {}
    for _, v in ipairs(graph[u] or {}) do
      adj[u][v] = true
    end
  end

  local coloring = {}

  local function is_safe(u, c)
    for _, v in ipairs(graph[u] or {}) do
      if coloring[v] == c then return false end
    end
    return true
  end

  local function solve(idx)
    if idx > n then return true end
    local u = ns[idx]
    for c = 1, k do
      if is_safe(u, c) then
        coloring[u] = c
        if solve(idx + 1) then return true end
        coloring[u] = nil
      end
    end
    return false
  end

  if solve(1) then
    return coloring, true
  else
    return nil, false
  end
end

-- ========================
-- CHROMATIC NUMBER
-- ========================

-- Find the minimum k for which the graph is k-colorable.
-- Uses backtracking from k=1 upward.
-- Returns the chromatic number.
function M.chromatic_number(graph)
  local ns = nodes(graph)
  if #ns == 0 then return 0 end
  for k = 1, #ns do
    local _, ok = M.backtrack(graph, k)
    if ok then return k end
  end
  return #ns
end

-- ========================
-- VALIDATION
-- ========================

-- Returns true if no two adjacent nodes share the same color.
function M.valid(graph, coloring)
  for u, neighbors in pairs(graph) do
    for _, v in ipairs(neighbors) do
      if coloring[u] ~= nil and coloring[v] ~= nil and coloring[u] == coloring[v] then
        return false
      end
    end
  end
  return true
end

-- Returns the number of distinct colors used in a coloring.
function M.num_colors(coloring)
  local seen = {}
  local count = 0
  for _, c in pairs(coloring) do
    if c ~= nil and not seen[c] then
      seen[c] = true
      count = count + 1
    end
  end
  return count
end

-- ========================
-- BIPARTITE CHECK
-- ========================

-- BFS 2-coloring attempt.
-- Returns (true, coloring) if bipartite, or (false, nil) if not.
function M.is_bipartite(graph)
  local ns = nodes(graph)
  if #ns == 0 then return true, {} end

  local coloring = {} --: { [unknown]: integer }

  for _, start in ipairs(ns) do
    if not coloring[start] then
      coloring[start] = 1
      local queue = { start }
      local head = 1
      while head <= #queue do
        local u = queue[head]
        head = head + 1
        for _, v in ipairs(graph[u] or {}) do
          if not coloring[v] then
            coloring[v] = 3 - coloring[u]  -- alternate between 1 and 2
            queue[#queue + 1] = v
          elseif coloring[v] == coloring[u] then
            return false, nil
          end
        end
      end
    end
  end

  return true, coloring
end

-- ========================
-- EDGE COLORING
-- ========================

-- Edge coloring: assign colors to edges so no two edges sharing a vertex
-- have the same color. By Vizing's theorem, chromatic index is Δ or Δ+1.
-- Uses a greedy algorithm over sorted edges.
-- Returns {[edge_key]=color, ...} where edge_key = "u,v" with u < v.
function M.edge_color(graph)
  -- collect unique edges (u < v)
  local edges = {}
  local seen_edges = {}
  for u, neighbors in pairs(graph) do
    for _, v in ipairs(neighbors) do
      local a = tostring(u)
      local b = tostring(v)
      if a > b then a, b = b, a end
      local key = a .. "," .. b
      if not seen_edges[key] then
        seen_edges[key] = true
        edges[#edges + 1] = { a, b, key }
      end
    end
  end

  -- sort edges for determinism
  table.sort(edges, function(e1, e2)
    if e1[1] ~= e2[1] then return e1[1] < e2[1] end
    return e1[2] < e2[2]
  end)

  local edge_coloring = {}
  -- vertex_colors[u] = set of colors used on edges incident to u
  local vertex_colors = {}

  local function init_vertex(u)
    if not vertex_colors[u] then vertex_colors[u] = {} end
  end

  for _, edge in ipairs(edges) do
    local a, b, key = edge[1], edge[2], edge[3]
    init_vertex(a)
    init_vertex(b)
    -- find lowest color not used by either endpoint
    local c = 1
    while vertex_colors[a][c] or vertex_colors[b][c] do
      c = c + 1
    end
    edge_coloring[key] = c
    vertex_colors[a][c] = true
    vertex_colors[b][c] = true
  end

  return edge_coloring
end

-- ========================
-- MAP COLORING
-- ========================

-- Map coloring using backtracking with 4 colors (4-color theorem for planar graphs).
-- Falls back to more colors if needed (non-planar input).
-- Returns {[node]=color, ...}.
function M.map_color(graph)
  -- try k=4 first (planar graphs), fall back if needed
  local coloring, ok = M.backtrack(graph, 4)
  if ok then return coloring end
  -- non-planar: use greedy as fallback
  return M.greedy(graph)
end

-- ========================
-- REGISTER ALLOCATION
-- ========================

-- Register allocation via graph coloring.
-- interference_graph: adjacency list where nodes are variable names/IDs,
--   edges indicate simultaneous liveness (interference).
-- num_registers: number of available registers (colors).
-- Returns {[var]=register, ...} if all variables fit.
-- Variables that can't be colored (spilled) get color=nil and a spill=true entry.
-- Returns (allocation_table, spilled_list).
function M.register_alloc(interference_graph, num_registers)
  local ns = nodes(interference_graph)
  if #ns == 0 then return {}, {} end

  -- try exact coloring first
  local coloring, ok = M.backtrack(interference_graph, num_registers)
  if ok then
    return coloring, {}
  end

  -- couldn't color within num_registers: greedy with spilling
  -- sort by degree descending (most constrained first)
  table.sort(ns, function(a, b)
    local da = degree(interference_graph, a)
    local db = degree(interference_graph, b)
    if da ~= db then return da > db end
    return tostring(a) < tostring(b)
  end)

  local allocation = {}
  local spilled = {}

  for _, u in ipairs(ns) do
    local used = neighbor_colors(interference_graph, allocation, u)
    local c = lowest_free(used)
    if c <= num_registers then
      allocation[u] = c
    else
      allocation[u] = nil
      spilled[#spilled + 1] = u
    end
  end

  return allocation, spilled
end

return M
