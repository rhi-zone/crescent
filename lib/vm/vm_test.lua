-- lib/vm/vm_test.lua
-- Tests for the stack-based VM.

if not package.path:find("./?/init.lua", 1, true) then
  package.path = "./?/init.lua;" .. package.path
end

local T  = require("lib.test.assert")
local vm = require("lib.vm")

-- ---------------------------------------------------------------------------
-- Helper: build & run a program, return the machine
-- ---------------------------------------------------------------------------
local function run(instrs)
  local prog = vm.program(instrs)
  local m = vm.new(prog)
  m:run()
  return m
end

-- ---------------------------------------------------------------------------
-- PUSH / POP / DUP / SWAP / ROT
-- ---------------------------------------------------------------------------
T.describe("stack ops", function()
  T.it("PUSH single value", function()
    local m = run({ {op="PUSH", value=42}, {op="HALT"} })
    T.eq(m:top(), 42)
  end)

  T.it("PUSH multiple values — top is last pushed", function()
    local m = run({ {op="PUSH", value=1}, {op="PUSH", value=2}, {op="PUSH", value=3}, {op="HALT"} })
    T.eq(m:top(), 3)
  end)

  T.it("POP removes top", function()
    local m = run({ {op="PUSH", value=10}, {op="PUSH", value=20}, {op="POP"}, {op="HALT"} })
    T.eq(m:top(), 10)
    local s = m:stack()
    T.eq(#s, 1)
  end)

  T.it("DUP duplicates top", function()
    local m = run({ {op="PUSH", value=7}, {op="DUP"}, {op="HALT"} })
    local s = m:stack()
    T.eq(#s, 2)
    T.eq(s[1], 7)
    T.eq(s[2], 7)
  end)

  T.it("SWAP exchanges top two", function()
    local m = run({ {op="PUSH", value=1}, {op="PUSH", value=2}, {op="SWAP"}, {op="HALT"} })
    local s = m:stack()
    T.eq(s[1], 2)
    T.eq(s[2], 1)
  end)

  T.it("ROT rotates top 3: (a b c) -> (b c a)", function()
    -- push 1 2 3 → stack bottom-to-top: 1 2 3
    -- after ROT: 2 3 1
    local m = run({
      {op="PUSH", value=1}, {op="PUSH", value=2}, {op="PUSH", value=3},
      {op="ROT"}, {op="HALT"},
    })
    local s = m:stack()
    T.eq(s[1], 2)
    T.eq(s[2], 3)
    T.eq(s[3], 1)
  end)

  T.it("stack() returns copy — mutation doesn't affect machine", function()
    local m = run({ {op="PUSH", value=5}, {op="HALT"} })
    local s = m:stack()
    s[1] = 99
    T.eq(m:top(), 5)
  end)

  T.it("stack underflow errors", function()
    T.throws(function()
      run({ {op="POP"}, {op="HALT"} })
    end)
  end)

  T.it("SWAP underflow errors", function()
    T.throws(function()
      run({ {op="PUSH", value=1}, {op="SWAP"}, {op="HALT"} })
    end)
  end)

  T.it("ROT underflow errors", function()
    T.throws(function()
      run({ {op="PUSH", value=1}, {op="PUSH", value=2}, {op="ROT"}, {op="HALT"} })
    end)
  end)
end)

-- ---------------------------------------------------------------------------
-- Arithmetic
-- ---------------------------------------------------------------------------
T.describe("arithmetic", function()
  T.it("ADD", function()
    local m = run({ {op="PUSH", value=3}, {op="PUSH", value=4}, {op="ADD"}, {op="HALT"} })
    T.eq(m:top(), 7)
  end)

  T.it("SUB", function()
    local m = run({ {op="PUSH", value=10}, {op="PUSH", value=3}, {op="SUB"}, {op="HALT"} })
    T.eq(m:top(), 7)
  end)

  T.it("MUL", function()
    local m = run({ {op="PUSH", value=6}, {op="PUSH", value=7}, {op="MUL"}, {op="HALT"} })
    T.eq(m:top(), 42)
  end)

  T.it("DIV", function()
    local m = run({ {op="PUSH", value=20}, {op="PUSH", value=4}, {op="DIV"}, {op="HALT"} })
    T.eq(m:top(), 5)
  end)

  T.it("MOD", function()
    local m = run({ {op="PUSH", value=17}, {op="PUSH", value=5}, {op="MOD"}, {op="HALT"} })
    T.eq(m:top(), 2)
  end)

  T.it("NEG", function()
    local m = run({ {op="PUSH", value=9}, {op="NEG"}, {op="HALT"} })
    T.eq(m:top(), -9)
  end)

  T.it("NEG of negative gives positive", function()
    local m = run({ {op="PUSH", value=-3}, {op="NEG"}, {op="HALT"} })
    T.eq(m:top(), 3)
  end)

  T.it("DIV by zero errors", function()
    T.throws(function()
      run({ {op="PUSH", value=1}, {op="PUSH", value=0}, {op="DIV"}, {op="HALT"} })
    end)
  end)

  T.it("MOD by zero errors", function()
    T.throws(function()
      run({ {op="PUSH", value=1}, {op="PUSH", value=0}, {op="MOD"}, {op="HALT"} })
    end)
  end)

  T.it("compound: (10+20)*2 == 60", function()
    local m = run({
      {op="PUSH", value=10}, {op="PUSH", value=20}, {op="ADD"},
      {op="PUSH", value=2}, {op="MUL"},
      {op="HALT"},
    })
    T.eq(m:top(), 60)
  end)
end)

-- ---------------------------------------------------------------------------
-- Comparison
-- ---------------------------------------------------------------------------
T.describe("comparison", function()
  T.it("EQ true", function()
    local m = run({ {op="PUSH", value=5}, {op="PUSH", value=5}, {op="EQ"}, {op="HALT"} })
    T.eq(m:top(), 1)
  end)

  T.it("EQ false", function()
    local m = run({ {op="PUSH", value=5}, {op="PUSH", value=6}, {op="EQ"}, {op="HALT"} })
    T.eq(m:top(), 0)
  end)

  T.it("NEQ true", function()
    local m = run({ {op="PUSH", value=3}, {op="PUSH", value=4}, {op="NEQ"}, {op="HALT"} })
    T.eq(m:top(), 1)
  end)

  T.it("NEQ false", function()
    local m = run({ {op="PUSH", value=3}, {op="PUSH", value=3}, {op="NEQ"}, {op="HALT"} })
    T.eq(m:top(), 0)
  end)

  T.it("LT true", function()
    local m = run({ {op="PUSH", value=2}, {op="PUSH", value=5}, {op="LT"}, {op="HALT"} })
    T.eq(m:top(), 1)
  end)

  T.it("LT false", function()
    local m = run({ {op="PUSH", value=5}, {op="PUSH", value=2}, {op="LT"}, {op="HALT"} })
    T.eq(m:top(), 0)
  end)

  T.it("LE equal", function()
    local m = run({ {op="PUSH", value=4}, {op="PUSH", value=4}, {op="LE"}, {op="HALT"} })
    T.eq(m:top(), 1)
  end)

  T.it("LE less", function()
    local m = run({ {op="PUSH", value=3}, {op="PUSH", value=4}, {op="LE"}, {op="HALT"} })
    T.eq(m:top(), 1)
  end)

  T.it("LE greater", function()
    local m = run({ {op="PUSH", value=5}, {op="PUSH", value=4}, {op="LE"}, {op="HALT"} })
    T.eq(m:top(), 0)
  end)

  T.it("GT true", function()
    local m = run({ {op="PUSH", value=9}, {op="PUSH", value=3}, {op="GT"}, {op="HALT"} })
    T.eq(m:top(), 1)
  end)

  T.it("GT false", function()
    local m = run({ {op="PUSH", value=1}, {op="PUSH", value=9}, {op="GT"}, {op="HALT"} })
    T.eq(m:top(), 0)
  end)

  T.it("GE equal", function()
    local m = run({ {op="PUSH", value=7}, {op="PUSH", value=7}, {op="GE"}, {op="HALT"} })
    T.eq(m:top(), 1)
  end)

  T.it("GE greater", function()
    local m = run({ {op="PUSH", value=8}, {op="PUSH", value=7}, {op="GE"}, {op="HALT"} })
    T.eq(m:top(), 1)
  end)

  T.it("GE less", function()
    local m = run({ {op="PUSH", value=6}, {op="PUSH", value=7}, {op="GE"}, {op="HALT"} })
    T.eq(m:top(), 0)
  end)
end)

-- ---------------------------------------------------------------------------
-- Logic
-- ---------------------------------------------------------------------------
T.describe("logic", function()
  T.it("AND 1 1 = 1", function()
    local m = run({ {op="PUSH", value=1}, {op="PUSH", value=1}, {op="AND"}, {op="HALT"} })
    T.eq(m:top(), 1)
  end)

  T.it("AND 1 0 = 0", function()
    local m = run({ {op="PUSH", value=1}, {op="PUSH", value=0}, {op="AND"}, {op="HALT"} })
    T.eq(m:top(), 0)
  end)

  T.it("AND 0 0 = 0", function()
    local m = run({ {op="PUSH", value=0}, {op="PUSH", value=0}, {op="AND"}, {op="HALT"} })
    T.eq(m:top(), 0)
  end)

  T.it("OR 0 0 = 0", function()
    local m = run({ {op="PUSH", value=0}, {op="PUSH", value=0}, {op="OR"}, {op="HALT"} })
    T.eq(m:top(), 0)
  end)

  T.it("OR 0 1 = 1", function()
    local m = run({ {op="PUSH", value=0}, {op="PUSH", value=1}, {op="OR"}, {op="HALT"} })
    T.eq(m:top(), 1)
  end)

  T.it("OR 1 1 = 1", function()
    local m = run({ {op="PUSH", value=1}, {op="PUSH", value=1}, {op="OR"}, {op="HALT"} })
    T.eq(m:top(), 1)
  end)

  T.it("NOT 0 = 1", function()
    local m = run({ {op="PUSH", value=0}, {op="NOT"}, {op="HALT"} })
    T.eq(m:top(), 1)
  end)

  T.it("NOT 1 = 0", function()
    local m = run({ {op="PUSH", value=1}, {op="NOT"}, {op="HALT"} })
    T.eq(m:top(), 0)
  end)

  T.it("NOT non-zero = 0", function()
    local m = run({ {op="PUSH", value=42}, {op="NOT"}, {op="HALT"} })
    T.eq(m:top(), 0)
  end)
end)

-- ---------------------------------------------------------------------------
-- LOAD / STORE
-- ---------------------------------------------------------------------------
T.describe("memory", function()
  T.it("STORE then LOAD round-trip", function()
    local m = run({
      {op="PUSH", value=99}, {op="STORE", name="x"},
      {op="LOAD", name="x"}, {op="HALT"},
    })
    T.eq(m:top(), 99)
    T.eq(m:env().x, 99)
  end)

  T.it("multiple variables", function()
    local m = run({
      {op="PUSH", value=1}, {op="STORE", name="a"},
      {op="PUSH", value=2}, {op="STORE", name="b"},
      {op="LOAD", name="a"}, {op="LOAD", name="b"}, {op="ADD"}, {op="HALT"},
    })
    T.eq(m:top(), 3)
  end)

  T.it("STORE overwrites previous value", function()
    local m = run({
      {op="PUSH", value=1}, {op="STORE", name="x"},
      {op="PUSH", value=2}, {op="STORE", name="x"},
      {op="LOAD", name="x"}, {op="HALT"},
    })
    T.eq(m:top(), 2)
  end)

  T.it("LOAD undefined variable errors", function()
    T.throws(function()
      run({ {op="LOAD", name="undefined_var"}, {op="HALT"} })
    end)
  end)
end)

-- ---------------------------------------------------------------------------
-- JMP (unconditional)
-- ---------------------------------------------------------------------------
T.describe("JMP", function()
  T.it("JMP skips instructions", function()
    local m = run({
      {op="JMP", target="skip"},
      {op="PUSH", value=999},   -- should be skipped
      {label="skip"},
      {op="PUSH", value=42},
      {op="HALT"},
    })
    -- stack should have only 42 (not 999)
    local s = m:stack()
    T.eq(#s, 1)
    T.eq(s[1], 42)
  end)
end)

-- ---------------------------------------------------------------------------
-- JMP_IF / JMP_IFNOT (conditional)
-- ---------------------------------------------------------------------------
T.describe("conditional jumps", function()
  T.it("JMP_IF taken when top is 1", function()
    local m = run({
      {op="PUSH", value=1},
      {op="JMP_IF", target="yes"},
      {op="PUSH", value=0},    -- not taken
      {op="HALT"},
      {label="yes"},
      {op="PUSH", value=1},
      {op="HALT"},
    })
    T.eq(m:top(), 1)
    T.eq(#m:stack(), 1)
  end)

  T.it("JMP_IF not taken when top is 0", function()
    local m = run({
      {op="PUSH", value=0},
      {op="JMP_IF", target="yes"},
      {op="PUSH", value=99},
      {op="HALT"},
      {label="yes"},
      {op="PUSH", value=0},
      {op="HALT"},
    })
    T.eq(m:top(), 99)
  end)

  T.it("JMP_IFNOT taken when top is 0", function()
    local m = run({
      {op="PUSH", value=0},
      {op="JMP_IFNOT", target="no"},
      {op="PUSH", value=999},  -- skipped
      {op="HALT"},
      {label="no"},
      {op="PUSH", value=7},
      {op="HALT"},
    })
    T.eq(m:top(), 7)
    T.eq(#m:stack(), 1)
  end)

  T.it("JMP_IFNOT not taken when top is 1", function()
    local m = run({
      {op="PUSH", value=1},
      {op="JMP_IFNOT", target="no"},
      {op="PUSH", value=55},
      {op="HALT"},
      {label="no"},
      {op="PUSH", value=0},
      {op="HALT"},
    })
    T.eq(m:top(), 55)
  end)

  T.it("JMP_IF pops the condition", function()
    -- after the conditional jump the condition value is gone
    local m = run({
      {op="PUSH", value=1},
      {op="JMP_IF", target="after"},
      {label="after"},
      {op="HALT"},
    })
    T.eq(#m:stack(), 0)
  end)
end)

-- ---------------------------------------------------------------------------
-- CALL / RET
-- ---------------------------------------------------------------------------
T.describe("CALL/RET", function()
  T.it("simple function call: double(10) = 20", function()
    local m = run({
      {op="PUSH", value=10},
      {op="CALL", target="double"},
      {op="HALT"},
      {label="double"},
      {op="PUSH", value=2},
      {op="MUL"},
      {op="RET"},
    })
    T.eq(m:top(), 20)
  end)

  T.it("nested call: double(double(5)) = 20", function()
    local m = run({
      {op="PUSH", value=5},
      {op="CALL", target="double"},
      {op="CALL", target="double"},
      {op="HALT"},
      {label="double"},
      {op="PUSH", value=2},
      {op="MUL"},
      {op="RET"},
    })
    T.eq(m:top(), 20)
  end)

  T.it("RET on empty call stack errors", function()
    T.throws(function()
      run({ {op="RET"} })
    end)
  end)

  T.it("call with local computation: add(3,4)=7", function()
    -- Convention: args pushed before CALL, function uses them
    local m = run({
      {op="PUSH", value=3},
      {op="PUSH", value=4},
      {op="CALL", target="add"},
      {op="HALT"},
      {label="add"},
      {op="ADD"},
      {op="RET"},
    })
    T.eq(m:top(), 7)
  end)
end)

-- ---------------------------------------------------------------------------
-- Loop program: sum 1+2+3+4+5 = 15
-- ---------------------------------------------------------------------------
T.describe("loop program", function()
  T.it("sum 1..5 via label loop = 15", function()
    local m = run({
      {op="PUSH", value=5},
      {op="STORE", name="n"},
      {op="PUSH", value=0},
      {op="STORE", name="sum"},
      {label="loop"},
      {op="LOAD", name="n"},
      {op="PUSH", value=0},
      {op="LE"},
      {op="JMP_IF", target="done"},
      {op="LOAD", name="sum"},
      {op="LOAD", name="n"},
      {op="ADD"},
      {op="STORE", name="sum"},
      {op="LOAD", name="n"},
      {op="PUSH", value=1},
      {op="SUB"},
      {op="STORE", name="n"},
      {op="JMP", target="loop"},
      {label="done"},
      {op="LOAD", name="sum"},
      {op="HALT"},
    })
    T.eq(m:top(), 15)
  end)
end)

-- ---------------------------------------------------------------------------
-- NOP / HALT / is_halted / pc
-- ---------------------------------------------------------------------------
T.describe("special ops", function()
  T.it("NOP does nothing", function()
    local m = run({
      {op="PUSH", value=5},
      {op="NOP"},
      {op="NOP"},
      {op="HALT"},
    })
    T.eq(m:top(), 5)
    T.eq(#m:stack(), 1)
  end)

  T.it("is_halted false before HALT", function()
    local prog = vm.program({ {op="PUSH", value=1}, {op="HALT"} })
    local m = vm.new(prog)
    T.ok(not m:is_halted())
    m:step()   -- executes PUSH
    T.ok(not m:is_halted())
    m:step()   -- executes HALT
    T.ok(m:is_halted())
  end)

  T.it("pc starts at 1", function()
    local prog = vm.program({ {op="HALT"} })
    local m = vm.new(prog)
    T.eq(m:pc(), 1)
  end)

  T.it("pc advances after step", function()
    local prog = vm.program({ {op="PUSH", value=1}, {op="HALT"} })
    local m = vm.new(prog)
    m:step()
    T.eq(m:pc(), 2)
  end)

  T.it("unknown opcode errors", function()
    T.throws(function()
      run({ {op="UNKNOWN_OP"} })
    end)
  end)
end)

-- ---------------------------------------------------------------------------
-- Step mode
-- ---------------------------------------------------------------------------
T.describe("step mode", function()
  T.it("step executes one instruction", function()
    local prog = vm.program({ {op="PUSH", value=1}, {op="PUSH", value=2}, {op="HALT"} })
    local m = vm.new(prog)
    m:step()
    T.eq(#m:stack(), 1)
    T.eq(m:top(), 1)
    m:step()
    T.eq(#m:stack(), 2)
    T.eq(m:top(), 2)
  end)

  T.it("steps(n) executes n instructions", function()
    local prog = vm.program({
      {op="PUSH", value=10},
      {op="PUSH", value=20},
      {op="PUSH", value=30},
      {op="HALT"},
    })
    local m = vm.new(prog)
    m:steps(2)
    T.eq(#m:stack(), 2)
    T.eq(m:top(), 20)
    T.ok(not m:is_halted())
  end)

  T.it("step returns false when halted", function()
    local prog = vm.program({ {op="HALT"} })
    local m = vm.new(prog)
    local cont = m:step()
    T.ok(not cont)
    T.ok(m:is_halted())
  end)

  T.it("step returns false on subsequent calls after halt", function()
    local prog = vm.program({ {op="HALT"} })
    local m = vm.new(prog)
    m:step()
    local cont = m:step()
    T.ok(not cont)
  end)

  T.it("steps stops early when halted", function()
    local prog = vm.program({ {op="HALT"}, {op="PUSH", value=99} })
    local m = vm.new(prog)
    m:steps(5)
    T.eq(#m:stack(), 0)   -- PUSH was never reached
    T.ok(m:is_halted())
  end)
end)

-- ---------------------------------------------------------------------------
-- Label resolution errors
-- ---------------------------------------------------------------------------
T.describe("label resolution", function()
  T.it("undefined label errors at program build time", function()
    T.throws(function()
      vm.program({ {op="JMP", target="nosuchlabel"} })
    end)
  end)
end)

-- ---------------------------------------------------------------------------
-- Print summary when run as a script
-- ---------------------------------------------------------------------------
local summary = T._summary()
local total = summary.pass + summary.fail
io.write(string.format("\n%d/%d assertions passed", summary.pass, total))
if summary.fail > 0 then
  io.write(string.format(", %d FAILED\n", summary.fail))
  for _, t in ipairs(summary.tests) do
    if not t.ok then
      io.write(string.format("  FAIL: %s\n", t.name))
      if t.err then
        io.write(string.format("        %s\n", t.err))
      end
    end
  end
  os.exit(1)
else
  io.write(" — all passed\n")
end
