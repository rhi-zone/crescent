if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

-- Graph metatable
local Graph = {}
Graph.__index = Graph

--: (opts: { directed: boolean? }?) -> Graph
function M.new(opts)
	local directed = true
	if opts and opts.directed == false then
		directed = false
	end
	local g = {
		_directed = directed,
		_adj = {},       -- vertex_id -> { {to, weight}, ... }
		_in_adj = {},    -- vertex_id -> { {from, weight}, ... } (directed only)
		_data = {},      -- vertex_id -> user data
		_vcount = 0,
		_ecount = 0,
	}
	return setmetatable(g, Graph)
end

--: (id: unknown, data: unknown?) -> boolean
function Graph:add_vertex(id, data)
	if self._adj[id] then return false end
	self._adj[id] = {}
	if self._directed then
		self._in_adj[id] = {}
	end
	self._data[id] = data
	self._vcount = self._vcount + 1
	return true
end

--: (id: unknown) -> boolean
function Graph:remove_vertex(id)
	if not self._adj[id] then return false end
	-- Remove all outgoing edges
	local out = self._adj[id]
	for i = 1, #out do
		local to = out[i][1]
		if self._directed then
			-- Remove from in_adj of target
			local ins = self._in_adj[to]
			if ins then
				for j = #ins, 1, -1 do
					if ins[j][1] == id then
						ins[j] = ins[#ins]
						ins[#ins] = nil
					end
				end
			end
		else
			-- Remove reverse edge (unless self-loop, handled below)
			if to ~= id then
				local adj_to = self._adj[to]
				if adj_to then
					for j = #adj_to, 1, -1 do
						if adj_to[j][1] == id then
							adj_to[j] = adj_to[#adj_to]
							adj_to[#adj_to] = nil
						end
					end
				end
			end
		end
		self._ecount = self._ecount - 1
	end
	-- Remove all incoming edges (directed only)
	if self._directed then
		local ins = self._in_adj[id]
		for i = 1, #ins do
			local from = ins[i][1]
			if from ~= id then -- self-loop already removed above
				local adj_from = self._adj[from]
				if adj_from then
					for j = #adj_from, 1, -1 do
						if adj_from[j][1] == id then
							adj_from[j] = adj_from[#adj_from]
							adj_from[#adj_from] = nil
							self._ecount = self._ecount - 1
						end
					end
				end
			end
		end
		self._in_adj[id] = nil
	end
	self._adj[id] = nil
	self._data[id] = nil
	self._vcount = self._vcount - 1
	return true
end

--: (id: unknown) -> boolean
function Graph:has_vertex(id)
	return self._adj[id] ~= nil
end

--: () -> { unknown }
function Graph:vertices()
	local result = {}
	for id in pairs(self._adj) do
		result[#result + 1] = id
	end
	return result
end

--: (id: unknown) -> unknown
function Graph:vertex_data(id)
	return self._data[id]
end

--: () -> number
function Graph:vertex_count()
	return self._vcount
end

--: (from: unknown, to: unknown, weight: number?) -> boolean, string?
function Graph:add_edge(from, to, weight)
	if not self._adj[from] then
		return false, "vertex not found: " .. tostring(from)
	end
	if not self._adj[to] then
		return false, "vertex not found: " .. tostring(to)
	end
	weight = weight or 1
	-- Check if edge already exists
	local out = self._adj[from]
	for i = 1, #out do
		if out[i][1] == to then
			return false, "edge already exists"
		end
	end
	out[#out + 1] = { to, weight }
	if self._directed then
		local ins = self._in_adj[to]
		ins[#ins + 1] = { from, weight }
	else
		-- Add reverse edge (unless self-loop)
		if from ~= to then
			local rev = self._adj[to]
			rev[#rev + 1] = { from, weight }
		end
	end
	self._ecount = self._ecount + 1
	return true
end

--: (from: unknown, to: unknown) -> boolean
function Graph:remove_edge(from, to)
	local out = self._adj[from]
	if not out then return false end
	local found = false
	for i = #out, 1, -1 do
		if out[i][1] == to then
			out[i] = out[#out]
			out[#out] = nil
			found = true
			break
		end
	end
	if not found then return false end
	if self._directed then
		local ins = self._in_adj[to]
		if ins then
			for i = #ins, 1, -1 do
				if ins[i][1] == from then
					ins[i] = ins[#ins]
					ins[#ins] = nil
					break
				end
			end
		end
	else
		if from ~= to then
			local rev = self._adj[to]
			if rev then
				for i = #rev, 1, -1 do
					if rev[i][1] == from then
						rev[i] = rev[#rev]
						rev[#rev] = nil
						break
					end
				end
			end
		end
	end
	self._ecount = self._ecount - 1
	return true
end

--: (from: unknown, to: unknown) -> boolean
function Graph:has_edge(from, to)
	local out = self._adj[from]
	if not out then return false end
	for i = 1, #out do
		if out[i][1] == to then return true end
	end
	return false
end

--: (from: unknown, to: unknown) -> number?
function Graph:edge_weight(from, to)
	local out = self._adj[from]
	if not out then return nil end
	for i = 1, #out do
		if out[i][1] == to then return out[i][2] end
	end
	return nil
end

--: () -> { { from: unknown, to: unknown, weight: number } }
function Graph:edges()
	local result = {}
	local seen = {}
	for from, out in pairs(self._adj) do
		for i = 1, #out do
			local to = out[i][1]
			local w = out[i][2]
			if self._directed then
				result[#result + 1] = { from = from, to = to, weight = w }
			else
				-- Deduplicate undirected edges
				local key = from < to and (tostring(from) .. "\0" .. tostring(to))
					or (tostring(to) .. "\0" .. tostring(from))
				if from == to then
					key = tostring(from) .. "\0" .. tostring(to) .. "\0self"
				end
				if not seen[key] then
					seen[key] = true
					result[#result + 1] = { from = from, to = to, weight = w }
				end
			end
		end
	end
	return result
end

--: () -> number
function Graph:edge_count()
	return self._ecount
end

--: (id: unknown) -> { unknown }
function Graph:neighbors(id)
	local out = self._adj[id]
	if not out then return {} end
	local result = {}
	for i = 1, #out do
		result[#result + 1] = out[i][1]
	end
	return result
end

--: (id: unknown) -> { unknown }
function Graph:in_neighbors(id)
	if not self._directed then
		return self:neighbors(id)
	end
	local ins = self._in_adj[id]
	if not ins then return {} end
	local result = {}
	for i = 1, #ins do
		result[#result + 1] = ins[i][1]
	end
	return result
end

--: (id: unknown) -> number
function Graph:degree(id)
	local out = self._adj[id]
	if not out then return 0 end
	return #out
end

--: (id: unknown) -> number
function Graph:in_degree(id)
	if not self._directed then
		return self:degree(id)
	end
	local ins = self._in_adj[id]
	if not ins then return 0 end
	return #ins
end

-- Algorithms

--: (g: Graph, start: unknown) -> { unknown }
function M.bfs(g, start)
	if not g._adj[start] then return {} end
	local visited = {}
	local result = {}
	local queue = { start }
	local head = 1
	visited[start] = true
	while head <= #queue do
		local v = queue[head]
		head = head + 1
		result[#result + 1] = v
		local out = g._adj[v]
		for i = 1, #out do
			local to = out[i][1]
			if not visited[to] then
				visited[to] = true
				queue[#queue + 1] = to
			end
		end
	end
	return result
end

--: (g: Graph, start: unknown) -> { unknown }
function M.dfs(g, start)
	if not g._adj[start] then return {} end
	local visited = {}
	local result = {}
	local stack = { start }
	while #stack > 0 do
		local v = stack[#stack]
		stack[#stack] = nil
		if not visited[v] then
			visited[v] = true
			result[#result + 1] = v
			-- Push neighbors in reverse order so first neighbor is visited first
			local out = g._adj[v]
			for i = #out, 1, -1 do
				local to = out[i][1]
				if not visited[to] then
					stack[#stack + 1] = to
				end
			end
		end
	end
	return result
end

--: (g: Graph) -> { unknown }?, string?
function M.topological_sort(g)
	if not g._directed then
		return nil, "topological sort requires a directed graph"
	end
	-- Kahn's algorithm
	local in_deg = {}
	local queue = {}
	local result = {}
	-- Compute in-degrees
	for v in pairs(g._adj) do
		in_deg[v] = 0
	end
	for _, out in pairs(g._adj) do
		for i = 1, #out do
			local to = out[i][1]
			in_deg[to] = in_deg[to] + 1
		end
	end
	-- Seed queue with zero in-degree vertices
	for v, d in pairs(in_deg) do
		if d == 0 then
			queue[#queue + 1] = v
		end
	end
	local head = 1
	while head <= #queue do
		local v = queue[head]
		head = head + 1
		result[#result + 1] = v
		local out = g._adj[v]
		for i = 1, #out do
			local to = out[i][1]
			in_deg[to] = in_deg[to] - 1
			if in_deg[to] == 0 then
				queue[#queue + 1] = to
			end
		end
	end
	if #result ~= g._vcount then
		return nil, "cycle detected"
	end
	return result
end

--: (g: Graph, from: unknown, to: unknown) -> { path: { unknown }, distance: number }?
function M.shortest_path(g, from, to)
	if not g._adj[from] or not g._adj[to] then return nil end
	-- Dijkstra with simple scan (no heap)
	local dist = {}
	local prev = {}
	local visited = {}
	dist[from] = 0
	while true do
		-- Find unvisited vertex with smallest distance
		local u = nil
		local d = math.huge
		for v, dv in pairs(dist) do
			if not visited[v] and dv < d then
				u = v
				d = dv
			end
		end
		if u == nil then break end
		if u == to then
			-- Reconstruct path
			local path = {}
			local cur = to
			while cur do
				path[#path + 1] = cur
				cur = prev[cur]
			end
			-- Reverse
			local n = #path
			for i = 1, n / 2 do
				path[i], path[n - i + 1] = path[n - i + 1], path[i]
			end
			return { path = path, distance = d }
		end
		visited[u] = true
		local out = g._adj[u]
		for i = 1, #out do
			local v = out[i][1]
			local w = out[i][2]
			if w < 0 then
				-- Dijkstra does not support negative weights
				return nil
			end
			local alt = d + w
			if dist[v] == nil or alt < dist[v] then
				dist[v] = alt
				prev[v] = u
			end
		end
	end
	return nil
end

--: (g: Graph) -> boolean
function M.has_cycle(g)
	if g._directed then
		-- DFS with coloring: 0=white, 1=gray, 2=black
		local color = {}
		for v in pairs(g._adj) do
			color[v] = 0
		end
		local function visit(v)
			color[v] = 1
			local out = g._adj[v]
			for i = 1, #out do
				local to = out[i][1]
				if color[to] == 1 then return true end
				if color[to] == 0 and visit(to) then return true end
			end
			color[v] = 2
			return false
		end
		for v in pairs(g._adj) do
			if color[v] == 0 and visit(v) then return true end
		end
		return false
	else
		-- Undirected: DFS, track parent
		local visited = {}
		local function visit(v, parent)
			visited[v] = true
			local out = g._adj[v]
			for i = 1, #out do
				local to = out[i][1]
				if not visited[to] then
					if visit(to, v) then return true end
				elseif to ~= parent then
					return true
				end
			end
			return false
		end
		for v in pairs(g._adj) do
			if not visited[v] and visit(v, nil) then return true end
		end
		return false
	end
end

--: (g: Graph) -> { { unknown } }
function M.connected_components(g)
	local visited = {}
	local components = {}
	for v in pairs(g._adj) do
		if not visited[v] then
			local comp = {}
			-- BFS
			local queue = { v }
			local head = 1
			visited[v] = true
			while head <= #queue do
				local u = queue[head]
				head = head + 1
				comp[#comp + 1] = u
				local out = g._adj[u]
				for i = 1, #out do
					local to = out[i][1]
					if not visited[to] then
						visited[to] = true
						queue[#queue + 1] = to
					end
				end
			end
			components[#components + 1] = comp
		end
	end
	return components
end

--: (g: Graph) -> { { unknown } }
function M.strongly_connected(g)
	-- Tarjan's SCC algorithm
	local index_counter = 0
	local stack = {}
	local on_stack = {}
	local index = {}
	local lowlink = {}
	local result = {}

	local function strongconnect(v)
		index[v] = index_counter
		lowlink[v] = index_counter
		index_counter = index_counter + 1
		stack[#stack + 1] = v
		on_stack[v] = true

		local out = g._adj[v]
		for i = 1, #out do
			local w = out[i][1]
			if index[w] == nil then
				strongconnect(w)
				if lowlink[w] < lowlink[v] then
					lowlink[v] = lowlink[w]
				end
			elseif on_stack[w] then
				if index[w] < lowlink[v] then
					lowlink[v] = index[w]
				end
			end
		end

		if lowlink[v] == index[v] then
			local comp = {}
			while true do
				local w = stack[#stack]
				stack[#stack] = nil
				on_stack[w] = false
				comp[#comp + 1] = w
				if w == v then break end
			end
			result[#result + 1] = comp
		end
	end

	for v in pairs(g._adj) do
		if index[v] == nil then
			strongconnect(v)
		end
	end
	return result
end

--: (g: Graph) -> Graph
function M.transpose(g)
	local t = M.new({ directed = g._directed })
	for v, data in pairs(g._data) do
		t:add_vertex(v, data)
	end
	-- Also add vertices with no data
	for v in pairs(g._adj) do
		if not t._adj[v] then
			t:add_vertex(v)
		end
	end
	for from, out in pairs(g._adj) do
		for i = 1, #out do
			local to = out[i][1]
			local w = out[i][2]
			t:add_edge(to, from, w)
		end
	end
	return t
end

return M
