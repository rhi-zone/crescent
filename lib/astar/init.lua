if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local heap = require("lib.heap")

local M = {}
M._tier = "pure"

-- ========================
-- INTERNAL HELPERS
-- ========================

local function reconstruct_path(came_from, current)
  local path = { current }
  while came_from[current] do
    current = came_from[current]
    table.insert(path, 1, current)
  end
  return path
end

-- Encode a {row,col} grid cell as a single number key (1-indexed, max 65535 per dim)
local function cell_key(row, col)
  return row * 65536 + col
end

-- ========================
-- GENERIC A* / DIJKSTRA
-- ========================

--- A* search on a generic graph.
-- start: start node (any value usable as table key)
-- goal: goal node OR goal_fn(node) -> boolean
-- neighbors_fn: function(node) -> {{node, cost}, ...}
-- heuristic_fn: function(node, goal) -> estimated cost (admissible)
-- Returns: path (array of nodes from start to goal), total_cost
--       or: nil, "no path found"
function M.astar(start, goal, neighbors_fn, heuristic_fn)
  local goal_fn = type(goal) == "function" and goal or function(n) return n == goal end
  local h = type(heuristic_fn) == "function" and heuristic_fn or function() return 0 end

  local open = heap.new("min")
  local g_score = { [start] = 0 }
  local came_from = {}
  local closed = {}

  open:push(start, h(start, goal))

  while not open:empty() do
    local current = open:pop()
    if closed[current] then goto continue end
    closed[current] = true

    if goal_fn(current) then
      return reconstruct_path(came_from, current), g_score[current]
    end

    for _, nb in ipairs(neighbors_fn(current)) do
      local next_node, edge_cost = nb[1], nb[2]
      if not closed[next_node] then
        local new_g = g_score[current] + edge_cost
        if g_score[next_node] == nil or new_g < g_score[next_node] then
          g_score[next_node] = new_g
          came_from[next_node] = current
          local f = new_g + h(next_node, goal)
          open:push_or_update(next_node, f)
        end
      end
    end

    ::continue::
  end

  return nil, "no path found"
end

--- Dijkstra (A* with zero heuristic).
-- start: start node
-- goal: goal node OR goal_fn(node) -> boolean
-- neighbors_fn: function(node) -> {{node, cost}, ...}
-- Returns: path, total_cost  or  nil, "no path found"
function M.dijkstra(start, goal, neighbors_fn)
  return M.astar(start, goal, neighbors_fn, function() return 0 end)
end

--- Breadth-first search (unweighted).
-- start: start node
-- goal: goal node OR goal_fn(node) -> boolean
-- neighbors_fn: function(node) -> {node, ...} (plain array of neighbors, no costs)
-- Returns: path, steps  or  nil, "no path found"
function M.bfs(start, goal, neighbors_fn)
  local goal_fn = type(goal) == "function" and goal or function(n) return n == goal end
  local queue = { start }
  local head = 1
  local came_from = {}
  local visited = { [start] = true }
  local steps = { [start] = 0 }

  while head <= #queue do
    local current = queue[head]
    head = head + 1

    if goal_fn(current) then
      return reconstruct_path(came_from, --[[:! any]] current), steps[current]
    end

    for _, nb in ipairs(neighbors_fn(current)) do
      if not visited[nb] then
        visited[nb] = true
        came_from[nb] = current
        steps[nb] = steps[current] + 1
        queue[#queue + 1] = nb
      end
    end
  end

  return nil, "no path found"
end

--- Depth-first search (may not find shortest path).
-- start: start node
-- goal: goal node OR goal_fn(node) -> boolean
-- neighbors_fn: function(node) -> {node, ...} (plain array of neighbors, no costs)
-- Returns: path, steps  or  nil, "no path found"
function M.dfs(start, goal, neighbors_fn)
  local goal_fn = type(goal) == "function" and goal or function(n) return n == goal end
  local stack = { start }
  local came_from = {}
  local visited = { [start] = true }
  local steps = { [start] = 0 }

  while #stack > 0 do
    local current = table.remove(stack)

    if goal_fn(current) then
      return reconstruct_path(came_from, current), steps[current]
    end

    for _, nb in ipairs(neighbors_fn(current)) do
      if not visited[nb] then
        visited[nb] = true
        came_from[nb] = current
        steps[nb] = steps[current] + 1
        stack[#stack + 1] = nb
      end
    end
  end

  return nil, "no path found"
end

--- Bellman-Ford: single-source shortest paths (handles negative edge weights).
-- start: start node
-- nodes: array of all nodes
-- edges: array of {from, to, cost}
-- Returns: dist_map ({node = {dist=number, prev=node|nil}}), has_negative_cycle (boolean)
function M.bellman_ford(start, nodes, edges)
  local INF = math.huge
  local dist = {}
  local prev = {}

  for _, n in ipairs(nodes) do
    dist[n] = INF
    prev[n] = nil
  end
  dist[start] = 0

  local n_nodes = #nodes

  -- Relax edges |V|-1 times
  for _ = 1, n_nodes - 1 do
    local updated = false
    for _, e in ipairs(edges) do
      local u, v, w = e[1], e[2], e[3]
      if dist[u] ~= INF and dist[u] + w < dist[v] then
        dist[v] = dist[u] + w
        prev[v] = u
        updated = true
      end
    end
    if not updated then break end
  end

  -- Check for negative cycles
  local has_negative_cycle = false
  for _, e in ipairs(edges) do
    local u, v, w = e[1], e[2], e[3]
    if dist[u] ~= INF and dist[u] + w < dist[v] then
      has_negative_cycle = true
      break
    end
  end

  local result = {}
  for _, n in ipairs(nodes) do
    result[n] = { dist = dist[n], prev = prev[n] }
  end

  return result, has_negative_cycle
end

-- ========================
-- GRID PATHFINDING HELPERS
-- ========================

local DIRS_4 = { { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } }
local DIRS_8 = {
  { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 },
  { -1, -1 }, { -1, 1 }, { 1, -1 }, { 1, 1 },
}

local function default_obstacle(grid, row, col)
  local r = grid[row]
  return r == nil or r[col] == nil or r[col] ~= 0
end

local function heuristic_manhattan(r1, c1, r2, c2)
  local dr = r1 - r2
  local dc = c1 - c2
  return (dr < 0 and -dr or dr) + (dc < 0 and -dc or dc)
end

local function heuristic_euclidean(r1, c1, r2, c2)
  local dr = r1 - r2
  local dc = c1 - c2
  return math.sqrt(dr * dr + dc * dc)
end

local function heuristic_chebyshev(r1, c1, r2, c2)
  local dr = r1 - r2
  local dc = c1 - c2
  dr = dr < 0 and -dr or dr
  dc = dc < 0 and -dc or dc
  return dr > dc and dr or dc
end

-- ========================
-- GRID A*
-- ========================

--- A* on a 2D grid.
-- grid: 2D array (grid[row][col]); 0 = walkable, non-zero = obstacle
-- start, goal: {row, col} (1-indexed)
-- opts:
--   diagonal: boolean (8-dir movement; default false = 4-dir)
--   obstacle_fn: function(grid, row, col) -> boolean
--   heuristic: "manhattan"|"euclidean"|"chebyshev" (default "manhattan")
-- Returns: path (array of {row,col}), cost  or  nil, "no path found"
function M.grid_astar(grid, start, goal, opts)
  opts = opts or {}
  local obstacle = opts.obstacle_fn or default_obstacle
  local dirs = opts.diagonal and DIRS_8 or DIRS_4
  local h_name = opts.heuristic or "manhattan"

  local h_fn
  if h_name == "euclidean" then
    h_fn = heuristic_euclidean
  elseif h_name == "chebyshev" then
    h_fn = heuristic_chebyshev
  else
    h_fn = heuristic_manhattan
  end

  local sr, sc = start[1], start[2]
  local gr, gc = goal[1], goal[2]

  -- Early exit if start or goal is blocked
  if obstacle(grid, sr, sc) then return nil, "no path found" end
  if obstacle(grid, gr, gc) then return nil, "no path found" end

  local open = heap.new("min")
  local g_score = {}
  local came_from = {}
  local closed = {}

  local start_key = cell_key(sr, sc)
  local goal_key = cell_key(gr, gc)

  g_score[start_key] = 0
  open:push(start_key, h_fn(sr, sc, gr, gc))

  -- Decode key back to row, col
  local function decode(k)
    return math.floor(k / 65536), k % 65536
  end

  while not open:empty() do
    local cur_key = open:pop()
    if closed[cur_key] then goto grid_continue end
    closed[cur_key] = true

    if cur_key == goal_key then
      -- Reconstruct path as {row, col} tables
      local path = {}
      local k = cur_key
      while k do
        local r, c = decode(k)
        table.insert(path, 1, { r, c })
        k = came_from[k]
      end
      return path, g_score[cur_key]
    end

    local cur_r, cur_c = decode(cur_key)

    for _, d in ipairs(dirs) do
      local nr, nc = cur_r + d[1], cur_c + d[2]
      if not obstacle(grid, nr, nc) then
        local nk = cell_key(nr, nc)
        if not closed[nk] then
          -- Cost: 1 for cardinal, sqrt(2) for diagonal
          local move_cost = (d[1] ~= 0 and d[2] ~= 0) and 1.41421356 or 1
          local new_g = g_score[cur_key] + move_cost
          if g_score[nk] == nil or new_g < g_score[nk] then
            g_score[nk] = new_g
            came_from[nk] = cur_key
            local f = new_g + h_fn(nr, nc, gr, gc)
            open:push_or_update(nk, f)
          end
        end
      end
    end

    ::grid_continue::
  end

  return nil, "no path found"
end

--- Flood fill: find all reachable cells from start.
-- grid: 2D grid (0 = walkable)
-- start: {row, col}
-- opts: same as grid_astar (obstacle_fn, diagonal)
-- Returns: array of {row, col} reachable cells
function M.flood_fill(grid, start, opts)
  opts = opts or {}
  local obstacle = opts.obstacle_fn or default_obstacle
  local dirs = opts.diagonal and DIRS_8 or DIRS_4

  local sr, sc = start[1], start[2]
  if obstacle(grid, sr, sc) then return {} end

  local queue = { cell_key(sr, sc) }
  local head = 1
  local visited = { [cell_key(sr, sc)] = true }
  local result = {}

  while head <= #queue do
    local cur_key = queue[head]
    head = head + 1

    local r = math.floor(cur_key / 65536)
    local c = cur_key % 65536
    result[#result + 1] = { r, c }

    for _, d in ipairs(dirs) do
      local nr, nc = r + d[1], c + d[2]
      if not obstacle(grid, nr, nc) then
        local nk = cell_key(nr, nc)
        if not visited[nk] then
          visited[nk] = true
          queue[#queue + 1] = nk
        end
      end
    end
  end

  return result
end

--- Distance map: BFS distance from start to all reachable cells.
-- Returns: flat map { cell_key = dist }, where cell_key = row*65536+col
-- Also returns a decode helper: dm, decode
function M.distance_map(grid, start, opts)
  opts = opts or {}
  local obstacle = opts.obstacle_fn or default_obstacle
  local dirs = opts.diagonal and DIRS_8 or DIRS_4

  local sr, sc = start[1], start[2]
  local dist = {}

  if obstacle(grid, sr, sc) then return dist end

  local queue = { cell_key(sr, sc) }
  local head = 1
  dist[cell_key(sr, sc)] = 0

  while head <= #queue do
    local cur_key = queue[head]
    head = head + 1

    local r = math.floor(cur_key / 65536)
    local c = cur_key % 65536
    local d = dist[cur_key]

    for _, dir in ipairs(dirs) do
      local nr, nc = r + dir[1], c + dir[2]
      if not obstacle(grid, nr, nc) then
        local nk = cell_key(nr, nc)
        if dist[nk] == nil then
          dist[nk] = d + 1
          queue[#queue + 1] = nk
        end
      end
    end
  end

  return dist
end

-- ========================
-- FLOW FIELD
-- ========================

--- Compute flow field toward goal.
-- For each walkable cell, stores the direction {dr, dc} that moves toward goal.
-- Uses BFS from goal outward (reverse search).
-- Returns: 2D array flow[row][col] = {dr, dc}, or nil for unreachable cells
function M.flow_field(grid, goal, opts)
  opts = opts or {}
  local obstacle = opts.obstacle_fn or default_obstacle
  local dirs = DIRS_4  -- flow field uses 4-dir by default

  local gr, gc = goal[1], goal[2]

  -- BFS from goal outward
  local dist = {}
  local goal_key = cell_key(gr, gc)
  dist[goal_key] = 0

  local queue = { goal_key }
  local head = 1

  while head <= #queue do
    local cur_key = queue[head]
    head = head + 1

    local r = math.floor(cur_key / 65536)
    local c = cur_key % 65536
    local d = dist[cur_key]

    for _, dir in ipairs(dirs) do
      local nr, nc = r + dir[1], c + dir[2]
      if not obstacle(grid, nr, nc) then
        local nk = cell_key(nr, nc)
        if dist[nk] == nil then
          dist[nk] = d + 1
          queue[#queue + 1] = nk
        end
      end
    end
  end

  -- Build flow field: for each cell, pick neighbor with lowest dist (toward goal)
  local flow = {}
  for key, _ in pairs(dist) do
    local r = math.floor(key / 65536)
    local c = key % 65536

    if key == goal_key then
      -- At goal: no direction needed, use {0,0}
      if not flow[r] then flow[r] = {} end
      flow[r][c] = { 0, 0 }
    else
      local best_dist = math.huge
      local best_dir = nil
      for _, dir in ipairs(dirs) do
        local nr, nc = r + dir[1], c + dir[2]
        local nk = cell_key(nr, nc)
        if dist[nk] ~= nil and dist[nk] < best_dist then
          best_dist = dist[nk]
          best_dir = dir
        end
      end
      if best_dir then
        if not flow[r] then flow[r] = {} end
        flow[r][c] = best_dir
      end
    end
  end

  return flow
end

-- ========================
-- PATH SMOOTHING
-- ========================

--- String-pull path smoothing.
-- Removes intermediate waypoints if a direct line-of-sight exists.
-- los_fn: function(p1, p2) -> boolean (true if straight path is clear)
-- p1, p2 are elements from the path array.
-- Returns: smoothed path (subset of original path nodes)
function M.smooth_path(path, los_fn)
  if #path <= 2 then return path end

  local smoothed = { path[1] }
  local anchor = 1

  local i = 3
  while i <= #path do
    -- Check if we can go directly from anchor to i (skipping i-1)
    if not los_fn(path[anchor], path[i]) then
      -- Lost line-of-sight: commit i-1 as a waypoint
      anchor = i - 1
      smoothed[#smoothed + 1] = path[anchor]
    end
    i = i + 1
  end

  -- Always include the final node
  smoothed[#smoothed + 1] = path[#path]

  return smoothed
end

return M
