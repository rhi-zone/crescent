-- lib/logic_circuit/logic_circuit_test.lua

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T  = require("lib.test.assert")
local lc = require("lib.logic_circuit")

-- ── AND gate ──────────────────────────────────────────────────────────────────

T.describe("AND gate", function()
  local function make_and()
    local c = lc.circuit()
    c:input("A"); c:input("B")
    c:output("OUT")
    c:gate("g1", "AND", {"A","B"})
    c:connect("g1", "OUT")
    return c
  end

  T.it("0 AND 0 = 0", function()
    T.eq(make_and():eval({A=0,B=0}).OUT, 0)
  end)
  T.it("0 AND 1 = 0", function()
    T.eq(make_and():eval({A=0,B=1}).OUT, 0)
  end)
  T.it("1 AND 0 = 0", function()
    T.eq(make_and():eval({A=1,B=0}).OUT, 0)
  end)
  T.it("1 AND 1 = 1", function()
    T.eq(make_and():eval({A=1,B=1}).OUT, 1)
  end)
end)

-- ── OR gate ───────────────────────────────────────────────────────────────────

T.describe("OR gate", function()
  local function make_or()
    local c = lc.circuit()
    c:input("A"); c:input("B")
    c:output("OUT")
    c:gate("g1", "OR", {"A","B"})
    c:connect("g1", "OUT")
    return c
  end

  T.it("0 OR 0 = 0", function() T.eq(make_or():eval({A=0,B=0}).OUT, 0) end)
  T.it("0 OR 1 = 1", function() T.eq(make_or():eval({A=0,B=1}).OUT, 1) end)
  T.it("1 OR 0 = 1", function() T.eq(make_or():eval({A=1,B=0}).OUT, 1) end)
  T.it("1 OR 1 = 1", function() T.eq(make_or():eval({A=1,B=1}).OUT, 1) end)
end)

-- ── NOT gate ──────────────────────────────────────────────────────────────────

T.describe("NOT gate", function()
  local function make_not()
    local c = lc.circuit()
    c:input("A")
    c:output("OUT")
    c:gate("g1", "NOT", {"A"})
    c:connect("g1", "OUT")
    return c
  end

  T.it("NOT 0 = 1", function() T.eq(make_not():eval({A=0}).OUT, 1) end)
  T.it("NOT 1 = 0", function() T.eq(make_not():eval({A=1}).OUT, 0) end)
end)

-- ── XOR gate ──────────────────────────────────────────────────────────────────

T.describe("XOR gate", function()
  local function make_xor()
    local c = lc.circuit()
    c:input("A"); c:input("B")
    c:output("OUT")
    c:gate("g1", "XOR", {"A","B"})
    c:connect("g1", "OUT")
    return c
  end

  T.it("0 XOR 0 = 0", function() T.eq(make_xor():eval({A=0,B=0}).OUT, 0) end)
  T.it("0 XOR 1 = 1", function() T.eq(make_xor():eval({A=0,B=1}).OUT, 1) end)
  T.it("1 XOR 0 = 1", function() T.eq(make_xor():eval({A=1,B=0}).OUT, 1) end)
  T.it("1 XOR 1 = 0", function() T.eq(make_xor():eval({A=1,B=1}).OUT, 0) end)
end)

-- ── NAND gate (De Morgan: NAND(A,B) = NOT(AND(A,B))) ─────────────────────────

T.describe("NAND gate", function()
  local function make_nand()
    local c = lc.circuit()
    c:input("A"); c:input("B")
    c:output("OUT")
    c:gate("g1", "NAND", {"A","B"})
    c:connect("g1", "OUT")
    return c
  end

  T.it("0 NAND 0 = 1", function() T.eq(make_nand():eval({A=0,B=0}).OUT, 1) end)
  T.it("0 NAND 1 = 1", function() T.eq(make_nand():eval({A=0,B=1}).OUT, 1) end)
  T.it("1 NAND 0 = 1", function() T.eq(make_nand():eval({A=1,B=0}).OUT, 1) end)
  T.it("1 NAND 1 = 0", function() T.eq(make_nand():eval({A=1,B=1}).OUT, 0) end)

  -- De Morgan: NAND(A,B) = OR(NOT A, NOT B)
  T.it("NAND De Morgan parity", function()
    local demorgan = lc.circuit()
    demorgan:input("A"); demorgan:input("B")
    demorgan:output("OUT")
    demorgan:gate("na", "NOT", {"A"})
    demorgan:gate("nb", "NOT", {"B"})
    demorgan:gate("or1", "OR", {"na","nb"})
    demorgan:connect("or1", "OUT")

    local nand = make_nand()
    for _, pair in ipairs({{0,0},{0,1},{1,0},{1,1}}) do
      local A, B = pair[1], pair[2]
      T.eq(nand:eval({A=A,B=B}).OUT, demorgan:eval({A=A,B=B}).OUT)
    end
  end)
end)

-- ── NOR gate ──────────────────────────────────────────────────────────────────

T.describe("NOR gate", function()
  local function make_nor()
    local c = lc.circuit()
    c:input("A"); c:input("B")
    c:output("OUT")
    c:gate("g1", "NOR", {"A","B"})
    c:connect("g1", "OUT")
    return c
  end

  T.it("0 NOR 0 = 1", function() T.eq(make_nor():eval({A=0,B=0}).OUT, 1) end)
  T.it("0 NOR 1 = 0", function() T.eq(make_nor():eval({A=0,B=1}).OUT, 0) end)
  T.it("1 NOR 0 = 0", function() T.eq(make_nor():eval({A=1,B=0}).OUT, 0) end)
  T.it("1 NOR 1 = 0", function() T.eq(make_nor():eval({A=1,B=1}).OUT, 0) end)

  -- De Morgan: NOR(A,B) = AND(NOT A, NOT B)
  T.it("NOR De Morgan parity", function()
    local demorgan = lc.circuit()
    demorgan:input("A"); demorgan:input("B")
    demorgan:output("OUT")
    demorgan:gate("na", "NOT", {"A"})
    demorgan:gate("nb", "NOT", {"B"})
    demorgan:gate("and1", "AND", {"na","nb"})
    demorgan:connect("and1", "OUT")

    local nor = make_nor()
    for _, pair in ipairs({{0,0},{0,1},{1,0},{1,1}}) do
      local A, B = pair[1], pair[2]
      T.eq(nor:eval({A=A,B=B}).OUT, demorgan:eval({A=A,B=B}).OUT)
    end
  end)
end)

-- ── XNOR gate ─────────────────────────────────────────────────────────────────

T.describe("XNOR gate", function()
  local function make_xnor()
    local c = lc.circuit()
    c:input("A"); c:input("B")
    c:output("OUT")
    c:gate("g1", "XNOR", {"A","B"})
    c:connect("g1", "OUT")
    return c
  end

  T.it("0 XNOR 0 = 1", function() T.eq(make_xnor():eval({A=0,B=0}).OUT, 1) end)
  T.it("0 XNOR 1 = 0", function() T.eq(make_xnor():eval({A=0,B=1}).OUT, 0) end)
  T.it("1 XNOR 0 = 0", function() T.eq(make_xnor():eval({A=1,B=0}).OUT, 0) end)
  T.it("1 XNOR 1 = 1", function() T.eq(make_xnor():eval({A=1,B=1}).OUT, 1) end)

  -- XNOR De Morgan: XNOR(A,B) = NOT(XOR(A,B))
  T.it("XNOR = NOT XOR (De Morgan)", function()
    local not_xor = lc.circuit()
    not_xor:input("A"); not_xor:input("B")
    not_xor:output("OUT")
    not_xor:gate("x", "XOR", {"A","B"})
    not_xor:gate("n", "NOT", {"x"})
    not_xor:connect("n", "OUT")

    local xnor = make_xnor()
    for _, pair in ipairs({{0,0},{0,1},{1,0},{1,1}}) do
      local A, B = pair[1], pair[2]
      T.eq(xnor:eval({A=A,B=B}).OUT, not_xor:eval({A=A,B=B}).OUT)
    end
  end)
end)

-- ── Half adder ────────────────────────────────────────────────────────────────

T.describe("half adder", function()
  local function make_half_adder()
    local c = lc.circuit()
    c:input("A"); c:input("B")
    c:output("Sum"); c:output("Cout")
    c:gate("sum_g",  "XOR", {"A","B"})
    c:gate("cout_g", "AND", {"A","B"})
    c:connect("sum_g",  "Sum")
    c:connect("cout_g", "Cout")
    return c
  end

  T.it("0+0 = Sum=0, Cout=0", function()
    local r = make_half_adder():eval({A=0,B=0})
    T.eq(r.Sum, 0); T.eq(r.Cout, 0)
  end)
  T.it("0+1 = Sum=1, Cout=0", function()
    local r = make_half_adder():eval({A=0,B=1})
    T.eq(r.Sum, 1); T.eq(r.Cout, 0)
  end)
  T.it("1+0 = Sum=1, Cout=0", function()
    local r = make_half_adder():eval({A=1,B=0})
    T.eq(r.Sum, 1); T.eq(r.Cout, 0)
  end)
  T.it("1+1 = Sum=0, Cout=1", function()
    local r = make_half_adder():eval({A=1,B=1})
    T.eq(r.Sum, 0); T.eq(r.Cout, 1)
  end)
end)

-- ── Full adder truth table ────────────────────────────────────────────────────

T.describe("full adder truth table", function()
  local function make_full_adder()
    local c = lc.circuit()
    c:input("A"); c:input("B"); c:input("Cin")
    c:output("Sum"); c:output("Cout")
    c:gate("xor1", "XOR", {"A","B"})
    c:gate("xor2", "XOR", {"xor1","Cin"})
    c:gate("and1", "AND", {"A","B"})
    c:gate("and2", "AND", {"xor1","Cin"})
    c:gate("or1",  "OR",  {"and1","and2"})
    c:connect("xor2", "Sum")
    c:connect("or1",  "Cout")
    return c
  end

  -- Expected: {A, B, Cin, Sum, Cout}
  local expected = {
    {0,0,0, 0,0},
    {0,0,1, 1,0},
    {0,1,0, 1,0},
    {0,1,1, 0,1},
    {1,0,0, 1,0},
    {1,0,1, 0,1},
    {1,1,0, 0,1},
    {1,1,1, 1,1},
  }

  local fa = make_full_adder()
  for _, row in ipairs(expected) do
    local A,B,Cin,eSum,eCout = row[1],row[2],row[3],row[4],row[5]
    T.it(("A=%d B=%d Cin=%d → Sum=%d Cout=%d"):format(A,B,Cin,eSum,eCout), function()
      local r = fa:eval({A=A,B=B,Cin=Cin})
      T.eq(r.Sum,  eSum,  "Sum")
      T.eq(r.Cout, eCout, "Cout")
    end)
  end

  T.it("truth_table has 8 rows", function()
    local tt = fa:truth_table()
    T.eq(#tt, 8)
  end)

  T.it("truth_table rows match expected", function()
    local tt = fa:truth_table()
    for idx, row in ipairs(tt) do
      local e = expected[idx]
      T.eq(row.inputs.A,   e[1], "row "..idx.." A")
      T.eq(row.inputs.B,   e[2], "row "..idx.." B")
      T.eq(row.inputs.Cin, e[3], "row "..idx.." Cin")
      T.eq(row.outputs.Sum,  e[4], "row "..idx.." Sum")
      T.eq(row.outputs.Cout, e[5], "row "..idx.." Cout")
    end
  end)
end)

-- ── D flip-flop ───────────────────────────────────────────────────────────────

T.describe("D flip-flop", function()
  T.it("captures D=1 on rising edge", function()
    local ff = lc.d_flipflop()
    T.eq(ff:output(), 0, "initial Q=0")
    ff:tick(1, 0)  -- CLK low, no capture
    T.eq(ff:output(), 0, "CLK low, still 0")
    ff:tick(1, 1)  -- CLK rising edge, D=1 captured
    T.eq(ff:output(), 1, "after rising edge with D=1")
  end)

  T.it("holds value when CLK stays high", function()
    local ff = lc.d_flipflop()
    ff:tick(1, 1)  -- capture D=1
    T.eq(ff:output(), 1)
    ff:tick(0, 1)  -- CLK high (no edge), D=0; should NOT capture
    T.eq(ff:output(), 1, "hold: CLK not rising edge")
  end)

  T.it("captures D=0 on next rising edge", function()
    local ff = lc.d_flipflop()
    ff:tick(1, 1)  -- Q=1
    ff:tick(1, 0)  -- CLK falling
    ff:tick(0, 1)  -- rising edge, D=0 captured
    T.eq(ff:output(), 0, "Q captured D=0 on second rising edge")
  end)

  T.it("ignores D changes while CLK=0", function()
    local ff = lc.d_flipflop()
    ff:tick(1, 1)  -- Q=1
    ff:tick(0, 0)  -- CLK low: should hold
    T.eq(ff:output(), 1)
    ff:tick(1, 0)  -- still CLK low
    T.eq(ff:output(), 1)
  end)
end)

-- ── SR latch ──────────────────────────────────────────────────────────────────

T.describe("SR latch", function()
  T.it("S=1 R=0 sets Q=1", function()
    local sr = lc.sr_latch()
    sr:set(1, 0)
    T.eq(sr:output(), 1)
  end)

  T.it("hold: S=0 R=0 preserves Q", function()
    local sr = lc.sr_latch()
    sr:set(1, 0)    -- Q=1
    sr:set(0, 0)    -- hold
    T.eq(sr:output(), 1)
  end)

  T.it("S=0 R=1 resets Q=0", function()
    local sr = lc.sr_latch()
    sr:set(1, 0)    -- set
    sr:set(0, 1)    -- reset
    T.eq(sr:output(), 0)
  end)

  T.it("initial state Q=0", function()
    local sr = lc.sr_latch()
    T.eq(sr:output(), 0)
  end)
end)

-- ── gate_count ────────────────────────────────────────────────────────────────

T.describe("gate_count", function()
  T.it("counts gates correctly", function()
    local c = lc.circuit()
    c:input("A"); c:input("B")
    c:output("OUT")
    c:gate("g1", "AND", {"A","B"})
    c:gate("g2", "NOT", {"g1"})
    c:connect("g2", "OUT")
    T.eq(c:gate_count(), 2)
  end)

  T.it("full adder has 5 gates", function()
    local c = lc.circuit()
    c:input("A"); c:input("B"); c:input("Cin")
    c:output("Sum"); c:output("Cout")
    c:gate("xor1", "XOR", {"A","B"})
    c:gate("xor2", "XOR", {"xor1","Cin"})
    c:gate("and1", "AND", {"A","B"})
    c:gate("and2", "AND", {"xor1","Cin"})
    c:gate("or1",  "OR",  {"and1","and2"})
    c:connect("xor2", "Sum")
    c:connect("or1",  "Cout")
    T.eq(c:gate_count(), 5)
  end)
end)

-- ── critical_path ─────────────────────────────────────────────────────────────

T.describe("critical_path", function()
  T.it("single gate has depth 1", function()
    local c = lc.circuit()
    c:input("A"); c:input("B")
    c:output("OUT")
    c:gate("g1", "AND", {"A","B"})
    c:connect("g1", "OUT")
    T.eq(c:critical_path(), 1)
  end)

  T.it("two-gate chain has depth 2", function()
    local c = lc.circuit()
    c:input("A"); c:input("B")
    c:output("OUT")
    c:gate("g1", "AND", {"A","B"})
    c:gate("g2", "NOT", {"g1"})
    c:connect("g2", "OUT")
    T.eq(c:critical_path(), 2)
  end)

  T.it("full adder has critical path 3 (xor1→xor2→Sum, and1→or1→Cout not longer)", function()
    -- xor1 (depth 1) → xor2 (depth 2) = 2 for Sum
    -- and1 (depth 1) → or1 (depth 2) = 2 for Cout
    -- actually xor1 → and2 (depth 2) → or1 (depth 3) = 3 for Cout
    local c = lc.circuit()
    c:input("A"); c:input("B"); c:input("Cin")
    c:output("Sum"); c:output("Cout")
    c:gate("xor1", "XOR", {"A","B"})
    c:gate("xor2", "XOR", {"xor1","Cin"})
    c:gate("and1", "AND", {"A","B"})
    c:gate("and2", "AND", {"xor1","Cin"})
    c:gate("or1",  "OR",  {"and1","and2"})
    c:connect("xor2", "Sum")
    c:connect("or1",  "Cout")
    T.eq(c:critical_path(), 3)
  end)
end)

-- ── from_bool ─────────────────────────────────────────────────────────────────

T.describe("from_bool", function()
  T.it("AND expression", function()
    local c = lc.from_bool("A AND B")
    local r = c:eval({A=1, B=1})
    T.eq(r.OUT, 1)
    local r2 = c:eval({A=1, B=0})
    T.eq(r2.OUT, 0)
  end)

  T.it("OR expression", function()
    local c = lc.from_bool("A OR B")
    T.eq(c:eval({A=0,B=0}).OUT, 0)
    T.eq(c:eval({A=0,B=1}).OUT, 1)
  end)

  T.it("NOT expression", function()
    local c = lc.from_bool("NOT A")
    T.eq(c:eval({A=0}).OUT, 1)
    T.eq(c:eval({A=1}).OUT, 0)
  end)

  T.it("compound: (A AND B) OR (NOT A AND C)", function()
    local c = lc.from_bool("(A AND B) OR (NOT A AND C)")
    -- A=0, B=0, C=1 → (0) OR (1 AND 1)=1
    T.eq(c:eval({A=0,B=0,C=1}).OUT, 1)
    -- A=1, B=1, C=0 → (1 AND 1)=1 OR (0)=1
    T.eq(c:eval({A=1,B=1,C=0}).OUT, 1)
    -- A=0, B=1, C=0 → 0 OR 0 = 0
    T.eq(c:eval({A=0,B=1,C=0}).OUT, 0)
    -- A=1, B=0, C=1 → 0 OR 0 = 0
    T.eq(c:eval({A=1,B=0,C=1}).OUT, 0)
  end)
end)

-- ── Quine-McCluskey simplification ───────────────────────────────────────────

T.describe("Quine-McCluskey simplification", function()
  T.it("single variable: minterm {1} = A", function()
    local expr = lc.simplify_bool({ vars={"A"}, minterms={1} })
    T.eq(expr, "A")
  end)

  T.it("single variable: minterm {0} = NOT A", function()
    local expr = lc.simplify_bool({ vars={"A"}, minterms={0} })
    T.eq(expr, "NOT A")
  end)

  T.it("two variables: minterms {1,3} = B (A is don't-care)", function()
    -- AB: 00=0, 01=1, 10=2, 11=3. minterms {1,3} both have B=1 → B
    local expr = lc.simplify_bool({ vars={"A","B"}, minterms={1,3} })
    T.eq(expr, "B")
  end)

  T.it("two variables: minterms {0,1} = NOT A (B is don't-care)", function()
    -- AB: 00=0, 01=1. both have A=0 → NOT A
    local expr = lc.simplify_bool({ vars={"A","B"}, minterms={0,1} })
    T.eq(expr, "NOT A")
  end)

  T.it("tautology: all 4 minterms = 1", function()
    local expr = lc.simplify_bool({ vars={"A","B"}, minterms={0,1,2,3} })
    T.eq(expr, "1")
  end)

  T.it("empty minterms = 0", function()
    local expr = lc.simplify_bool({ vars={"A","B"}, minterms={} })
    T.eq(expr, "0")
  end)

  T.it("simplified expression evaluates correctly for minterms", function()
    -- 3-variable example: minterms {0,1,3,5,7}
    -- Result should be a valid boolean expression
    local vars = {"A","B","C"}
    local minterms = {0,1,3,5,7}
    local expr = lc.simplify_bool({ vars=vars, minterms=minterms })
    T.ok(type(expr) == "string" and #expr > 0, "got expression: " .. tostring(expr))
    -- Verify the simplified expression evaluates correctly on all 8 combos
    local c = lc.from_bool(expr)
    local minterm_set = {}
    for _, m in ipairs(minterms) do minterm_set[m] = true end
    for i = 0, 7 do
      local A = math.floor(i/4)%2
      local B = math.floor(i/2)%2
      local C = i%2
      local r = c:eval({A=A,B=B,C=C})
      local expected = minterm_set[i] and 1 or 0
      T.eq(r.OUT, expected, ("A=%d B=%d C=%d (minterm %d)"):format(A,B,C,i))
    end
  end)
end)
