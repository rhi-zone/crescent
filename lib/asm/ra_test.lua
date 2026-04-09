if not package.path:find("?/init.lua", 1, true) then
  package.path = package.path .. ";./?/init.lua"
end

local T  = require("lib.test.assert")
local ra = require("lib.asm.ra")

-- Small test register file: 3 GPR, 4 SIMD.
-- callee_saved: rbx=true (must save), rax/rcx=false.
-- aliases: ymm0=xmm0, ymm1=xmm1, ymm2=xmm2, ymm3=xmm3.
local function small_regfile()
  return {
    gpr  = { "rax", "rcx", "rbx" },
    simd = { "xmm0", "xmm1", "xmm2", "xmm3" },
    callee_saved = {
      rax = false, rcx = false, rbx = true,
      xmm0 = false, xmm1 = false, xmm2 = false, xmm3 = false,
    },
    aliases = {
      ymm0 = "xmm0", ymm1 = "xmm1", ymm2 = "xmm2", ymm3 = "xmm3",
    },
  }
end

T.describe("ra.allocate", function()

  T.it("empty intervals → empty result", function()
    local r = ra.allocate({}, small_regfile())
    T.eq(next(r.assignment), nil)
    T.eq(next(r.spills), nil)
    T.eq(#r.callee_saves, 0)
    T.eq(r.num_spill_slots, 0)
  end)

  T.it("single GPR interval → first register assigned", function()
    local intervals = { { id = 1, first = 0, last = 5, type = "gpr" } }
    local r = ra.allocate(intervals, small_regfile())
    -- Must get *some* register; no spill.
    T.ok(r.assignment[1] ~= nil, "should have an assignment")
    T.eq(r.spills[1], nil)
    T.eq(r.num_spill_slots, 0)
  end)

  T.it("single SIMD interval → first simd register assigned", function()
    local intervals = { { id = 1, first = 0, last = 5, type = "simd" } }
    local r = ra.allocate(intervals, small_regfile())
    T.ok(r.assignment[1] ~= nil)
    T.eq(r.spills[1], nil)
    T.eq(r.num_spill_slots, 0)
  end)

  T.it("two non-overlapping intervals → same register reused", function()
    -- v1: [0,3], v2: [5,8] — no overlap so v2 can reuse v1's register.
    local intervals = {
      { id = 1, first = 0, last = 3, type = "gpr" },
      { id = 2, first = 5, last = 8, type = "gpr" },
    }
    local r = ra.allocate(intervals, small_regfile())
    T.ok(r.assignment[1] ~= nil, "v1 assigned")
    T.ok(r.assignment[2] ~= nil, "v2 assigned")
    T.eq(r.assignment[1], r.assignment[2], "same register reused after expiry")
    T.eq(r.num_spill_slots, 0)
  end)

  T.it("two overlapping intervals → different registers", function()
    -- v1: [0,10], v2: [3,8] — overlap, need two registers.
    local intervals = {
      { id = 1, first = 0, last = 10, type = "gpr" },
      { id = 2, first = 3, last = 8,  type = "gpr" },
    }
    local r = ra.allocate(intervals, small_regfile())
    T.ok(r.assignment[1] ~= nil, "v1 assigned")
    T.ok(r.assignment[2] ~= nil, "v2 assigned")
    T.neq(r.assignment[1], r.assignment[2], "different registers")
    T.eq(r.num_spill_slots, 0)
  end)

  T.it("more overlapping intervals than registers → excess get spill slots", function()
    -- 3 GPR available, 4 simultaneous intervals → 1 must spill.
    local intervals = {
      { id = 1, first = 0, last = 20, type = "gpr" },
      { id = 2, first = 1, last = 20, type = "gpr" },
      { id = 3, first = 2, last = 20, type = "gpr" },
      { id = 4, first = 3, last = 20, type = "gpr" },
    }
    local r = ra.allocate(intervals, small_regfile())
    -- Count assignments and spills.
    local assigned_count = 0
    local spilled_count  = 0
    for i = 1, 4 do
      if r.assignment[i] ~= nil then assigned_count = assigned_count + 1 end
      if r.spills[i]     ~= nil then spilled_count  = spilled_count  + 1 end
    end
    T.eq(assigned_count, 3, "3 registers assigned")
    T.eq(spilled_count,  1, "1 interval spilled")
    T.eq(r.num_spill_slots, 1)
  end)

  T.it("spill chooses interval with largest last when register pressure hits", function()
    -- 1 GPR available. v1: [0,100] (very long), v2: [1,5] (short).
    -- When v2 arrives: no free reg; active = {v1 last=100}. v1.last > v2.last,
    -- so v1 is spilled and v2 gets the register.
    local regfile_1gpr = {
      gpr          = { "rax" },
      simd         = {},
      callee_saved = { rax = false },
      aliases      = {},
    }
    local intervals = {
      { id = 1, first = 0, last = 100, type = "gpr" },
      { id = 2, first = 1, last = 5,   type = "gpr" },
    }
    local r = ra.allocate(intervals, regfile_1gpr)
    -- v2 should be assigned "rax" (short interval, better to keep).
    T.eq(r.assignment[2], "rax", "short interval keeps the register")
    -- v1 (long) should be spilled.
    T.ok(r.spills[1] ~= nil, "long interval spilled")
    T.eq(r.num_spill_slots, 1)
  end)

  T.it("spill current when all active have shorter last", function()
    -- 1 GPR. v1: [0,3] (expires before v2 ends), v2: [1,10] long.
    -- When v3 [2,20] arrives, active = {v1 last=3, v2 last=10} (but v1 expired at v2).
    -- Let's use a simpler case: v1:[0,5], v2:[2,20] arrive together, no free reg.
    -- Actually test: 1 reg, v1:[0,10], v2:[1,4]. v2 arrives, active={v1 last=10}.
    -- v1.last(10) > v2.last(4) → v1 spills, v2 gets register.
    -- Now add v3:[3,15]. v2 still live (last=4 >= 3). active={v2}. no free reg.
    -- spill candidate: v2 last=4. v2.last(4) < v3.last(15) → v3 spills itself.
    local regfile_1gpr = {
      gpr          = { "rax" },
      simd         = {},
      callee_saved = { rax = false },
      aliases      = {},
    }
    local intervals = {
      { id = 1, first = 0, last = 10, type = "gpr" },
      { id = 2, first = 1, last = 4,  type = "gpr" },
      { id = 3, first = 3, last = 15, type = "gpr" },
    }
    local r = ra.allocate(intervals, regfile_1gpr)
    -- v1 spilled (long), v2 gets reg, v3 spills itself (active interval has smaller last).
    T.ok(r.spills[1] ~= nil, "v1 spilled (long)")
    T.eq(r.assignment[2], "rax", "v2 assigned")
    T.ok(r.spills[3] ~= nil, "v3 spilled itself")
    T.eq(r.num_spill_slots, 2)
  end)

  T.it("callee-saved registers tracked", function()
    -- rbx is callee-saved. With 3 GPR intervals starting together, rbx will be assigned.
    local intervals = {
      { id = 1, first = 0, last = 5, type = "gpr" },
      { id = 2, first = 0, last = 5, type = "gpr" },
      { id = 3, first = 0, last = 5, type = "gpr" },
    }
    local r = ra.allocate(intervals, small_regfile())
    -- All 3 registers used; rbx is one of them; it must appear in callee_saves.
    local rbx_assigned = false
    for _, phys in pairs(r.assignment) do
      if phys == "rbx" then rbx_assigned = true end
    end
    T.ok(rbx_assigned, "rbx assigned (only 3 GPRs)")
    local found = false
    for _, reg in ipairs(r.callee_saves) do
      if reg == "rbx" then found = true end
    end
    T.ok(found, "rbx in callee_saves")
  end)

  T.it("callee_saves is empty when only non-callee-saved regs used", function()
    -- Only 1 GPR (rax, not callee-saved).
    local regfile_rax = {
      gpr          = { "rax" },
      simd         = {},
      callee_saved = { rax = false },
      aliases      = {},
    }
    local intervals = { { id = 1, first = 0, last = 5, type = "gpr" } }
    local r = ra.allocate(intervals, regfile_rax)
    T.eq(#r.callee_saves, 0)
  end)

  T.it("aliasing: xmm0 assigned blocks ymm0 from simultaneous interval", function()
    -- 4 SIMD registers: xmm0, xmm1, xmm2, xmm3.
    -- aliases: ymm0=xmm0 (bidirectional in impl).
    -- Two simultaneous SIMD intervals: v1 gets xmm0 (first free).
    -- Then add ymm0 as an explicit entry in free pool to simulate the scenario.
    --
    -- We test a concrete case: regfile has xmm0 and ymm0 as separate pool entries
    -- with the alias relationship. v1 gets xmm0; v2 must NOT get ymm0 (it's blocked).
    local regfile_alias = {
      gpr          = {},
      simd         = { "xmm0", "ymm0" },  -- both in pool; aliases link them
      callee_saved = { xmm0 = false, ["ymm0"] = false },
      aliases      = { ["ymm0"] = "xmm0" },  -- ymm0 aliases xmm0
    }
    local intervals = {
      { id = 1, first = 0, last = 10, type = "simd" },
      { id = 2, first = 1, last = 10, type = "simd" },
    }
    local r = ra.allocate(intervals, regfile_alias)
    -- v1 gets xmm0 (first from pool end or start).
    -- v2 must NOT get ymm0 (blocked because xmm0 is active and ymm0 is its alias).
    local v1 = r.assignment[1]
    local v2 = r.assignment[2]
    T.ok(v1 ~= nil, "v1 assigned")
    -- If v1 = xmm0, then v2 must not be ymm0.
    -- If v1 = ymm0, then v2 must not be xmm0.
    if v1 == "xmm0" then
      T.neq(v2, "ymm0", "ymm0 blocked while xmm0 active")
      -- v2 gets a spill slot since no non-blocked register is available.
      T.ok(r.spills[2] ~= nil, "v2 spilled (ymm0 blocked)")
    elseif v1 == "ymm0" then
      T.neq(v2, "xmm0", "xmm0 blocked while ymm0 active")
      T.ok(r.spills[2] ~= nil, "v2 spilled (xmm0 blocked)")
    else
      T.fail(true, "unexpected v1 assignment: " .. tostring(v1))
    end
  end)

  T.it("aliasing: non-aliased simd regs still usable alongside aliased pair", function()
    -- 4 SIMD: xmm0, ymm0, xmm1, xmm2. Only xmm0<->ymm0 aliased.
    -- 3 simultaneous intervals: v1=xmm0, v2 blocked from ymm0 (gets xmm1), v3=xmm2.
    local regfile_partial = {
      gpr          = {},
      simd         = { "xmm0", "ymm0", "xmm1", "xmm2" },
      callee_saved = { xmm0=false, ["ymm0"]=false, xmm1=false, xmm2=false },
      aliases      = { ["ymm0"] = "xmm0" },
    }
    local intervals = {
      { id = 1, first = 0, last = 10, type = "simd" },
      { id = 2, first = 1, last = 10, type = "simd" },
      { id = 3, first = 2, last = 10, type = "simd" },
    }
    local r = ra.allocate(intervals, regfile_partial)
    -- All three must be assigned (xmm0 or ymm0 for v1; the aliased one blocked;
    -- xmm1 and xmm2 available for v2 and v3).
    T.ok(r.assignment[1] ~= nil, "v1 assigned")
    T.ok(r.assignment[2] ~= nil, "v2 assigned")
    T.ok(r.assignment[3] ~= nil, "v3 assigned")
    T.eq(r.num_spill_slots, 0, "no spills when 3 usable regs available")
    -- All three different.
    T.neq(r.assignment[1], r.assignment[2])
    T.neq(r.assignment[1], r.assignment[3])
    T.neq(r.assignment[2], r.assignment[3])
  end)

  T.it("mixed gpr and simd intervals are independent", function()
    -- GPR and SIMD pools are separate; simultaneous intervals of each type
    -- should both be assignable.
    local intervals = {
      { id = 1, first = 0, last = 10, type = "gpr"  },
      { id = 2, first = 0, last = 10, type = "simd" },
    }
    local r = ra.allocate(intervals, small_regfile())
    T.ok(r.assignment[1] ~= nil, "gpr assigned")
    T.ok(r.assignment[2] ~= nil, "simd assigned")
    T.eq(r.num_spill_slots, 0)
  end)

  T.it("spill slot numbers are 1-indexed and unique", function()
    -- Force 4 spills from 3 GPRs with 6 simultaneous intervals.
    local intervals = {}
    for i = 1, 6 do
      intervals[i] = { id = i, first = 0, last = 10, type = "gpr" }
    end
    local r = ra.allocate(intervals, small_regfile())
    local slots = {}
    for _, slot in pairs(r.spills) do
      T.ok(slot >= 1, "slot is 1-indexed")
      slots[slot] = (slots[slot] or 0) + 1
    end
    -- Each slot number should appear at most once.
    for _, count in pairs(slots) do
      T.eq(count, 1, "slot numbers are unique")
    end
    T.eq(r.num_spill_slots, 3, "3 spill slots for 6 intervals minus 3 regs")
  end)

end)
