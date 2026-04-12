-- lib/circuit_sim/init.lua
-- Analog circuit simulator using Modified Nodal Analysis (MNA)
-- Supports: resistors, voltage sources, current sources, wires
-- DC operating point, parameter sweep, Thevenin/Norton equivalents

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

M._tier = "pure"

-- Gaussian elimination with partial pivoting
-- Solves Ax = b in place, returns x or (nil, errmsg)
local function gaussian_solve(A, b, n)
	-- Forward elimination with partial pivoting
	for col = 1, n do
		-- Find pivot
		local max_val = math.abs(A[col][col])
		local max_row = col
		for row = col + 1, n do
			local v = math.abs(A[row][col])
			if v > max_val then
				max_val = v
				max_row = row
			end
		end
		if max_val < 1e-14 then
			return nil, "singular matrix: circuit may be ill-conditioned or have floating nodes"
		end
		-- Swap rows
		if max_row ~= col then
			A[col], A[max_row] = A[max_row], A[col]
			b[col], b[max_row] = b[max_row], b[col]
		end
		-- Eliminate below
		local pivot = A[col][col]
		for row = col + 1, n do
			local factor = A[row][col] / pivot
			for c = col, n do
				A[row][c] = A[row][c] - factor * A[col][c]
			end
			b[row] = b[row] - factor * b[col]
		end
	end
	-- Back substitution
	local x = {}
	for row = n, 1, -1 do
		local sum = b[row]
		for c = row + 1, n do
			sum = sum - A[row][c] * x[c]
		end
		x[row] = sum / A[row][row]
	end
	return x
end

-- Deep copy a 2D matrix
local function copy_matrix(A, n)
	local B = {}
	for i = 1, n do
		B[i] = {}
		for j = 1, n do
			B[i][j] = A[i][j]
		end
	end
	return B
end

local function copy_vec(b, n)
	local v = {}
	for i = 1, n do v[i] = b[i] end
	return v
end

-- Result object returned by solve_dc
-- Internal fields: _voltages, _currents, _power
-- Public fields: node_voltages, branch_currents
-- Methods: voltage(name), current(name), power(name)
local Result = {}
Result.__index = Result

function Result:voltage(name)
	return self._voltages[name]
end

function Result:current(name)
	return self._currents[name]
end

function Result:power(name)
	return self._power[name]
end

-- Circuit object
local Circuit = {}
Circuit.__index = Circuit

function M.new()
	local c = setmetatable({}, Circuit)
	c._nodes = {}        -- name -> id (0 = ground)
	c._node_names = {}   -- id -> name
	c._node_count = 0    -- number of non-ground nodes
	c._components = {}   -- list of component tables
	c._vsources = {}     -- list of voltage source component tables (ordered)
	return c
end

-- Register a named node, returns its id (1-based, 0 = ground)
function Circuit:node(name)
	if name == "0" or name == "gnd" or name == "GND" then
		return 0
	end
	if self._nodes[name] then
		return self._nodes[name]
	end
	self._node_count = self._node_count + 1
	local id = self._node_count
	self._nodes[name] = id
	self._node_names[id] = name
	return id
end

-- Get or register node by id or name
function Circuit:_ensure_node(n)
	if type(n) == "number" then
		if n == 0 then return 0 end
		-- Register numeric nodes without a name if not already named
		if not self._node_names[n] then
			if n > self._node_count then self._node_count = n end
			self._node_names[n] = tostring(n)
			self._nodes[tostring(n)] = n
		end
		return n
	end
	return self:node(n)
end

function Circuit:resistor(name, np, nn, r)
	np = self:_ensure_node(np)
	nn = self:_ensure_node(nn)
	local comp = { type = "R", name = name, np = np, nn = nn, value = r }
	self._components[#self._components + 1] = comp
	return self
end

function Circuit:voltage_source(name, np, nn, v)
	np = self:_ensure_node(np)
	nn = self:_ensure_node(nn)
	local comp = { type = "V", name = name, np = np, nn = nn, value = v }
	self._components[#self._components + 1] = comp
	self._vsources[#self._vsources + 1] = comp
	return self
end

function Circuit:current_source(name, np, nn, i)
	np = self:_ensure_node(np)
	nn = self:_ensure_node(nn)
	local comp = { type = "I", name = name, np = np, nn = nn, value = i }
	self._components[#self._components + 1] = comp
	return self
end

-- Wire = 0Ω resistance (implemented as voltage source with 0V)
function Circuit:wire(name, np, nn)
	np = self:_ensure_node(np)
	nn = self:_ensure_node(nn)
	local comp = { type = "V", name = name, np = np, nn = nn, value = 0.0 }
	self._components[#self._components + 1] = comp
	self._vsources[#self._vsources + 1] = comp
	return self
end

-- Build the MNA matrix. Returns A, b, size, vsource_idx_map
-- vsource_idx_map: vsource_name -> extra variable index (1-based into vsources)
function Circuit:_build_mna()
	local N = self._node_count    -- number of non-ground nodes
	local Nv = #self._vsources    -- number of voltage sources / wires
	local sz = N + Nv             -- total system size

	-- Initialize A and b
	local A = {}
	local b = {}
	for i = 1, sz do
		A[i] = {}
		b[i] = 0
		for j = 1, sz do
			A[i][j] = 0
		end
	end

	-- Stamp each component
	-- Nodes: 1..N map to rows/cols 1..N (ground = 0, excluded)
	-- Voltage source k maps to row/col N+k

	-- Build vsource index map
	local vsource_idx = {}
	for k, vs in ipairs(self._vsources) do
		vsource_idx[vs.name] = k
	end

	for _, comp in ipairs(self._components) do
		local t = comp.type
		local i = comp.np   -- positive node (0 = ground)
		local j = comp.nn   -- negative node (0 = ground)

		if t == "R" then
			local G = 1.0 / comp.value
			if i ~= 0 then A[i][i] = A[i][i] + G end
			if j ~= 0 then A[j][j] = A[j][j] + G end
			if i ~= 0 and j ~= 0 then
				A[i][j] = A[i][j] - G
				A[j][i] = A[j][i] - G
			end
		elseif t == "V" then
			local k = vsource_idx[comp.name]
			local row = N + k
			-- KCL: inject current into np, extract from nn
			if i ~= 0 then
				A[i][row] = A[i][row] + 1
				A[row][i] = A[row][i] + 1
			end
			if j ~= 0 then
				A[j][row] = A[j][row] - 1
				A[row][j] = A[row][j] - 1
			end
			-- KVL: V_np - V_nn = value
			b[row] = b[row] + comp.value
		elseif t == "I" then
			-- Current source: current flows from j to i (conventional: np is where current exits)
			-- I flows into np (positive), out of nn (negative)
			if i ~= 0 then b[i] = b[i] + comp.value end
			if j ~= 0 then b[j] = b[j] - comp.value end
		end
	end

	return A, b, sz, N, vsource_idx
end

-- Solve DC operating point
-- Returns Result object or (nil, errmsg)
function Circuit:solve_dc()
	local A, b, sz, N, vsource_idx = self:_build_mna()

	if sz == 0 then
		-- trivial: only ground node
		local empty_pwr = { total = 0 }
		return setmetatable({
			_voltages = {}, _currents = {}, _power = empty_pwr,
			node_voltages = {}, branch_currents = {},
		}, Result)
	end

	local Ac = copy_matrix(A, sz)
	local bc = copy_vec(b, sz)
	local x, err = gaussian_solve(Ac, bc, sz)
	if not x then return nil, err end

	-- Extract node voltages
	local node_voltages = {}
	for id, name in pairs(self._node_names) do
		node_voltages[name] = x[id]
	end
	node_voltages["0"] = 0
	node_voltages["gnd"] = 0

	-- Extract branch currents
	local branch_currents = {}
	-- For voltage sources: current is the extra variable
	for name, k in pairs(vsource_idx) do
		branch_currents[name] = x[N + k]
	end
	-- For resistors: I = (V_np - V_nn) / R
	for _, comp in ipairs(self._components) do
		if comp.type == "R" then
			local vp = (comp.np == 0) and 0 or x[comp.np]
			local vn = (comp.nn == 0) and 0 or x[comp.nn]
			branch_currents[comp.name] = (vp - vn) / comp.value
		elseif comp.type == "I" then
			branch_currents[comp.name] = comp.value
		end
	end

	-- Compute power
	local power = {}
	local total_power = 0
	for _, comp in ipairs(self._components) do
		local name = comp.name
		local cur = branch_currents[name]
		local vp = (comp.np == 0) and 0 or x[comp.np]
		local vn = (comp.nn == 0) and 0 or x[comp.nn]
		local v_drop = vp - vn
		local p = v_drop * cur
		power[name] = p
		if comp.type == "R" then total_power = total_power + p end
	end
	power.total = total_power

	return setmetatable({
		_voltages = node_voltages,
		_currents = branch_currents,
		_power = power,
		-- public aliases for direct table access (no 'power' field — use :power() method)
		node_voltages = node_voltages,
		branch_currents = branch_currents,
	}, Result)
end

-- Parameter sweep: change a component value and solve for each
-- comp_name: component name, param: "voltage"/"current"/"resistance", values: array
function Circuit:sweep(comp_name, param, values)
	-- Find the component
	local target = nil
	for _, comp in ipairs(self._components) do
		if comp.name == comp_name then
			target = comp
			break
		end
	end
	if not target then
		return nil, "component not found: " .. tostring(comp_name)
	end

	local original = target.value
	local results = {}
	for i = 1, #values do
		target.value = values[i]
		-- Rebuild vsources list if needed (type change not supported)
		local result, err = self:solve_dc()
		if not result then
			target.value = original
			return nil, err
		end
		results[i] = result
	end
	target.value = original
	return results
end

-- Thevenin equivalent between two nodes
-- Returns {vth, rth} or (nil, errmsg)
function CS_thevenin(circuit, n_pos, n_neg)
	-- Vth = open circuit voltage between n_pos and n_neg
	local result, err = circuit:solve_dc()
	if not result then return nil, err end

	local np_name = circuit._node_names[n_pos] or tostring(n_pos)
	local nn_name = (n_neg == 0) and "0" or (circuit._node_names[n_neg] or tostring(n_neg))

	local vp = result.node_voltages[np_name] or 0
	local vn = result.node_voltages[nn_name] or 0
	local vth = vp - vn

	-- Rth: zero all independent sources, apply 1V test source between n_pos and n_neg
	-- Build modified circuit
	local test = M.new()
	-- Copy all nodes
	for id, name in pairs(circuit._node_names) do
		test._nodes[name] = id
		test._node_names[id] = name
		if id > test._node_count then test._node_count = id end
	end
	-- Copy components with zeroed sources
	for _, comp in ipairs(circuit._components) do
		if comp.type == "R" then
			test:resistor(comp.name, comp.np, comp.nn, comp.value)
		elseif comp.type == "V" then
			test:voltage_source(comp.name, comp.np, comp.nn, 0)
		elseif comp.type == "I" then
			-- zero current source = open circuit: skip
		end
	end
	-- Add 1V test source
	test:voltage_source("_test_vth", n_pos, n_neg, 1.0)

	local tr, terr = test:solve_dc()
	if not tr then return nil, terr end

	local i_test = tr.branch_currents["_test_vth"]
	if not i_test or math.abs(i_test) < 1e-15 then
		return nil, "cannot determine Rth: zero test current"
	end
	-- MNA convention: I_b is negative of current delivered into np by source
	-- So actual current into n_pos = -i_test; Rth = V_test / I_into = 1 / (-i_test)
	local rth = -1.0 / i_test

	return { vth = vth, rth = rth }
end

-- Norton equivalent between two nodes
-- Returns {in_, rn} or (nil, errmsg)
local function CS_norton(circuit, n_pos, n_neg)
	local th, err = CS_thevenin(circuit, n_pos, n_neg)
	if not th then return nil, err end
	local rn = th.rth
	local in_ = th.vth / rn
	return { in_ = in_, rn = rn }
end

M.thevenin = CS_thevenin
M.norton = CS_norton

-- Convenience: voltage divider
-- Returns {circuit, result}
function M.voltage_divider(v_in, r1, r2)
	local c = M.new()
	local n1 = c:node("n1")
	local n2 = c:node("n2")
	c:voltage_source("V1", n1, 0, v_in)
	c:resistor("R1", n1, n2, r1)
	c:resistor("R2", n2, 0, r2)
	local result, err = c:solve_dc()
	if not result then return nil, err end
	return { circuit = c, result = result }
end

-- Convenience: Wheatstone bridge
-- Standard bridge: V_in across top; R1/R2 form left arm, R3/R4 form right arm
-- Nodes: n1=top, n2=left-mid, n3=right-mid, ground=bottom
-- R1: n1->n2, R2: n2->0, R3: n1->n3, R4: n3->0
-- V_in: n1->0
function M.wheatstone_bridge(r1, r2, r3, r4, v_in)
	local c = M.new()
	local n1 = c:node("n1")
	local n2 = c:node("n2")
	local n3 = c:node("n3")
	c:voltage_source("V1", n1, 0, v_in)
	c:resistor("R1", n1, n2, r1)
	c:resistor("R2", n2, 0, r2)
	c:resistor("R3", n1, n3, r3)
	c:resistor("R4", n3, 0, r4)
	local result, err = c:solve_dc()
	if not result then return nil, err end
	return { circuit = c, result = result }
end

return M
