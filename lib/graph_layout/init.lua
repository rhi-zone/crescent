if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local M = {}
M._tier = "pure"

--:: GNode = integer | string
--:: GEdge = { [integer]: GNode }
--:: Graph = { nodes: { [integer]: GNode }, edges: { [integer]: GEdge } }
--:: Pos2D = { x: number, y: number }
--:: PosMap = { [any]: Pos2D }
--:: DispMap = { [any]: Pos2D }
--:: AdjSet = { [any]: boolean }
--:: AdjMap = { [any]: AdjSet }
--:: OutAdjList = { [any]: { [integer]: GNode } }
--:: InDegMap = { [any]: integer }
--:: LayerMap = { [any]: integer }

local math_sqrt  = math.sqrt
local math_floor = math.floor
local math_ceil  = math.ceil
local math_cos   = math.cos
local math_sin   = math.sin
local math_pi    = math.pi
local math_max   = math.max
local math_min   = math.min
local math_huge  = math.huge

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

-- Simple LCG RNG (same seed -> same sequence, portable)
--: (seed: integer | nil) -> () -> number
local function make_rng(seed)
  local s = seed or 42 --: number
  return function()
    s = (s * 1664525 + 1013904223) % (2^32)
    return s / (2^32)
  end
end

-- Collect nodes into an ordered array for deterministic iteration
--: (graph: Graph) -> { [integer]: GNode }
local function collect_nodes(graph)
  local nodes = {} --: { [integer]: GNode }
  for i = 1, #graph.nodes do
    nodes[i] = graph.nodes[i]
  end
  return nodes
end

-- Build adjacency set from edge list for fast lookup
--: (graph: Graph) -> AdjMap
local function build_adj(graph)
  local adj = {} --: AdjMap
  for i = 1, #graph.nodes do
    adj[graph.nodes[i]] = {} --[[:! AdjSet]]
  end
  for i = 1, #graph.edges do
    local e = graph.edges[i]
    local u = e[1] --[[:! GNode]]
    local v = e[2] --[[:! GNode]]
    if adj[u] then adj[u][v] = true end
    if adj[v] then adj[v][u] = true end
  end
  return adj
end

-- ---------------------------------------------------------------------------
-- M.bbox
-- ---------------------------------------------------------------------------

-- Bounding box of positions.
-- Returns {x_min, y_min, x_max, y_max} or nil if empty.
--: (positions: PosMap) -> { [integer]: number }
function M.bbox(positions)
  local x_min, y_min =  math_huge,  math_huge
  local x_max, y_max = -math_huge, -math_huge
  local any = false
  for _, p in pairs(positions) do
    any = true
    if p.x < x_min then x_min = p.x end
    if p.x > x_max then x_max = p.x end
    if p.y < y_min then y_min = p.y end
    if p.y > y_max then y_max = p.y end
  end
  if not any then return {0, 0, 0, 0} end
  return {x_min, y_min, x_max, y_max}
end

-- ---------------------------------------------------------------------------
-- M.centroid
-- ---------------------------------------------------------------------------

-- Center of mass of positions. Returns x, y.
--: (positions: PosMap) -> (number, number)
function M.centroid(positions)
  local sx = 0 --: number
  local sy = 0 --: number
  local n = 0 --: number
  for _, p in pairs(positions) do
    sx = sx + p.x
    sy = sy + p.y
    n  = n + 1
  end
  if n == 0 then return 0, 0 end
  return sx / n, sy / n
end

-- ---------------------------------------------------------------------------
-- M.normalize
-- ---------------------------------------------------------------------------

-- Normalize positions to fit in bounding box [0..width] x [0..height].
-- opts: width, height (default 100), margin (default 5)
--: (positions: PosMap, opts: { width: number | nil, height: number | nil, margin: number | nil } | nil) -> PosMap
function M.normalize(positions, opts)
  local opts_ = opts or {} --[[:! { width: number | nil, height: number | nil, margin: number | nil }]]
  local W      = opts_.width  or 100
  local H      = opts_.height or 100
  local margin = opts_.margin or 5
  local bb     = M.bbox(positions)
  local x_min = bb[1] --[[:! number]]
  local y_min = bb[2] --[[:! number]]
  local x_max = bb[3] --[[:! number]]
  local y_max = bb[4] --[[:! number]]
  local dx = x_max - x_min
  local dy = y_max - y_min
  local out = {} --: PosMap
  local inner_w = W - 2 * margin
  local inner_h = H - 2 * margin
  for k, p in pairs(positions) do
    local nx = dx > 0 and (margin + (p.x - x_min) / dx * inner_w) or (W / 2)
    local ny = dy > 0 and (margin + (p.y - y_min) / dy * inner_h) or (H / 2)
    out[k] = {x = nx, y = ny}
  end
  return out
end

-- ---------------------------------------------------------------------------
-- M.random_layout
-- ---------------------------------------------------------------------------

-- Random layout.
-- opts: width, height (default 100), seed (default 42)
--: (graph: Graph, opts: { width: number | nil, height: number | nil, seed: integer | nil } | nil) -> PosMap
function M.random_layout(graph, opts)
  local opts_ = opts or {} --[[:! { width: number | nil, height: number | nil, seed: integer | nil }]]
  local W    = opts_.width  or 100
  local H    = opts_.height or 100
  local rng  = make_rng(opts_.seed)
  local nodes = collect_nodes(graph)
  local pos  = {} --: PosMap
  for i = 1, #nodes do
    local id = nodes[i]
    pos[id] = {x = rng() * W, y = rng() * H}
  end
  return pos
end

-- ---------------------------------------------------------------------------
-- M.circular
-- ---------------------------------------------------------------------------

-- Circular layout: nodes evenly spaced on a circle.
-- opts: radius (default 50), cx, cy (center, default 0,0)
--: (graph: Graph, opts: { radius: number | nil, cx: number | nil, cy: number | nil } | nil) -> PosMap
function M.circular(graph, opts)
  local opts_ = opts or {} --[[:! { radius: number | nil, cx: number | nil, cy: number | nil }]]
  local r   = opts_.radius or 50
  local cx  = opts_.cx or 0
  local cy  = opts_.cy or 0
  local nodes = collect_nodes(graph)
  local n   = #nodes
  local pos = {} --: PosMap
  if n == 0 then return pos end
  if n == 1 then
    pos[nodes[1]] = {x = cx, y = cy}
    return pos
  end
  local step = 2 * math_pi / n
  for i = 1, n do
    local angle = (i - 1) * step
    pos[nodes[i]] = {x = cx + r * math_cos(angle), y = cy + r * math_sin(angle)}
  end
  return pos
end

-- ---------------------------------------------------------------------------
-- M.grid
-- ---------------------------------------------------------------------------

-- Grid layout: nodes arranged in a grid.
-- opts: cols (default ceil(sqrt(n))), spacing (default 10)
--: (graph: Graph, opts: { cols: integer | nil, spacing: number | nil } | nil) -> PosMap
function M.grid(graph, opts)
  local opts_ = opts or {} --[[:! { cols: integer | nil, spacing: number | nil }]]
  local nodes   = collect_nodes(graph)
  local n       = #nodes
  local cols    = opts_.cols or math_ceil(math_sqrt(n))
  if cols < 1 then cols = 1 end
  local spacing = opts_.spacing or 10
  local pos     = {} --: PosMap
  for i = 1, n do
    local row = math_floor((i - 1) / cols)
    local col = (i - 1) % cols
    pos[nodes[i]] = {x = col * spacing, y = row * spacing}
  end
  return pos
end

-- ---------------------------------------------------------------------------
-- M.force_directed  (Fruchterman-Reingold)
-- ---------------------------------------------------------------------------

-- Fruchterman-Reingold force-directed layout.
-- opts: width, height, iterations, temperature, seed, gravity
--:: FDOpts = { width: number | nil, height: number | nil, iterations: integer | nil, seed: integer | nil, gravity: number | nil, temperature: number | nil }
--: (graph: Graph, opts: FDOpts | nil) -> PosMap
function M.force_directed(graph, opts)
  local opts_ = opts or {} --[[:! FDOpts]]
  local W    = opts_.width      or 100
  local H    = opts_.height     or 100
  local iters = opts_.iterations or 50
  local seed  = opts_.seed
  local grav  = opts_.gravity or 0.1

  local nodes = collect_nodes(graph)
  local n     = #nodes
  if n == 0 then return {} end

  local area  = W * H
  local k     = math_sqrt(area / n)
  local init_temp = opts_.temperature or (W / 10)

  -- Initialize positions randomly in [-W/2, W/2] x [-H/2, H/2]
  local rng = make_rng(seed)
  local pos = {} --: PosMap
  for i = 1, n do
    local id = nodes[i]
    pos[id] = {
      x = (rng() - 0.5) * W,
      y = (rng() - 0.5) * H,
    }
  end

  -- Build adjacency list for edge iteration
  local adj = build_adj(graph)

  local disp = {} --: DispMap
  for i = 1, n do
    local zero = 0 --: number
    disp[nodes[i]] = {x = zero, y = zero}
  end

  for iter = 1, iters do
    local temp = init_temp * (1 - iter / iters)

    -- Reset displacements
    for i = 1, n do
      local d = disp[nodes[i]]
      d.x = 0; d.y = 0
    end

    -- Repulsive forces between all pairs
    for i = 1, n do
      local vi = nodes[i]
      local pi = pos[vi]
      local di = disp[vi]
      for j = i + 1, n do
        local vj = nodes[j]
        local pj = pos[vj]
        local dj = disp[vj]
        local dx = pi.x - pj.x
        local dy = pi.y - pj.y
        local dist = math_sqrt(dx * dx + dy * dy)
        if dist < 0.01 then dist = 0.01 end
        local force = (k * k) / dist
        local fx = (dx / dist) * force
        local fy = (dy / dist) * force
        di.x = di.x + fx
        di.y = di.y + fy
        dj.x = dj.x - fx
        dj.y = dj.y - fy
      end
    end

    -- Attractive forces along edges
    for i = 1, n do
      local vi = nodes[i]
      local pi = pos[vi]
      local di = disp[vi]
      for vj in pairs(adj[vi] or {}) do
        -- only process each edge once (vi < vj by index, use string comparison)
        if tostring(vi) < tostring(vj) then
          local pj = pos[vj]
          local dj = disp[vj]
          local dx = pi.x - pj.x
          local dy = pi.y - pj.y
          local dist = math_sqrt(dx * dx + dy * dy)
          if dist < 0.01 then dist = 0.01 end
          local force = (dist * dist) / k
          local fx = (dx / dist) * force
          local fy = (dy / dist) * force
          di.x = di.x - fx
          di.y = di.y - fy
          dj.x = dj.x + fx
          dj.y = dj.y + fy
        end
      end
    end

    -- Gravity toward center
    if grav ~= 0 then
      for i = 1, n do
        local vi = nodes[i]
        local di = disp[vi]
        local pi = pos[vi]
        di.x = di.x - grav * pi.x
        di.y = di.y - grav * pi.y
      end
    end

    -- Apply displacement, capped by temperature
    for i = 1, n do
      local vi = nodes[i]
      local pi = pos[vi]
      local di = disp[vi]
      local dmag = math_sqrt(di.x * di.x + di.y * di.y)
      if dmag < 0.01 then dmag = 0.01 end
      local scale = math_min(dmag, temp) / dmag
      pi.x = pi.x + di.x * scale
      pi.y = pi.y + di.y * scale
      -- Clamp to canvas
      pi.x = math_max(-W / 2, math_min(W / 2, pi.x))
      pi.y = math_max(-H / 2, math_min(H / 2, pi.y))
    end
  end

  return pos
end

-- ---------------------------------------------------------------------------
-- M.hierarchical  (simplified Reingold-Tilford / layer assignment)
-- ---------------------------------------------------------------------------

-- Hierarchical layout for DAGs/trees.
-- opts: layer_sep (default 20), node_sep (default 15), direction="down"|"right"
--
-- Automatically detects roots (nodes with no in-edges in the directed sense).
-- For undirected inputs, treats edges as directed from lower-index to higher.
--: (graph: Graph, opts: { layer_sep: number | nil, node_sep: number | nil, direction: string | nil } | nil) -> PosMap
function M.hierarchical(graph, opts)
  local opts_ = opts or {} --[[:! { layer_sep: number | nil, node_sep: number | nil, direction: string | nil }]]
  local layer_sep = opts_.layer_sep or 20
  local node_sep  = opts_.node_sep  or 15
  local direction = opts_.direction or "down"

  local nodes = collect_nodes(graph)
  local n     = #nodes
  if n == 0 then return {} end

  -- Build directed adjacency (edges as-given, undirected: both directions stored
  -- but we compute in_degree for root detection)
  local out_adj = {} --: OutAdjList
  local in_deg  = {} --: InDegMap
  for i = 1, n do
    out_adj[nodes[i]] = {} --[[:! { [integer]: GNode }]]
    in_deg[nodes[i]]  = 0
  end

  for i = 1, #graph.edges do
    local e = graph.edges[i]
    local u = e[1] --[[:! GNode]]
    local v = e[2] --[[:! GNode]]
    local ou = out_adj[u] --[[:! { [integer]: GNode }]]
    ou[#ou+1] = v
    in_deg[v] = (in_deg[v] or 0) + 1
  end

  -- Topological sort (Kahn's) to assign layers
  local layer   = {} --: LayerMap
  local queue   = {} --: { [integer]: GNode }
  for i = 1, n do
    local id = nodes[i]
    if in_deg[id] == 0 then
      queue[#queue+1] = id
      layer[id] = 0
    end
  end

  -- If no roots found (cycle), fall back to all at layer 0
  if #queue == 0 then
    for i = 1, n do
      layer[nodes[i]] = 0
      queue[i] = nodes[i]
    end
  end

  local topo = {}
  local head = 1
  while head <= #queue do
    local u = queue[head]; head = head + 1
    topo[#topo+1] = u
    local ou = out_adj[u] --[[:! { [integer]: GNode }]]
    for _, v in ipairs(ou) do
      -- assign layer as max(current, parent+1)
      local new_layer = (layer[u] or 0) + 1
      if (layer[v] == nil) or (new_layer > layer[v]) then
        layer[v] = new_layer
      end
      in_deg[v] = (in_deg[v] or 0) - 1
      if in_deg[v] == 0 then
        queue[#queue+1] = v
      end
    end
  end

  -- Any unvisited nodes (from cycles) get layer 0
  for i = 1, n do
    if layer[nodes[i]] == nil then layer[nodes[i]] = 0 end
  end

  -- Group nodes by layer
  local max_layer = 0
  for i = 1, n do
    local l = layer[nodes[i]] --[[:! integer]]
    if l > max_layer then max_layer = l end
  end

  local layers = {} --: { [integer]: { [integer]: GNode } }
  for l = 0, max_layer do layers[l] = {} --[[:! { [integer]: GNode }]] end
  for i = 1, n do
    local id = nodes[i]
    local l  = layer[id] --[[:! integer]]
    local lyr = layers[l] --[[:! { [integer]: GNode }]]
    lyr[#lyr+1] = id
  end

  -- Barycentric heuristic to reduce crossings (one pass top-down)
  for l = 1, max_layer do
    local cur_layer = layers[l] --[[:! { [integer]: GNode }]]
    -- Score each node by average position of its parents
    local score = {} --: { [any]: number }
    for _, id in ipairs(cur_layer) do
      -- find parents (nodes in layer l-1 that have edge to id)
      local parent_sum  = 0 --: number
      local parent_cnt  = 0
      local prev_layer = layers[l-1] --[[:! { [integer]: GNode }]]
      for pi, pid in ipairs(prev_layer) do
        -- check if pid -> id edge exists
        local opid = out_adj[pid] --[[:! { [integer]: GNode }]]
        for _, ch in ipairs(opid) do
          if ch == id then
            parent_sum = parent_sum + pi
            parent_cnt = parent_cnt + 1
            break
          end
        end
      end
      score[id] = parent_cnt > 0 and (parent_sum / parent_cnt) or 0
    end
    table.sort(cur_layer, function(a, b) return (score[a] or 0) < (score[b] or 0) end)
  end

  -- Assign coordinates
  local pos = {} --: PosMap
  for l = 0, max_layer do
    local cur_layer = layers[l] --[[:! { [integer]: GNode }]]
    for order, id in ipairs(cur_layer) do
      local primary   = (order - 1) * node_sep   -- x for "down"
      local secondary = l * layer_sep             -- y for "down"
      if direction == "right" then
        pos[id] = {x = secondary, y = primary}
      else
        pos[id] = {x = primary, y = secondary}
      end
    end
  end

  return pos
end

return M
