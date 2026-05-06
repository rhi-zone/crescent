-- lib/circuit_sim/init.lua
-- Analog circuit simulator using Modified Nodal Analysis (MNA)
-- Supports: resistors, voltage sources, current sources, wires
-- DC operating point, parameter sweep, Thevenin/Norton equivalents

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local M = {}

M._tier = "pure"

--:: CompRecord = { type: string, name: string, np: integer, nn: integer, value: number }
--:: CircuitShape = { _nodes: { [string]: integer }, _node_names: { [integer]: string }, _node_count: integer, _components: { [integer]: CompRecord }, _vsources: { [integer]: CompRecord }, node: (CircuitShape, string) -> integer, _ensure_node: (CircuitShape, any) -> integer, resistor: (CircuitShape, string, any, any, number) -> CircuitShape, voltage_source: (CircuitShape, string, any, any, number) -> CircuitShape, current_source: (CircuitShape, string, any, any, number) -> CircuitShape, wire: (CircuitShape, string, any, any) -> CircuitShape, _build_mna: (CircuitShape) -> any, solve_dc: (CircuitShape) -> any, sweep: (CircuitShape, string, string, any) -> any }
--:: ResultShape = { _voltages: { [string]: number }, _currents: { [string]: number }, _power: { [string]: number }, node_voltages: { [string]: number }, branch_currents: { [string]: number } }
--:: NumMatrix = { [integer]: { [integer]: number } }
--:: NumVec = { [integer]: number }

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
	local x = {} --: NumVec
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
--: (NumMatrix, integer) -> NumMatrix
local function copy_matrix(A, n)
	local B = {} --: NumMatrix
	for i = 1, n do
		B[i] = {}
		for j = 1, n do
			local Ai = A[i] --[[:! { [integer]: number }]]
			local Bi = B[i] --[[:! { [integer]: number }]]
			Bi[j] = Ai[j]
		end
	end
	return B
end

--: (NumVec, integer) -> NumVec
local function copy_vec(b, n)
	local v = {} --: NumVec
	for i = 1, n do v[i] = b[i] end
	return v
end

-- Result object returned by solve_dc
-- Internal fields: _voltages, _currents, _power
-- Public fields: node_voltages, branch_currents
-- Methods: voltage(name), current(name), power(name)
local Result = {}
Result.__index = Result

--: (ResultShape, string) -> number | nil
function Result:voltage(name)
	return self._voltages[name]
end

--: (ResultShape, string) -> number | nil
function Result:current(name)
	return self._currents[name]
end

--: (ResultShape, string) -> number | nil
function Result:power(name)
	return self._power[name]
end

-- Circuit object
local Circuit = {}
Circuit.__index = Circuit

function M.new()
	local c = setmetatable({
		_nodes = {},        -- name -> id (0 = ground)
		_node_names = {},   -- id -> name
		_node_count = 0,    -- number of non-ground nodes
		_components = {},   -- list of component tables
		_vsources = {},     -- list of voltage source component tables (ordered)
	}, Circuit) --[[: any]]
	return c --[[:! CircuitShape]]
end

-- Register a named node, returns its id (1-based, 0 = ground)
--: (CircuitShape, string) -> integer
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
--: (CircuitShape, any) -> integer
function Circuit:_ensure_node(n)
	if type(n) == "number" then
		local n_ = n --[[:! integer]]
		if n_ == 0 then return 0 end
		-- Register numeric nodes without a name if not already named
		if not self._node_names[n_] then
			if n_ > self._node_count then self._node_count = n_ end
			self._node_names[n_] = tostring(n_)
			self._nodes[tostring(n_)] = n_
		end
		return n_
	end
	return self:node(n --[[:! string]])
end

--: (CircuitShape, string, any, any, number) -> CircuitShape
function Circuit:resistor(name, np, nn, r)
	local np_ = self:_ensure_node(np)
	local nn_ = self:_ensure_node(nn)
	local r_ = r --[[:! number]]
	local comp = { type = "R", name = name --[[:! string]], np = np_, nn = nn_, value = r_ }
	self._components[#self._components + 1] = comp
	return self
end

--: (CircuitShape, string, any, any, number) -> CircuitShape
function Circuit:voltage_source(name, np, nn, v)
	local np_ = self:_ensure_node(np)
	local nn_ = self:_ensure_node(nn)
	local v_ = v --[[:! number]]
	local comp = { type = "V", name = name --[[:! string]], np = np_, nn = nn_, value = v_ }
	self._components[#self._components + 1] = comp
	self._vsources[#self._vsources + 1] = comp
	return self
end

--: (CircuitShape, string, any, any, number) -> CircuitShape
function Circuit:current_source(name, np, nn, i)
	local np_ = self:_ensure_node(np)
	local nn_ = self:_ensure_node(nn)
	local i_ = i --[[:! number]]
	local comp = { type = "I", name = name --[[:! string]], np = np_, nn = nn_, value = i_ }
	self._components[#self._components + 1] = comp
	return self
end

-- Wire = 0Ω resistance (implemented as voltage source with 0V)
--: (CircuitShape, string, any, any) -> CircuitShape
function Circuit:wire(name, np, nn)
	local np_ = self:_ensure_node(np)
	local nn_ = self:_ensure_node(nn)
	local comp = { type = "V", name = name --[[:! string]], np = np_, nn = nn_, value = 0.0 }
	self._components[#self._components + 1] = comp
	self._vsources[#self._vsources + 1] = comp
	return self
end

-- Build the MNA matrix. Returns A, b, size, vsource_idx_map
-- vsource_idx_map: vsource_name -> extra variable index (1-based into vsources)
--: (CircuitShape) -> any
function Circuit:_build_mna()
	local N = self._node_count    -- number of non-ground nodes
	local Nv = #self._vsources    -- number of voltage sources / wires
	local sz = N + Nv             -- total system size

	-- Initialize A and b
	local A = {} --: NumMatrix
	local b = {} --: NumVec
	for i = 1, sz do
		A[i] = {}
		b[i] = 0.0
		for j = 1, sz do
			local Ai = A[i] --[[:! { [integer]: number }]]
			Ai[j] = 0.0
		end
	end

	-- Stamp each component
	-- Nodes: 1..N map to rows/cols 1..N (ground = 0, excluded)
	-- Voltage source k maps to row/col N+k

	-- Build vsource index map
	local vsource_idx = {} --: { [string]: integer }
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
--: (CircuitShape) -> any
function Circuit:solve_dc()
	local mna = {self:_build_mna()} --[[:! { [integer]: any }]]
	local A_ = mna[1] --[[:! NumMatrix]]
	local b_ = mna[2] --[[:! NumVec]]
	local sz_ = mna[3] --[[:! integer]]
	local N_ = mna[4] --[[:! integer]]
	local vsource_idx_ = mna[5] --[[:! { [string]: integer }]]

	if sz_ == 0 then
		-- trivial: only ground node
		local empty_pwr = { total = 0.0 } --: { [string]: number }
		return setmetatable({
			_voltages = {} --[[:! { [string]: number }]],
			_currents = {} --[[:! { [string]: number }]],
			_power = empty_pwr,
			node_voltages = {} --[[:! { [string]: number }]],
			branch_currents = {} --[[:! { [string]: number }]],
		}, Result) --[[: any]]
	end

	local Ac = copy_matrix(A_, sz_)
	local bc = copy_vec(b_, sz_)
	local x = gaussian_solve(Ac, bc, sz_)
	if not x then return nil, "singular matrix" end

	-- Extract node voltages
	local node_voltages = { ["0"] = 0.0, gnd = 0.0 } --: { [string]: number }
	for id, name in pairs(self._node_names) do
		local id_ = id --[[:! integer]]
		node_voltages[name] = x[id_]
	end

	-- Extract branch currents
	local branch_currents = {} --: { [string]: number }
	-- For voltage sources: current is the extra variable
	for name, k in pairs(vsource_idx_) do
		branch_currents[name] = x[N_ + k]
	end
	-- For resistors: I = (V_np - V_nn) / R
	for _, comp in ipairs(self._components) do
		if comp.type == "R" then
			local vp = (comp.np == 0) and 0.0 or x[comp.np]
			local vn = (comp.nn == 0) and 0.0 or x[comp.nn]
			branch_currents[comp.name] = (vp - vn) / comp.value
		elseif comp.type == "I" then
			branch_currents[comp.name] = comp.value
		end
	end

	-- Compute power
	local power = { total = 0.0 } --: { [string]: number }
	local total_power = 0.0 --: number
	for _, comp in ipairs(self._components) do
		local name = comp.name
		local cur = branch_currents[name] or 0.0
		local vp = (comp.np == 0) and 0.0 or x[comp.np]
		local vn = (comp.nn == 0) and 0.0 or x[comp.nn]
		local v_drop = vp - vn
		local p = v_drop * cur
		power[name] = p
		if comp.type == "R" then total_power = total_power + p end
	end
	power["total"] = total_power

	return setmetatable({
		_voltages = node_voltages,
		_currents = branch_currents,
		_power = power,
		-- public aliases for direct table access (no 'power' field — use :power() method)
		node_voltages = node_voltages,
		branch_currents = branch_currents,
	}, Result) --[[: any]]
end

-- Parameter sweep: change a component value and solve for each
-- comp_name: component name, param: "voltage"/"current"/"resistance", values: array
--: (CircuitShape, string, string, any) -> any
function Circuit:sweep(comp_name, param, values)
	local values_ = values --[[:! { [integer]: number }]]
	-- Find the component
	local target = nil --: CompRecord|nil
	for _, comp in ipairs(self._components) do
		if comp.name == comp_name then
			target = comp
			break
		end
	end
	if not target then
		return nil, "component not found: " .. tostring(comp_name)
	end
	local target_ = target --[[:! CompRecord]]

	local original = target_.value
	local results = {}
	for i = 1, #values_ do
		target_.value = values_[i]
		-- Rebuild vsources list if needed (type change not supported)
		local result, err = self:solve_dc()
		if not result then
			target_.value = original
			return nil, err
		end
		results[i] = result
	end
	target_.value = original
	return results
end

-- Thevenin equivalent between two nodes
-- Returns {vth, rth} or (nil, errmsg)
function CS_thevenin(circuit, n_pos, n_neg)
	local c_ = circuit --[[:! CircuitShape]]
	local np = n_pos --[[:! integer]]
	local nn = n_neg --[[:! integer]]
	-- Vth = open circuit voltage between n_pos and n_neg
	local result = c_:solve_dc()
	if not result then return nil, "solve failed" end
	local result_ = result --[[:! ResultShape]]

	local np_name = c_._node_names[np] or tostring(np)
	local nn_name = (nn == 0) and "0" or (c_._node_names[nn] or tostring(nn))

	local vp = result_.node_voltages[np_name] or 0.0
	local vn = result_.node_voltages[nn_name] or 0.0
	local vth = vp - vn

	-- Rth: zero all independent sources, apply 1V test source between n_pos and n_neg
	-- Build modified circuit
	local test = M.new()
	-- Copy all nodes
	for id, name in pairs(c_._node_names) do
		local id_ = id --[[:! integer]]
		test._nodes[name] = id_
		test._node_names[id_] = name
		if id_ > test._node_count then test._node_count = id_ end
	end
	-- Copy components with zeroed sources
	for _, comp in ipairs(c_._components) do
		if comp.type == "R" then
			test:resistor(comp.name, comp.np, comp.nn, comp.value)
		elseif comp.type == "V" then
			test:voltage_source(comp.name, comp.np, comp.nn, 0.0)
		elseif comp.type == "I" then
			-- zero current source = open circuit: skip
		end
	end
	-- Add 1V test source
	test:voltage_source("_test_vth", np, nn, 1.0)

	local tr = test:solve_dc()
	if not tr then return nil, "solve failed on test circuit" end
	local tr_ = tr --[[:! ResultShape]]

	local i_test = tr_.branch_currents["_test_vth"]
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
	local th = CS_thevenin(circuit, n_pos, n_neg)
	if not th then return nil, "thevenin failed" end
	local th_ = th --[[:! { vth: number, rth: number }]]
	local rn = th_.rth
	local in_ = th_.vth / rn
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
