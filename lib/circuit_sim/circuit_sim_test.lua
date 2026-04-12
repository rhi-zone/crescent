-- lib/circuit_sim/circuit_sim_test.lua
-- Tests for the analog circuit simulator (MNA-based)

if not package.path:find("./?/init.lua", 1, true) then
	package.path = "./?/init.lua;" .. package.path
end

local T = require("lib.test.assert")
local CS = require("lib.circuit_sim")

local EPS = 1e-9

local function near(a, b, msg)
	local ok = math.abs(a - b) < 1e-9
	local label = (msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a)
	T.ok(ok, label)
end

T.describe("circuit_sim", function()

	T.it("tier is pure", function()
		T.eq(CS._tier, "pure")
	end)

	-- -------------------------------------------------------------------------
	T.describe("voltage divider (V1=10V, R1=R2=1000Ω)", function()
		local c = CS.new()
		local n1 = c:node("n1")
		local n2 = c:node("n2")
		c:voltage_source("V1", n1, 0, 10)
		c:resistor("R1", n1, n2, 1000)
		c:resistor("R2", n2, 0, 1000)
		local r = c:solve_dc()

		T.it("n1 = 10V", function()
			near(r:voltage("n1"), 10.0)
		end)
		T.it("n2 = 5V (midpoint)", function()
			near(r:voltage("n2"), 5.0)
		end)
		T.it("gnd = 0V", function()
			near(r.node_voltages["0"], 0.0)
		end)
		T.it("current through R1 = 5mA", function()
			near(r:current("R1"), 0.005)
		end)
		T.it("current through R2 = 5mA", function()
			near(r:current("R2"), 0.005)
		end)
		T.it("power in R1 = 25mW", function()
			near(r:power("R1"), 0.025)
		end)
		T.it("power in R2 = 25mW", function()
			near(r:power("R2"), 0.025)
		end)
		T.it("total power = 50mW", function()
			near(r:power("total"), 0.05)
		end)
	end)

	-- -------------------------------------------------------------------------
	T.describe("single resistor (V1=5V, R1=100Ω)", function()
		local c = CS.new()
		local n1 = c:node("n1")
		c:voltage_source("V1", n1, 0, 5)
		c:resistor("R1", n1, 0, 100)
		local r = c:solve_dc()

		T.it("n1 = 5V", function()
			near(r:voltage("n1"), 5.0)
		end)
		T.it("current through R1 = 50mA", function()
			near(r:current("R1"), 0.05)
		end)
		T.it("current from V1 = -50mA (supplies current)", function()
			-- Voltage source current convention: positive = into np
			-- V1: np=n1, nn=0; current flows n1->R1->0, so source supplies +50mA
			-- MNA convention: extra variable is current into np from source
			-- so I_V1 = -0.05 (source pushes current out of np into circuit)
			T.ok(math.abs(r:current("V1")) - 0.05 < EPS)
		end)
		T.it("power in R1 = 250mW", function()
			near(r:power("R1"), 0.25)
		end)
	end)

	-- -------------------------------------------------------------------------
	T.describe("parallel resistors (two 100Ω)", function()
		-- V1=1V, R1=100Ω, R2=100Ω both across the source
		-- Equivalent resistance = 50Ω, total current = 20mA
		local c = CS.new()
		local n1 = c:node("n1")
		c:voltage_source("V1", n1, 0, 1)
		c:resistor("R1", n1, 0, 100)
		c:resistor("R2", n1, 0, 100)
		local r = c:solve_dc()

		T.it("n1 = 1V", function()
			near(r:voltage("n1"), 1.0)
		end)
		T.it("R1 current = 10mA", function()
			near(r:current("R1"), 0.01)
		end)
		T.it("R2 current = 10mA", function()
			near(r:current("R2"), 0.01)
		end)
		T.it("total current from V1 = 20mA", function()
			-- total current = I_R1 + I_R2 = 20mA
			-- V1 current (into circuit) should be -20mA in MNA convention
			T.ok(math.abs(math.abs(r:current("V1")) - 0.02) < EPS)
		end)
	end)

	-- -------------------------------------------------------------------------
	T.describe("current source (I1=1A, R1=10Ω to ground)", function()
		-- Current source pushes 1A into n1; R1 connects n1 to ground
		-- V_n1 = I * R = 10V
		local c = CS.new()
		local n1 = c:node("n1")
		c:current_source("I1", n1, 0, 1.0)
		c:resistor("R1", n1, 0, 10)
		local r = c:solve_dc()

		T.it("n1 = 10V", function()
			near(r:voltage("n1"), 10.0)
		end)
		T.it("current through R1 = 1A", function()
			near(r:current("R1"), 1.0)
		end)
		T.it("current source value = 1A", function()
			near(r:current("I1"), 1.0)
		end)
		T.it("power in R1 = 10W", function()
			near(r:power("R1"), 10.0)
		end)
	end)

	-- -------------------------------------------------------------------------
	T.describe("KVL verification (voltage divider loop)", function()
		local c = CS.new()
		local n1 = c:node("n1")
		local n2 = c:node("n2")
		c:voltage_source("V1", n1, 0, 12)
		c:resistor("R1", n1, n2, 300)
		c:resistor("R2", n2, 0, 700)
		local r = c:solve_dc()

		T.it("V_n1 = 12V", function()
			near(r:voltage("n1"), 12.0)
		end)
		T.it("V_n2 proportional to divider ratio", function()
			-- V_n2 = 12 * 700/(300+700) = 8.4V
			near(r:voltage("n2"), 8.4)
		end)
		T.it("KVL: V_source - V_R1 - V_R2 = 0", function()
			local v_r1 = r:voltage("n1") - r:voltage("n2")
			local v_r2 = r:voltage("n2") - 0
			local kvl = 12 - v_r1 - v_r2
			T.ok(math.abs(kvl) < EPS)
		end)
	end)

	-- -------------------------------------------------------------------------
	T.describe("KCL verification (node currents sum to zero)", function()
		-- Three-node circuit: V1 source, two branches from n1
		local c = CS.new()
		local n1 = c:node("n1")
		local n2 = c:node("n2")
		c:voltage_source("V1", n1, 0, 6)
		c:resistor("R1", n1, n2, 200)
		c:resistor("R2", n2, 0, 400)
		c:resistor("R3", n2, 0, 400)
		local r = c:solve_dc()

		T.it("KCL at n2: current in = current out", function()
			-- Current in via R1
			local i_r1 = r:current("R1")
			-- Current out via R2 and R3
			local i_r2 = r:current("R2")
			local i_r3 = r:current("R3")
			-- At n2: i_r1 = i_r2 + i_r3
			near(i_r1, i_r2 + i_r3)
		end)
		T.it("V_n2 correct (parallel R2||R3 = 200Ω, total = 400Ω)", function()
			-- V_n1 = 6, effective from n1 to 0 is R1 + (R2||R3) = 200+200 = 400Ω
			-- V_n2 = 6 * (200/400) = 3V
			near(r:voltage("n2"), 3.0)
		end)
	end)

	-- -------------------------------------------------------------------------
	T.describe("wire (short circuit)", function()
		-- Connect n1 and n2 with a wire; both should be at same voltage
		local c = CS.new()
		local n1 = c:node("n1")
		local n2 = c:node("n2")
		c:voltage_source("V1", n1, 0, 7)
		c:wire("W1", n1, n2)
		c:resistor("R1", n2, 0, 100)
		local r = c:solve_dc()

		T.it("n1 and n2 are at same voltage", function()
			near(r:voltage("n1"), r:voltage("n2"))
		end)
		T.it("n2 = 7V (same as n1)", function()
			near(r:voltage("n2"), 7.0)
		end)
		T.it("current through R1 = 70mA", function()
			near(r:current("R1"), 0.07)
		end)
	end)

	-- -------------------------------------------------------------------------
	T.describe("parameter sweep", function()
		-- Sweep V1 from 1V to 5V; expect proportional n1 voltages
		local c = CS.new()
		local n1 = c:node("n1")
		c:voltage_source("V1", n1, 0, 1)
		c:resistor("R1", n1, 0, 100)
		local results = c:sweep("V1", "voltage", {1, 2, 3, 4, 5})

		T.it("sweep returns 5 results", function()
			T.eq(#results, 5)
		end)
		T.it("result[1].n1 = 1V", function()
			near(results[1]:voltage("n1"), 1.0)
		end)
		T.it("result[3].n1 = 3V", function()
			near(results[3]:voltage("n1"), 3.0)
		end)
		T.it("result[5].n1 = 5V", function()
			near(results[5]:voltage("n1"), 5.0)
		end)
		T.it("proportional currents", function()
			near(results[2]:current("R1"), 0.02)
			near(results[4]:current("R1"), 0.04)
		end)
		T.it("original circuit unchanged after sweep", function()
			local r = c:solve_dc()
			near(r:voltage("n1"), 1.0)
		end)
	end)

	-- -------------------------------------------------------------------------
	T.describe("convenience: voltage_divider", function()
		local out = CS.voltage_divider(10, 1000, 1000)

		T.it("returns circuit and result", function()
			T.ok(out.circuit ~= nil)
			T.ok(out.result ~= nil)
		end)
		T.it("midpoint n2 = 5V", function()
			near(out.result:voltage("n2"), 5.0)
		end)
		T.it("unequal divider ratio", function()
			local out2 = CS.voltage_divider(10, 1000, 4000)
			-- V_n2 = 10 * 4000/5000 = 8V
			near(out2.result:voltage("n2"), 8.0)
		end)
	end)

	-- -------------------------------------------------------------------------
	T.describe("convenience: wheatstone_bridge", function()
		T.it("balanced bridge: 0V across bridge nodes", function()
			-- Balanced when R1/R2 = R3/R4, i.e. R1*R4 = R2*R3
			-- R1=R2=R3=R4=1000Ω: perfectly balanced
			local out = CS.wheatstone_bridge(1000, 1000, 1000, 1000, 10)
			-- n2 and n3 should be at same voltage
			local vn2 = out.result:voltage("n2")
			local vn3 = out.result:voltage("n3")
			near(vn2, vn3)
			near(vn2 - vn3, 0.0)
		end)
		T.it("n2 = n3 = 5V when balanced with 10V supply", function()
			local out = CS.wheatstone_bridge(1000, 1000, 1000, 1000, 10)
			near(out.result:voltage("n2"), 5.0)
			near(out.result:voltage("n3"), 5.0)
		end)
		T.it("unbalanced bridge has nonzero differential", function()
			-- R1=100, R2=200, R3=100, R4=100 → unbalanced
			local out = CS.wheatstone_bridge(100, 200, 100, 100, 10)
			local vn2 = out.result:voltage("n2")
			local vn3 = out.result:voltage("n3")
			T.ok(math.abs(vn2 - vn3) > EPS)
		end)
	end)

	-- -------------------------------------------------------------------------
	T.describe("Thevenin equivalent", function()
		-- Simple circuit: V1=12V, R1=6Ω, R2=4Ω from n1 to n2 to ground
		-- Open circuit voltage at n2: Vth = 12 * 4/(6+4) = 4.8V
		-- Thevenin resistance from n2: R1||... with source zeroed = R1 in series? no:
		-- Zero V1 (short), seen from n2: R1 connects n1 to ground (short), R2 from n2 to 0
		-- Actually with V1 zeroed (short n1 to 0), Rth = R2 || R1 = 4||6 = 2.4Ω
		local c = CS.new()
		local n1 = c:node("n1")
		local n2 = c:node("n2")
		c:voltage_source("V1", n1, 0, 12)
		c:resistor("R1", n1, n2, 6)
		c:resistor("R2", n2, 0, 4)
		local th = CS.thevenin(c, c._nodes["n2"], 0)

		T.it("Vth = 4.8V", function()
			near(th.vth, 4.8)
		end)
		T.it("Rth = 2.4Ω", function()
			near(th.rth, 2.4)
		end)
	end)

	-- -------------------------------------------------------------------------
	T.describe("Norton equivalent", function()
		-- Same circuit as Thevenin: Vth=4.8, Rth=2.4 → In = 4.8/2.4 = 2A, Rn = 2.4Ω
		local c = CS.new()
		local n1 = c:node("n1")
		local n2 = c:node("n2")
		c:voltage_source("V1", n1, 0, 12)
		c:resistor("R1", n1, n2, 6)
		c:resistor("R2", n2, 0, 4)
		local nr = CS.norton(c, c._nodes["n2"], 0)

		T.it("Rn = 2.4Ω", function()
			near(nr.rn, 2.4)
		end)
		T.it("In = 2A", function()
			near(nr.in_, 2.0)
		end)
	end)

	-- -------------------------------------------------------------------------
	T.describe("result accessors", function()
		local c = CS.new()
		local n1 = c:node("n1")
		c:voltage_source("V1", n1, 0, 3)
		c:resistor("R1", n1, 0, 30)
		local r = c:solve_dc()

		T.it(":voltage() returns correct value", function()
			near(r:voltage("n1"), 3.0)
		end)
		T.it(":current() returns correct value", function()
			near(r:current("R1"), 0.1)
		end)
		T.it(":power() returns correct value", function()
			near(r:power("R1"), 0.3)
		end)
	end)

	-- -------------------------------------------------------------------------
	T.describe("two voltage sources in loop", function()
		-- V1=10V at n1, V2=3V at n2 (from n2 to n1), R1 between n1 and n2
		-- Net voltage across R1 = 10 - 3 = 7V, R1 = 7Ω → I = 1A
		local c = CS.new()
		local n1 = c:node("n1")
		local n2 = c:node("n2")
		c:voltage_source("V1", n1, 0, 10)
		c:voltage_source("V2", n2, 0, 3)
		c:resistor("R1", n1, n2, 7)
		local r = c:solve_dc()

		T.it("n1 = 10V", function()
			near(r:voltage("n1"), 10.0)
		end)
		T.it("n2 = 3V", function()
			near(r:voltage("n2"), 3.0)
		end)
		T.it("current through R1 = 1A", function()
			near(r:current("R1"), 1.0)
		end)
	end)

	-- -------------------------------------------------------------------------
	T.describe("node registration", function()
		local c = CS.new()
		local id1 = c:node("alpha")
		local id2 = c:node("beta")
		local id3 = c:node("alpha")  -- same name, same id

		T.it("distinct nodes get distinct ids", function()
			T.neq(id1, id2)
		end)
		T.it("same name returns same id", function()
			T.eq(id1, id3)
		end)
		T.it("node count reflects distinct nodes", function()
			T.eq(c._node_count, 2)
		end)
	end)

	-- -------------------------------------------------------------------------
	T.describe("mixed current and voltage sources", function()
		-- V1=5V at n1, I1=0.1A draining n2 to ground, R1=50Ω between n1 and n2
		-- V_n1 = 5V (fixed by source)
		-- current_source(name, np=0, nn=n2, 0.1): subtracts 0.1A from n2 (drains to ground)
		-- KCL at n2: (V_n1 - V_n2)/R1 - 0.1 = 0 → (5 - V_n2)/50 = 0.1 → V_n2 = 0V
		local c = CS.new()
		local n1 = c:node("n1")
		local n2 = c:node("n2")
		c:voltage_source("V1", n1, 0, 5)
		c:current_source("I1", 0, n2, 0.1)   -- drains 0.1A from n2 to ground
		c:resistor("R1", n1, n2, 50)
		local r = c:solve_dc()

		T.it("n1 = 5V", function()
			near(r:voltage("n1"), 5.0)
		end)
		T.it("n2 = 0V (current source drains exactly what R1 supplies)", function()
			-- R1 carries (5-0)/50 = 0.1A from n1 to n2; I1 drains 0.1A from n2
			near(r:voltage("n2"), 0.0)
		end)
		T.it("R1 current = 100mA", function()
			near(r:current("R1"), 0.1)
		end)
	end)

end)

T._summary()
